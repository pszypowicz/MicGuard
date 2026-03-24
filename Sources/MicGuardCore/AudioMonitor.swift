import CoreAudio
import Foundation
import Observation
import os

@Observable
@MainActor
public final class AudioMonitor {
    public static let shared = AudioMonitor()

    public var isEnabled: Bool = true {
        didSet {
            if !suppressConfigSideEffects {
                config.writeEnabled(isEnabled)
                debouncedPostStatusChanged()
            }
        }
    }
    public var mode: String = "auto" {
        didSet {
            if !suppressConfigSideEffects {
                config.writeMode(mode)
                debouncedPostStatusChanged()
            }
        }
    }
    public var preferredDevice: String = ""
    public var currentDevice: String = ""
    public var inputDevices: [(id: AudioDeviceID, name: String)] = []
    public var inputVolume: Int = 0

    private var volumeListenerDeviceID: AudioDeviceID?
    private var volumeListenerDeviceName: String?
    private var muteListenerDeviceID: AudioDeviceID?
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?

    var previousDeviceIDs: Set<AudioDeviceID> = []
    var lastDeviceListChange: CFAbsoluteTime = 0
    public var settleSeconds: TimeInterval = 5.0

    public static let statusChangedNotification = NSNotification.Name("com.pszypowicz.MicGuard.statusChanged")
    public static let requestStatusNotification = NSNotification.Name("com.pszypowicz.MicGuard.requestStatus")
    public static let toggleMuteNotification = NSNotification.Name("com.pszypowicz.MicGuard.toggleMute")
    public static let setVolumeNotification = NSNotification.Name("com.pszypowicz.MicGuard.setVolume")

    private var configWatcherSource: DispatchSourceFileSystemObject?
    private var suppressConfigSideEffects = false
    private var statusDebounceWork: DispatchWorkItem?
    private var preMuteVolume: Int = 100

    let audio: any AudioDeviceProviding
    let config: any ConfigProviding

    private init() {
        self.audio = LiveAudioDevices()
        self.config = LiveConfig()
    }

    init(audio: some AudioDeviceProviding, config: some ConfigProviding) {
        self.audio = audio
        self.config = config
    }

    public func start() {
        logger.info("MicGuard started [pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)]")
        suppressConfigSideEffects = true
        isEnabled = config.readEnabled()
        mode = config.readMode()
        suppressConfigSideEffects = false
        preferredDevice = readPreference()
        settleSeconds = config.readSettleSeconds()
        currentDevice = audio.currentInputDevice()?.name ?? ""

        startConfigWatcher()

        // Listen for status requests from external consumers
        DistributedNotificationCenter.default().addObserver(
            forName: Self.requestStatusNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.postStatusChanged()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Self.toggleMuteNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.toggleMute()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Self.setVolumeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let volumeStr = notification.userInfo?["volume"] as? String
            Task { @MainActor in
                guard let self,
                      let str = volumeStr,
                      let volume = Int(str) else { return }
                self.setVolume(volume)
            }
        }

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
            inputVolume = audio.inputVolume(for: device.id) ?? 0
            registerVolumeListener(for: device.id, name: device.name)
        }

        enforcePreferredOnStartup()

