import CoreAudio
import Testing
@testable import MicGuardCore

@Suite("XPC Request Handler")
struct XPCHandlerTests {
    @Test("ping returns ok")
    @MainActor func ping() {
        let (monitor, _, _) = makeMonitor()
        let response = monitor.handleRequest(.ping)
        #expect(response == .ok)
    }

    @Test("enable sets isEnabled true")
    @MainActor func enable() {
        let (monitor, _, _) = makeMonitor(enabled: false)
        let response = monitor.handleRequest(.enable)
        #expect(response == .ok)
        #expect(monitor.isEnabled == true)
    }

    @Test("disable sets isEnabled false")
    @MainActor func disable() {
        let (monitor, _, _) = makeMonitor(enabled: true)
        let response = monitor.handleRequest(.disable)
        #expect(response == .ok)
        #expect(monitor.isEnabled == false)
    }

    @Test("toggle flips enabled and returns new state")
    @MainActor func toggle() {
        let (monitor, _, _) = makeMonitor(enabled: true)
        let response = monitor.handleRequest(.toggle)
        #expect(response == .statusInfo(enabled: false, mode: "auto"))
        #expect(monitor.isEnabled == false)

        let response2 = monitor.handleRequest(.toggle)
        #expect(response2 == .statusInfo(enabled: true, mode: "auto"))
        #expect(monitor.isEnabled == true)
    }

    @Test("status returns current state")
    @MainActor func status() {
        let (monitor, _, _) = makeMonitor(mode: "manual", enabled: true)
        let response = monitor.handleRequest(.status)
        #expect(response == .statusInfo(enabled: true, mode: "manual"))
    }

    @Test("setDevice switches to device and sets manual mode")
    @MainActor func setDevice() {
        let (monitor, audio, _) = makeMonitor(devices: [macbook, airpods])
        let response = monitor.handleRequest(.setDevice(name: "AirPods Pro 3"))
        #expect(response == .ok)
        #expect(monitor.mode == "manual")
        #expect(monitor.preferredDevice == "AirPods Pro 3")
        #expect(audio.setInputDeviceCalls.last == "AirPods Pro 3")
    }

    @Test("setDevice with unknown device returns error")
    @MainActor func setDeviceUnknown() {
        let (monitor, _, _) = makeMonitor()
        let response = monitor.handleRequest(.setDevice(name: "Nonexistent Mic"))
        #expect(response == .error(message: "Device 'Nonexistent Mic' not found"))
    }

    @Test("setVolume updates volume on current device")
    @MainActor func setVolume() {
        let (monitor, audio, _) = makeMonitor()
        audio.volumes[macbook.id] = 50
        let response = monitor.handleRequest(.setVolume(volume: 75))
        #expect(response == .ok)
        #expect(audio.volumes[macbook.id] == 75)
        #expect(monitor.inputVolume == 75)
    }

    @Test("setVolume to 0 triggers mute state")
    @MainActor func setVolumeZeroMutes() {
        let (monitor, audio, _) = makeMonitor()
        audio.volumes[macbook.id] = 50
        monitor.inputVolume = 50
        let response = monitor.handleRequest(.setVolume(volume: 0))
        #expect(response == .ok)
        #expect(monitor.isMuted == true)
        #expect(monitor.inputVolume == 0)
    }

    @Test("mute toggles mute state via daemon")
    @MainActor func muteToggle() {
        let (monitor, audio, _) = makeMonitor()
        audio.volumes[macbook.id] = 75
        monitor.inputVolume = 75
        monitor.isMuted = false

        // Mute
        let response = monitor.handleRequest(.mute)
        #expect(response == .ok)
        #expect(monitor.isMuted == true)
        #expect(monitor.inputVolume == 0)
        #expect(monitor.preMuteVolume == 75)

        // Unmute
        let response2 = monitor.handleRequest(.mute)
        #expect(response2 == .ok)
        #expect(monitor.isMuted == false)
        #expect(monitor.inputVolume == 75)
    }

    @Test("list returns device info list")
    @MainActor func list() {
        let (monitor, audio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            devices: [macbook, airpods]
        )
        audio.volumes[macbook.id] = 80
        audio.volumes[airpods.id] = 60
        monitor.inputVolume = 80

        let response = monitor.handleRequest(.list)
        guard case .deviceList(let devices) = response else {
            #expect(Bool(false), "Expected deviceList response")
            return
        }
        #expect(devices.count == 2)
        // Sorted alphabetically
        #expect(devices[0].name == "AirPods Pro 3")
        #expect(devices[1].name == "MacBook Pro Microphone")
        #expect(devices[1].current == true)
        #expect(devices[1].preferred == true)
    }

    @Test("current returns current device name")
    @MainActor func current() {
        let (monitor, _, _) = makeMonitor()
        let response = monitor.handleRequest(.current)
        #expect(response == .device(name: "MacBook Pro Microphone"))
    }

    @Test("current returns nil when no device")
    @MainActor func currentEmpty() {
        let (monitor, _, _) = makeMonitor()
        monitor.currentDevice = ""
        let response = monitor.handleRequest(.current)
        #expect(response == .device(name: nil))
    }
}

// MARK: - Equatable for test assertions

extension MicGuardResponse: Equatable {
    public static func == (lhs: MicGuardResponse, rhs: MicGuardResponse) -> Bool {
        switch (lhs, rhs) {
        case (.ok, .ok):
            return true
        case (.statusInfo(let le, let lm), .statusInfo(let re, let rm)):
            return le == re && lm == rm
        case (.device(let l), .device(let r)):
            return l == r
        case (.deviceList(let l), .deviceList(let r)):
            return l.count == r.count
        case (.error(let l), .error(let r)):
            return l == r
        default:
            return false
        }
    }
}
