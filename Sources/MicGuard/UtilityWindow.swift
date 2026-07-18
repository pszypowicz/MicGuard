import AppKit
import SwiftUI

/// Presents SwiftUI content in a single reusable utility window per id.
@MainActor
enum UtilityWindow {
    static func show(id: String, title: String, content: some View) {
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == id }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let fittingSize = hostingView.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.title = title
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false  // reused, not rebuilt
        window.level = .floating  // accessory app has no Dock to click back to
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
