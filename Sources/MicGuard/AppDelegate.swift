import AppKit
import MicGuardCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("MicGuard starting")
        AudioMonitor.shared.start()

        // Auto-enable login item on first install
        if SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
            logger.info("Auto-enabled Launch at Login (first install)")
        }

        statusItem.install()
    }
}
