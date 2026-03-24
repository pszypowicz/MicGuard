@preconcurrency import XPC

/// Send a request to the MicGuard daemon over XPC and return the response.
///
/// Creates the session as inactive, then activates manually — `activate()` throws
/// a `XPCRichError` (instead of trapping) if the Mach service is unavailable.
/// Returns `nil` if the daemon is not running or the request fails.
public func sendDaemonRequest(_ request: MicGuardRequest) -> MicGuardResponse? {
    do {
        let session = try XPCSession(machService: micGuardMachService, options: .inactive)
        try session.activate()
        defer { session.cancel(reason: "CLI request complete") }
        let reply: MicGuardResponse = try session.sendSync(request)
        return reply
    } catch {
        return nil
    }
}
