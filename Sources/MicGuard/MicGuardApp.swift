import MicGuardCore
import os
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
        let lockPath = Config.configDir.appending(component: "lock").path(percentEncoded: false)
        let lockFD = open(lockPath, O_CREAT | O_WRONLY, 0o600)
        guard lockFD != -1 else {
            logger.error("Could not create lock file — exiting")
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
            logger.info("Another instance is already running (PID \(info.l_pid, privacy: .public)) — exiting")
            exit(0)
        }
        // lockFD intentionally kept open — kernel releases lock on exit/crash

        logger.info("MicGuard starting")
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

        Settings {
            SettingsView()
        }
    }

    private static let version: String = {
        // When invoked via CLI symlink, Bundle.main doesn't resolve to the .app.
        // Walk up from the real executable path to find the enclosing bundle.
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let appURL = execURL
            .deletingLastPathComponent()  // MacOS/
            .deletingLastPathComponent()  // Contents/
            .deletingLastPathComponent()  // MicGuard.app/
        let bundle = Bundle(url: appURL) ?? Bundle.main
        let base = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev"
        return formatVersion(base: base)
    }()

    private static func wantsHelp(_ args: [String]) -> Bool {
        args.contains("--help") || args.contains("-h")
    }

    private static func handleCLI(command: String, args: [String]) {
        switch command {
        case "list":
            if wantsHelp(args) {
                print("Usage: mic-guard list [--output text|json]")
                print("\nList all input devices.")
                return
            }
            let outputFormat = Self.parseOutputFlag(args: args)
            let devices = AudioDevices.listInputDevices()
            if outputFormat == "json" {
                let currentDevice = AudioDevices.currentInputDevice()
                let entries: [[String: Any]] = devices.map { device in
                    ["name": device.name, "current": device.id == currentDevice?.id]
                }
                if let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]),
                   let json = String(data: data, encoding: .utf8) {
                    print(json)
                }
            } else {
                for device in devices {
                    print(device.name)
                }
            }
        case "current":
            if wantsHelp(args) {
                print("Usage: mic-guard current")
                print("\nPrint the current default input device.")
                return
            }
            if let device = AudioDevices.currentInputDevice() {
                print(device.name)
            }
        case "set":
            if wantsHelp(args) {
                print("Usage: mic-guard set <device name>")
                print("\nSet the preferred device and switch to manual mode.")
                return
            }
            let name = args.joined(separator: " ")
            guard !name.isEmpty else {
                fputs("Usage: mic-guard set <device name>\n", stderr)
                exit(1)
            }
            Config.writePreferredDevice(name)
            Config.writeMode("manual")
            if !AudioDevices.setInputDevice(name: name) {
                fputs("Failed to set input device to '\(name)'\n", stderr)
                exit(1)
            }
        case "enable":
            if wantsHelp(args) {
                print("Usage: mic-guard enable")
                print("\nEnable MicGuard.")
                return
            }
            Config.writeEnabled(true)
            print("enabled")
        case "disable":
            if wantsHelp(args) {
                print("Usage: mic-guard disable")
                print("\nDisable MicGuard.")
                return
            }
            Config.writeEnabled(false)
            print("disabled")
        case "status":
            if wantsHelp(args) {
                print("Usage: mic-guard status")
                print("\nPrint whether MicGuard is enabled or disabled.")
                return
            }
            let enabled = Config.readEnabled()
            let mode = Config.readMode()
            if enabled {
                print("enabled (\(mode))")
            } else {
                print("disabled")
            }
        case "volume":
            if wantsHelp(args) {
                print("Usage: mic-guard volume <0-100>")
                print("\nSet input volume (0-100).")
                return
            }
            guard let volumeStr = args.first, let volume = Int(volumeStr),
                  volume >= 0, volume <= 100 else {
                fputs("Usage: mic-guard volume <0-100>\n", stderr)
                exit(1)
            }
            guard let device = AudioDevices.currentInputDevice() else {
                fputs("No input device found\n", stderr)
                exit(1)
            }
            if !AudioDevices.setInputVolume(for: device.id, volume: volume) {
                fputs("Failed to set volume\n", stderr)
                exit(1)
            }
        case "mute":
            if wantsHelp(args) {
                print("Usage: mic-guard mute")
                print("\nToggle mute on the current input device.")
                return
            }
            DistributedNotificationCenter.default().postNotificationName(
                AudioMonitor.toggleMuteNotification, object: nil)
        case "ping":
            if wantsHelp(args) {
                print("Usage: mic-guard ping")
                print("\nAsk the running daemon to re-broadcast its status.")
                return
            }
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
            print("  list [--output text|json]  List all input devices")
            print("  current    Print the current default input device")
            print("  set <name> Set the preferred device (switches to manual mode)")
            print("  volume <n> Set input volume (0-100)")
            print("  mute       Toggle mute on the current input device")
            print("  enable     Enable MicGuard")
            print("  disable    Disable MicGuard")
            print("  status     Print status (enabled/disabled and mode)")
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

    private static func parseOutputFlag(args: [String]) -> String {
        guard let idx = args.firstIndex(of: "--output"), idx + 1 < args.count else {
            return "text"
        }
        let value = args[idx + 1]
        guard value == "text" || value == "json" else {
            fputs("Invalid output format: \(value). Use 'text' or 'json'.\n", stderr)
            exit(1)
        }
        return value
    }
}
