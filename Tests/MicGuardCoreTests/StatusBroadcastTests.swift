import CoreAudio
import Testing

@testable import MicGuardCore

@Suite("Status Broadcast")
struct StatusBroadcastTests {

    @Test("Payload carries the device name and muted as a string")
    func payloadShape() {
        let status = StatusRecorder()
        let (monitor, mockAudio, _) = makeMonitor(current: usbMic, devices: [macbook, usbMic], status: status)

        mockAudio.muted[usbMic.id] = true
        monitor.broadcastStatus()

        #expect(status.posts.last == ["device": "USB Microphone", "muted": "true"])
    }

    @Test("Volume near zero but not zero is not muted")
    func lowVolumeNotMuted() {
        let status = StatusRecorder()
        let (monitor, mockAudio, _) = makeMonitor(current: usbMic, devices: [macbook, usbMic], status: status)

        mockAudio.volumes[usbMic.id] = 0.004
        monitor.broadcastStatus()
        #expect(status.posts.last?["muted"] == "false")

        mockAudio.volumes[usbMic.id] = 0
        monitor.broadcastStatus()
        #expect(status.posts.last?["muted"] == "true")
    }

    @Test("Last input device removed → device is empty and listeners stop")
    func noInputDevice() {
        let status = StatusRecorder()
        let (monitor, mockAudio, _) = makeMonitor(
            preferred: "USB Microphone", current: usbMic, devices: [usbMic], status: status
        )

        mockAudio.devices = []
        mockAudio.currentDefault = nil
        monitor.handleDeviceListChanged()
        monitor.broadcastStatus()

        #expect(monitor.currentDevice == "")
        #expect(status.posts.last == ["device": "", "muted": "false"])
        #expect(mockAudio.observedDeviceIDs.isEmpty)
    }

    @Test("Switch that lands late → listeners and muted follow the target device")
    func asynchronousSwitch() {
        let status = StatusRecorder()
        let (monitor, mockAudio, _) = makeMonitor(
            mode: "manual", current: macbook, devices: [macbook, usbMic], status: status
        )

        // CoreAudio may apply the new default after setInputDevice returns
        mockAudio.setInputDeviceAppliesImmediately = false
        mockAudio.muted[macbook.id] = true
        monitor.setPreferredDevice(name: "USB Microphone")
        monitor.broadcastStatus()

        #expect(mockAudio.observedDeviceIDs == [usbMic.id])
        #expect(status.posts.last == ["device": "USB Microphone", "muted": "false"])
    }

    @Test("Device recreated under a new ID with the same name → listeners move to the new ID")
    func sameNameNewID() {
        let (monitor, mockAudio, _) = makeMonitor(current: usbMic, devices: [macbook, usbMic])
        #expect(mockAudio.observedDeviceIDs == [usbMic.id])

        // After wake the USB mic comes back as a new object with the same name
        let recreated: (id: AudioDeviceID, name: String) = (id: 4, name: "USB Microphone")
        mockAudio.devices = [macbook, recreated]
        mockAudio.currentDefault = recreated
        monitor.handleDeviceListChanged()
        monitor.handleDefaultInputChanged()

        #expect(mockAudio.observedDeviceIDs == [4])
        #expect(monitor.currentDevice == "USB Microphone")
    }

    @Test("A level change from the observed device triggers a broadcast")
    func levelChangeBroadcasts() async throws {
        let status = StatusRecorder()
        let (monitor, mockAudio, _) = makeMonitor(current: usbMic, devices: [macbook, usbMic], status: status)
        try await Task.sleep(for: .milliseconds(200))
        let before = status.posts.count

        mockAudio.muted[usbMic.id] = true
        mockAudio.fireLevelChange(for: usbMic.id)
        try await Task.sleep(for: .milliseconds(300))

        #expect(status.posts.count == before + 1)
        #expect(status.posts.last == ["device": "USB Microphone", "muted": "true"])
        withExtendedLifetime(monitor) {}
    }
}
