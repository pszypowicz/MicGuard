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
            }
            postStatusChanged()
        }
    }
    var preferredDevice: String = ""
    var currentDevice: String = ""
    var inputDevices: [(id: AudioDeviceID, name: String)] = []

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

    private func enforce() {
        // Always update current device
        currentDevice = AudioDevices.currentInputDevice()?.name ?? ""

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
        DistributedNotificationCenter.default().postNotificationName(
            Self.statusChangedNotification,
            object: nil
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
