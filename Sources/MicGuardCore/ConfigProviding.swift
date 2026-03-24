import Foundation

@MainActor
public protocol ConfigProviding {
    func readEnabled() -> Bool
    func writeEnabled(_ value: Bool)
    func readPreferredDevice() -> String
    func writePreferredDevice(_ name: String)
    func readMode() -> String
    func writeMode(_ value: String)
    func readSettleSeconds() -> TimeInterval
    func writeSettleSeconds(_ seconds: TimeInterval)
    func ensureConfigDir()
}
