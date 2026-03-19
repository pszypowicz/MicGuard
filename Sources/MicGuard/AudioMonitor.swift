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

    static let statusChangedNotification = NSNotification.Name("com.pszypowicz.MicGuard.statusChanged")
    static let requestStatusNotification = NSNotification.Name("com.pszypowicz.MicGuard.requestStatus")

    private var configWatcherSource: DispatchSourceFileSystemObject?
    private var suppressEnabledSideEffects = false
    private var statusDebounceWork: DispatchWorkItem?

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
            let muteStatus = AudioObjectAddPropertyListenerBlock(
                deviceID, &muteAddress, DispatchQueue.main
            ) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let vol = AudioDevices.inputVolume(for: deviceID) {
                        logger.debug("Mute changed, volume now \(vol, privacy: .public)%")
                        self.inputVolume = vol
                        self.debouncedPostStatusChanged()
                    }
                }
            }
            if muteStatus == noErr {
                muteListenerDeviceID = deviceID
                logger.debug("Mute listener registered for device \(deviceID, privacy: .public)")
            } else {
                logger.error("Failed to register mute listener (status: \(muteStatus, privacy: .public))")
            }
        }
    }

    private func unregisterVolumeListener() {
        if let deviceID = volumeListenerDeviceID {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, { _, _ in })
            volumeListenerDeviceID = nil
            logger.debug("Volume listener unregistered from device \(deviceID, privacy: .public)")
        }
        if let deviceID = muteListenerDeviceID {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, { _, _ in })
            muteListenerDeviceID = nil
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

    func postStatusChanged() {
        let info: [String: String] = [
            "enabled": isEnabled ? "1" : "0",
            "device": currentDevice,
            "volume": "\(inputVolume)",
        ]
        logger.debug("Posting status notification: enabled=\(self.isEnabled ? "1" : "0", privacy: .public) device=\(self.currentDevice, privacy: .public) volume=\(self.inputVolume, privacy: .public)")
        DistributedNotificationCenter.default().postNotificationName(
            Self.statusChangedNotification,
            object: nil,
            userInfo: info,
            deliverImmediately: true
        )
    }
}

let logger = Logger(subsystem: "com.pszypowicz.MicGuard", category: "general")
