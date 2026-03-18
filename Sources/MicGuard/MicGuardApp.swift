import AppKit
import ServiceManagement

@main
struct MicGuardApp {
    static func main() {
        let args = CommandLine.arguments.dropFirst()

        // CLI subcommands
        if let command = args.first {
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
                let name = args.dropFirst().joined(separator: " ")
                guard !name.isEmpty else {
                    fputs("Usage: mic-guard set <device name>\n", stderr)
                    exit(1)
                }
                if !AudioDevices.setInputDevice(name: name) {
                    fputs("Failed to set input device to '\(name)'\n", stderr)
                    exit(1)
                }
            default:
                fputs("Usage: mic-guard [list|current|set <name>]\n", stderr)
                fputs("  No arguments: run as daemon\n", stderr)
                exit(1)
            }
            return
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

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AudioMonitor.shared.start()
    }
}
