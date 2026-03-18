import CoreAudio
import Foundation
import Observation

@Observable
@MainActor
final class AudioMonitor {
    static let shared = AudioMonitor()

    var isEnabled: Bool = true {
        didSet {
            writeEnabled(isEnabled)
        }
    }
    var preferredDevice: String = ""
    var currentDevice: String = ""

    private let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mic-guard")
    private let prefFile: URL
    private let enabledFile: URL

    static let enabledChangedNotification = NSNotification.Name("com.micguard.enabledChanged")

    private init() {
        prefFile = configDir.appendingPathComponent("preferred-mic")
        enabledFile = configDir.appendingPathComponent("enabled")
    }

    func start() {
        isEnabled = readEnabled()
        preferredDevice = readPreference()
        currentDevice = AudioDevices.currentInputDevice()?.name ?? ""

        // Listen for CLI-triggered enable/disable changes
        DistributedNotificationCenter.default().addObserver(
            forName: Self.enabledChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadEnabled()
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
    }

    func readEnabled() -> Bool {
        guard let data = try? String(contentsOf: enabledFile, encoding: .utf8) else {
            return true // enabled by default
        }
        return data.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
    }

    private func writeEnabled(_ value: Bool) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? (value ? "1" : "0").write(to: enabledFile, atomically: true, encoding: .utf8)
    }

    private func reloadEnabled() {
        let newValue = readEnabled()
        if isEnabled != newValue {
            isEnabled = newValue
        }
    }

    func readPreference() -> String {
        if let data = try? String(contentsOf: prefFile, encoding: .utf8) {
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        // No preference — use current device
        if let current = AudioDevices.currentInputDevice() {
            try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            try? current.name.write(to: prefFile, atomically: true, encoding: .utf8)
            log("Initialized preference: \(current.name)")
            return current.name
        }
        return ""
    }

    func setPreferredDevice(name: String) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? name.write(to: prefFile, atomically: true, encoding: .utf8)
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

        guard isEnabled else { return }

        let preferred = readPreference()
        guard !preferred.isEmpty,
              let current = AudioDevices.currentInputDevice() else { return }

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

        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.micguard.deviceChanged"),
            object: nil
        )
    }
}

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(msg)\n".utf8))
}
