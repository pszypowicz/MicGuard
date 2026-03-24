import Foundation
import Testing
@testable import MicGuardCore

@Suite("XPC Protocol Codable")
struct XPCProtocolTests {
    @Test("MicGuardRequest round-trips through JSON encoding")
    func requestRoundTrip() throws {
        let requests: [MicGuardRequest] = [
            .ping, .enable, .disable, .toggle, .status,
            .setDevice(name: "AirPods Pro 3"),
            .setVolume(volume: 75),
            .mute, .list, .current,
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for request in requests {
            let data = try encoder.encode(request)
            // Just verify it decodes without error
            _ = try decoder.decode(MicGuardRequest.self, from: data)
        }
    }

    @Test("MicGuardResponse round-trips through JSON encoding")
    func responseRoundTrip() throws {
        let responses: [MicGuardResponse] = [
            .ok,
            .statusInfo(enabled: true, mode: "auto"),
            .statusInfo(enabled: false, mode: "manual"),
            .device(name: "MacBook Pro Microphone"),
            .device(name: nil),
            .deviceList([
                DeviceInfo(name: "MacBook Pro Microphone", current: true, volume: 80, muted: false, available: true, preferred: true),
            ]),
            .error(message: "Something went wrong"),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for response in responses {
            let data = try encoder.encode(response)
            let decoded = try decoder.decode(MicGuardResponse.self, from: data)
            // Verify equality using our Equatable conformance
            #expect(response == decoded)
        }
    }

    @Test("DeviceInfo fields encode correctly")
    func deviceInfoFields() throws {
        let info = DeviceInfo(name: "Test Mic", current: true, volume: 50, muted: false, available: true, preferred: true)
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(DeviceInfo.self, from: data)
        #expect(decoded.name == "Test Mic")
        #expect(decoded.current == true)
        #expect(decoded.volume == 50)
        #expect(decoded.muted == false)
        #expect(decoded.available == true)
        #expect(decoded.preferred == true)
    }
}
