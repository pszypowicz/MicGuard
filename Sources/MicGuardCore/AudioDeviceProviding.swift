import CoreAudio

@MainActor
public protocol AudioDeviceProviding {
    func listInputDevices() -> [(id: AudioDeviceID, name: String)]
    func currentInputDevice() -> (id: AudioDeviceID, name: String)?
    func setInputDevice(name: String) -> Bool
    func inputVolume(for deviceID: AudioDeviceID) -> Int?
    func isInputMuted(for deviceID: AudioDeviceID) -> Bool?
}
