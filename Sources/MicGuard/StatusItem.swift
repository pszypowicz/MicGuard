import AppKit
import MicGuardCore

/// Menu bar icon with the app menu. `refresh()` creates or removes the status
/// item to match the Show Menu Bar Icon setting; the owner calls it at launch
/// and from its defaults observation, so hiding or showing the icon applies
/// live. Idempotent.
@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let prefs = Preferences()

    func refresh() {
        if prefs.showMenuBarIcon {
            guard statusItem == nil else { return }
            statusItem = makeItem()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image()

        let menu = NSMenu()
        menu.autoenablesItems = false

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "About MicGuard", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(aboutItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MicGuard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu
        return item
    }

    @objc private func showSettings() {
        SettingsView.showWindow()
    }

    @objc private func showAbout() {
        AboutView.showWindow()
    }
}
