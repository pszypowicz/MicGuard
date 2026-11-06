import CoreAudio
@testable import MicGuardCore

@MainActor
final class MockAudioDevices: AudioDeviceProviding {
    var devices: [(id: AudioDeviceID, name: String)] = []
    var currentDefault: (id: AudioDeviceID, name: String)?
    var setInputDeviceResult: Bool = true
    /// False models CoreAudio applying the new default after the call returns.
    var setInputDeviceAppliesImmediately = true
    var setInputDeviceCalls: [String] = []
    var volumes: [AudioDeviceID: Float32] = [:]
    var muted: [AudioDeviceID: Bool] = [:]
    private var observations: [MockLevelObservation] = []

    /// Devices with level listeners that haven't been cancelled.
    var observedDeviceIDs: [AudioDeviceID] {
        observations.filter { !$0.cancelled }.map(\.deviceID)
    }

    func listInputDevices() -> [(id: AudioDeviceID, name: String)] { devices }
    func currentInputDevice() -> (id: AudioDeviceID, name: String)? { currentDefault }

    func setInputDevice(name: String) -> Bool {
        setInputDeviceCalls.append(name)
        if setInputDeviceResult, setInputDeviceAppliesImmediately,
           let dev = devices.first(where: { $0.name == name }) {
            currentDefault = dev
        }
        return setInputDeviceResult
    }

    func inputVolume(for deviceID: AudioDeviceID) -> Float32? {
        volumes[deviceID] ?? 0.5
    }

    func isInputMuted(for deviceID: AudioDeviceID) -> Bool? {
        muted[deviceID]
    }

    func observeLevel(
        of deviceID: AudioDeviceID, onChange: @escaping @MainActor () -> Void
    ) -> (any LevelObservation)? {
        let observation = MockLevelObservation(deviceID: deviceID, onChange: onChange)
        observations.append(observation)
        return observation
    }

    func fireLevelChange(for deviceID: AudioDeviceID) {
        for observation in observations where !observation.cancelled && observation.deviceID == deviceID {
            observation.onChange()
        }
    }
}

@MainActor
final class MockLevelObservation: LevelObservation {
    let deviceID: AudioDeviceID
    let onChange: @MainActor () -> Void
    var cancelled = false

    init(deviceID: AudioDeviceID, onChange: @escaping @MainActor () -> Void) {
        self.deviceID = deviceID
        self.onChange = onChange
    }

    func cancel() { cancelled = true }
}
