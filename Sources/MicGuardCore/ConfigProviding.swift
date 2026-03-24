@MainActor
public protocol ConfigProviding {
    func readEnabled() -> Bool
    func writeEnabled(_ value: Bool)
    func readPreferredDevice() -> String
    func writePreferredDevice(_ name: String)
    func readMode() -> String
    func writeMode(_ value: String)
    func ensureConfigDir()
}
