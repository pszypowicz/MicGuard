public import CoreAudio
import Foundation
import Observation
import os

@Observable
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
    /// Name of the current input device; empty when there is none.
    public var currentDevice: String = "" {
        didSet {
            guard currentDevice != oldValue else { return }
            followCurrentDevice()
            debouncedBroadcastStatus()
        }
    }
    public var inputDevices: [(id: AudioDeviceID, name: String)] = []

    var previousDeviceIDs: Set<AudioDeviceID> = []
    var lastDeviceListChange: CFAbsoluteTime = 0
    /// Read on every decision, so `defaults write` applies without a relaunch.
    var settleSeconds: TimeInterval { prefs.settleSeconds }

    let audio: any AudioDeviceProviding
    @ObservationIgnored let prefs: Preferences

    /// Receives each statusChanged userInfo payload.
    public typealias StatusPoster = @MainActor (_ userInfo: [String: String]) -> Void
    @ObservationIgnored private let postStatus: StatusPoster

    /// The device behind `currentDevice`, which the level listeners watch.
    @ObservationIgnored private var currentDeviceID: AudioDeviceID?
    @ObservationIgnored private var levelObservation: (any LevelObservation)?
    @ObservationIgnored private var statusDebounceWork: DispatchWorkItem?
    /// Default input and device list listeners, registered once by `start()`.
    @ObservationIgnored private var systemListeners: [PropertyListener] = []
    @ObservationIgnored private var started = false

    init(
        audio: some AudioDeviceProviding,
        prefs: Preferences,
        postStatus: @escaping StatusPoster = AudioMonitor.postDistributedStatus
    ) {
        self.audio = audio
        self.prefs = prefs
        self.postStatus = postStatus
        self.mode = prefs.mode
        self.preferredDevice = prefs.preferredDevice
    }

    public func start() {
        guard !started else { return }
        started = true
        logger.info("MicGuard started [pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)]")

        // Watch default input device changes
        do {
            systemListeners.append(try PropertyListener(
                AudioDevices.systemObject,
                AudioDevices.globalAddress(kAudioHardwarePropertyDefaultInputDevice)
            ) { [weak self] in
                logger.debug("[CoreAudio] DEFAULT_INPUT_CHANGED")
                Task { @MainActor in
                    self?.handleDefaultInputChanged()
                }
            })
            logger.info("Watching default input device changes")
        } catch {
            logger.error("Failed to register CoreAudio listener (status: \(error.status, privacy: .public))")
        }

        // Watch device list changes
        do {
            systemListeners.append(try PropertyListener(
                AudioDevices.systemObject,
                AudioDevices.globalAddress(kAudioHardwarePropertyDevices)
            ) { [weak self] in
                logger.debug("[CoreAudio] DEVICE_LIST_CHANGED")
                Task { @MainActor in
                    self?.handleDeviceListChanged()
                }
            })
        } catch {
            logger.error("Failed to register device list listener (status: \(error.status, privacy: .public))")
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

        // Listed devices count as known from here on. A takeover within
        // settleSeconds of this change is still reverted as system noise, and
        // a later switch to one of them is the user's choice.
        previousDeviceIDs = newIDs
        inputDevices = newDevices

        if !newDevices.contains(where: { $0.name == currentDevice }) {
            // Current device disconnected: settle on whatever macOS picked
            if let device = audio.currentInputDevice() {
                logger.info("Current device '\(self.currentDevice, privacy: .public)' disconnected - falling back to '\(device.name, privacy: .public)'")
                previousDeviceIDs.insert(device.id)
                currentDevice = device.name
            } else if !currentDevice.isEmpty {
                logger.info("Current device '\(self.currentDevice, privacy: .public)' disconnected - no input device left")
                currentDevice = ""
            }
        } else if followCurrentDevice() {
            // Same name under a new ID: the device was recreated
            debouncedBroadcastStatus()
        }

        // The preferred device is back but macOS kept another default, so no
        // DEFAULT_INPUT_CHANGED follows. Switch back here.
        let preferred = preferredDevice
        if !preferred.isEmpty, addedNames.contains(preferred),
           audio.currentInputDevice()?.name != preferred {
            if audio.setInputDevice(name: preferred) {
                logger.info("Preferred device '\(preferred, privacy: .public)' reconnected - switching back")
                currentDevice = preferred
            } else {
                logger.error("Failed to set input device to '\(preferred, privacy: .public)'")
            }
        }
    }

    func handleDefaultInputChanged() {
        guard let newDefault = audio.currentInputDevice() else { return }
        guard newDefault.name != currentDevice else {
            // Same name under a new ID: the device was reconnected or recreated
            if followCurrentDevice() { debouncedBroadcastStatus() }
            return
        }

        let oldDevice = currentDevice
        let isKnown = previousDeviceIDs.contains(newDefault.id)
        logger.debug("DEFAULT_INPUT_CHANGED: '\(oldDevice, privacy: .public)' → '\(newDefault.name, privacy: .public)' [id=\(newDefault.id, privacy: .public), known=\(isKnown, privacy: .public)]")

        // If the previous device has left the list, macOS is falling back after
        // a disconnect and reported it before DEVICE_LIST_CHANGED. Treat it as
        // that list change, so the fallback isn't saved as the user's choice.
        if !oldDevice.isEmpty,
           !audio.listInputDevices().contains(where: { $0.name == oldDevice }) {
            handleDeviceListChanged()
            return
        }

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
                if isNew {
                    logger.info("Protecting preferred '\(preferred, privacy: .public)' - reverting from '\(newDefault.name, privacy: .public)' (new device)")
                } else {
                    let settleLeft = settleSeconds - (CFAbsoluteTimeGetCurrent() - lastDeviceListChange)
                    logger.info("Protecting preferred '\(preferred, privacy: .public)' - reverting from '\(newDefault.name, privacy: .public)' (settle: \(settleLeft, format: .fixed(precision: 1), privacy: .public)s left)")
                }
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
    /// the current device name and its muted state. Muted means volume 0 or
    /// the hardware mute flag - state is read fresh on every post, never stored.
    func broadcastStatus() {
        statusDebounceWork?.cancel()
        var muted = false
        if let id = currentDeviceID {
            muted = audio.isInputMuted(for: id) == true || audio.inputVolume(for: id) == 0
        }
        logger.debug("broadcastStatus: device='\(self.currentDevice, privacy: .public)' muted=\(muted, privacy: .public)")
        postStatus(["device": currentDevice, "muted": muted ? "true" : "false"])
    }

    public static func postDistributedStatus(_ userInfo: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(
            MicGuardNotification.statusChanged,
            object: nil,
            userInfo: userInfo,
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

    /// Points the volume and mute listeners at the device behind
    /// `currentDevice`, so mute changes made elsewhere (System Settings,
    /// hardware buttons) show up in the status broadcast. The live default
    /// wins when its name matches, which follows a device that came back
    /// under a new ID. Otherwise the name is looked up in the device list,
    /// which covers a switch CoreAudio hasn't applied yet. Returns true if
    /// the device changed.
    @discardableResult
    private func followCurrentDevice() -> Bool {
        var id: AudioDeviceID?
        if !currentDevice.isEmpty {
            if let live = audio.currentInputDevice(), live.name == currentDevice {
                id = live.id
            } else {
                id = audio.listInputDevices().first { $0.name == currentDevice }?.id
            }
        }
        guard id != currentDeviceID else { return false }

        levelObservation?.cancel()
        levelObservation = nil
        currentDeviceID = id
        if let id {
            levelObservation = audio.observeLevel(of: id) { [weak self] in
                self?.debouncedBroadcastStatus()
            }
        }
        return true
    }
}
