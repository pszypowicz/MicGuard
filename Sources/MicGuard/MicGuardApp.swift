import ServiceManagement
import SwiftUI

@main
struct MicGuardApp: App {
    init() {
        let args = CommandLine.arguments.dropFirst()
        if let command = args.first {
            Self.handleCLI(command: command, args: Array(args.dropFirst()))
            exit(0)
        }

        // Daemon mode
        log("MicGuard starting")

        let service = SMAppService.mainApp
        if service.status != .enabled {
            do {
                try service.register()
                log("Registered as login item")
            } catch {
                log("Failed to register as login item: \(error)")
            }
        }

        AudioMonitor.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
        } label: {
            Image(nsImage: MenuBarIcon.image(enabled: AudioMonitor.shared.isEnabled))
        }
        .menuBarExtraStyle(.window)
    }

    private static func handleCLI(command: String, args: [String]) {
        switch command {
        case "list":
            for device in AudioDevices.listInputDevices() {
                print(device.name)
            }
        case "current":
            if let device = AudioDevices.currentInputDevice() {
                print(device.name)
            }
        case "set":
            let name = args.joined(separator: " ")
            guard !name.isEmpty else {
                fputs("Usage: mic-guard set <device name>\n", stderr)
                exit(1)
            }
            let configDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/mic-guard")
            try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            try? name.write(to: configDir.appendingPathComponent("preferred-mic"), atomically: true, encoding: .utf8)
            if !AudioDevices.setInputDevice(name: name) {
                fputs("Failed to set input device to '\(name)'\n", stderr)
                exit(1)
            }
        case "enable":
            writeEnabledFile(true)
            DistributedNotificationCenter.default().postNotificationName(
                AudioMonitor.enabledChangedNotification, object: nil)
            print("enabled")
        case "disable":
            writeEnabledFile(false)
            DistributedNotificationCenter.default().postNotificationName(
                AudioMonitor.enabledChangedNotification, object: nil)
            print("disabled")
        case "status":
            let enabled = readEnabledFile()
            print(enabled ? "enabled" : "disabled")
        default:
            fputs("Usage: mic-guard [list|current|set <name>|enable|disable|status]\n", stderr)
            fputs("  No arguments: run as daemon\n", stderr)
            exit(1)
        }
    }
}

private func readEnabledFile() -> Bool {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mic-guard/enabled")
    guard let data = try? String(contentsOf: url, encoding: .utf8) else { return true }
    return data.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
}

private func writeEnabledFile(_ value: Bool) {
    let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mic-guard")
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    try? (value ? "1" : "0").write(
        to: configDir.appendingPathComponent("enabled"),
        atomically: true, encoding: .utf8)
}
