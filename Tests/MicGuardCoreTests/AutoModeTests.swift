import CoreAudio
import Testing

@testable import MicGuardCore

@Suite("Auto Mode")
@MainActor
struct AutoModeTests {

    // MARK: - New device detection (any event ordering)

    @Test("New non-preferred device → revert")
    func newDeviceReverts() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods

        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"))
        #expect(monitor.currentDevice == "MacBook Pro Microphone")
    }

    @Test("Preferred device reconnects → accepted")
    func preferredReconnects() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "AirPods Pro 3",
            current: macbook,
            devices: [macbook]
        )

        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods

        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty)
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }

    @Test("New device via race ordering → still reverts")
    func raceOrderingReverts() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods

        // DEFAULT_INPUT_CHANGED before DEVICE_LIST_CHANGED
        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"))

        // Subsequent DEVICE_LIST_CHANGED - no double revert
        mockAudio.setInputDeviceCalls = []
        monitor.handleDeviceListChanged()
        #expect(mockAudio.setInputDeviceCalls.isEmpty)
    }

    @Test("Preferred reconnects via race → accepted")
    func preferredReconnectsRace() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "AirPods Pro 3",
            current: macbook,
            devices: [macbook]
        )

        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods

        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty)
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }

    // MARK: - Settle period

    @Test("User switch after settle period → saved as preferred")
    func userSwitchAfterSettle() {
        let (monitor, mockAudio, prefs) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, usbMic]
        )

        // Devices settled (no recent DEVICE_LIST_CHANGED)
        monitor.lastDeviceListChange = CFAbsoluteTimeGetCurrent() - 10

        mockAudio.currentDefault = usbMic
        monitor.handleDefaultInputChanged()

        #expect(monitor.preferredDevice == "USB Microphone")
        #expect(prefs.preferredDevice == "USB Microphone")
        #expect(monitor.currentDevice == "USB Microphone")
    }

    @Test("Device connected without becoming default → later user switch saved as preferred")
    func userSwitchToQuietlyConnectedDevice() {
        let (monitor, mockAudio, prefs) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // USB mic plugged in, macOS keeps the MacBook as default
        mockAudio.devices = [macbook, usbMic]
        monitor.handleDeviceListChanged()

        // Devices settle, then the user picks the USB mic in System Settings
        monitor.lastDeviceListChange = CFAbsoluteTimeGetCurrent() - 10
        mockAudio.currentDefault = usbMic
        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty, "A deliberate switch must not be reverted")
        #expect(monitor.currentDevice == "USB Microphone")
        #expect(prefs.preferredDevice == "USB Microphone")
    }

    @Test("settleSeconds written while running applies to the next decision")
    func settleSecondsReadLive() {
        let (monitor, mockAudio, prefs) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, usbMic]
        )

        // 10 s since the last device activity: settled under the 2 s default,
        // still settling under 30 s
        UserDefaults(suiteName: testSuiteName)!.set(30.0, forKey: Preferences.settleSecondsKey)
        monitor.lastDeviceListChange = CFAbsoluteTimeGetCurrent() - 10

        mockAudio.currentDefault = usbMic
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone",
                "Should revert - still inside the 30 s settle period")
        #expect(prefs.preferredDevice == "MacBook Pro Microphone")
    }

    @Test("Switch during settle period → reverted to preferred")
    func switchDuringSettle() {
        let (monitor, mockAudio, prefs) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, airpods]
        )

        // Within settle period
        monitor.lastDeviceListChange = CFAbsoluteTimeGetCurrent()

        mockAudio.currentDefault = airpods
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone",
                "Should revert - within settle period")
        #expect(monitor.preferredDevice == "MacBook Pro Microphone")
        #expect(prefs.preferredDevice == "MacBook Pro Microphone")
    }

    @Test("Full flow: hijack → stale callbacks during settle → user switch after settle")
    func fullFlow() {
        let (monitor, mockAudio, prefs) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // 1. AirPods connect (triggers DEVICE_LIST_CHANGED)
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone")

        // 2. Stale callbacks during settle period - reverted
        mockAudio.currentDefault = airpods
        monitor.handleDefaultInputChanged()
        #expect(monitor.currentDevice == "MacBook Pro Microphone",
                "Stale callback reverted during settle period")
        #expect(monitor.preferredDevice == "MacBook Pro Microphone")

        // 4. Simulate settle period passing
        monitor.lastDeviceListChange = CFAbsoluteTimeGetCurrent() - 10

        // 5. User switches in System Settings
        mockAudio.currentDefault = airpods
        monitor.handleDefaultInputChanged()

        #expect(monitor.preferredDevice == "AirPods Pro 3")
        #expect(prefs.preferredDevice == "AirPods Pro 3")
    }

    // MARK: - Disconnect / reconnect

    @Test("Preferred disconnects → fallback → reconnect accepted")
    func preferredDisconnectReconnect() {
        let (monitor, mockAudio, prefs) = makeMonitor(
            preferred: "AirPods Pro 3",
            current: airpods,
            devices: [macbook, airpods]
        )

        // Disconnect
        mockAudio.devices = [macbook]
        mockAudio.currentDefault = macbook
        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone")
        #expect(monitor.preferredDevice == "AirPods Pro 3",
                "Disconnect fallback should NOT change preferred")
        #expect(prefs.preferredDevice == "AirPods Pro 3")

        // Reconnect
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "AirPods Pro 3")
    }

    @Test("Preferred disconnects, fallback reported before the list change → preferred kept")
    func preferredDisconnectDefaultFirst() {
        let (monitor, mockAudio, prefs) = makeMonitor(
            preferred: "AirPods Pro 3",
            current: airpods,
            devices: [macbook, airpods]
        )
        monitor.lastDeviceListChange = CFAbsoluteTimeGetCurrent() - 10

        // DEFAULT_INPUT_CHANGED (fallback) before DEVICE_LIST_CHANGED
        mockAudio.devices = [macbook]
        mockAudio.currentDefault = macbook
        monitor.handleDefaultInputChanged()
        monitor.handleDeviceListChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone")
        #expect(prefs.preferredDevice == "AirPods Pro 3",
                "Disconnect fallback should NOT change preferred")
    }

    @Test("Rapid connect/disconnect cycles - preferred never changes")
    func rapidCycles() {
        let (monitor, mockAudio, prefs) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        for _ in 0..<5 {
            // Connect
            mockAudio.devices = [macbook, airpods]
            mockAudio.currentDefault = airpods
            mockAudio.setInputDeviceCalls = []
            monitor.handleDeviceListChanged()
            monitor.handleDefaultInputChanged()
            #expect(monitor.currentDevice == "MacBook Pro Microphone")

            // Disconnect
            mockAudio.devices = [macbook]
            mockAudio.currentDefault = macbook
            monitor.handleDeviceListChanged()
        }

        #expect(monitor.preferredDevice == "MacBook Pro Microphone")
        #expect(prefs.preferredDevice == "MacBook Pro Microphone")
    }

    @Test("BT glitch during settle → reverted to preferred")
    func btGlitchDuringSettle() {
        let (monitor, mockAudio, prefs) = makeMonitor(
            preferred: "AirPods Pro 3",
            current: airpods,
            devices: [macbook, airpods]
        )

        // Recent device activity (AirPods just connected)
        monitor.lastDeviceListChange = CFAbsoluteTimeGetCurrent()

        // macOS glitches to MacBook while AirPods still in list
        mockAudio.currentDefault = macbook
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "AirPods Pro 3",
                "Should revert to preferred during settle period")
        #expect(monitor.preferredDevice == "AirPods Pro 3")
        #expect(prefs.preferredDevice == "AirPods Pro 3")
    }

    @Test("Revert extends settle period - prevents bounce from saving preferred")
    func revertExtendsSettle() {
        let (monitor, mockAudio, prefs) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // Last device activity long ago, so only the revert itself can
        // restart the settle period
        monitor.lastDeviceListChange = CFAbsoluteTimeGetCurrent() - 10

        // AirPods take over before their DEVICE_LIST_CHANGED arrives: new device → reverted
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone", "Should revert")

        // AirPods are now known; a bounce back is reverted only because the
        // revert restarted the settle period
        mockAudio.currentDefault = airpods
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone",
                "Should still revert - revert extended the settle period")
        #expect(prefs.preferredDevice == "MacBook Pro Microphone",
                "Should NOT save preferred during extended settle")
    }

    // MARK: - Edge cases

    @Test("Preferred not connected → stays on new device")
    func preferredNotConnected() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "USB Microphone",
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

    @Test("setInputDevice fails → stays on current")
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

    @Test("No preferred set → accepts new device")
    func noPreferred() {
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

    @Test("Second DEVICE_LIST_CHANGED after revert → no re-trigger")
    func secondDeviceListNoRetrigger() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        mockAudio.setInputDeviceCalls = []
        mockAudio.currentDefault = macbook
        monitor.handleDeviceListChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty)
    }

    @Test("Device disconnects → settles on fallback")
    func deviceDisconnects() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "AirPods Pro 3",
            current: airpods,
            devices: [macbook, airpods]
        )

        mockAudio.devices = [macbook]
        mockAudio.currentDefault = macbook
        monitor.handleDeviceListChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone")
    }

    // MARK: - Startup

    @Test("Startup enforces preferred")
    func startupEnforces() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: airpods,
            devices: [macbook, airpods]
        )
        monitor.enforcePreferredOnStartup()
        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"))
    }

    @Test("Startup no-op when preferred is active")
    func startupNoOp() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )
        monitor.enforcePreferredOnStartup()
        #expect(mockAudio.setInputDeviceCalls.isEmpty)
    }

    @Test("Startup skips when preferred is disconnected")
    func startupSkips() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "USB Microphone",
            current: airpods,
            devices: [macbook, airpods]
        )
        monitor.enforcePreferredOnStartup()
        #expect(mockAudio.setInputDeviceCalls.isEmpty)
    }
}
