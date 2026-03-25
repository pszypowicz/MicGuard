import MicGuardCore
import SwiftUI

struct PopoverView: View {
    private var monitor = AudioMonitor.shared

    var body: some View {
        Toggle("Enabled", isOn: Binding(
            get: { monitor.isEnabled },
            set: { monitor.isEnabled = $0 }
        ))

        Button("Reload Config") {
            monitor.reloadConfig()
            monitor.postStatusChanged()
        }

        Divider()

        Button("Settings...") { SettingsView.showWindow() }

        Button("About MicGuard") { AboutView.showWindow() }
        Button("Quit MicGuard") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
