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
                enforce()
            }
        }
    }
    var preferredDevice: String = ""
    var currentDevice: String = ""
    var inputDevices: [(id: AudioDeviceID, name: String)] = []
    var inputVolume: Int = 0

    private var volumeListenerDeviceID: AudioDeviceID?
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
            self?.enforce()
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
                self?.inputDevices = AudioDevices.listInputDevices()
            }
        }

        if devicesStatus != noErr {
            logger.error("Failed to register device list listener (status: \(devicesStatus, privacy: .public))")
        }

        // Enforce preferred device on launch (also broadcasts statusChanged)
        inputDevices = AudioDevices.listInputDevices()
        enforce()
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
        let newEnabled = Config.readEnabled()
        if isEnabled != newEnabled {
            suppressEnabledSideEffects = true
            isEnabled = newEnabled
            suppressEnabledSideEffects = false
            logger.info("Config watcher: enabled changed to \(newEnabled, privacy: .public)")
            enforce()
        }

        let newPreferred = Config.readPreferredDevice()
        if preferredDevice != newPreferred {
            preferredDevice = newPreferred
            logger.info("Config watcher: preferred device changed to '\(newPreferred, privacy: .public)'")
            enforce()
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

        // Check if device supports volume (use element 0 — wildcard isn't valid for HasProperty)
        var checkAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &checkAddress) else {
            logger.debug("Device \(deviceID, privacy: .public) does not support volume — skipping listener")
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
                if let vol = AudioDevices.inputVolume(for: deviceID) {
                    logger.debug("Volume changed to \(vol, privacy: .public)%")
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
            logger.debug("Volume listener registered for device \(deviceID, privacy: .public)")
        } else {
            logger.error("Failed to register volume listener (status: \(status, privacy: .public))")
        }

        // Also listen for mute property changes
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementWildcard
        )
        if AudioObjectHasProperty(deviceID, &muteAddress) {
            let muteHandler: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let vol = AudioDevices.inputVolume(for: deviceID) {
                        logger.debug("Mute changed, volume now \(vol, privacy: .public)%")
                        self.inputVolume = vol
                        self.debouncedPostStatusChanged()
                    }
                }
            }
            self.muteListenerBlock = muteHandler
            let muteStatus = AudioObjectAddPropertyListenerBlock(
                deviceID, &muteAddress, DispatchQueue.main, muteHandler
            )
            if muteStatus == noErr {
                muteListenerDeviceID = deviceID
                logger.debug("Mute listener registered for device \(deviceID, privacy: .public)")
            } else {
                logger.error("Failed to register mute listener (status: \(muteStatus, privacy: .public))")
            }
        }
    }

    private func unregisterVolumeListener() {
        if let deviceID = volumeListenerDeviceID, let block = volumeListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
            volumeListenerDeviceID = nil
            volumeListenerBlock = nil
            logger.debug("Volume listener unregistered from device \(deviceID, privacy: .public)")
        }
        if let deviceID = muteListenerDeviceID, let block = muteListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
            muteListenerDeviceID = nil
            muteListenerBlock = nil
            logger.debug("Mute listener unregistered from device \(deviceID, privacy: .public)")
        }
    }

    private func enforce() {
        // Always update current device and volume
        let currentInput = AudioDevices.currentInputDevice()
        currentDevice = currentInput?.name ?? ""

        if let device = currentInput {
            inputVolume = AudioDevices.inputVolume(for: device.id) ?? 0
            if volumeListenerDeviceID != device.id {
                registerVolumeListener(for: device.id)
            }
        }

        if isEnabled {
            let preferred = readPreference()
            if !preferred.isEmpty, let current = AudioDevices.currentInputDevice() {
                if current.name != preferred {
                    logger.info("Input changed to '\(current.name, privacy: .public)' — reverting to '\(preferred, privacy: .public)'")
                    if !AudioDevices.setInputDevice(name: preferred) {
                        logger.error("Failed to set input device to '\(preferred, privacy: .public)'")
                    } else {
                        currentDevice = preferred
                    }
                } else {
                    logger.debug("Input is already '\(current.name, privacy: .public)' — no action")
                }
            }
        }

        postStatusChanged()
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

        if let muted = AudioDevices.isInputMuted(for: device.id) {
            // Device has native mute property
            let newMuted = !muted
            if AudioDevices.setInputMuted(for: device.id, muted: newMuted) {
                logger.info("toggleMute: native mute set to \(newMuted, privacy: .public)")
            } else {
                logger.error("toggleMute: failed to set native mute")
            }
        } else {
            // No mute property — emulate via volume
            let currentVolume = AudioDevices.inputVolume(for: device.id) ?? 0
            if currentVolume > 0 {
                preMuteVolume = currentVolume
                _ = AudioDevices.setInputVolume(for: device.id, volume: 0)
                logger.info("toggleMute: soft-muted (saved volume \(self.preMuteVolume, privacy: .public))")
            } else {
                _ = AudioDevices.setInputVolume(for: device.id, volume: preMuteVolume)
                logger.info("toggleMute: soft-unmuted (restored volume \(self.preMuteVolume, privacy: .public))")
            }
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
        var isMuted = false
        if let device = AudioDevices.currentInputDevice() {
            if let nativeMute = AudioDevices.isInputMuted(for: device.id) {
                isMuted = nativeMute
            } else {
                isMuted = inputVolume == 0
            }
        }
        let info: [String: String] = [
            "enabled": isEnabled ? "1" : "0",
            "device": currentDevice,
            "volume": "\(inputVolume)",
            "muted": isMuted ? "1" : "0",
        ]
        logger.debug("Posting status notification: enabled=\(self.isEnabled ? "1" : "0", privacy: .public) device=\(self.currentDevice, privacy: .public) volume=\(self.inputVolume, privacy: .public) muted=\(isMuted ? "1" : "0", privacy: .public)")
        DistributedNotificationCenter.default().postNotificationName(
            Self.statusChangedNotification,
            object: nil,
            userInfo: info,
            deliverImmediately: true
        )
    }
}

let logger = Logger(subsystem: "com.pszypowicz.MicGuard", category: "general")
