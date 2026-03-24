import CoreAudio

@MainActor
public protocol AudioDeviceProviding {
    func listInputDevices() -> [(id: AudioDeviceID, name: String)]
    func currentInputDevice() -> (id: AudioDeviceID, name: String)?
    func setInputDevice(name: String) -> Bool
    func transportType(for deviceID: AudioDeviceID) -> String
    func inputVolume(for deviceID: AudioDeviceID) -> Int?
    func isInputMuted(for deviceID: AudioDeviceID) -> Bool?
    func setInputMuted(for deviceID: AudioDeviceID, muted: Bool) -> Bool
    func setInputVolume(for deviceID: AudioDeviceID, volume: Int) -> Bool
}
