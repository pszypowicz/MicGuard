import ServiceManagement
import SwiftUI

private func postTerminationNotification() {
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name("com.pszypowicz.MicGuard.appTerminated"),
        object: nil
    )
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        postTerminationNotification()
    }
}

private func installSignalHandlers() {
    // Use DispatchSource for async-signal-safety instead of signal()
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigterm.setEventHandler {
        postTerminationNotification()
        exit(0)
    }
    sigterm.resume()

    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        postTerminationNotification()
        exit(0)
    }
    sigint.resume()

    // Ignore default signal handling so DispatchSource receives them
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)

    // Keep sources alive for app lifetime
    _signalSources = [sigterm, sigint]
}

nonisolated(unsafe) private var _signalSources: [any DispatchSourceSignal] = []

@main
struct MicGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let args = CommandLine.arguments.dropFirst()
        if let command = args.first {
            Self.handleCLI(command: command, args: Array(args.dropFirst()))
            exit(0)
        }

        // Daemon mode — ensure single instance via fcntl lock file
        Config.ensureConfigDir()
        let lockPath = Config.configDir.appendingPathComponent("lock").path
        let lockFD = open(lockPath, O_CREAT | O_WRONLY, 0o600)
        guard lockFD != -1 else {
            log("Could not create lock file — exiting")
            exit(1)
        }
        var lock = flock(
            l_start: 0, l_len: 0, l_pid: getpid(),
            l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET)
        )
        if fcntl(lockFD, F_SETLK, &lock) == -1 {
            // Query which process holds the lock
            var info = lock
            _ = fcntl(lockFD, F_GETLK, &info)
            log("Another instance is already running (PID \(info.l_pid)) — exiting")
            exit(0)
        }
        // lockFD intentionally kept open — kernel releases lock on exit/crash

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
        .menuBarExtraStyle(.menu)
    }

    private static let version: String = {
        let base = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev"
        #if DEBUG
        return "\(base) (\(BuildMetadata.gitHash) \(BuildMetadata.buildDate))"
        #else
        return "\(base) (\(BuildMetadata.gitHash))"
        #endif
    }()

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
            Config.writePreferredDevice(name)
            if !AudioDevices.setInputDevice(name: name) {
                fputs("Failed to set input device to '\(name)'\n", stderr)
                exit(1)
            }
        case "enable":
            Config.writeEnabled(true)
            print("enabled")
        case "disable":
            Config.writeEnabled(false)
            print("disabled")
        case "status":
            let enabled = Config.readEnabled()
            print(enabled ? "enabled" : "disabled")
        case "ping":
            DistributedNotificationCenter.default().postNotificationName(
                AudioMonitor.requestStatusNotification, object: nil)
        case "version", "--version", "-v":
            print("mic-guard \(version)")
        case "help", "--help", "-h":
            print("mic-guard \(version)")
            print()
            print("Usage: mic-guard [command]")
            print()
            print("Commands:")
            print("  list       List all input devices")
            print("  current    Print the current default input device")
            print("  set <name> Set the default input device by name")
            print("  enable     Enable MicGuard")
            print("  disable    Disable MicGuard")
            print("  status     Print whether MicGuard is enabled or disabled")
            print("  ping       Ask the running daemon to re-broadcast its status")
            print("  version    Print version")
            print("  help       Show this help")
            print()
            print("Run with no arguments to start as a menubar daemon.")
        default:
            fputs("Unknown command: \(command)\n", stderr)
            fputs("Run 'mic-guard help' for usage information.\n", stderr)
            exit(1)
        }
    }
}
