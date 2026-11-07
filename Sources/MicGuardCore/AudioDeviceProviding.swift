public import CoreAudio

public protocol AudioDeviceProviding {
    func listInputDevices() -> [(id: AudioDeviceID, name: String)]
    func currentInputDevice() -> (id: AudioDeviceID, name: String)?
    func setInputDevice(name: String) -> Bool
    /// Input volume scalar, 0...1.
    func inputVolume(for deviceID: AudioDeviceID) -> Float32?
    func isInputMuted(for deviceID: AudioDeviceID) -> Bool?
    /// Calls `onChange` when the device's input volume or mute flag changes,
    /// until the observation is cancelled. Nil if the device exposes neither.
    func observeLevel(
        of deviceID: AudioDeviceID, onChange: @escaping @MainActor () -> Void
    ) -> (any LevelObservation)?
}

/// Volume and mute listeners on one device.
public protocol LevelObservation: AnyObject {
    var deviceID: AudioDeviceID { get }
    func cancel()
}
