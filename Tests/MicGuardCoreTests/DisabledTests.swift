import CoreAudio
import Testing

@testable import MicGuardCore

@Suite("Disabled Mode")
@MainActor
struct DisabledTests {

    @Test("Accepts any device change without enforcement")
    func acceptsAnyChange() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            enabled: false,
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, airpods]
        )

        // Default changes to AirPods
        mockAudio.currentDefault = airpods

        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty,
                "Should not enforce anything when disabled")
        #expect(monitor.currentDevice == "AirPods Pro 3")
        #expect(mockConfig.writePreferredDeviceCalls.isEmpty,
                "Should not save preference when disabled")
    }

    @Test("BT hijack ignored when disabled")
    func btHijackIgnoredWhenDisabled() {
        let (monitor, mockAudio, _) = makeMonitor(
            enabled: false,
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // AirPods connect
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        mockAudio.transportTypes[airpods.id] = "bluetooth"

        monitor.handleDeviceListChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty,
                "Should not enforce when disabled")
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }
}
