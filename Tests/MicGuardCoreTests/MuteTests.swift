import CoreAudio
import Testing

@testable import MicGuardCore

@Suite("Mute State Tracking")
@MainActor
struct MuteTests {

    // MARK: - reloadConfig

    @Test("reloadConfig updates enabled from config")
    func reloadConfigEnabled() {
        let (monitor, _, mockConfig) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        #expect(monitor.isEnabled == true)

        mockConfig.enabled = false
        monitor.reloadConfig()

        #expect(monitor.isEnabled == false)
    }

    @Test("reloadConfig updates mode from config")
    func reloadConfigMode() {
        let (monitor, _, mockConfig) = makeMonitor(
            mode: "auto",
            current: macbook,
            devices: [macbook]
        )

        mockConfig.mode = "manual"
        monitor.reloadConfig()

        #expect(monitor.mode == "manual")
    }

    @Test("reloadConfig updates preferred device from config")
    func reloadConfigPreferred() {
        let (monitor, _, mockConfig) = makeMonitor(
            current: macbook,
            devices: [macbook, airpods]
        )

        mockConfig.preferredDevice = "AirPods Pro 3"
        monitor.reloadConfig()

        #expect(monitor.preferredDevice == "AirPods Pro 3")
    }

    @Test("reloadConfig is no-op when config unchanged")
    func reloadConfigNoop() {
        let (monitor, _, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        let oldEnabled = monitor.isEnabled
        let oldMode = monitor.mode
        let oldPreferred = monitor.preferredDevice

        monitor.reloadConfig()

        #expect(monitor.isEnabled == oldEnabled)
        #expect(monitor.mode == oldMode)
        #expect(monitor.preferredDevice == oldPreferred)
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

    // MARK: - External volume change detection

    @Test("External volume → 0 triggers mute")
    func externalVolumeZeroMutes() {
        let (monitor, mockAudio, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        mockAudio.volumes[macbook.id] = 50
        monitor.inputVolume = 50

        // Simulate CLI setting volume to 0
        mockAudio.volumes[macbook.id] = 0
        monitor.handleExternalVolumeChange(deviceID: macbook.id, deviceName: macbook.name)

        #expect(monitor.isMuted == true)
        #expect(monitor.inputVolume == 0)
        #expect(monitor.preMuteVolume == 50)
    }

    @Test("External volume > 0 while muted triggers unmute")
    func externalVolumePositiveUnmutes() {
        let (monitor, mockAudio, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        mockAudio.volumes[macbook.id] = 0
        monitor.inputVolume = 0
        monitor.isMuted = true
        monitor.preMuteVolume = 50

        // Simulate CLI setting volume to 75
        mockAudio.volumes[macbook.id] = 75
        monitor.handleExternalVolumeChange(deviceID: macbook.id, deviceName: macbook.name)

        #expect(monitor.isMuted == false)
        #expect(monitor.inputVolume == 75)
    }

    @Test("External volume change while muted and still 0 is ignored")
    func externalVolumeZeroWhileMutedIgnored() {
        let (monitor, mockAudio, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        mockAudio.volumes[macbook.id] = 0
        monitor.inputVolume = 0
        monitor.isMuted = true
        monitor.preMuteVolume = 50

        // Volume stays 0 — no change to detect
        monitor.handleExternalVolumeChange(deviceID: macbook.id, deviceName: macbook.name)

        #expect(monitor.isMuted == true)
        #expect(monitor.preMuteVolume == 50)
    }

    @Test("Normal external volume change updates inputVolume")
    func externalVolumeChangeUpdates() {
        let (monitor, mockAudio, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        mockAudio.volumes[macbook.id] = 50
        monitor.inputVolume = 50

        mockAudio.volumes[macbook.id] = 75
        monitor.handleExternalVolumeChange(deviceID: macbook.id, deviceName: macbook.name)

        #expect(monitor.isMuted == false)
        #expect(monitor.inputVolume == 75)
    }

    // MARK: - External hw mute change detection

    @Test("External hw mute triggers isMuted and saves volume")
    func externalHwMuteMutes() {
        let (monitor, mockAudio, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        mockAudio.volumes[macbook.id] = 50
        monitor.inputVolume = 50

        mockAudio.muted[macbook.id] = true
        monitor.handleExternalMuteChange(deviceID: macbook.id, deviceName: macbook.name)

        #expect(monitor.isMuted == true)
        #expect(monitor.inputVolume == 0)
        #expect(monitor.preMuteVolume == 50)
    }

    @Test("External hw unmute restores pre-mute volume")
    func externalHwUnmuteRestores() {
        let (monitor, mockAudio, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        mockAudio.volumes[macbook.id] = 0
        monitor.inputVolume = 0
        monitor.isMuted = true
        monitor.preMuteVolume = 49

        mockAudio.muted[macbook.id] = false
        monitor.handleExternalMuteChange(deviceID: macbook.id, deviceName: macbook.name)

        #expect(monitor.isMuted == false)
        #expect(monitor.inputVolume == 49)
        #expect(mockAudio.volumes[macbook.id] == 49)
    }

    @Test("External hw mute when already muted is idempotent")
    func externalHwMuteAlreadyMutedNoop() {
        let (monitor, mockAudio, _) = makeMonitor(
            current: macbook,
            devices: [macbook]
        )
        monitor.isMuted = true
        monitor.preMuteVolume = 50
        monitor.inputVolume = 0

        mockAudio.muted[macbook.id] = true
        monitor.handleExternalMuteChange(deviceID: macbook.id, deviceName: macbook.name)

        #expect(monitor.isMuted == true)
        #expect(monitor.preMuteVolume == 50)
        #expect(monitor.inputVolume == 0)
    }
}
