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
    @State private var showAdvanced = false

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

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Settle period")
                        Slider(value: Binding(
                            get: { monitor.settleSeconds },
                            set: { monitor.setSettleSeconds($0) }
                        ), in: 1...10, step: 1)
                        Text("\(Int(monitor.settleSeconds))s")
                            .monospacedDigit()
                            .frame(width: 24, alignment: .trailing)
                    }
                    Text("After a device connects or disconnects, MicGuard protects your preferred microphone for this period while macOS stabilizes. Switch your input device in System Settings after devices settle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    static func showWindow() {
        let windowID = "settings-micguard"

        // Reuse existing window if open
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == windowID }) {
            existing.level = .floating
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let hostingView = NSHostingView(rootView: SettingsView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let fittingSize = hostingView.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(windowID)
        window.title = "MicGuard Settings"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
