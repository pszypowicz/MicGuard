import CoreAudio
import Foundation
@testable import MicGuardCore

let macbook: (id: AudioDeviceID, name: String) = (id: 1, name: "MacBook Pro Microphone")
let airpods: (id: AudioDeviceID, name: String) = (id: 2, name: "AirPods Pro 3")
let usbMic: (id: AudioDeviceID, name: String) = (id: 3, name: "USB Microphone")

let testSuiteName = "cz.szypowi.micguard.tests"

/// Collects statusChanged payloads in place of the distributed notification.
@MainActor
final class StatusRecorder {
    var posts: [[String: String]] = []
}

@MainActor
func makeMonitor(
    mode: String = "auto",
    preferred: String = "MacBook Pro Microphone",
    current: (id: AudioDeviceID, name: String) = macbook,
    devices: [(id: AudioDeviceID, name: String)] = [macbook],
    status: StatusRecorder? = nil
) -> (monitor: AudioMonitor, audio: MockAudioDevices, prefs: Preferences) {
    let mockAudio = MockAudioDevices()
    mockAudio.devices = devices
    mockAudio.currentDefault = current

    // A single shared suite, wiped per monitor. Synchronous @MainActor tests
    // serialize, so they cannot wipe each other mid-test. An async test must
    // not read defaults after its first await.
    let defaults = UserDefaults(suiteName: testSuiteName)!
    defaults.removePersistentDomain(forName: testSuiteName)
    let prefs = Preferences(defaults: defaults)

    let monitor = AudioMonitor(audio: mockAudio, prefs: prefs) { status?.posts.append($0) }
    monitor.mode = mode
    monitor.preferredDevice = preferred
    monitor.currentDevice = current.name
    monitor.inputDevices = devices
    monitor.previousDeviceIDs = Set(devices.map(\.id))

    return (monitor, mockAudio, prefs)
}
