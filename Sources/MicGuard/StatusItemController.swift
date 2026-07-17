import AppKit
import MicGuardCore
import ServiceManagement

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let monitor = AudioMonitor.shared

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    // Rebuilt on every open so the device list, checkmarks, and login-item
    // state are read at the moment the user sees them. System Settings >
    // General > Login Items is a second writer of the login-item state and
    // SMAppService offers no change notification.
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(NSMenuItem.sectionHeader(title: "Preferred Microphone"))

        // In auto mode the system manages the preference, so the device rows
        // are visible but disabled; uncheck "Auto Mode" to pick one.
        let inAuto = monitor.mode == "auto"
        for device in deviceList() {
            let item = NSMenuItem(
                title: device.available ? device.name : "\(device.name) (offline)",
                action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.name
            item.state = device.name == monitor.preferredDevice ? .on : .off
            item.isEnabled = device.available && !inAuto
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let autoItem = NSMenuItem(
            title: "Auto Mode", action: #selector(toggleAutoMode), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = monitor.mode == "auto" ? .on : .off
        menu.addItem(autoItem)

        let loginItem = NSMenuItem(
            title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "About MicGuard", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "Quit MicGuard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)
    }

    private struct DisplayDevice {
        let name: String
        let available: Bool
    }

    private func deviceList() -> [DisplayDevice] {
        var devices = monitor.inputDevices.map { DisplayDevice(name: $0.name, available: true) }
        if !monitor.preferredDevice.isEmpty,
           !devices.contains(where: { $0.name == monitor.preferredDevice }) {
            devices.append(DisplayDevice(name: monitor.preferredDevice, available: false))
        }
        return devices.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        monitor.setPreferredDevice(name: name)
    }

    @objc private func toggleAutoMode() {
        monitor.setMode(monitor.mode == "auto" ? "manual" : "auto")
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            logger.error("Login item toggle failed: \(error, privacy: .public)")
        }
    }

    @objc private func showAbout() {
        AboutView.showWindow()
    }
}
