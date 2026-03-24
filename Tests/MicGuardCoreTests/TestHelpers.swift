import CoreAudio
@testable import MicGuardCore

let macbook: (id: AudioDeviceID, name: String) = (id: 1, name: "MacBook Pro Microphone")
let airpods: (id: AudioDeviceID, name: String) = (id: 2, name: "AirPods Pro 3")
let usbMic: (id: AudioDeviceID, name: String) = (id: 3, name: "USB Microphone")

@MainActor
func makeMonitor(
    mode: String = "auto",
    enabled: Bool = true,
    preferred: String = "MacBook Pro Microphone",
    current: (id: AudioDeviceID, name: String) = macbook,
    devices: [(id: AudioDeviceID, name: String)] = [macbook],
    transportTypes: [AudioDeviceID: String] = [:],
    audio: MockAudioDevices? = nil,
    config: MockConfig? = nil
) -> (monitor: AudioMonitor, audio: MockAudioDevices, config: MockConfig) {
    let mockAudio = audio ?? MockAudioDevices()
    let mockConfig = config ?? MockConfig()

    mockAudio.devices = devices
    mockAudio.currentDefault = current
    if !transportTypes.isEmpty {
        mockAudio.transportTypes = transportTypes
    }

    mockConfig.enabled = enabled
    mockConfig.preferredDevice = preferred
    mockConfig.mode = mode

    let monitor = AudioMonitor(audio: mockAudio, config: mockConfig)
    monitor.isEnabled = enabled
    monitor.mode = mode
    monitor.preferredDevice = preferred
    monitor.currentDevice = current.name
    monitor.inputDevices = devices
    monitor.previousDeviceIDs = Set(devices.map(\.id))

    return (monitor, mockAudio, mockConfig)
}
