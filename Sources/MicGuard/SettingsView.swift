import MicGuardCore
import ServiceManagement
import SwiftUI

private struct InfoDot: View {
    let text: String
    init(_ text: String) { self.text = text }

    @State private var shown = false
    @State private var hoverDelay: Task<Void, Never>?

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .onHover { inside in
                hoverDelay?.cancel()
                if inside {
                    hoverDelay = Task {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard !Task.isCancelled else { return }
                        shown = true
                    }
                } else {
                    shown = false
                }
            }
            .popover(isPresented: $shown) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                    .padding(12)
            }
    }
}

/// The Settings window content. Microphone settings bind straight to the
/// AudioMonitor (which persists them to the defaults domain); the login item
/// has no change notification, so its state is re-read whenever the app
/// activates.
struct SettingsView: View {
    @AppStorage(Preferences.showMenuBarIconKey) private var showMenuBarIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var monitor: AudioMonitor { AudioMonitor.shared }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $launchAtLogin) {
                    Label("Launch at Login", systemImage: "power")
                }
                .onChange(of: launchAtLogin) { _, enable in setLaunchAtLogin(enable) }
                Toggle(isOn: $showMenuBarIcon) {
                    HStack(spacing: 4) {
                        Label("Show Menu Bar Icon", systemImage: "menubar.rectangle")
                        InfoDot("With the icon hidden, open MicGuard again to get back here.")
                    }
                }
            }

            Section {
                Toggle(isOn: autoModeBinding) {
                    HStack(spacing: 4) {
                        Label("Auto Mode", systemImage: "wand.and.stars")
                        InfoDot("Protects the preferred microphone during device connect and disconnect, and treats switches you make in System Settings as intentional. Turn it off to lock the input to one device.")
                    }
                }
                Picker(selection: preferredDeviceBinding) {
                    ForEach(devices, id: \.name) { device in
                        Text(device.available ? device.name : "\(device.name) (offline)")
                            .tag(device.name)
                    }
                } label: {
                    Label("Preferred Microphone", systemImage: "mic")
                }
                .disabled(monitor.mode == "auto")
                LabeledContent {
                    Text(monitor.currentDevice.isEmpty ? "Unknown" : monitor.currentDevice)
                } label: {
                    Label("Current Input", systemImage: "waveform")
                }
            } header: {
                Text("Microphone")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        .onAppear { syncLaunchAtLogin() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncLaunchAtLogin()
        }
    }

    private var autoModeBinding: Binding<Bool> {
        Binding(
            get: { monitor.mode == "auto" },
            set: { monitor.setMode($0 ? "auto" : "manual") }
        )
    }

    private var preferredDeviceBinding: Binding<String> {
        Binding(
            get: { monitor.preferredDevice },
            set: { monitor.setPreferredDevice(name: $0) }
        )
    }

    private struct DisplayDevice {
        let name: String
        let available: Bool
    }

    // A disconnected preferred device stays listed as "(offline)" so the
    // picker's selection remains valid until it reconnects.
    private var devices: [DisplayDevice] {
        var list = monitor.inputDevices.map { DisplayDevice(name: $0.name, available: true) }
        if !monitor.preferredDevice.isEmpty,
           !list.contains(where: { $0.name == monitor.preferredDevice }) {
            list.append(DisplayDevice(name: monitor.preferredDevice, available: false))
        }
        return list.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func syncLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        guard enable != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Login item toggle failed: \(error, privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    static func showWindow() {
        UtilityWindow.show(id: "micguard-settings", title: "MicGuard Settings", content: SettingsView())
    }
}
