import CoreAudio
import Foundation
import Observation
import os

@Observable
@MainActor
final class AudioMonitor {
    static let shared = AudioMonitor()

    var isEnabled: Bool = true {
        didSet {
            if !suppressEnabledSideEffects {
                Config.writeEnabled(isEnabled)
                _ = enforce()
                debouncedPostStatusChanged()
            }
        }
    }
    var preferredDevice: String = ""
    var currentDevice: String = ""
    var inputDevices: [(id: AudioDeviceID, name: String)] = []
    var inputVolume: Int = 0

    private var volumeListenerDeviceID: AudioDeviceID?
    private var volumeListenerDeviceName: String?
    private var muteListenerDeviceID: AudioDeviceID?
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?

    static let statusChangedNotification = NSNotification.Name("com.pszypowicz.MicGuard.statusChanged")
    static let requestStatusNotification = NSNotification.Name("com.pszypowicz.MicGuard.requestStatus")
    static let toggleMuteNotification = NSNotification.Name("com.pszypowicz.MicGuard.toggleMute")
    static let setVolumeNotification = NSNotification.Name("com.pszypowicz.MicGuard.setVolume")

    private var configWatcherSource: DispatchSourceFileSystemObject?
    private var suppressEnabledSideEffects = false
    private var statusDebounceWork: DispatchWorkItem?
    private var preMuteVolume: Int = 100

    private init() {}

