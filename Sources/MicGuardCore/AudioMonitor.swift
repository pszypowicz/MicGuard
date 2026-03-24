import CoreAudio
import Foundation
import Observation
import os
@preconcurrency import XPC

@Observable
@MainActor
public final class AudioMonitor {
    public static let shared = AudioMonitor()

    public var isEnabled: Bool = true {
        didSet {
            config.writeEnabled(isEnabled)
            debouncedPostStatusChanged()
        }
    }
    public var mode: String = "auto" {
        didSet {
            config.writeMode(mode)
            debouncedPostStatusChanged()
        }
    }
    public var preferredDevice: String = ""
    public var currentDevice: String = ""
    public var inputDevices: [(id: AudioDeviceID, name: String)] = []
    public var inputVolume: Int = 0
    public var isMuted: Bool = false

    private var volumeListenerDeviceID: AudioDeviceID?
    private var volumeListenerDeviceName: String?
    private var muteListenerDeviceID: AudioDeviceID?
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?

    var previousDeviceIDs: Set<AudioDeviceID> = []
    var lastDeviceListChange: CFAbsoluteTime = 0
    public var settleSeconds: TimeInterval = 2.0


    private var statusDebounceWork: DispatchWorkItem?
    @ObservationIgnored
    private var xpcListener: XPCListener?
    var preMuteVolume: Int = 100

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
        reloadConfig()
        currentDevice = audio.currentInputDevice()?.name ?? ""

        // Listen for status requests from CLI and external consumers.
        // On request, re-read config (CLI may have written files) then broadcast.
        DistributedNotificationCenter.default().addObserver(
            forName: MicGuardNotification.requestStatus,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadConfig()
                self?.postStatusChanged()
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
            let hwVol = audio.inputVolume(for: device.id)
            let hwMute = audio.isInputMuted(for: device.id)
            inputVolume = hwVol ?? 0
            logger.debug("Startup: device='\(device.name, privacy: .public)' id=\(device.id, privacy: .public) hwVol=\(hwVol.map(String.init) ?? "nil", privacy: .public) hwMute=\(hwMute.map(String.init) ?? "nil", privacy: .public)")
            if inputVolume == 0 || hwMute == true {
                isMuted = true
                inputVolume = 0
                logger.info("Startup: hardware already muted on '\(device.name, privacy: .public)'")
            }
            registerVolumeListener(for: device.id, name: device.name)
        }

        enforcePreferredOnStartup()

