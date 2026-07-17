import CoreAudio
import Testing

@testable import MicGuardCore

@Suite("Edge Cases")
@MainActor
struct EdgeCaseTests {

    @Test("No preferred device + new device connects - accepts without crash")
    func noPreferredAccepts() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "",
            current: macbook,
            devices: [macbook]
        )

        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods

        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "AirPods Pro 3")
        #expect(mockAudio.setInputDeviceCalls.isEmpty)
    }

    @Test("Device list changes but default unchanged - no action")
    func deviceListChangeDefaultUnchanged() {
        let (monitor, mockAudio, prefs) = makeMonitor(
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

        // handleDefaultInputChanged is no-op (guard: newName == currentDevice)
        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty)
        #expect(prefs.preferredDevice == "MacBook Pro Microphone")
    }

    @Test("Non-current device disconnects - device list updated")
    func nonCurrentDeviceDisconnects() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, airpods]
        )

        // AirPods disconnect while MacBook is current (e.g. after revert)
        mockAudio.devices = [macbook]
        mockAudio.currentDefault = macbook

        monitor.handleDeviceListChanged()

        // Current device unchanged, but device list must be updated
        #expect(monitor.currentDevice == "MacBook Pro Microphone")
        #expect(monitor.inputDevices.count == 1)
        #expect(monitor.inputDevices.first?.name == "MacBook Pro Microphone")
        // AirPods removed from previousDeviceIDs
        #expect(!monitor.previousDeviceIDs.contains(airpods.id))
    }

    @Test("setInputDevice fails - stays on current")
    func setInputDeviceFails() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        mockAudio.setInputDeviceResult = false
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods

        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"))
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }
}
