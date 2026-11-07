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
        let base = BuildMetadata.version
        return formatVersion(base: base)
    }()

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("MicGuard")
                .font(.title.bold())

            Text(String(format: NSLocalizedString("Version %@", comment: "Version label in About window"), version))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(String(format: NSLocalizedString("by %@", comment: "Author label in About window"), "Przemysław Szypowicz"))
                .font(.subheadline)

            Divider()

            Link(destination: repoURL) {
                Label(NSLocalizedString("GitHub Repository", comment: "Link to GitHub repository"), systemImage: "link")
            }

            Link(destination: sponsorURL) {
                HStack(spacing: 4) {
                    Text(NSLocalizedString("Support this project", comment: "Link to sponsor author"))
                    Image(systemName: "heart.fill")
                }
            }
            .foregroundStyle(.pink)
        }
        .padding(24)
        .frame(width: 260)
    }

    static func showWindow() {
        UtilityWindow.show(id: "about-micguard", title: NSLocalizedString("About MicGuard", comment: "About window title"), content: AboutView())
    }
}
