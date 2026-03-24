import CoreAudio
import Testing

@testable import MicGuardCore

@Suite("Mute State Tracking")
@MainActor
struct MuteTests {

    // MARK: - toggleMute

    @Test("toggleMute sets isMuted and zeros volume")
    func toggleMuteMutes() {
        let (monitor, mockAudio, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        mockAudio.volumes[macbook.id] = 50

        monitor.toggleMute()

        #expect(monitor.isMuted == true)
        #expect(monitor.inputVolume == 0)
        #expect(mockAudio.volumes[macbook.id] == 0)
        #expect(mockAudio.muted[macbook.id] == true)
    }

    @Test("toggleMute unmutes and restores volume")
    func toggleMuteUnmutes() {
        let (monitor, mockAudio, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        mockAudio.volumes[macbook.id] = 50

        // Mute first
        monitor.toggleMute()
        #expect(monitor.isMuted == true)

        // Mock restores volume on setInputVolume (already done by MockAudioDevices)
        monitor.toggleMute()

        #expect(monitor.isMuted == false)
        #expect(monitor.inputVolume == 50)
        #expect(mockAudio.muted[macbook.id] == false)
    }

    @Test("toggleMute round-trip preserves volume")
    func toggleMuteRoundTrip() {
        let (monitor, mockAudio, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        mockAudio.volumes[macbook.id] = 73

        monitor.toggleMute()
        monitor.toggleMute()

        #expect(monitor.isMuted == false)
        #expect(monitor.inputVolume == 73)
        #expect(mockAudio.volumes[macbook.id] == 73)
    }

    @Test("toggleMute saves at least 1 for preMuteVolume when volume is 0")
    func toggleMuteMinPreMuteVolume() {
        let (monitor, mockAudio, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        mockAudio.volumes[macbook.id] = 0

        // Mute (volume already 0) then unmute
        monitor.toggleMute()
        #expect(monitor.isMuted == true)

        monitor.toggleMute()
        #expect(monitor.isMuted == false)
        // preMuteVolume should be at least 1, so restored volume >= 1
        #expect(monitor.inputVolume >= 1)
    }

    @Test("toggleMute with no current device is no-op")
    func toggleMuteNoDevice() {
        let (monitor, mockAudio, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        mockAudio.currentDefault = nil

        monitor.toggleMute()

        #expect(monitor.isMuted == false)
    }

    // MARK: - settleOnDevice

    @Test("settleOnDevice clears isMuted on device switch")
    func settleOnDeviceClearsMute() {
        let (monitor, mockAudio, _) = makeMonitor(
            enabled: false,
            current: macbook,
            devices: [macbook, airpods]
        )
        monitor.isMuted = true

        // Switch default to airpods — disabled mode goes straight to settleOnDevice
        mockAudio.currentDefault = airpods
        monitor.handleDefaultInputChanged()

        #expect(monitor.isMuted == false)
        #expect(monitor.currentDevice == "AirPods Pro 3")
    }

    // MARK: - setVolume

    @Test("setVolume > 0 clears isMuted")
    func setVolumeClearsMute() {
        let (monitor, mockAudio, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        mockAudio.volumes[macbook.id] = 50
        monitor.isMuted = true

        monitor.setVolume(75)

        #expect(monitor.isMuted == false)
    }

    @Test("setVolume(0) does not clear isMuted")
    func setVolumeZeroKeepsMute() {
        let (monitor, mockAudio, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        mockAudio.volumes[macbook.id] = 50
        monitor.isMuted = true

        monitor.setVolume(0)

        #expect(monitor.isMuted == true)
    }

    // MARK: - Startup detection (requires start() to run init logic)

    @Test("Startup with hardware volume 0 sets isMuted")
    func startupMutedByVolume() {
        let mockAudio = MockAudioDevices()
        let mockConfig = MockConfig()
        mockAudio.devices = [macbook]
        mockAudio.currentDefault = macbook
        mockAudio.volumes[macbook.id] = 0
        mockConfig.enabled = true
        mockConfig.preferredDevice = macbook.name
        mockConfig.mode = "auto"

        let monitor = AudioMonitor(audio: mockAudio, config: mockConfig)
        monitor.start()

        #expect(monitor.isMuted == true)
        #expect(monitor.inputVolume == 0)
    }

    @Test("Startup with hardware mute true sets isMuted")
    func startupMutedByHardwareMute() {
        let mockAudio = MockAudioDevices()
        let mockConfig = MockConfig()
        mockAudio.devices = [macbook]
        mockAudio.currentDefault = macbook
        mockAudio.volumes[macbook.id] = 50
        mockAudio.muted[macbook.id] = true
        mockConfig.enabled = true
        mockConfig.preferredDevice = macbook.name
        mockConfig.mode = "auto"

        let monitor = AudioMonitor(audio: mockAudio, config: mockConfig)
        monitor.start()

        #expect(monitor.isMuted == true)
        #expect(monitor.inputVolume == 0)
    }

    @Test("Startup with normal volume leaves isMuted false")
    func startupNotMuted() {
        let mockAudio = MockAudioDevices()
        let mockConfig = MockConfig()
        mockAudio.devices = [macbook]
        mockAudio.currentDefault = macbook
        mockAudio.volumes[macbook.id] = 50
        mockConfig.enabled = true
        mockConfig.preferredDevice = macbook.name
        mockConfig.mode = "auto"

        let monitor = AudioMonitor(audio: mockAudio, config: mockConfig)
        monitor.start()

        #expect(monitor.isMuted == false)
        #expect(monitor.inputVolume == 50)
    }
}
