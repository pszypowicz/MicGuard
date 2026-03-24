import os
import ServiceManagement
import SwiftUI

private struct DisplayDevice: Equatable {
    let name: String
    let available: Bool
}

struct PopoverView: View {
    private var monitor = AudioMonitor.shared
    @State private var isLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var displayDevices: [DisplayDevice]

    init() {
        _displayDevices = State(initialValue: Self.buildDeviceList())
    }

    var body: some View {
        Picker("Preferred Device", selection: Binding(
            get: { monitor.preferredDevice },
            set: { monitor.setPreferredDevice(name: $0) }
        )) {
            ForEach(displayDevices, id: \.name) { device in
                Text(device.available ? device.name : "\(device.name) (offline)")
                    .foregroundStyle(device.available ? .primary : .secondary)
                    .tag(device.name)
            }
        }
        .pickerStyle(.inline)
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            displayDevices = Self.buildDeviceList()
        }

        Section("Configuration") {
            Toggle("Enabled", isOn: Binding(
                get: { monitor.isEnabled },
                set: { monitor.isEnabled = $0 }
            ))

            Toggle("Launch at Login", isOn: Binding(
                get: { isLoginEnabled },
                set: { newValue in
                    toggleLoginItem(newValue)
                }
            ))
        }

        Section {
            Button("About MicGuard") { AboutView.showWindow() }
            Button("Quit MicGuard") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private static func buildDeviceList() -> [DisplayDevice] {
        let monitor = AudioMonitor.shared
        var devices = monitor.inputDevices.map { DisplayDevice(name: $0.name, available: true) }
        if !monitor.preferredDevice.isEmpty,
           !devices.contains(where: { $0.name == monitor.preferredDevice }) {
            devices.append(DisplayDevice(name: monitor.preferredDevice, available: false))
        }
        return devices.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func toggleLoginItem(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Login item toggle failed: \(error, privacy: .public)")
        }
        isLoginEnabled = SMAppService.mainApp.status == .enabled
    }
}
