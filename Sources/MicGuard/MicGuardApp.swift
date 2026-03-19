import ServiceManagement
import SwiftUI

private func postTerminationNotification() {
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name("com.micguard.appTerminated"),
        object: nil
    )
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        postTerminationNotification()
    }
}

private func installSignalHandlers() {
    let handler: @convention(c) (Int32) -> Void = { _ in
        postTerminationNotification()
        exit(0)
    }
    signal(SIGTERM, handler)
    signal(SIGINT, handler)
}

@main
struct MicGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let args = CommandLine.arguments.dropFirst()
        if let command = args.first {
            Self.handleCLI(command: command, args: Array(args.dropFirst()))
            exit(0)
        }

        // Daemon mode
        log("MicGuard starting")
        installSignalHandlers()

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

    private static func readEnabledFile() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mic-guard/enabled")
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return true }
        return data.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
    }

    private static func writeEnabledFile(_ value: Bool) {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mic-guard")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? (value ? "1" : "0").write(
            to: configDir.appendingPathComponent("enabled"),
            atomically: true, encoding: .utf8)
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
            Self.writeEnabledFile(true)
            print("enabled")
        case "disable":
            Self.writeEnabledFile(false)
            print("disabled")
        case "status":
            let enabled = Self.readEnabledFile()
            print(enabled ? "enabled" : "disabled")
        case "ping":
            DistributedNotificationCenter.default().postNotificationName(
                AudioMonitor.requestStatusNotification, object: nil)
        default:
            fputs("Usage: mic-guard [list|current|set <name>|enable|disable|status|ping]\n", stderr)
            fputs("  No arguments: run as daemon\n", stderr)
            exit(1)
        }
    }
}

