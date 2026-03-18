import CoreAudio
import Foundation

@MainActor
final class AudioMonitor {
    static let shared = AudioMonitor()

    private let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mic-guard")
    private let prefFile: URL

    private init() {
        prefFile = configDir.appendingPathComponent("preferred-mic")
    }

    func start() {
        _ = readPreference()

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

    private func enforce() {
        let preferred = readPreference()
        guard !preferred.isEmpty,
              let current = AudioDevices.currentInputDevice() else { return }

        if current.name != preferred {
            log("Input changed to '\(current.name)' — reverting to '\(preferred)'")
            if !AudioDevices.setInputDevice(name: preferred) {
                log("Failed to set input device to '\(preferred)'")
            }
        } else {
            log("Input is already '\(current.name)' — no action")
        }
    }
}

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(msg)\n".utf8))
}
