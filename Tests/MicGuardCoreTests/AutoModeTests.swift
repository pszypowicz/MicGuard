import CoreAudio
import Testing

@testable import MicGuardCore

@Suite("Auto Mode")
@MainActor
struct AutoModeTests {

    @Test("BT hijack reverts to preferred device")
    func btHijackRevertsToPreferred() {
        // Start with MacBook as preferred and current, only MacBook connected
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // AirPods connect and macOS makes them default
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        mockAudio.transportTypes[airpods.id] = "bluetooth"

        monitor.handleDeviceListChanged()

        // Revert is deferred until DEFAULT_INPUT_CHANGED confirms
        #expect(monitor.pendingBTHijack == true)
        #expect(mockAudio.setInputDeviceCalls.isEmpty,
                "Should NOT revert yet — waiting for correlation")

        // DEFAULT_INPUT_CHANGED fires, confirming the hijack
        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"),
                "Should revert to preferred MacBook")
        #expect(monitor.currentDevice == "MacBook Pro Microphone")
        #expect(monitor.pendingBTHijack == false)
    }

    @Test("BT hijack with preferred unavailable stays on BT device")
    func btHijackPreferredUnavailable() {
        // Preferred is a USB mic that is disconnected
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "USB Microphone",
            current: macbook,
            devices: [macbook]
        )

        // AirPods connect, USB mic still absent
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        mockAudio.transportTypes[airpods.id] = "bluetooth"

        monitor.handleDeviceListChanged()

        #expect(monitor.pendingBTHijack == true)

        // DEFAULT_INPUT_CHANGED confirms — but preferred not connected
        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty,
                "Should not attempt to revert — preferred not connected")
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }

    @Test("BT device IS the preferred device — no revert")
    func btDeviceIsPreferred() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "AirPods Pro 3",
            current: macbook,
            devices: [macbook]
        )

        // AirPods connect and become default — but they ARE the preferred device
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        mockAudio.transportTypes[airpods.id] = "bluetooth"

        monitor.handleDeviceListChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty,
                "Should not revert — BT device is preferred")
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }

    @Test("User-initiated switch saves as new preferred")
    func userSwitchSavesPreferred() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, usbMic]
        )

        // User switches to USB mic (handleDefaultInputChanged, not device list change)
        mockAudio.currentDefault = usbMic

        monitor.handleDefaultInputChanged()

        #expect(monitor.preferredDevice == "USB Microphone")
        #expect(mockConfig.writePreferredDeviceCalls.contains("USB Microphone"))
        #expect(monitor.currentDevice == "USB Microphone")
    }

    @Test("Non-BT device connects — no hijack detection")
    func nonBTDeviceNoHijack() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // USB mic connects and becomes default (transport = usb, not bluetooth)
        mockAudio.devices = [macbook, usbMic]
        mockAudio.currentDefault = usbMic
        mockAudio.transportTypes[usbMic.id] = "usb"

        monitor.handleDeviceListChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty,
                "Should not trigger BT hijack for non-bluetooth device")
        #expect(monitor.currentDevice == "USB Microphone")
    }

    @Test("Startup enforces preferred device in auto mode")
    func startupEnforcesPreferred() {
        // Simulate reboot: macOS picked AirPods as default, but user prefers MacBook
        let (monitor, mockAudio, _) = makeMonitor(
            mode: "auto",
            preferred: "MacBook Pro Microphone",
            current: airpods,
            devices: [macbook, airpods]
        )

        monitor.enforcePreferredOnStartup()

        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"))
        #expect(monitor.currentDevice == "MacBook Pro Microphone")
    }

    @Test("Startup does nothing when preferred device is already active")
    func startupNoOpWhenAlreadyPreferred() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        monitor.enforcePreferredOnStartup()

        #expect(mockAudio.setInputDeviceCalls.isEmpty)
        #expect(monitor.currentDevice == "MacBook Pro Microphone")
    }

    @Test("Startup skips enforcement when preferred device is disconnected")
    func startupSkipsDisconnectedPreferred() {
        // Preferred is USB mic but it's not connected
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "USB Microphone",
            current: airpods,
            devices: [macbook, airpods]
        )

        monitor.enforcePreferredOnStartup()

        #expect(mockAudio.setInputDeviceCalls.isEmpty)
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }

    @Test("Stale callback after BT revert does not save as preferred")
    func staleCallbackAfterRevert() {
        // BT hijack was reverted — flag is set
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook, airpods]
        )
        monitor.revertingToPreferred = true

        // Stale callback arrives: macOS still reports AirPods as default
        mockAudio.currentDefault = airpods

        monitor.handleDefaultInputChanged()

        #expect(monitor.preferredDevice == "MacBook Pro Microphone",
                "Should NOT save AirPods as preferred")
        #expect(mockConfig.writePreferredDeviceCalls.isEmpty,
                "Should NOT write preferred device")
        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"),
                "Should re-enforce MacBook")
        #expect(monitor.revertingToPreferred == false,
                "Flag should be cleared")
    }

    @Test("Flag is cleared even if preferred is unavailable during stale callback")
    func staleCallbackPreferredUnavailable() {
        // Preferred device disconnected between revert and stale callback
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "USB Microphone",
            current: macbook,
            devices: [macbook, airpods]
        )
        monitor.revertingToPreferred = true

        mockAudio.currentDefault = airpods

        monitor.handleDefaultInputChanged()

        #expect(monitor.revertingToPreferred == false, "Flag should be cleared")
        // Falls through to settleOnDevice since preferred not in list
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }

    @Test("User manual switch after BT hijack revert is accepted")
    func userSwitchAfterHijackRevert() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // 1. AirPods connect — BT hijack
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        mockAudio.transportTypes[airpods.id] = "bluetooth"

        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "MacBook Pro Microphone")
        #expect(monitor.revertingToPreferred == true)

        // 2. Stale callback arrives — re-enforces preferred
        mockAudio.currentDefault = airpods
        monitor.handleDefaultInputChanged()

        #expect(monitor.revertingToPreferred == false)
        #expect(monitor.currentDevice == "MacBook Pro Microphone")

        // 3. User manually switches to AirPods in System Settings
        //    Only DEFAULT_INPUT_CHANGED fires (no DEVICE_LIST_CHANGED)
        mockAudio.currentDefault = airpods
        mockAudio.setInputDeviceCalls = []

        monitor.handleDefaultInputChanged()

        #expect(monitor.preferredDevice == "AirPods Pro 3",
                "Should accept user's manual switch")
        #expect(mockConfig.writePreferredDeviceCalls.contains("AirPods Pro 3"))
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }

    @Test("DEFAULT_INPUT_CHANGED before DEVICE_LIST_CHANGED still detects hijack")
    func defaultInputBeforeDeviceList() {
        // DEFAULT_INPUT_CHANGED can race ahead of DEVICE_LIST_CHANGED
        // due to Task scheduling on MainActor
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // AirPods connect — CoreAudio state updated, but only DEFAULT_INPUT_CHANGED
        // fires first (DEVICE_LIST_CHANGED hasn't been processed yet)
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        mockAudio.transportTypes[airpods.id] = "bluetooth"

        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.contains("MacBook Pro Microphone"),
                "Should detect hijack even when DEFAULT_INPUT_CHANGED arrives first")
        #expect(monitor.currentDevice == "MacBook Pro Microphone")
        #expect(mockConfig.writePreferredDeviceCalls.isEmpty,
                "Should NOT save AirPods as preferred")

        // Subsequent DEVICE_LIST_CHANGED should be a no-op
        mockAudio.setInputDeviceCalls = []
        monitor.handleDeviceListChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty,
                "Should not double-revert — AirPods already in previousDeviceIDs")
    }

    @Test("Preferred BT device reconnect via DEFAULT_INPUT_CHANGED first is accepted")
    func preferredBTReconnectRaceOrdering() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "AirPods Pro 3",
            current: macbook,
            devices: [macbook]
        )

        // AirPods (the preferred device) reconnect, DEFAULT_INPUT_CHANGED first
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        mockAudio.transportTypes[airpods.id] = "bluetooth"

        monitor.handleDefaultInputChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty,
                "Should NOT revert — AirPods is the preferred device")
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }

    @Test("Non-BT device connection via race does not save as preferred")
    func nonBTDeviceConnectionRace() {
        let (monitor, mockAudio, mockConfig) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // USB mic connects, DEFAULT_INPUT_CHANGED fires first
        mockAudio.devices = [macbook, usbMic]
        mockAudio.currentDefault = usbMic
        mockAudio.transportTypes[usbMic.id] = "usb"

        monitor.handleDefaultInputChanged()

        #expect(monitor.currentDevice == "USB Microphone",
                "Should accept non-BT device")
        #expect(monitor.preferredDevice == "MacBook Pro Microphone",
                "Should NOT save as preferred — this is a device connection, not user switch")
        #expect(mockConfig.writePreferredDeviceCalls.isEmpty)
    }

    @Test("Second DEVICE_LIST_CHANGED after revert does not re-trigger hijack")
    func secondDeviceListChangeAfterRevert() {
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "MacBook Pro Microphone",
            current: macbook,
            devices: [macbook]
        )

        // AirPods connect — first DEVICE_LIST_CHANGED
        mockAudio.devices = [macbook, airpods]
        mockAudio.currentDefault = airpods
        mockAudio.transportTypes[airpods.id] = "bluetooth"

        monitor.handleDeviceListChanged()
        #expect(monitor.pendingBTHijack == true)

        // DEFAULT_INPUT_CHANGED confirms hijack and reverts
        monitor.handleDefaultInputChanged()
        #expect(monitor.currentDevice == "MacBook Pro Microphone")

        mockAudio.setInputDeviceCalls = []

        // Second DEVICE_LIST_CHANGED arrives (race variant C from logs)
        // AirPods still in list but MacBook is now default after revert
        mockAudio.currentDefault = macbook

        monitor.handleDeviceListChanged()

        #expect(mockAudio.setInputDeviceCalls.isEmpty,
                "Should not re-trigger — AirPods already in previousDeviceIDs")
        #expect(monitor.pendingBTHijack == false)
    }
}
