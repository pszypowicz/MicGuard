public import CoreAudio
import Foundation

public enum AudioDevices {
    public static func listInputDevices() -> [(id: AudioDeviceID, name: String)] {
        let ids = readArray(
            systemObject, globalAddress(kAudioHardwarePropertyDevices), of: AudioDeviceID.self
        ) ?? []
        return ids.compactMap { id in
            guard hasInputChannels(id), let name = deviceName(id) else { return nil }
            return (id: id, name: name)
        }
    }

    public static func currentInputDevice() -> (id: AudioDeviceID, name: String)? {
        guard let deviceID = readValue(
            systemObject, globalAddress(kAudioHardwarePropertyDefaultInputDevice), as: AudioDeviceID.self
        ), let name = deviceName(deviceID) else { return nil }
        return (id: deviceID, name: name)
    }

    public static func setInputDevice(name: String) -> Bool {
        guard let device = listInputDevices().first(where: { $0.name == name }) else {
            return false
        }
        return setInputDevice(id: device.id)
    }

    public static func setInputDevice(id: AudioDeviceID) -> Bool {
        writeValue(systemObject, globalAddress(kAudioHardwarePropertyDefaultInputDevice), id)
    }

    /// Input volume scalar, 0...1.
    public static func inputVolume(for deviceID: AudioDeviceID) -> Float32? {
        // Try master channel (element 0) first, then fall back to first channel
        // (AirPods and some BT devices only expose volume on element 1).
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            let address = inputAddress(kAudioDevicePropertyVolumeScalar, element: element)
            guard hasProperty(deviceID, address),
                  let volume = readValue(deviceID, address, as: Float32.self) else { continue }
            return volume
        }
        return nil
    }

    public static func isInputMuted(for deviceID: AudioDeviceID) -> Bool? {
        let address = inputAddress(kAudioDevicePropertyMute)
        guard hasProperty(deviceID, address),
              let muted = readValue(deviceID, address, as: UInt32.self) else { return nil }
        return muted != 0
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        readString(id, globalAddress(kAudioObjectPropertyName))
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        let channels = inputBufferChannelCounts(id) ?? []
        return channels.contains { $0 > 0 }
    }
}

// MARK: - Property access

// Code in MicGuardCore that hands pointers to CoreAudio belongs here, so the
// unsafe parts stay in one place.
extension AudioDevices {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func inputAddress(
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element
        )
    }

    static func hasProperty(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return unsafe AudioObjectHasProperty(object, &address)
    }

    /// Reads a fixed-size numeric property. Nil if the read fails or returns a
    /// size other than `T`'s. `BitwiseCopyable` lets CoreAudio write `T`'s
    /// bytes directly.
    static func readValue<T: BitwiseCopyable & ExpressibleByIntegerLiteral>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as type: T.Type
    ) -> T? {
        var address = address
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        guard unsafe AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              size == UInt32(MemoryLayout<T>.size) else { return nil }
        return value
    }

    static func writeValue<T: BitwiseCopyable>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T
    ) -> Bool {
        var address = address
        var value = value
        return unsafe AudioObjectSetPropertyData(
            object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value
        ) == noErr
    }

    /// Reads an array property, keeping only the whole elements CoreAudio
    /// returned.
    static func readArray<T: BitwiseCopyable>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of type: T.Type
    ) -> [T]? {
        let stride = MemoryLayout<T>.stride
        return unsafe withPropertyData(object, address) { bytes in
            (0..<(bytes.count / stride)).map { index in
                unsafe bytes.loadUnaligned(fromByteOffset: index * stride, as: T.self)
            }
        }
    }

    /// Reads a CFString property, which CoreAudio hands over already
    /// retained, so the caller releases it.
    static func readString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var name: Unmanaged<CFString>?
        var size = unsafe UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard unsafe AudioObjectGetPropertyData(object, &address, 0, nil, &size, &name) == noErr,
              let string = unsafe name?.takeRetainedValue() else { return nil }
        return string as String
    }

    /// The channel count of each buffer in a device's input stream
    /// configuration. An AudioBufferList is a buffer count followed by that
    /// many AudioBuffers, and only the buffers that fit in the returned bytes
    /// are read, whatever the count says.
    static func inputBufferChannelCounts(_ id: AudioDeviceID) -> [UInt32]? {
        guard let header = unsafe MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) else {
            return nil
        }
        let stride = unsafe MemoryLayout<AudioBuffer>.stride
        return unsafe withPropertyData(id, inputAddress(kAudioDevicePropertyStreamConfiguration)) { bytes in
            guard bytes.count >= header else { return [] }
            let declared = Int(unsafe bytes.loadUnaligned(as: UInt32.self))
            let count = min(declared, (bytes.count - header) / stride)
            return (0..<count).map { index in
                unsafe bytes.loadUnaligned(
                    fromByteOffset: header + index * stride, as: AudioBuffer.self
                ).mNumberChannels
            }
        }
    }

    /// Reads a variable-size property and passes `body` the bytes CoreAudio
    /// wrote. The size can grow between the size query and the read, for
    /// example while devices connect, so a read that runs out of room is
    /// retried. Nil if the property can't be read.
    private static func withPropertyData<R>(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
        _ body: (UnsafeRawBufferPointer) -> R
    ) -> R? {
        var address = address
        for _ in 0..<3 {
            var size: UInt32 = 0
            guard unsafe AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr
            else { return nil }
            guard size > 0 else { return unsafe body(UnsafeRawBufferPointer(start: nil, count: 0)) }

            let buffer = UnsafeMutableRawBufferPointer.allocate(
                byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { unsafe buffer.deallocate() }
            var written = size
            let status = unsafe AudioObjectGetPropertyData(
                object, &address, 0, nil, &written, buffer.baseAddress!
            )
            if status == kAudioHardwareBadPropertySizeError { continue }
            guard status == noErr else { return nil }
            let count = min(Int(written), Int(size))
            return unsafe body(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
        }
        return nil
    }
}

/// The status of a CoreAudio call that failed.
struct CoreAudioError: Error {
    let status: OSStatus
}

/// A CoreAudio property listener that calls `onChange` on the main queue. It
/// stays registered until `remove()` is called or the listener is released.
@safe nonisolated final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var registered = true

    init(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
        onChange: @escaping () -> Void
    ) throws(CoreAudioError) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        var address = address
        let status = unsafe AudioObjectAddPropertyListenerBlock(
            object, &address, DispatchQueue.main, block
        )
        guard status == noErr else { throw CoreAudioError(status: status) }
        self.object = object
        self.address = address
        unsafe self.block = block
    }

    func remove() {
        guard registered else { return }
        registered = false
        unsafe AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }

    deinit {
        remove()
    }
}
