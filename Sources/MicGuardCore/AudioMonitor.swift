import CoreAudio
import Foundation
import Observation
import os

@Observable
@MainActor
public final class AudioMonitor {
    public static let shared = AudioMonitor(audio: LiveAudioDevices(), prefs: Preferences())

    /// "auto" or "manual"; persisted across launches.
    public var mode: String {
        didSet { prefs.mode = mode }
    }
    /// The input device MicGuard protects; persisted across launches.
    public var preferredDevice: String {
        didSet { prefs.preferredDevice = preferredDevice }
    }
    public var currentDevice: String = "" {
        didSet {
            guard currentDevice != oldValue else { return }
            registerMuteListeners()
            debouncedBroadcastStatus()
        }
    }
    public var inputDevices: [(id: AudioDeviceID, name: String)] = []

    var previousDeviceIDs: Set<AudioDeviceID> = []
    var lastDeviceListChange: CFAbsoluteTime = 0
    let settleSeconds: TimeInterval

    let audio: any AudioDeviceProviding
    @ObservationIgnored let prefs: Preferences

    @ObservationIgnored private var volumeListenerDeviceID: AudioDeviceID?
    @ObservationIgnored private var muteListenerDeviceID: AudioDeviceID?
    @ObservationIgnored private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var muteListenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var statusDebounceWork: DispatchWorkItem?

    init(audio: some AudioDeviceProviding, prefs: Preferences) {
        self.audio = audio
        self.prefs = prefs
        self.mode = prefs.mode
        self.preferredDevice = prefs.preferredDevice
        self.settleSeconds = prefs.settleSeconds
    }

    public func start() {
        logger.info("MicGuard started [pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)]")

        // Watch default input device changes
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let audioRef = self.audio
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            let device = audioRef.currentInputDevice()
            logger.debug("[CoreAudio] DEFAULT_INPUT_CHANGED → '\(device?.name ?? "nil", privacy: .public)' [id=\(device?.id ?? 0, privacy: .public)]")
            Task { @MainActor in
                self?.handleDefaultInputChanged()
            }
        }

        if status != noErr {
            logger.error("Failed to register CoreAudio listener (status: \(status, privacy: .public))")
        } else {
            logger.info("Watching default input device changes")
        }

