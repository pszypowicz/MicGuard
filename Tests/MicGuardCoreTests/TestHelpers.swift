import CoreAudio
import Foundation
@testable import MicGuardCore

let macbook: (id: AudioDeviceID, name: String) = (id: 1, name: "MacBook Pro Microphone")
let airpods: (id: AudioDeviceID, name: String) = (id: 2, name: "AirPods Pro 3")
let usbMic: (id: AudioDeviceID, name: String) = (id: 3, name: "USB Microphone")

private let testSuiteName = "cz.szypowi.micguard.tests"

@MainActor
func makeMonitor(
    mode: String = "auto",
    preferred: String = "MacBook Pro Microphone",
    current: (id: AudioDeviceID, name: String) = macbook,
    devices: [(id: AudioDeviceID, name: String)] = [macbook]
) -> (monitor: AudioMonitor, audio: MockAudioDevices, prefs: Preferences) {
    let mockAudio = MockAudioDevices()
    mockAudio.devices = devices
    mockAudio.currentDefault = current

    // A single shared suite, wiped per monitor: @MainActor test functions are
    // synchronous, so they serialize and cannot wipe each other mid-test.
    let defaults = UserDefaults(suiteName: testSuiteName)!
    defaults.removePersistentDomain(forName: testSuiteName)
    let prefs = Preferences(defaults: defaults)

    let monitor = AudioMonitor(audio: mockAudio, prefs: prefs)
    monitor.mode = mode
    monitor.preferredDevice = preferred
    monitor.currentDevice = current.name
    monitor.inputDevices = devices
    monitor.previousDeviceIDs = Set(devices.map(\.id))

    return (monitor, mockAudio, prefs)
}
