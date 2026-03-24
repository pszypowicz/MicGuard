import CoreAudio
@testable import MicGuardCore

@MainActor
final class MockAudioDevices: AudioDeviceProviding {
    var devices: [(id: AudioDeviceID, name: String)] = []
    var currentDefault: (id: AudioDeviceID, name: String)?
    var transportTypes: [AudioDeviceID: String] = [:]
    var setInputDeviceResult: Bool = true
    var setInputDeviceCalls: [String] = []
    var volumes: [AudioDeviceID: Int] = [:]
    var muted: [AudioDeviceID: Bool] = [:]

    func listInputDevices() -> [(id: AudioDeviceID, name: String)] { devices }
    func currentInputDevice() -> (id: AudioDeviceID, name: String)? { currentDefault }

    func setInputDevice(name: String) -> Bool {
        setInputDeviceCalls.append(name)
        if setInputDeviceResult, let dev = devices.first(where: { $0.name == name }) {
            currentDefault = dev
        }
        return setInputDeviceResult
    }

    func transportType(for deviceID: AudioDeviceID) -> String {
        transportTypes[deviceID] ?? "built-in"
    }

    func inputVolume(for deviceID: AudioDeviceID) -> Int? {
        volumes[deviceID] ?? 50
    }

    func isInputMuted(for deviceID: AudioDeviceID) -> Bool? {
        muted[deviceID]
    }

    func setInputMuted(for deviceID: AudioDeviceID, muted: Bool) -> Bool {
        self.muted[deviceID] = muted
        return true
    }

    func setInputVolume(for deviceID: AudioDeviceID, volume: Int) -> Bool {
        volumes[deviceID] = volume
        return true
    }
}
