import CoreAudio
import Foundation
import Observation

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
            log("Failed to register CoreAudio listener (status: \(status))")
        } else {
            log("Watching default input device changes")
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
            log("Failed to register device list listener (status: \(devicesStatus))")
        }

        // Enforce preferred device on launch (also broadcasts statusChanged)
        inputDevices = AudioDevices.listInputDevices()
        enforce()
    }

    private func startConfigWatcher() {
        Config.ensureConfigDir()
        let fd = open(Config.configDir.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else {
            log("Failed to open config directory for watching")
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
        log("Watching config directory for changes")
    }

    private func handleConfigChange() {
        let newEnabled = Config.readEnabled()
        if isEnabled != newEnabled {
            suppressEnabledSideEffects = true
            isEnabled = newEnabled
            suppressEnabledSideEffects = false
            log("Config watcher: enabled changed to \(newEnabled)")
            enforce()
        }

        let newPreferred = Config.readPreferredDevice()
        if preferredDevice != newPreferred {
            preferredDevice = newPreferred
            log("Config watcher: preferred device changed to '\(newPreferred)'")
            enforce()
        }
    }

    func readPreference() -> String {
        let stored = Config.readPreferredDevice()
        if !stored.isEmpty { return stored }
        // No preference — use current device
        if let current = AudioDevices.currentInputDevice() {
            Config.writePreferredDevice(current.name)
            log("Initialized preference: \(current.name)")
            return current.name
        }
        return ""
    }

    func setPreferredDevice(name: String) {
        Config.writePreferredDevice(name)
        preferredDevice = name
        if AudioDevices.setInputDevice(name: name) {
            currentDevice = name
            log("Preferred device set to '\(name)'")
        } else {
            log("Failed to set input device to '\(name)'")
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
            log("Device \(deviceID) does not support volume — skipping listener")
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
                    log("Volume changed to \(vol)%")
                    self.inputVolume = vol
                    self.postStatusChanged()
                }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID, &volumeAddress, DispatchQueue.main, volumeHandler
        )
        if status == noErr {
            volumeListenerDeviceID = deviceID
            log("Volume listener registered for device \(deviceID)")
        } else {
            log("Failed to register volume listener (status: \(status))")
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
                        log("Mute changed, volume now \(vol)%")
                        self.inputVolume = vol
                        self.postStatusChanged()
                    }
                }
            }
            if muteStatus == noErr {
                muteListenerDeviceID = deviceID
                log("Mute listener registered for device \(deviceID)")
            } else {
                log("Failed to register mute listener (status: \(muteStatus))")
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
            log("Volume listener unregistered from device \(deviceID)")
        }
        if let deviceID = muteListenerDeviceID {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, { _, _ in })
            muteListenerDeviceID = nil
            log("Mute listener unregistered from device \(deviceID)")
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
                    log("Input changed to '\(current.name)' — reverting to '\(preferred)'")
                    if !AudioDevices.setInputDevice(name: preferred) {
                        log("Failed to set input device to '\(preferred)'")
                    } else {
                        currentDevice = preferred
                    }
                } else {
                    log("Input is already '\(current.name)' — no action")
                }
            }
        }

        postStatusChanged()
    }

    func postStatusChanged() {
        let info: [String: String] = [
            "enabled": isEnabled ? "1" : "0",
            "device": currentDevice,
            "volume": "\(inputVolume)",
        ]
        log("Posting status: enabled=\(isEnabled ? "1" : "0") device=\(currentDevice) volume=\(inputVolume)")
        DistributedNotificationCenter.default().postNotificationName(
            Self.statusChangedNotification,
            object: nil,
            userInfo: info,
            deliverImmediately: true
        )
    }
}

nonisolated(unsafe) private let logDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    return formatter
}()

func log(_ msg: String) {
    let ts = logDateFormatter.string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(msg)\n".utf8))
}
