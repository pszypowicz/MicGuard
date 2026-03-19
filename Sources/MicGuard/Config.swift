import Foundation
import os

enum Config {
    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mic-guard")
    static let prefFile = configDir.appendingPathComponent("preferred-mic")
    static let enabledFile = configDir.appendingPathComponent("enabled")

    static func ensureConfigDir() {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
    }

    static func readEnabled() -> Bool {
        guard let data = try? String(contentsOf: enabledFile, encoding: .utf8) else {
            return true // enabled by default
        }
        return data.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
    }

    static func writeEnabled(_ value: Bool) {
        ensureConfigDir()
        do {
            try (value ? "1" : "0").write(to: enabledFile, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write enabled state: \(error, privacy: .public)")
        }
        setFilePermissions(enabledFile)
    }

    static func readPreferredDevice() -> String {
        if let data = try? String(contentsOf: prefFile, encoding: .utf8) {
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    static func writePreferredDevice(_ name: String) {
        ensureConfigDir()
        do {
            try name.write(to: prefFile, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write preferred device: \(error, privacy: .public)")
        }
        setFilePermissions(prefFile)
    }

    private static func setFilePermissions(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
