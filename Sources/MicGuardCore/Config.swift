import Foundation
import os

public enum Config {
    public static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/mic-guard")
    public static let prefFile = configDir.appending(component: "preferred-mic")
    public static let enabledFile = configDir.appending(component: "enabled")
    public static let modeFile = configDir.appending(component: "mode")
    public static let settleFile = configDir.appending(component: "settle-seconds")

    public static func ensureConfigDir() {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
    }

    public static func readEnabled() -> Bool {
        guard let data = try? String(contentsOf: enabledFile, encoding: .utf8) else {
            return true // enabled by default
        }
        return data.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
    }

    public static func writeEnabled(_ value: Bool) {
        ensureConfigDir()
        do {
            try (value ? "1" : "0").write(to: enabledFile, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write enabled state: \(error, privacy: .public)")
        }
        setFilePermissions(enabledFile)
    }

    public static func readPreferredDevice() -> String {
        if let data = try? String(contentsOf: prefFile, encoding: .utf8) {
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    public static func writePreferredDevice(_ name: String) {
        ensureConfigDir()
        do {
            try name.write(to: prefFile, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write preferred device: \(error, privacy: .public)")
        }
        setFilePermissions(prefFile)
    }

    public static func readMode() -> String {
        if let data = try? String(contentsOf: modeFile, encoding: .utf8) {
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "manual" { return "manual" }
        }
        return "auto"
    }

    public static func writeMode(_ value: String) {
        ensureConfigDir()
        do {
            try value.write(to: modeFile, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write mode: \(error, privacy: .public)")
        }
        setFilePermissions(modeFile)
    }

    public static let defaultSettleSeconds: TimeInterval = 5.0

    public static func readSettleSeconds() -> TimeInterval {
        guard let data = try? String(contentsOf: settleFile, encoding: .utf8),
              let value = TimeInterval(data.trimmingCharacters(in: .whitespacesAndNewlines)),
              value >= 1, value <= 30 else {
            return defaultSettleSeconds
        }
        return value
    }

    public static func writeSettleSeconds(_ seconds: TimeInterval) {
        ensureConfigDir()
        do {
            try String(Int(seconds)).write(to: settleFile, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write settle seconds: \(error, privacy: .public)")
        }
        setFilePermissions(settleFile)
    }

    private static func setFilePermissions(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }
}
