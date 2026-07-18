import MicGuardCore
import SwiftUI

func formatVersion(base: String) -> String {
    #if DEBUG
    return "\(base) (\(BuildMetadata.gitHash) \(BuildMetadata.buildDate))"
    #else
    return "\(base) (\(BuildMetadata.gitHash))"
    #endif
}

private let repoURL = URL(string: "https://github.com/pszypowicz/MicGuard")!
private let sponsorURL = URL(string: "https://github.com/sponsors/pszypowicz")!

struct AboutView: View {
    private let version: String = {
        let base = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return formatVersion(base: base)
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
        UtilityWindow.show(id: "about-micguard", title: "About MicGuard", content: AboutView())
    }
}
