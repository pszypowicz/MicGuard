import os
import ServiceManagement
import SwiftUI

struct PopoverView: View {
    private var monitor = AudioMonitor.shared
    @State private var isLoginEnabled = SMAppService.mainApp.status == .enabled

    private var displayDevices: [(name: String, available: Bool)] {
        var devices = monitor.inputDevices.map { (name: $0.name, available: true) }
        if !monitor.preferredDevice.isEmpty,
           !devices.contains(where: { $0.name == monitor.preferredDevice }) {
            devices.append((name: monitor.preferredDevice, available: false))
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Picker("Preferred Device", selection: Binding(
            get: { monitor.preferredDevice },
            set: { monitor.setPreferredDevice(name: $0) }
        )) {
            ForEach(displayDevices, id: \.name) { device in
                if device.available {
                    Text(device.name).tag(device.name)
                } else {
                    Text("\(device.name) (offline)")
                        .foregroundStyle(.secondary)
                        .tag(device.name)
                }
            }
        }
        .pickerStyle(.inline)

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
