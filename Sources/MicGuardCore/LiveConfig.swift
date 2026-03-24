public struct LiveConfig: ConfigProviding {
    public init() {}

    public func readEnabled() -> Bool { Config.readEnabled() }
    public func writeEnabled(_ value: Bool) { Config.writeEnabled(value) }
    public func readPreferredDevice() -> String { Config.readPreferredDevice() }
    public func writePreferredDevice(_ name: String) { Config.writePreferredDevice(name) }
    public func readMode() -> String { Config.readMode() }
    public func writeMode(_ value: String) { Config.writeMode(value) }
    public func ensureConfigDir() { Config.ensureConfigDir() }
}
