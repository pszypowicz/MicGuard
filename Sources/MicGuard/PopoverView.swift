import ServiceManagement
import SwiftUI

struct PopoverView: View {
    private var monitor = AudioMonitor.shared
    @State private var devices: [(id: UInt32, name: String)] = []
    @State private var isUpdatingLogin = false
    @State private var isLoginEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Device picker
            Text("Preferred Device")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)

            ForEach(devices, id: \.id) { device in
                let isSelected = device.name == monitor.preferredDevice
                Button {
                    monitor.setPreferredDevice(name: device.name)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "record.circle" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .frame(width: 14)
                        Text(device.name)
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .buttonStyle(MenuRowButtonStyle())
            }

            Divider().padding(.vertical, 2)

            // Enable/Disable
            Button {
                monitor.isEnabled.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    Text("Monitoring")
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { monitor.isEnabled },
                        set: { monitor.isEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .buttonStyle(MenuRowButtonStyle())

            Divider().padding(.vertical, 2)

            // Launch at Login
            Button {
                guard !isUpdatingLogin else { return }
                isUpdatingLogin = true
                defer { isUpdatingLogin = false }
                do {
                    if isLoginEnabled {
                        try SMAppService.mainApp.unregister()
                    } else {
                        try SMAppService.mainApp.register()
                    }
                } catch {
                    log("Login item toggle failed: \(error)")
                }
                isLoginEnabled = SMAppService.mainApp.status == .enabled
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    Text("Launch at Login")
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isLoginEnabled },
                        set: { _ in }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .buttonStyle(MenuRowButtonStyle())

            Divider().padding(.vertical, 2)

            // About
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text("MicGuard \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // Quit
            MenuRow(title: "Quit MicGuard", shortcut: "⌘Q", icon: "xmark.circle") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 250)
        .onAppear {
            devices = AudioDevices.listInputDevices()
        }
    }
}

private struct MenuRow: View {
    let title: String
    var shortcut: String? = nil
    var checkmark: Bool = false
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                } else {
                    Image(systemName: checkmark ? "checkmark" : "")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                }
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed ? Color.accentColor.opacity(0.8) : Color.clear)
                    .padding(.horizontal, 4)
            )
    }
}
