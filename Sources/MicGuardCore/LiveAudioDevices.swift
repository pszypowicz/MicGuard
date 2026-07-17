import CoreAudio

public struct LiveAudioDevices: AudioDeviceProviding {
    public init() {}

    public func listInputDevices() -> [(id: AudioDeviceID, name: String)] {
        AudioDevices.listInputDevices()
    }

    public func currentInputDevice() -> (id: AudioDeviceID, name: String)? {
        AudioDevices.currentInputDevice()
    }

    public func setInputDevice(name: String) -> Bool {
        AudioDevices.setInputDevice(name: name)
    }

    public func inputVolume(for deviceID: AudioDeviceID) -> Int? {
        AudioDevices.inputVolume(for: deviceID)
    }

    public func isInputMuted(for deviceID: AudioDeviceID) -> Bool? {
        AudioDevices.isInputMuted(for: deviceID)
    }
}
