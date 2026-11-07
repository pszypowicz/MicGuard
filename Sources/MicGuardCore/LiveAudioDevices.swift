public import CoreAudio
import Foundation

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

    public func inputVolume(for deviceID: AudioDeviceID) -> Float32? {
        AudioDevices.inputVolume(for: deviceID)
    }

    public func isInputMuted(for deviceID: AudioDeviceID) -> Bool? {
        AudioDevices.isInputMuted(for: deviceID)
    }

    public func observeLevel(
        of deviceID: AudioDeviceID, onChange: @escaping @MainActor () -> Void
    ) -> (any LevelObservation)? {
        LiveLevelObservation(deviceID: deviceID, onChange: onChange)
    }
}

/// CoreAudio listeners on a device's input volume and mute flag, delivered
/// on the main queue. Releasing the observation removes them too.
final class LiveLevelObservation: LevelObservation {
    let deviceID: AudioDeviceID
    private var listeners: [PropertyListener] = []
    private var cancelled = false

    init?(deviceID: AudioDeviceID, onChange: @escaping @MainActor () -> Void) {
        self.deviceID = deviceID
        let handler: () -> Void = { [weak self] in
            Task { @MainActor in
                // A callback queued before cancel() can still arrive
                guard let self, !self.cancelled else { return }
                onChange()
            }
        }

        // Check main element first, fall back to channel 1 (AirPods and some
        // BT devices only expose volume on element 1); listen on the wildcard
        // element to catch per-channel changes.
        let hasVolume = AudioDevices.hasProperty(
            deviceID, AudioDevices.inputAddress(kAudioDevicePropertyVolumeScalar)
        ) || AudioDevices.hasProperty(
            deviceID, AudioDevices.inputAddress(kAudioDevicePropertyVolumeScalar, element: 1)
        )
        if hasVolume {
            listen(to: kAudioDevicePropertyVolumeScalar, handler)
        }
        if AudioDevices.hasProperty(deviceID, AudioDevices.inputAddress(kAudioDevicePropertyMute)) {
            listen(to: kAudioDevicePropertyMute, handler)
        }

        if listeners.isEmpty { return nil }
    }

    private func listen(to selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        let address = AudioDevices.inputAddress(selector, element: kAudioObjectPropertyElementWildcard)
        if let listener = try? PropertyListener(deviceID, address, onChange: handler) {
            listeners.append(listener)
        }
    }

    func cancel() {
        cancelled = true
        for listener in listeners {
            listener.remove()
        }
        listeners = []
    }
}
