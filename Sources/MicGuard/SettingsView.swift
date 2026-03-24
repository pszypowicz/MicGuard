import MicGuardCore
import ServiceManagement
import SwiftUI

private struct DisplayDevice: Equatable, Identifiable {
    let name: String
    let available: Bool
    var id: String { name }
}

struct SettingsView: View {
    private var monitor = AudioMonitor.shared
    @State private var isLoginEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Picker("Mode", selection: Binding(
                get: { monitor.mode },
                set: { monitor.setMode($0) }
            )) {
                Text("Auto").tag("auto")
                Text("Manual").tag("manual")
            }
            .pickerStyle(.segmented)

            Section("Preferred Device") {
                Picker("Device", selection: Binding(
                    get: { monitor.preferredDevice },
                    set: { monitor.setPreferredDevice(name: $0) }
                )) {
                    ForEach(buildDeviceList()) { device in
                        Text(device.available ? device.name : "\(device.name) (offline)")
                            .foregroundStyle(device.available ? .primary : .secondary)
                            .tag(device.name)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(monitor.mode == "auto")
                .opacity(monitor.mode == "auto" ? 0.5 : 1.0)
                .labelsHidden()
            }

            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { isLoginEnabled },
                    set: { toggleLoginItem($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(minWidth: 300)
    }

    private func buildDeviceList() -> [DisplayDevice] {
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
