import CoreAudio
import Testing

@testable import MicGuardCore

@Suite("Manual Mode")
@MainActor
struct ManualModeTests {

    @Test("Any device change reverts to preferred")
    func anyChangeRevertsToPreferred() {
        let (monitor, mockAudio, _) = makeMonitor(
            mode: "manual",
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, airpods]
        )

        // Something changes the default to AirPods
        mockAudio.currentDefault = airpods

        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"),
                "Manual mode should always revert to preferred")
        #expect(monitor.currentDevice == "MacBook Pro Microphone")
    }

    @Test("Preferred disconnected — stays on current device")
    func preferredDisconnectedStaysOnCurrent() {
        // Preferred is USB mic but it's not connected
        let (monitor, mockAudio, _) = makeMonitor(
            mode: "manual",
            preferred: "USB Microphone",
            current: macbook,
            devices: [macbook, airpods]
        )

        // Default changes to AirPods
        mockAudio.currentDefault = airpods

        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty,
                "Should not try to revert to disconnected preferred device")
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }

    @Test("setPreferredDevice switches immediately")
    func setPreferredDeviceSwitches() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            mode: "manual",
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, usbMic]
        )

        monitor.setPreferredDevice(name: "USB Microphone")

        #expect(mockConfig.writePreferredDeviceCalls.contains("USB Microphone"))
        #expect(mockAudio.setInputDeviceCalls.contains("USB Microphone"))
        #expect(monitor.currentDevice == "USB Microphone")
        #expect(monitor.preferredDevice == "USB Microphone")
    }

    @Test("setPreferredDevice updates volume and clears mute")
    func setPreferredDeviceUpdatesState() {
        let (monitor, mockAudio, _) = makeMonitor(
            mode: "manual",
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, usbMic]
        )
        mockAudio.volumes[usbMic.id] = 80
        monitor.isMuted = true

        monitor.setPreferredDevice(name: "USB Microphone")

        #expect(monitor.currentDevice == "USB Microphone")
        #expect(monitor.inputVolume == 80)
        #expect(monitor.isMuted == false)
    }

    @Test("Startup enforces preferred device in manual mode")
    func startupEnforcesPreferredManual() {
        let (monitor, mockAudio, _) = makeMonitor(
            mode: "manual",
            preferred: "MacBook Pro Microphone",
            current: airpods,
            devices: [macbook, airpods]
        )

        monitor.enforcePreferredOnStartup()

        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"))
        #expect(monitor.currentDevice == "MacBook Pro Microphone")
    }
}
