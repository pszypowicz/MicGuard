import CoreAudio
import Foundation

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(msg)\n".utf8))
}

@discardableResult
func shell(_ args: String...) -> String {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/mic-guard")
let prefFile = configDir.appendingPathComponent("preferred-mic")

func readPreference() -> String {
    if let data = try? String(contentsOf: prefFile, encoding: .utf8) {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }
    // No preference set — use current device
    let current = shell("SwitchAudioSource", "-t", "input", "-c")
    if !current.isEmpty {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? current.write(to: prefFile, atomically: true, encoding: .utf8)
        log("Initialized preference: \(current)")
    }
    return current
}

func currentInput() -> String {
    shell("SwitchAudioSource", "-t", "input", "-c")
}

func enforce() {
    let preferred = readPreference()
    let current = currentInput()
    guard !preferred.isEmpty else { return }
    if current != preferred {
        log("Input changed to '\(current)' — reverting to '\(preferred)'")
        shell("SwitchAudioSource", "-t", "input", "-s", preferred)
    } else {
        log("Input is already '\(current)' — no action")
    }
}

// Register CoreAudio listener
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

let status = AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject),
    &address,
    DispatchQueue.main
) { _, _ in
    enforce()
}

if status != noErr {
    log("Failed to register CoreAudio listener (status: \(status))")
    exit(1)
}

log("MicGuard started — watching default input device changes")
let _ = readPreference() // ensure config exists on startup
RunLoop.main.run()
