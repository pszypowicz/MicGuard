import Foundation

/// Mach service name for XPC communication.
public let micGuardMachService = "com.pszypowicz.MicGuard.xpc"

// MARK: - Request/Response Types (Codable, used internally and for tests)

/// Request sent from CLI to daemon over XPC.
public enum MicGuardRequest: Codable, Sendable {
    case ping
    case enable
    case disable
    case toggle
    case status
    case setDevice(name: String)
    case setVolume(volume: Int)
    case mute
    case list
    case current
}

/// Response sent from daemon to CLI over XPC.
public enum MicGuardResponse: Codable, Sendable {
    case ok
    case statusInfo(enabled: Bool, mode: String)
    case device(name: String?)
    case deviceList([DeviceInfo])
    case error(message: String)
}

/// Device info included in XPC responses.
public struct DeviceInfo: Codable, Sendable {
    public let name: String
    public let current: Bool
    public let volume: Int
    public let muted: Bool
    public let available: Bool
    public let preferred: Bool

    public init(name: String, current: Bool, volume: Int, muted: Bool, available: Bool, preferred: Bool) {
        self.name = name
        self.current = current
        self.volume = volume
        self.muted = muted
        self.available = available
        self.preferred = preferred
    }
}
