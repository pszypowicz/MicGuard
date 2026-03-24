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
    var pendingBTHijack = false
    var hijackCorrelationWork: DispatchWorkItem?
    var revertingToPreferred = false

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
        suppressConfigSideEffects = true
        isEnabled = config.readEnabled()
        mode = config.readMode()
        suppressConfigSideEffects = false
        preferredDevice = readPreference()
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

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
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

    // MARK: - BT Hijack Detection

    func handleDeviceListChanged() {
        let newDevices = audio.listInputDevices()
        let newDefault = audio.currentInputDevice()
        let newIDs = Set(newDevices.map(\.id))
        let addedIDs = newIDs.subtracting(previousDeviceIDs)

        // Check if a new Bluetooth device appeared and is already the default
        if let defaultDevice = newDefault, isEnabled, mode == "auto" {
            for addedID in addedIDs {
                if audio.transportType(for: addedID) == "bluetooth" && addedID == defaultDevice.id {
                    let preferred = readPreference()
                    if preferred == defaultDevice.name || preferred.isEmpty {
                        logger.debug("Preferred bluetooth device '\(defaultDevice.name, privacy: .public)' reconnected")
                        break
                    }
                    // Potential BT hijack — defer revert until DEFAULT_INPUT_CHANGED confirms
                    logger.debug("BT hijack pending: '\(defaultDevice.name, privacy: .public)' took default from preferred '\(preferred, privacy: .public)'")
                    pendingBTHijack = true
                    hijackCorrelationWork?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        Task { @MainActor in
                            guard let self, self.pendingBTHijack else { return }
                            self.pendingBTHijack = false
                            self.hijackCorrelationWork = nil
                            logger.debug("BT hijack correlation timeout — reverting")
                            self.revertHijack()
                        }
                    }
                    hijackCorrelationWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)

                    previousDeviceIDs = newIDs
                    inputDevices = newDevices
                    // Don't settleOnDevice — keep currentDevice as-is so
                    // handleDefaultInputChanged's guard passes when it fires
                    DistributedNotificationCenter.default().postNotificationName(
                        NSNotification.Name("com.pszypowicz.MicGuard.devicesChanged"),
                        object: nil
                    )
                    return
                }
            }
        }

        previousDeviceIDs = newIDs
        inputDevices = newDevices
        if let device = newDefault {
            settleOnDevice(device)
        }

        // Post devicesChanged notification for UI updates
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.pszypowicz.MicGuard.devicesChanged"),
            object: nil
        )
    }

    func handleDefaultInputChanged() {
        let newDefault = audio.currentInputDevice()
        let newName = newDefault?.name ?? ""

        guard newName != currentDevice else { return }

        let oldDevice = currentDevice
        let transport = newDefault.map { audio.transportType(for: $0.id) } ?? "none"
        logger.debug("Default input changed: \(oldDevice, privacy: .public) → \(newName, privacy: .public) (\(transport, privacy: .public))")

        if !isEnabled {
            // Disabled — accept any change without enforcement
            pendingBTHijack = false
            hijackCorrelationWork?.cancel()
            hijackCorrelationWork = nil
            settleOnDevice(newDefault)
            return
        }

        // BT hijack confirmed — DEVICE_LIST_CHANGED flagged a new BT device as default,
        // now DEFAULT_INPUT_CHANGED arrived within the correlation window
        if pendingBTHijack {
            hijackCorrelationWork?.cancel()
            hijackCorrelationWork = nil
            pendingBTHijack = false
            logger.info("BT hijack confirmed — reverting")
            revertHijack()
            return
        }

        if mode == "auto" {
            if revertingToPreferred {
                revertingToPreferred = false
                let preferred = readPreference()
                if newName != preferred && !preferred.isEmpty
                    && inputDevices.contains(where: { $0.name == preferred }) {
                    logger.debug("Ignoring stale callback after BT hijack revert — re-enforcing '\(preferred, privacy: .public)'")
                    if audio.setInputDevice(name: preferred) {
                        currentDevice = preferred
                        return
                    }
                }
                settleOnDevice(newDefault)
            } else if let newDefault,
                      !previousDeviceIDs.contains(newDefault.id) {
                // Device connection event — DEFAULT_INPUT_CHANGED raced ahead of
                // DEVICE_LIST_CHANGED. Not a user switch — don't save as preferred.
                inputDevices = audio.listInputDevices()
                previousDeviceIDs = Set(inputDevices.map(\.id))
                let preferred = readPreference()
                if preferred == newName || preferred.isEmpty {
                    logger.debug("Preferred device '\(newName, privacy: .public)' reconnected (via DEFAULT_INPUT_CHANGED race)")
                    settleOnDevice(newDefault)
                } else if audio.transportType(for: newDefault.id) == "bluetooth" {
                    logger.debug("New BT device '\(newName, privacy: .public)' became default before DEVICE_LIST_CHANGED — treating as hijack")
                    revertHijack()
                } else {
                    logger.debug("New device '\(newName, privacy: .public)' connected (via DEFAULT_INPUT_CHANGED race) — accepting without saving as preferred")
                    settleOnDevice(newDefault)
                }
            } else {
                // User-initiated change — accept and save as new preferred
                logger.info("User-initiated switch to '\(newName, privacy: .public)' — saving as preferred")
                preferredDevice = newName
                config.writePreferredDevice(newName)
                settleOnDevice(newDefault)
            }
        } else {
            // Manual mode — always enforce preferred
            let preferred = readPreference()
            if newName != preferred && !preferred.isEmpty && inputDevices.contains(where: { $0.name == preferred }) {
                logger.info("Manual mode: reverting to '\(preferred, privacy: .public)' (was '\(newName, privacy: .public)')")
                if audio.setInputDevice(name: preferred) {
                    currentDevice = preferred
                    return // Another callback coming
                }
                logger.error("Failed to revert to preferred device '\(preferred, privacy: .public)'")
            }
            settleOnDevice(newDefault)
        }
    }

    /// Accept the current device state and update all dependent state
    private func settleOnDevice(_ device: (id: AudioDeviceID, name: String)?) {
        if let device {
            currentDevice = device.name
            inputVolume = audio.inputVolume(for: device.id) ?? 0
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

    /// Revert to the preferred device after a confirmed BT hijack.
    func revertHijack() {
        let preferred = readPreference()
        guard isEnabled, mode == "auto", !preferred.isEmpty,
              inputDevices.contains(where: { $0.name == preferred }) else {
            // Can't revert — accept current device
            if let device = audio.currentInputDevice() {
                logger.info("BT hijack: preferred device '\(preferred, privacy: .public)' not connected — staying on '\(device.name, privacy: .public)'")
                settleOnDevice(device)
            }
            return
        }
        logger.info("BT hijack: reverting to '\(preferred, privacy: .public)'")
        if audio.setInputDevice(name: preferred) {
            revertingToPreferred = true
            currentDevice = preferred
            if let prefDevice = inputDevices.first(where: { $0.name == preferred }) {
                settleOnDevice((id: prefDevice.id, name: prefDevice.name))
            }
        } else {
            logger.error("Failed to revert to preferred device '\(preferred, privacy: .public)'")
            if let device = audio.currentInputDevice() {
                settleOnDevice(device)
            }
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