    func start() {
        suppressEnabledSideEffects = true
        isEnabled = Config.readEnabled()
        suppressEnabledSideEffects = false
        preferredDevice = readPreference()
        currentDevice = AudioDevices.currentInputDevice()?.name ?? ""

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
                self?.handleDeviceChange(trigger: "default-device-changed")
            }
        }

        if status != noErr {
            logger.error("Failed to register CoreAudio listener (status: \(status, privacy: .public))")
        } else {
            logger.info("Watching default input device changes")
        }

        // Watch device list changes (registered once, lives for app lifetime)
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
                self?.handleDeviceChange(trigger: "device-list-changed")
            }
        }

        if devicesStatus != noErr {
            logger.error("Failed to register device list listener (status: \(devicesStatus, privacy: .public))")
        }

        // Enforce preferred device on launch and broadcast initial status
        inputDevices = AudioDevices.listInputDevices()
        if let device = AudioDevices.currentInputDevice() {
            currentDevice = device.name
            inputVolume = AudioDevices.inputVolume(for: device.id) ?? 0
            registerVolumeListener(for: device.id)
        }
        _ = enforce()
        postStatusChanged()
    }

    private func startConfigWatcher() {
        Config.ensureConfigDir()
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

        let newEnabled = Config.readEnabled()
        if isEnabled != newEnabled {
            suppressEnabledSideEffects = true
            isEnabled = newEnabled
            suppressEnabledSideEffects = false
            logger.info("Config watcher: enabled changed to \(newEnabled, privacy: .public)")
            changed = true
        }

        let newPreferred = Config.readPreferredDevice()
        if preferredDevice != newPreferred {
            preferredDevice = newPreferred
            logger.info("Config watcher: preferred device changed to '\(newPreferred, privacy: .public)'")
            changed = true
        }

        if changed {
            _ = enforce()
            debouncedPostStatusChanged()
        }
    }

    func readPreference() -> String {
        let stored = Config.readPreferredDevice()
        if !stored.isEmpty { return stored }
        // No preference — use current device
        if let current = AudioDevices.currentInputDevice() {
            Config.writePreferredDevice(current.name)
            logger.info("Initialized preference: \(current.name, privacy: .public)")
            return current.name
        }
        return ""
    }

    func setPreferredDevice(name: String) {
        Config.writePreferredDevice(name)
        preferredDevice = name
        if AudioDevices.setInputDevice(name: name) {
            currentDevice = name
            logger.info("Preferred device set to '\(name, privacy: .public)'")
        } else {
            logger.error("Failed to set input device to '\(name, privacy: .public)'")
        }
    }

    private func registerVolumeListener(for deviceID: AudioDeviceID) {
        unregisterVolumeListener()

        let deviceName = AudioDevices.currentInputDevice()?.name ?? "device \(deviceID)"

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
        let volumeHandler: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                if let vol = AudioDevices.inputVolume(for: deviceID), vol != self.inputVolume {
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
                    let vol = AudioDevices.inputVolume(for: deviceID) ?? self.inputVolume
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

    /// Enforces the preferred input device. Returns `true` if it changed the device
    /// (meaning another CoreAudio callback is coming), `false` if settled.
    @discardableResult
    private func enforce() -> Bool {
        if isEnabled {
            let preferred = readPreference()
            if !preferred.isEmpty, let current = AudioDevices.currentInputDevice() {
                if current.name != preferred {
                    // Only attempt revert if the preferred device is still connected
                    guard inputDevices.contains(where: { $0.name == preferred }) else {
                        logger.info("Preferred device '\(preferred, privacy: .public)' is not connected — staying on '\(current.name, privacy: .public)'")
                        return false
                    }
                    logger.info("Reverting to '\(preferred, privacy: .public)' (was '\(current.name, privacy: .public)')")
                    if AudioDevices.setInputDevice(name: preferred) {
                        currentDevice = preferred
                        return true
                    }
                    logger.error("Failed to set input device to '\(preferred, privacy: .public)'")
                    return false
                }
            }
        }
        return false
    }

    private func handleDeviceChange(trigger: String) {
        let oldDevice = currentDevice
        let newInput = AudioDevices.currentInputDevice()
        let newName = newInput?.name ?? ""
        let transport = newInput.map { AudioDevices.transportType(for: $0.id) } ?? "none"

        if newName != oldDevice {
            logger.debug("[\(trigger, privacy: .public)] \(oldDevice, privacy: .public) → \(newName, privacy: .public) (\(newInput?.id ?? 0, privacy: .public), \(transport, privacy: .public))")
        }

        inputDevices = AudioDevices.listInputDevices()
        currentDevice = newName
        if let device = newInput {
            inputVolume = AudioDevices.inputVolume(for: device.id) ?? 0
        }

        if enforce() {
            return  // changed device — another callback is coming, don't post yet
        }

        // Settled — re-read final state after enforce
        if let device = AudioDevices.currentInputDevice() {
            currentDevice = device.name
            inputVolume = AudioDevices.inputVolume(for: device.id) ?? 0
            if volumeListenerDeviceID != device.id {
                registerVolumeListener(for: device.id)
            }
        }

        debouncedPostStatusChanged()
    }

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

    func toggleMute() {
        guard let device = AudioDevices.currentInputDevice() else {
            logger.error("toggleMute: no current input device")
            return
        }

        // Always mute/unmute via volume — native mute flag alone doesn't
        // silence the mic on all devices (e.g. MacBook Pro Microphone).
        let currentVolume = AudioDevices.inputVolume(for: device.id) ?? 0
        if currentVolume > 0 {
            preMuteVolume = currentVolume
            _ = AudioDevices.setInputVolume(for: device.id, volume: 0)
            _ = AudioDevices.setInputMuted(for: device.id, muted: true)
            logger.info("toggleMute: muted (saved volume \(self.preMuteVolume, privacy: .public))")
        } else {
            _ = AudioDevices.setInputVolume(for: device.id, volume: preMuteVolume)
            _ = AudioDevices.setInputMuted(for: device.id, muted: false)
            logger.info("toggleMute: unmuted (restored volume \(self.preMuteVolume, privacy: .public))")
        }
    }

    func setVolume(_ volume: Int) {
        guard let device = AudioDevices.currentInputDevice() else {
            logger.error("setVolume: no current input device")
            return
        }
        let clamped = min(max(volume, 0), 100)
        if AudioDevices.setInputVolume(for: device.id, volume: clamped) {
            logger.info("setVolume: set to \(clamped, privacy: .public)")
        } else {
            logger.error("setVolume: failed to set volume to \(clamped, privacy: .public)")
        }
        // If setting volume > 0 and device has native mute, also unmute
        if clamped > 0, AudioDevices.isInputMuted(for: device.id) == true {
            _ = AudioDevices.setInputMuted(for: device.id, muted: false)
        }
    }

    func postStatusChanged() {
        statusDebounceWork?.cancel()

        // Build per-device status, sorted alphabetically
        var devices: [[String: Any]] = inputDevices
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { device in
                let vol = AudioDevices.inputVolume(for: device.id) ?? 0
                let muted = AudioDevices.isInputMuted(for: device.id) ?? false
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

let logger = Logger(subsystem: "com.pszypowicz.MicGuard", category: "general")