        // Watch device list changes
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            logger.debug("[CoreAudio] DEVICE_LIST_CHANGED")
            Task { @MainActor in
                self?.handleDeviceListChanged()
            }
        }

        if devicesStatus != noErr {
            logger.error("Failed to register device list listener (status: \(devicesStatus, privacy: .public))")
        }

        // Initialize state and enforce on launch
        inputDevices = audio.listInputDevices()
        previousDeviceIDs = Set(inputDevices.map(\.id))
        if let device = audio.currentInputDevice() {
            currentDevice = device.name
        }
        _ = readPreference()

        enforcePreferredOnStartup()

        broadcastStatus()
    }

    /// The preferred device, initializing it from the current device on first use.
    func readPreference() -> String {
        if !preferredDevice.isEmpty { return preferredDevice }
        if let current = audio.currentInputDevice() {
            preferredDevice = current.name
            logger.info("Initialized preference: \(current.name, privacy: .public)")
            return current.name
        }
        return ""
    }

    public func setPreferredDevice(name: String) {
        preferredDevice = name
        if audio.setInputDevice(name: name) {
            logger.info("Preferred device set to '\(name, privacy: .public)'")
            currentDevice = name
        } else {
            logger.error("Failed to set input device to '\(name, privacy: .public)'")
        }
    }

    public func setMode(_ newMode: String) {
        mode = newMode
        if newMode == "manual" {
            enforceManual()
        }
    }

    // MARK: - Device Change Detection

    func handleDeviceListChanged() {
        let newDevices = audio.listInputDevices()
        let newIDs = Set(newDevices.map(\.id))
        let addedNames = newIDs.subtracting(previousDeviceIDs)
            .compactMap { id in newDevices.first { $0.id == id }?.name }
        let removedIDs = previousDeviceIDs.subtracting(newIDs)

        if !addedNames.isEmpty || !removedIDs.isEmpty {
            logger.debug("DEVICE_LIST_CHANGED: added=\(addedNames, privacy: .public) removed=\(removedIDs.sorted().map { String($0) }, privacy: .public)")
        } else {
            logger.debug("DEVICE_LIST_CHANGED: no additions or removals")
        }

        lastDeviceListChange = CFAbsoluteTimeGetCurrent()

        // Only remove departed devices - new devices are acknowledged
        // in handleDefaultInputChanged after the policy decision.
        previousDeviceIDs.formIntersection(newIDs)
        inputDevices = newDevices

        // If current device disconnected, settle on whatever macOS picked
        if !newDevices.contains(where: { $0.name == currentDevice }),
           let device = audio.currentInputDevice() {
            logger.info("Current device '\(self.currentDevice, privacy: .public)' disconnected - falling back to '\(device.name, privacy: .public)'")
            previousDeviceIDs.insert(device.id)
            currentDevice = device.name
        }
    }

    func handleDefaultInputChanged() {
        guard let newDefault = audio.currentInputDevice(),
              newDefault.name != currentDevice else { return }

        let oldDevice = currentDevice
        let isKnown = previousDeviceIDs.contains(newDefault.id)
        logger.debug("DEFAULT_INPUT_CHANGED: '\(oldDevice, privacy: .public)' → '\(newDefault.name, privacy: .public)' [id=\(newDefault.id, privacy: .public), known=\(isKnown, privacy: .public)]")

        guard mode == "auto" else {
            // Manual mode: any switch away from a connected preferred device is reverted.
            let preferred = readPreference()
            if newDefault.name != preferred && !preferred.isEmpty
                && inputDevices.contains(where: { $0.name == preferred }) {
                logger.info("Manual mode: reverting to '\(preferred, privacy: .public)' (was '\(newDefault.name, privacy: .public)')")
                if audio.setInputDevice(name: preferred) {
                    currentDevice = preferred
                    return
                }
            }
            currentDevice = newDefault.name
            return
        }

        // Core decision: is this device new (just connected) or known (already present)?
        let isNew = !previousDeviceIDs.contains(newDefault.id)
        previousDeviceIDs.insert(newDefault.id)
        if isNew {
            inputDevices = audio.listInputDevices()
            previousDeviceIDs = Set(inputDevices.map(\.id))
        }

        let isSettled = CFAbsoluteTimeGetCurrent() - lastDeviceListChange >= settleSeconds

        if isSettled && !isNew {
            // Known device, devices settled - user switch via System Settings
            logger.info("User-initiated switch to '\(newDefault.name, privacy: .public)' - saving as preferred")
            preferredDevice = newDefault.name
            currentDevice = newDefault.name
        } else {
            // New device OR within settle period - protect preferred
            let preferred = readPreference()
            if preferred == newDefault.name || preferred.isEmpty {
                logger.debug("Preferred device '\(newDefault.name, privacy: .public)' reconnected")
                currentDevice = newDefault.name
            } else {
                let reason = isNew ? "new device" : "settle: \(String(format: "%.1f", settleSeconds - (CFAbsoluteTimeGetCurrent() - lastDeviceListChange)))s left"
                logger.info("Protecting preferred '\(preferred, privacy: .public)' - reverting from '\(newDefault.name, privacy: .public)' (\(reason, privacy: .public))")
                revertHijack()
                // Extend settle period - a revert means devices aren't stable yet
                lastDeviceListChange = CFAbsoluteTimeGetCurrent()
            }
        }
    }

    /// Enforce preferred device on startup (both auto and manual modes).
    func enforcePreferredOnStartup() {
        guard !preferredDevice.isEmpty, currentDevice != preferredDevice,
              inputDevices.contains(where: { $0.name == preferredDevice }) else { return }
        if audio.setInputDevice(name: preferredDevice) {
            currentDevice = preferredDevice
            logger.info("Startup: enforced preferred device '\(self.preferredDevice, privacy: .public)'")
        }
    }

    /// Enforce preferred device in manual mode. Returns true if device was changed.
    @discardableResult
    func enforceManual() -> Bool {
        let preferred = readPreference()
        guard !preferred.isEmpty, let current = audio.currentInputDevice() else { return false }
        if current.name != preferred {
            guard inputDevices.contains(where: { $0.name == preferred }) else {
                logger.info("Preferred device '\(preferred, privacy: .public)' is not connected - staying on '\(current.name, privacy: .public)'")
                return false
            }
            logger.info("Manual mode: enforcing '\(preferred, privacy: .public)' (was '\(current.name, privacy: .public)')")
            if audio.setInputDevice(name: preferred) {
                currentDevice = preferred
                return true
            }
            logger.error("Failed to set input device to '\(preferred, privacy: .public)'")
        }
        return false
    }

    /// Revert to the preferred device after a new device took over.
    func revertHijack() {
        let preferred = readPreference()
        guard !preferred.isEmpty,
              inputDevices.contains(where: { $0.name == preferred }),
              audio.setInputDevice(name: preferred) else {
            if let device = audio.currentInputDevice() {
                logger.info("Preferred device '\(preferred, privacy: .public)' not connected - staying on '\(device.name, privacy: .public)'")
                currentDevice = device.name
            }
            return
        }
        logger.info("Reverting to preferred '\(preferred, privacy: .public)'")
        currentDevice = preferred
    }

    // MARK: - Status Broadcast

    /// One-way telemetry for personal integrations (e.g. SketchyBar): posts
    /// the current device name and muted state. Muted means volume 0 or the
    /// hardware mute flag - state is read fresh on every post, never stored.
    func broadcastStatus() {
        statusDebounceWork?.cancel()
        var muted = false
        if let device = audio.currentInputDevice() {
            muted = audio.isInputMuted(for: device.id) == true
                || audio.inputVolume(for: device.id) == 0
        }
        logger.debug("broadcastStatus: device='\(self.currentDevice, privacy: .public)' muted=\(muted, privacy: .public)")
        DistributedNotificationCenter.default().postNotificationName(
            MicGuardNotification.statusChanged,
            object: nil,
            userInfo: ["device": currentDevice, "muted": muted ? "true" : "false"],
            deliverImmediately: true
        )
    }

    /// CoreAudio fires bursts of callbacks per event; coalesce them.
    private func debouncedBroadcastStatus() {
        statusDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.broadcastStatus()
            }
        }
        statusDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: - Volume/Mute Listeners

    /// Watch the current input device's volume and hardware mute flag so mute
    /// changes made elsewhere (System Settings, hardware buttons) show up in
    /// the status broadcast.
    private func registerMuteListeners() {
        unregisterMuteListeners()
        guard let device = audio.currentInputDevice() else { return }
        let deviceID = device.id

        // Check main element first, fall back to channel 1 (AirPods and some
        // BT devices only expose volume on element 1); listen on the wildcard
        // element to catch per-channel changes.
        var volumeCheck = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if !AudioObjectHasProperty(deviceID, &volumeCheck) {
            volumeCheck.mElement = 1
        }
        if AudioObjectHasProperty(deviceID, &volumeCheck) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            let handler: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.volumeListenerDeviceID == deviceID else { return }
                    self.debouncedBroadcastStatus()
                }
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, handler) == noErr {
                volumeListenerDeviceID = deviceID
                volumeListenerBlock = handler
            }
        }

        var muteCheck = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &muteCheck) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            let handler: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.muteListenerDeviceID == deviceID else { return }
                    self.debouncedBroadcastStatus()
                }
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, handler) == noErr {
                muteListenerDeviceID = deviceID
                muteListenerBlock = handler
            }
        }
    }

    private func unregisterMuteListeners() {
        if let deviceID = volumeListenerDeviceID, let block = volumeListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        }
        if let deviceID = muteListenerDeviceID, let block = muteListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        }
        volumeListenerDeviceID = nil
        volumeListenerBlock = nil
        muteListenerDeviceID = nil
        muteListenerBlock = nil
    }
}
