import CoreAudio
import Testing

@testable import MicGuardCore

@Suite("Edge Cases")
@MainActor
struct EdgeCaseTests {

    @Test("No preferred device + BT connects — accepts without crash")
    func noPreferredBTConnects() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "",
            current: macbook,
            devices: [macbook]
        )

        // AirPods connect
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        mockAudio.transportTypes[airpods.id] = "bluetooth"

        monitor.handleDeviceListChanged()

        // Should not crash, and should accept the BT device
        #expect(monitor.currentDevice == "AirPods Pro 3")
        #expect(mockAudio.setInputDeviceCalls.isEmpty)
    }

    @Test("Device list changes but default unchanged — no action")
    func deviceListChangeDefaultUnchanged() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // USB mic appears but MacBook stays default
        mockAudio.devices = [macbook, usbMic]
        mockAudio.currentDefault = macbook

        monitor.handleDeviceListChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone")
        #expect(mockAudio.setInputDeviceCalls.isEmpty)
        // handleDefaultInputChanged would also be no-op (guard: newName == currentDevice)

        mockAudio.setInputDeviceCalls = []
        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty)
        #expect(mockConfig.writePreferredDeviceCalls.isEmpty)
    }

    @Test("setInputDevice fails — stays on current")
    func setInputDeviceFails() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, airpods],
            transportTypes: [airpods.id: "bluetooth"]
        )

        mockAudio.setInputDeviceResult = false
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        mockAudio.transportTypes[airpods.id] = "bluetooth"

        // Add airpods as "new" device
        monitor.previousDeviceIDs = Set([macbook.id])

        monitor.handleDeviceListChanged()

        #expect(monitor.pendingBTHijack == true)

        // DEFAULT_INPUT_CHANGED confirms hijack — revert attempted but fails
        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"))
        // Falls through to settleOnDevice with the actual default (AirPods)
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }
}
