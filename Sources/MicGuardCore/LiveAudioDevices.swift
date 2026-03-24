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

    public func transportType(for deviceID: AudioDeviceID) -> String {
        AudioDevices.transportType(for: deviceID)
    }

    public func inputVolume(for deviceID: AudioDeviceID) -> Int? {
        AudioDevices.inputVolume(for: deviceID)
    }

    public func isInputMuted(for deviceID: AudioDeviceID) -> Bool? {
        AudioDevices.isInputMuted(for: deviceID)
    }

    public func setInputMuted(for deviceID: AudioDeviceID, muted: Bool) -> Bool {
        AudioDevices.setInputMuted(for: deviceID, muted: muted)
    }

    public func setInputVolume(for deviceID: AudioDeviceID, volume: Int) -> Bool {
        AudioDevices.setInputVolume(for: deviceID, volume: volume)
    }
}
