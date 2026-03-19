import SwiftUI

private let repoURL = URL(string: "https://github.com/pszypowicz/MicGuard")!
private let sponsorURL = URL(string: "https://github.com/sponsors/pszypowicz")!

struct AboutView: View {
    private let version: String = {
        let base = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        #if DEBUG
        return "\(base) (\(BuildMetadata.gitHash) \(BuildMetadata.buildDate))"
        #else
        return "\(base) (\(BuildMetadata.gitHash))"
        #endif
    }()

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("MicGuard")
                .font(.title.bold())

            Text("Version \(version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("by Przemysław Szypowicz")
                .font(.subheadline)

            Divider()

            Link(destination: repoURL) {
                Label("GitHub Repository", systemImage: "link")
            }

            Link(destination: sponsorURL) {
                HStack(spacing: 4) {
                    Text("Support this project")
                    Image(systemName: "heart.fill")
                }
            }
            .foregroundStyle(.pink)
        }
        .padding(24)
        .frame(width: 260)
    }

    static func showWindow() {
        let windowID = "about-micguard"

        // Reuse existing window if open
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == windowID }) {
            existing.level = .floating
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let hostingView = NSHostingView(rootView: AboutView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let fittingSize = hostingView.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(windowID)
        window.title = "About MicGuard"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
