import CoreAudio
import Testing

@testable import MicGuardCore

@Suite("Auto Mode")
@MainActor
struct AutoModeTests {

    // MARK: - Normal ordering (DEVICE_LIST_CHANGED → DEFAULT_INPUT_CHANGED)

    @Test("New non-preferred device → revert to preferred")
    func newDeviceRevertsToPreferred() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // AirPods connect and macOS makes them default
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods

        monitor.handleDeviceListChanged()

        // handleDeviceListChanged only tracks — doesn't revert
        #expect(mockAudio.setInputDeviceCalls.isEmpty)

        // DEFAULT_INPUT_CHANGED triggers the policy decision
        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"))
        #expect(monitor.currentDevice == "MacBook Pro Microphone")
    }

    @Test("Preferred device reconnects → accepted")
    func preferredDeviceReconnects() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "AirPods Pro 3",
            current: macbook,
            devices: [macbook]
        )

        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods

        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty,
                "Should NOT revert — device is preferred")
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }

    @Test("User switches to known device → saved as preferred")
    func userSwitchSavesPreferred() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, usbMic]
        )

        // USB mic already in device list — user switches via System Settings
        mockAudio.currentDefault = usbMic

        monitor.handleDefaultInputChanged()

        #expect(monitor.preferredDevice == "USB Microphone")
        #expect(mockConfig.writePreferredDeviceCalls.contains("USB Microphone"))
        #expect(monitor.currentDevice == "USB Microphone")
    }

    // MARK: - Race ordering (DEFAULT_INPUT_CHANGED → DEVICE_LIST_CHANGED)

    @Test("New device via race → revert, subsequent DEVICE_LIST_CHANGED is no-op")
    func raceOrderingStillReverts() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // DEFAULT_INPUT_CHANGED fires before DEVICE_LIST_CHANGED
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods

        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"),
                "Should detect new device even via race ordering")
        #expect(monitor.currentDevice == "MacBook Pro Microphone")
        #expect(mockConfig.writePreferredDeviceCalls.isEmpty)

        // Subsequent DEVICE_LIST_CHANGED — no double revert
        mockAudio.setInputDeviceCalls = []
        monitor.handleDeviceListChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty)
    }

    @Test("Preferred device reconnects via race → accepted")
    func preferredReconnectsRaceOrdering() {
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

    @Test("New non-BT device via race → same revert rule")
    func nonBTNewDeviceRaceReverts() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // USB mic connects, DEFAULT_INPUT_CHANGED fires first
        mockAudio.devices = [macbook, usbMic]
        mockAudio.currentDefault = usbMic

        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"),
                "New device reverted regardless of transport type")
        #expect(monitor.currentDevice == "MacBook Pro Microphone")
    }

    // MARK: - Post-revert

    @Test("Stale callback after revert → re-enforces preferred")
    func staleCallbackAfterRevert() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, airpods]
        )
        monitor.revertedFromDeviceID = airpods.id
        monitor.revertTimestamp = CFAbsoluteTimeGetCurrent()

        mockAudio.currentDefault = airpods

        monitor.handleDefaultInputChanged()

        #expect(monitor.preferredDevice == "MacBook Pro Microphone")
        #expect(mockConfig.writePreferredDeviceCalls.isEmpty)
        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"))
    }

    @Test("Multiple stale callbacks after revert all caught")
    func multipleStaleCallbacksCaught() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, airpods]
        )
        monitor.revertedFromDeviceID = airpods.id
        monitor.revertTimestamp = CFAbsoluteTimeGetCurrent()

        // First stale callback
        mockAudio.currentDefault = airpods
        monitor.handleDefaultInputChanged()
        #expect(monitor.currentDevice == "MacBook Pro Microphone")

        // Second stale callback (macOS fires multiple during BT connect)
        mockAudio.currentDefault = airpods
        monitor.handleDefaultInputChanged()
        #expect(monitor.currentDevice == "MacBook Pro Microphone")

        // revertedFromDeviceID still set — will be cleared by timer in production
        #expect(monitor.revertedFromDeviceID == airpods.id)
    }

    @Test("Stale callback check ignores unrelated devices")
    func staleCallbackIgnoresUnrelated() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, airpods, usbMic]
        )
        monitor.revertedFromDeviceID = airpods.id
        monitor.revertTimestamp = CFAbsoluteTimeGetCurrent()

        // USB mic becomes default — NOT the reverted device
        mockAudio.currentDefault = usbMic

        monitor.handleDefaultInputChanged()

        // Should accept switch (not stale), and save as preferred (no recent activity on MacBook)
        #expect(monitor.currentDevice == "USB Microphone")
        #expect(monitor.preferredDevice == "USB Microphone")
    }

    @Test("Stale callback, preferred unavailable → settles on current")
    func staleCallbackPreferredUnavailable() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "USB Microphone",
            current: macbook,
            devices: [macbook, airpods]
        )
        monitor.revertedFromDeviceID = airpods.id
        monitor.revertTimestamp = CFAbsoluteTimeGetCurrent()

        mockAudio.currentDefault = airpods

        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "AirPods Pro 3")
    }

    @Test("Full flow: hijack → revert → stale callbacks → user switch accepted")
    func fullHijackThenUserSwitch() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // 1. Device connects — hijack
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods

        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone")
        #expect(monitor.revertedFromDeviceID == airpods.id)

        // 2. First stale callback
        mockAudio.currentDefault = airpods
        monitor.handleDefaultInputChanged()
        #expect(monitor.currentDevice == "MacBook Pro Microphone")

        // 3. Second stale callback
        mockAudio.currentDefault = airpods
        monitor.handleDefaultInputChanged()
        #expect(monitor.currentDevice == "MacBook Pro Microphone")

        // 4. Simulate suppression expiry + clear recent activity (>3s passed)
        monitor.revertedFromDeviceID = nil
        monitor.recentDeviceActivity.removeAll()

        // 5. User manually switches (no DEVICE_LIST_CHANGED)
        mockAudio.currentDefault = airpods
        mockAudio.setInputDeviceCalls = []

        monitor.handleDefaultInputChanged()

        #expect(monitor.preferredDevice == "AirPods Pro 3")
        #expect(mockConfig.writePreferredDeviceCalls.contains("AirPods Pro 3"))
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }

    @Test("Preferred device disconnects → fallback does not overwrite preferred")
    func disconnectFallbackKeepsPreferred() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "AirPods Pro 3",
            current: airpods,
            devices: [macbook, airpods]
        )

        // AirPods disconnect
        mockAudio.devices = [macbook]
        mockAudio.currentDefault = macbook

        monitor.handleDeviceListChanged()

        // DEFAULT_INPUT_CHANGED: system fallback to MacBook
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone")
        #expect(monitor.preferredDevice == "AirPods Pro 3",
                "Should NOT overwrite preferred — this is a system fallback")
        #expect(mockConfig.writePreferredDeviceCalls.isEmpty)

        // AirPods reconnect — should switch back to preferred
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods

        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "AirPods Pro 3",
                "Should accept — AirPods is the preferred device")
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

        #expect(mockAudio.setInputDeviceCalls.isEmpty,
                "Should not revert — preferred not connected")
        #expect(monitor.currentDevice == "AirPods Pro 3")
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
    func noPreferredAcceptsNew() {
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
    func secondDeviceListChangeNoRetrigger() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods

        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone")

        mockAudio.setInputDeviceCalls = []
        mockAudio.currentDefault = macbook

        monitor.handleDeviceListChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty)
    }

    @Test("Device disconnects → settles on fallback")
    func deviceDisconnectsFallback() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "AirPods Pro 3",
            current: airpods,
            devices: [macbook, airpods]
        )

        // AirPods disconnect, macOS falls back to MacBook
        mockAudio.devices = [macbook]
        mockAudio.currentDefault = macbook

        monitor.handleDeviceListChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone")
    }

    @Test("BT instability: switch away without disconnect does not save preferred")
    func btInstabilityNoDisconnect() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "AirPods Pro 3",
            current: airpods,
            devices: [macbook, airpods]
        )

        // Simulate recent DEVICE_LIST_CHANGED activity on AirPods (BT reconnection)
        monitor.recentDeviceActivity[airpods.id] = CFAbsoluteTimeGetCurrent()

        // macOS switches to MacBook due to BT instability — AirPods still in device list
        mockAudio.currentDefault = macbook

        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone",
                "Should accept the switch")
        #expect(monitor.preferredDevice == "AirPods Pro 3",
                "Should NOT save — old device had recent connection activity")
        #expect(mockConfig.writePreferredDeviceCalls.isEmpty)
    }

    @Test("Production replay: rapid BT connect/disconnect/connect cycle")
    func productionReplayRapidCycle() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // Cycle 1: AirPods connect → reverted
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()
        #expect(monitor.currentDevice == "MacBook Pro Microphone")

        // Cycle 1: stale callback
        mockAudio.currentDefault = airpods
        monitor.handleDefaultInputChanged()
        #expect(monitor.currentDevice == "MacBook Pro Microphone")

        // Cycle 1: AirPods disconnect
        mockAudio.devices = [macbook]
        mockAudio.currentDefault = macbook
        monitor.handleDeviceListChanged()

        // Cycle 2: AirPods reconnect ~1s later → still reverted (new device)
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        mockAudio.setInputDeviceCalls = []
        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()
        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"),
                "Should revert — this is a new device reconnection")
        #expect(monitor.currentDevice == "MacBook Pro Microphone")

        // Cycle 2: AirPods disconnect
        mockAudio.devices = [macbook]
        mockAudio.currentDefault = macbook
        monitor.handleDeviceListChanged()

        // Cycle 3: AirPods reconnect again
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        mockAudio.setInputDeviceCalls = []
        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()
        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"),
                "Should still revert on each reconnection")

        // Through all cycles, preferred never changed
        #expect(monitor.preferredDevice == "MacBook Pro Microphone")
        #expect(mockConfig.writePreferredDeviceCalls.isEmpty)
    }

    @Test("Production replay: preferred disconnect → fallback → reconnect accepted")
    func productionReplayPreferredDisconnectReconnect() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "AirPods Pro 3",
            current: airpods,
            devices: [macbook, airpods]
        )

        // AirPods disconnect
        mockAudio.devices = [macbook]
        mockAudio.currentDefault = macbook
        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone")
        #expect(monitor.preferredDevice == "AirPods Pro 3",
                "Preferred should NOT change on disconnect fallback")

        // AirPods reconnect → should be accepted (it's the preferred)
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        mockAudio.setInputDeviceCalls = []
        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "AirPods Pro 3")
        #expect(mockAudio.setInputDeviceCalls.isEmpty,
                "Should NOT revert — AirPods is the preferred device")
        #expect(mockConfig.writePreferredDeviceCalls.isEmpty)
    }

    @Test("Production replay: BT glitch switches to MacBook then AirPods disconnect later")
    func productionReplayBTGlitchThenDisconnect() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "AirPods Pro 3",
            current: airpods,
            devices: [macbook, airpods]
        )

        // Simulate AirPods had recent connection activity
        monitor.recentDeviceActivity[airpods.id] = CFAbsoluteTimeGetCurrent()

        // macOS glitches: switches to MacBook while AirPods still in device list
        mockAudio.currentDefault = macbook
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone")
        #expect(monitor.preferredDevice == "AirPods Pro 3",
                "BT instability detected — preferred preserved")

        // 2.2s later: AirPods actually removed from device list
        mockAudio.devices = [macbook]
        monitor.handleDeviceListChanged()

        // AirPods reconnect
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "AirPods Pro 3",
                "Preferred device reconnected — accepted")
        #expect(mockConfig.writePreferredDeviceCalls.isEmpty)
    }

    @Test("Startup enforces preferred")
    func startupEnforcesPreferred() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: airpods,
            devices: [macbook, airpods]
        )

        monitor.enforcePreferredOnStartup()

        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"))
        #expect(monitor.currentDevice == "MacBook Pro Microphone")
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
    func startupSkipsDisconnected() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "USB Microphone",
            current: airpods,
            devices: [macbook, airpods]
        )

        monitor.enforcePreferredOnStartup()

        #expect(mockAudio.setInputDeviceCalls.isEmpty)
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }
}