        postStatusChanged()
    }

    /// Re-read all config files and update internal state.
    /// Called on startup, on `requestStatus` notification, and from the popover reload button.
    public func reloadConfig() {
        var changed = false

        let newEnabled = config.readEnabled()
        if isEnabled != newEnabled {
            isEnabled = newEnabled
            logger.info("reloadConfig: enabled changed to \(newEnabled, privacy: .public)")
            changed = true
        }

        let newMode = config.readMode()
        if mode != newMode {
            mode = newMode
            logger.info("reloadConfig: mode changed to '\(newMode, privacy: .public)'")
            changed = true
        }

        let newPreferred = config.readPreferredDevice()
        if newPreferred.isEmpty {
            // No stored preference — derive from current device
            let derived = readPreference()
            if preferredDevice != derived {
                preferredDevice = derived
                changed = true
            }
        } else if preferredDevice != newPreferred {
            preferredDevice = newPreferred
            logger.info("reloadConfig: preferred device changed to '\(newPreferred, privacy: .public)'")
            changed = true
        }

        let newSettle = config.readSettleSeconds()
        if settleSeconds != newSettle {
            settleSeconds = newSettle
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
            logger.info("Preferred device set to '\(name, privacy: .public)'")
            if let device = inputDevices.first(where: { $0.name == name }) {
                settleOnDevice(device)
            }
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
                let reason = isNew ? "new device" : "settle: \(String(format: "%.1f", settleSeconds - (CFAbsoluteTimeGetCurrent() - lastDeviceListChange)))s left"
                logger.info("Protecting preferred '\(preferred, privacy: .public)' — reverting from '\(newDefault.name, privacy: .public)' (\(reason, privacy: .public))")
                revertHijack()
                // Extend settle period — a revert means devices aren't stable yet
                lastDeviceListChange = CFAbsoluteTimeGetCurrent()
            }
        }
    }

    /// Accept the current device state and update all dependent state
    private func settleOnDevice(_ device: (id: AudioDeviceID, name: String)?) {
        if let device {
            currentDevice = device.name
            isMuted = false
            inputVolume = audio.inputVolume(for: device.id) ?? 0
            logger.debug("settleOnDevice: '\(device.name, privacy: .public)' [id=\(device.id, privacy: .public)] isMuted=\(self.isMuted, privacy: .public) inputVolume=\(self.inputVolume, privacy: .public)")
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

        // Check if device supports volume — try main element first, fall back to channel 1
        // (AirPods and some BT devices only expose volume on element 1).
        var checkAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if !AudioObjectHasProperty(deviceID, &checkAddress) {
            checkAddress.mElement = 1
        }
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
        let volumeHandler: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, deviceID == self.volumeListenerDeviceID else { return }
                self.handleExternalVolumeChange(deviceID: deviceID, deviceName: deviceName)
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
                    guard let self, deviceID == self.muteListenerDeviceID else { return }
                    self.handleExternalMuteChange(deviceID: deviceID, deviceName: deviceName)
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

    // MARK: - External Change Handling

    /// Called when CoreAudio reports a volume change on the current input device.
    func handleExternalVolumeChange(deviceID: AudioDeviceID, deviceName: String) {
        guard let vol = audio.inputVolume(for: deviceID), vol != inputVolume else { return }
        if isMuted && vol > 0 {
            // External unmute (e.g. CLI set volume > 0 while we thought muted)
            logger.info("Volume listener: external unmute detected vol=\(vol, privacy: .public)% on '\(deviceName, privacy: .public)'")
            isMuted = false
            inputVolume = vol
            debouncedPostStatusChanged()
        } else if isMuted {
            logger.debug("Volume listener: ignoring vol=\(vol, privacy: .public)% (software muted) on '\(deviceName, privacy: .public)'")
        } else if vol == 0 {
            // External mute (e.g. CLI set volume to 0)
            logger.info("Volume listener: external mute detected on '\(deviceName, privacy: .public)'")
            preMuteVolume = max(inputVolume, 1)
            isMuted = true
            inputVolume = 0
            debouncedPostStatusChanged()
        } else {
            logger.debug("Volume listener: vol=\(vol, privacy: .public)% on '\(deviceName, privacy: .public)'")
            inputVolume = vol
            debouncedPostStatusChanged()
        }
    }

    /// Called when CoreAudio reports a mute-flag change on the current input device.
    func handleExternalMuteChange(deviceID: AudioDeviceID, deviceName: String) {
        let hwMuted = audio.isInputMuted(for: deviceID) == true
        if hwMuted && !isMuted {
            // External mute via hw flag (e.g. CLI or system UI)
            let currentVol = audio.inputVolume(for: deviceID) ?? inputVolume
            preMuteVolume = max(currentVol, max(inputVolume, 1))
            isMuted = true
            inputVolume = 0
            logger.info("Mute listener: external hw mute on '\(deviceName, privacy: .public)', saved vol=\(self.preMuteVolume, privacy: .public)")
            debouncedPostStatusChanged()
        } else if !hwMuted && isMuted {
            // External unmute via hw flag — restore pre-mute volume
            let volOk = audio.setInputVolume(for: deviceID, volume: preMuteVolume)
            isMuted = false
            inputVolume = audio.inputVolume(for: deviceID) ?? preMuteVolume
            logger.info("Mute listener: external hw unmute on '\(deviceName, privacy: .public)', restored vol=\(self.preMuteVolume, privacy: .public) volOk=\(volOk, privacy: .public)")
            debouncedPostStatusChanged()
        }
    }

    // MARK: - XPC

    /// Start the XPC listener. Returns true if the Mach service is available
    /// (process was launched by launchd with the service registered).
    @discardableResult
    public func startXPCListener() -> Bool {
        do {
            xpcListener = try XPCListener(service: micGuardMachService, targetQueue: .main) { request in
                request.accept { [weak self] (req: MicGuardRequest) -> MicGuardResponse in
                    guard let self else { return .error(message: "Daemon shutting down") }
                    return MainActor.assumeIsolated {
                        self.handleRequest(req)
                    }
                }
            }
            logger.info("XPC listener started on '\(micGuardMachService, privacy: .public)'")
            return true
        } catch {
            logger.error("Failed to start XPC listener: \(error, privacy: .public)")
            return false
        }
    }

    /// Handle an XPC request from the CLI and return a response.
    public func handleRequest(_ request: MicGuardRequest) -> MicGuardResponse {
        switch request {
        case .ping:
            postStatusChanged()
            return .ok

        case .enable:
            isEnabled = true
            return .ok

        case .disable:
            isEnabled = false
            return .ok

        case .toggle:
            isEnabled = !isEnabled
            return .statusInfo(enabled: isEnabled, mode: mode)

        case .status:
            return .statusInfo(enabled: isEnabled, mode: mode)

        case .setDevice(let name):
            guard inputDevices.contains(where: { $0.name == name }) else {
                return .error(message: "Device '\(name)' not found")
            }
            setMode("manual")
            setPreferredDevice(name: name)
            return .ok

        case .setVolume(let volume):
            guard let device = audio.currentInputDevice() else {
                return .error(message: "No input device found")
            }
            guard audio.setInputVolume(for: device.id, volume: volume) else {
                return .error(message: "Failed to set volume")
            }
            inputVolume = volume
            if volume > 0 && isMuted {
                isMuted = false
            } else if volume == 0 && !isMuted {
                preMuteVolume = max(inputVolume, 1)
                isMuted = true
            }
            debouncedPostStatusChanged()
            return .ok

        case .mute:
            return toggleMute()

        case .list:
            return .deviceList(buildDeviceInfoList())

        case .current:
            return .device(name: currentDevice.isEmpty ? nil : currentDevice)
        }
    }

    /// Toggle mute on the current input device using the daemon's mute state.
    @discardableResult
    public func toggleMute() -> MicGuardResponse {
        guard let device = audio.currentInputDevice() else {
            return .error(message: "No input device found")
        }
        if isMuted {
            _ = audio.setInputMuted(for: device.id, muted: false)
            _ = audio.setInputVolume(for: device.id, volume: preMuteVolume)
            isMuted = false
            inputVolume = preMuteVolume
            logger.info("toggleMute: unmuted '\(device.name, privacy: .public)' vol=\(self.preMuteVolume, privacy: .public)")
        } else {
            preMuteVolume = max(inputVolume, 1)
            _ = audio.setInputVolume(for: device.id, volume: 0)
            _ = audio.setInputMuted(for: device.id, muted: true)
            isMuted = true
            inputVolume = 0
            logger.info("toggleMute: muted '\(device.name, privacy: .public)' saved vol=\(self.preMuteVolume, privacy: .public)")
        }
        postStatusChanged()
        return .ok
    }

    /// Build a sorted list of DeviceInfo for XPC and status broadcasting.
    public func buildDeviceInfoList() -> [DeviceInfo] {
        var devices: [DeviceInfo] = inputDevices
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { device in
                let isCurrent = device.name == currentDevice
                let vol = (isCurrent && isMuted) ? 0 : (audio.inputVolume(for: device.id) ?? 0)
                let muted = (isCurrent && isMuted) || (audio.isInputMuted(for: device.id) ?? false)
                return DeviceInfo(
                    name: device.name,
                    current: isCurrent,
                    volume: vol,
                    muted: muted,
                    available: true,
                    preferred: device.name == preferredDevice
                )
            }

        // If the preferred device is disconnected, append it as unavailable
        if !preferredDevice.isEmpty,
           !devices.contains(where: { $0.name == preferredDevice }) {
            devices.append(DeviceInfo(
                name: preferredDevice,
                current: false,
                volume: 0,
                muted: false,
                available: false,
                preferred: true
            ))
            devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return devices
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
        logger.debug("postStatusChanged: isMuted=\(self.isMuted, privacy: .public) inputVolume=\(self.inputVolume, privacy: .public) currentDevice='\(self.currentDevice, privacy: .public)'")

        let devices: [[String: Any]] = buildDeviceInfoList().map { d in
            [
                "name": d.name,
                "current": d.current,
                "volume": d.volume,
                "muted": d.muted,
                "available": d.available,
                "preferred": d.preferred,
            ]
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
            MicGuardNotification.statusChanged,
            object: nil,
            userInfo: info,
            deliverImmediately: true
        )
    }
}

