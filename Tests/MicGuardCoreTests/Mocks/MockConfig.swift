import Foundation
@testable import MicGuardCore

@MainActor
final class MockConfig: ConfigProviding {
    var enabled: Bool = true
    var preferredDevice: String = ""
    var mode: String = "auto"
    var writePreferredDeviceCalls: [String] = []

    func readEnabled() -> Bool { enabled }
    func writeEnabled(_ value: Bool) { enabled = value }
    func readPreferredDevice() -> String { preferredDevice }
    func writePreferredDevice(_ name: String) {
        writePreferredDeviceCalls.append(name)
        preferredDevice = name
    }
    func readMode() -> String { mode }
    func writeMode(_ value: String) { mode = value }
    var settleSeconds: TimeInterval = 5.0
    func readSettleSeconds() -> TimeInterval { settleSeconds }
    func writeSettleSeconds(_ seconds: TimeInterval) { settleSeconds = seconds }
    func ensureConfigDir() {}
}
