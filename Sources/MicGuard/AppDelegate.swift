import AppKit
import MicGuardCore
import ServiceManagement

/// App lifecycle for the menu bar app: owns the status item, starts the audio
/// monitor, applies the icon setting live, and opens the Settings window on
/// reopen - the escape hatch when the menu bar icon is hidden.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// First-launch guard for the one-time launch-at-login registration.
    static let didRegisterLoginItemKey = "didRegisterLoginItem"

    private let statusItem = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("MicGuard starting")
        installMainMenu()
        registerLoginItemOnFirstLaunch()

        AudioMonitor.shared.start()
        statusItem.refresh()

        UserDefaults.standard.addObserver(
            self, forKeyPath: Preferences.showMenuBarIconKey, options: [], context: nil)
    }

    /// Reopening the app (Finder double-click, `open -a MicGuard`) presents
    /// Settings - the universal "where did it go" gesture, and the escape
    /// hatch when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsView.showWindow()
        return false
    }

    nonisolated override func observeValue(
        forKeyPath keyPath: String?, of object: Any?,
        change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        // KVO from an external `defaults write` can arrive off-main.
        Task { @MainActor in
            self.statusItem.refresh()
        }
    }

    /// MicGuard is useless unless it runs, so the first launch opts into
    /// launch at login (macOS shows its standard notification); the Settings
    /// toggle rules afterwards.
    private func registerLoginItemOnFirstLaunch() {
        guard Bundle.main.bundleIdentifier == "cz.szypowi.micguard",
              !UserDefaults.standard.bool(forKey: Self.didRegisterLoginItemKey)
        else { return }
        UserDefaults.standard.set(true, forKey: Self.didRegisterLoginItemKey)
        // Upgrade path: installs registered before this flag existed must not
        // be re-registered - register() from a dev bundle would repoint the
        // login item at the dev build.
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            logger.info("Launch at Login enabled (first launch)")
        } catch {
            logger.error("Launch at Login registration failed: \(error, privacy: .public)")
        }
    }

    /// An accessory app shows no menu bar, but key-equivalent routing still
    /// consults the main menu when a utility window is key; this makes Cmd+W
    /// and Cmd+Q work in the Settings and About windows.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit MicGuard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }
}