        postStatusChanged()
    }

    private func startConfigWatcher() {
        config.ensureConfigDir()
        let fd = open(Config.configDir.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else {
            logger.error("Failed to open config directory for watching")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.handleConfigChange()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        configWatcherSource = source
        logger.info("Watching config directory for changes")
    }

    private func handleConfigChange() {
        var changed = false

        let newEnabled = config.readEnabled()
        if isEnabled != newEnabled {
            suppressConfigSideEffects = true
            isEnabled = newEnabled
            suppressConfigSideEffects = false
            logger.info("Config watcher: enabled changed to \(newEnabled, privacy: .public)")
            changed = true
        }

        let newMode = config.readMode()
        if mode != newMode {
            suppressConfigSideEffects = true
            mode = newMode
            suppressConfigSideEffects = false
            logger.info("Config watcher: mode changed to '\(newMode, privacy: .public)'")
            changed = true
        }

        let newPreferred = config.readPreferredDevice()
        if preferredDevice != newPreferred {
            preferredDevice = newPreferred
            logger.info("Config watcher: preferred device changed to '\(newPreferred, privacy: .public)'")
            changed = true
        }

        if changed {
            if isEnabled && mode == "manual" {
                _ = enforceManual()
            }
            debouncedPostStatusChanged()
        }
    }

    public func readPreference() -> String {
        let stored = config.readPreferredDevice()
        if !stored.isEmpty { return stored }
        // No preference — use current device
        if let current = audio.currentInputDevice() {
            config.writePreferredDevice(current.name)
            logger.info("Initialized preference: \(current.name, privacy: .public)")
            return current.name
        }
        return ""
    }

    public func setPreferredDevice(name: String) {
        config.writePreferredDevice(name)
        preferredDevice = name
        if audio.setInputDevice(name: name) {
            currentDevice = name
            logger.info("Preferred device set to '\(name, privacy: .public)'")
        } else {
            logger.error("Failed to set input device to '\(name, privacy: .public)'")
        }
    }

    public func setMode(_ newMode: String) {
        mode = newMode
    }

    public func setSettleSeconds(_ seconds: TimeInterval) {
        settleSeconds = seconds
        config.writeSettleSeconds(seconds)
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

        // Only remove departed devices — new devices are acknowledged
        // in handleDefaultInputChanged after the policy decision.
        previousDeviceIDs.formIntersection(newIDs)
        inputDevices = newDevices

        // If current device disconnected, settle on whatever macOS picked
        if !newDevices.contains(where: { $0.name == currentDevice }),
           let device = audio.currentInputDevice() {
            logger.info("Current device '\(self.currentDevice, privacy: .public)' disconnected — falling back to '\(device.name, privacy: .public)'")
            previousDeviceIDs.insert(device.id)
            settleOnDevice(device)
        }

        debouncedPostStatusChanged()

        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.pszypowicz.MicGuard.devicesChanged"),
            object: nil
        )
    }

    func handleDefaultInputChanged() {
        guard let newDefault = audio.currentInputDevice(),
              newDefault.name != currentDevice else { return }

        let oldDevice = currentDevice
        let isKnown = previousDeviceIDs.contains(newDefault.id)
        logger.debug("DEFAULT_INPUT_CHANGED: '\(oldDevice, privacy: .public)' → '\(newDefault.name, privacy: .public)' [id=\(newDefault.id, privacy: .public), known=\(isKnown, privacy: .public)]")

        guard isEnabled, mode == "auto" else {
            if !isEnabled {
                previousDeviceIDs.insert(newDefault.id)
            }
            if isEnabled, mode == "manual" {
                let preferred = readPreference()
                if newDefault.name != preferred && !preferred.isEmpty
                    && inputDevices.contains(where: { $0.name == preferred }) {
                    logger.info("Manual mode: reverting to '\(preferred, privacy: .public)' (was '\(newDefault.name, privacy: .public)')")
                    if audio.setInputDevice(name: preferred) {
                        currentDevice = preferred
                        return
                    }
                }
            }
            settleOnDevice(newDefault)
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
            // Known device, devices settled — user switch via System Settings
            logger.info("User-initiated switch to '\(newDefault.name, privacy: .public)' — saving as preferred")
            preferredDevice = newDefault.name
            config.writePreferredDevice(newDefault.name)
            settleOnDevice(newDefault)
        } else {
            // New device OR within settle period — protect preferred
            let preferred = readPreference()
            if preferred == newDefault.name || preferred.isEmpty {
                logger.debug("Preferred device '\(newDefault.name, privacy: .public)' reconnected")
                settleOnDevice(newDefault)
            } else {
                logger.info("Protecting preferred '\(preferred, privacy: .public)' — reverting from '\(newDefault.name, privacy: .public)' (\(isNew ? "new device" : "settle period", privacy: .public))")
                revertHijack()
            }
        }
    }

    /// Accept the current device state and update all dependent state
    private func settleOnDevice(_ device: (id: AudioDeviceID, name: String)?) {
        if let device {
            currentDevice = device.name
            inputVolume = audio.inputVolume(for: device.id) ?? 0
            logger.debug("Settled on '\(device.name, privacy: .public)' [id=\(device.id, privacy: .public)]")
            if volumeListenerDeviceID != device.id {
                registerVolumeListener(for: device.id, name: device.name)
            }
        }
        debouncedPostStatusChanged()
    }

    /// Enforce preferred device on startup (both auto and manual modes).
    func enforcePreferredOnStartup() {
        guard isEnabled, !preferredDevice.isEmpty, currentDevice != preferredDevice,
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
                logger.info("Preferred device '\(preferred, privacy: .public)' is not connected — staying on '\(current.name, privacy: .public)'")
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
                logger.info("Preferred device '\(preferred, privacy: .public)' not connected — staying on '\(device.name, privacy: .public)'")
                settleOnDevice(device)
            }
            return
        }
        logger.info("Reverting to preferred '\(preferred, privacy: .public)'")
        currentDevice = preferred
        if let d = inputDevices.first(where: { $0.name == preferred }) {
            settleOnDevice((id: d.id, name: d.name))
        }
    }

    // MARK: - Volume/Mute Listeners

    private func registerVolumeListener(for deviceID: AudioDeviceID, name deviceName: String) {
        unregisterVolumeListener()

        // Check if device supports volume (use element 0 — wildcard isn't valid for HasProperty)
        var checkAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &checkAddress) else {
            logger.debug("'\(deviceName, privacy: .public)' (\(deviceID, privacy: .public)) does not support volume — skipping listener")
            return
        }

        // Listen on wildcard element to catch per-channel volume changes (elements 1, 2, …)
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementWildcard
        )
        let audioRef = self.audio
        let volumeHandler: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                if let vol = audioRef.inputVolume(for: deviceID), vol != self.inputVolume {
                    logger.debug("Volume changed to \(vol, privacy: .public)% on '\(deviceName, privacy: .public)'")
                    self.inputVolume = vol
                    self.debouncedPostStatusChanged()
                }
            }
        }
        self.volumeListenerBlock = volumeHandler
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID, &volumeAddress, DispatchQueue.main, volumeHandler
        )
        if status == noErr {
            volumeListenerDeviceID = deviceID
            volumeListenerDeviceName = deviceName
            logger.debug("Volume listener registered for '\(deviceName, privacy: .public)' (\(deviceID, privacy: .public))")
        } else {
            logger.error("Failed to register volume listener (status: \(status, privacy: .public))")
        }

        // Also listen for mute property changes (check with element 0, listen on wildcard)
        var muteCheckAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementWildcard
        )
        if AudioObjectHasProperty(deviceID, &muteCheckAddress) {
            let muteHandler: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    let vol = audioRef.inputVolume(for: deviceID) ?? self.inputVolume
                    guard vol != self.inputVolume else { return }
                    self.inputVolume = vol
                    logger.debug("Mute changed on '\(deviceName, privacy: .public)', volume now \(self.inputVolume, privacy: .public)%")
                    self.debouncedPostStatusChanged()
                }
            }
            self.muteListenerBlock = muteHandler
            let muteStatus = AudioObjectAddPropertyListenerBlock(
                deviceID, &muteAddress, DispatchQueue.main, muteHandler
            )
            if muteStatus == noErr {
                muteListenerDeviceID = deviceID
                logger.debug("Mute listener registered for '\(deviceName, privacy: .public)' (\(deviceID, privacy: .public))")
            } else {
                logger.error("Failed to register mute listener (status: \(muteStatus, privacy: .public))")
            }
        }
    }

    private func unregisterVolumeListener() {
        let savedName = volumeListenerDeviceName
        if let deviceID = volumeListenerDeviceID, let block = volumeListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
            let name = savedName ?? "device \(deviceID)"
            volumeListenerDeviceID = nil
            volumeListenerDeviceName = nil
            volumeListenerBlock = nil
            logger.debug("Volume listener unregistered from '\(name, privacy: .public)' (\(deviceID, privacy: .public))")
        }
        if let deviceID = muteListenerDeviceID, let block = muteListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
            let name = savedName ?? "device \(deviceID)"
            muteListenerDeviceID = nil
            muteListenerBlock = nil
            logger.debug("Mute listener unregistered from '\(name, privacy: .public)' (\(deviceID, privacy: .public))")
        }
    }

    // MARK: - Volume/Mute Control

    public func toggleMute() {
        guard let device = audio.currentInputDevice() else {
            logger.error("toggleMute: no current input device")
            return
        }

        // Always mute/unmute via volume — native mute flag alone doesn't
        // silence the mic on all devices (e.g. MacBook Pro Microphone).
        let currentVolume = audio.inputVolume(for: device.id) ?? 0
        if currentVolume > 0 {
            preMuteVolume = currentVolume
            _ = audio.setInputVolume(for: device.id, volume: 0)
            _ = audio.setInputMuted(for: device.id, muted: true)
            logger.info("toggleMute: muted (saved volume \(self.preMuteVolume, privacy: .public))")
        } else {
            _ = audio.setInputVolume(for: device.id, volume: preMuteVolume)
            _ = audio.setInputMuted(for: device.id, muted: false)
            logger.info("toggleMute: unmuted (restored volume \(self.preMuteVolume, privacy: .public))")
        }
    }

    public func setVolume(_ volume: Int) {
        guard let device = audio.currentInputDevice() else {
            logger.error("setVolume: no current input device")
            return
        }
        let clamped = min(max(volume, 0), 100)
        if audio.setInputVolume(for: device.id, volume: clamped) {
            logger.info("setVolume: set to \(clamped, privacy: .public)")
        } else {
            logger.error("setVolume: failed to set volume to \(clamped, privacy: .public)")
        }
        // If setting volume > 0 and device has native mute, also unmute
        if clamped > 0, audio.isInputMuted(for: device.id) == true {
            _ = audio.setInputMuted(for: device.id, muted: false)
        }
    }

    // MARK: - Status Notifications

    private func debouncedPostStatusChanged() {
        statusDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.postStatusChanged()
            }
        }
        statusDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    public func postStatusChanged() {
        statusDebounceWork?.cancel()

        // Build per-device status, sorted alphabetically
        var devices: [[String: Any]] = inputDevices
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { device in
                let vol = audio.inputVolume(for: device.id) ?? 0
                let muted = audio.isInputMuted(for: device.id) ?? false
                return [
                    "name": device.name,
                    "current": device.name == currentDevice,
                    "volume": vol,
                    "muted": muted,
                    "available": true,
                    "preferred": device.name == preferredDevice,
                ]
            }

        // If the preferred device is disconnected, append it as unavailable
        if !preferredDevice.isEmpty,
           !devices.contains(where: { ($0["name"] as? String) == preferredDevice }) {
            devices.append([
                "name": preferredDevice,
                "current": false,
                "volume": 0,
                "muted": false,
                "available": false,
                "preferred": true,
            ])
            devices.sort {
                let a = ($0["name"] as? String) ?? ""
                let b = ($1["name"] as? String) ?? ""
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        }

        let payload: [String: Any] = [
            "enabled": isEnabled,
            "mode": mode,
            "devices": devices,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("Failed to serialize status payload to JSON")
            return
        }

        let info: [String: String] = ["info": jsonString]
        logger.debug("Posting status notification: \(jsonString, privacy: .public)")
        DistributedNotificationCenter.default().postNotificationName(
            Self.statusChangedNotification,
            object: nil,
            userInfo: info,
            deliverImmediately: true
        )
    }
}
