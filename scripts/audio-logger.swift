#!/usr/bin/env swift
// audio-logger.swift — CoreAudio event logger for MicGuard research
// Usage: swift scripts/audio-logger.swift
// Logs every CoreAudio property change with timestamps. Ctrl-C to stop.

import CoreAudio
import Foundation

// MARK: - Helpers

func deviceName(_ id: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
          let cfName = name?.takeRetainedValue() else { return nil }
    return cfName as String
}

func hasInputChannels(_ id: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
    let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { rawPtr.deallocate() }
    let bufferListPtr = rawPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferListPtr) == noErr else { return false }
    let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
    return bufferList.contains { $0.mNumberChannels > 0 }
}

func transportType(for deviceID: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else { return "unknown" }
    switch transport {
    case kAudioDeviceTransportTypeBuiltIn: return "built-in"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeAggregate: return "aggregate"
    default: return "unknown(\(transport))"
    }
}

func listInputDevices() -> [(id: AudioDeviceID, name: String)] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices) == noErr else { return [] }
    return devices.compactMap { id in
        guard hasInputChannels(id), let name = deviceName(id) else { return nil }
        return (id: id, name: name)
    }
}

func currentInputDevice() -> (id: AudioDeviceID, name: String)? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
          let name = deviceName(deviceID) else { return nil }
    return (id: deviceID, name: name)
}

func inputVolume(for deviceID: AudioDeviceID) -> Int? {
    for element: UInt32 in [kAudioObjectPropertyElementMain, 1] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { continue }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr else { continue }
        return Int((volume * 100).rounded())
    }
    return nil
}

func isInputMuted(for deviceID: AudioDeviceID) -> Bool? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return nil }
    var muted: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr else { return nil }
    return muted != 0
}

// MARK: - Logging

let startTime = CFAbsoluteTimeGetCurrent()
let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "HH:mm:ss.SSS"

func timestamp() -> String {
    let now = Date()
    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
    return "\(dateFormatter.string(from: now)) [+\(String(format: "%.3f", elapsed))s]"
}

func log(_ message: String) {
    print("\(timestamp())  \(message)")
    fflush(stdout)
}

func logDeviceSnapshot(label: String) {
    let devices = listInputDevices()
    let current = currentInputDevice()
    log("\(label) input devices (\(devices.count)):")
    for d in devices {
        let isCurrent = d.id == current?.id ? " ← DEFAULT" : ""
        let transport = transportType(for: d.id)
        let vol = inputVolume(for: d.id).map { "\($0)%" } ?? "n/a"
        let muted = isInputMuted(for: d.id).map { $0 ? "muted" : "unmuted" } ?? "n/a"
        log("  [\(d.id)] \(d.name) (\(transport)) vol=\(vol) \(muted)\(isCurrent)")
    }
}

// MARK: - Listeners

// Keep listener blocks alive
var listenerBlocks: [AudioObjectPropertyListenerBlock] = []
var perDeviceListenerBlocks: [(deviceID: AudioDeviceID, block: AudioObjectPropertyListenerBlock, selector: AudioObjectPropertySelector)] = []

func registerPerDeviceListeners(for deviceID: AudioDeviceID) {
    // Unregister old per-device listeners
    for entry in perDeviceListenerBlocks {
        var addr = AudioObjectPropertyAddress(
            mSelector: entry.selector,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementWildcard
        )
        AudioObjectRemovePropertyListenerBlock(entry.deviceID, &addr, DispatchQueue.main, entry.block)
    }
    perDeviceListenerBlocks.removeAll()

    let name = deviceName(deviceID) ?? "device \(deviceID)"

    // Volume listener
    var volCheck = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    if AudioObjectHasProperty(deviceID, &volCheck) {
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementWildcard
        )
        let block: AudioObjectPropertyListenerBlock = { numAddresses, addresses in
            let elements = (0..<Int(numAddresses)).map { addresses[$0].mElement }
            let vol = inputVolume(for: deviceID).map { "\($0)%" } ?? "n/a"
            log("VOLUME_CHANGED  device='\(name)' id=\(deviceID) elements=\(elements) vol=\(vol)")
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &volAddr, DispatchQueue.main, block) == noErr {
            perDeviceListenerBlocks.append((deviceID, block, kAudioDevicePropertyVolumeScalar))
        }
    }

    // Mute listener
    var muteCheck = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    if AudioObjectHasProperty(deviceID, &muteCheck) {
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementWildcard
        )
        let block: AudioObjectPropertyListenerBlock = { numAddresses, addresses in
            let muted = isInputMuted(for: deviceID).map { $0 ? "yes" : "no" } ?? "n/a"
            let vol = inputVolume(for: deviceID).map { "\($0)%" } ?? "n/a"
            log("MUTE_CHANGED    device='\(name)' id=\(deviceID) muted=\(muted) vol=\(vol)")
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &muteAddr, DispatchQueue.main, block) == noErr {
            perDeviceListenerBlocks.append((deviceID, block, kAudioDevicePropertyMute))
        }
    }

    // Data source listener (some devices change data source during transitions)
    var dsCheck = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    if AudioObjectHasProperty(deviceID, &dsCheck) {
        var dsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementWildcard
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            log("DATA_SOURCE_CHANGED  device='\(name)' id=\(deviceID)")
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &dsAddr, DispatchQueue.main, block) == noErr {
            perDeviceListenerBlocks.append((deviceID, block, kAudioDevicePropertyDataSource))
        }
    }
}

// Default input device changed
func registerGlobalListeners() {
    var defaultInputAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let defaultInputBlock: AudioObjectPropertyListenerBlock = { _, _ in
        let device = currentInputDevice()
        let name = device?.name ?? "(none)"
        let id = device?.id ?? 0
        let transport = device.map { transportType(for: $0.id) } ?? "none"
        let vol = device.flatMap { inputVolume(for: $0.id) }.map { "\($0)%" } ?? "n/a"
        log("DEFAULT_INPUT_CHANGED  device='\(name)' id=\(id) transport=\(transport) vol=\(vol)")
        logDeviceSnapshot(label: "  snapshot:")
        if let d = device {
            registerPerDeviceListeners(for: d.id)
        }
    }
    if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddr, DispatchQueue.main, defaultInputBlock) == noErr {
        listenerBlocks.append(defaultInputBlock)
        log("Registered: DEFAULT_INPUT_CHANGED listener")
    }

    // Device list changed
    var devicesAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let devicesBlock: AudioObjectPropertyListenerBlock = { _, _ in
        log("DEVICE_LIST_CHANGED")
        logDeviceSnapshot(label: "  snapshot:")
    }
    if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, DispatchQueue.main, devicesBlock) == noErr {
        listenerBlocks.append(devicesBlock)
        log("Registered: DEVICE_LIST_CHANGED listener")
    }

    // Default output device changed (useful for BT devices that switch profiles)
    var defaultOutputAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let defaultOutputBlock: AudioObjectPropertyListenerBlock = { _, _ in
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let name: String
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
           let n = deviceName(deviceID) {
            name = n
        } else {
            name = "(none)"
        }
        log("DEFAULT_OUTPUT_CHANGED  device='\(name)' id=\(deviceID)")
    }
    if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddr, DispatchQueue.main, defaultOutputBlock) == noErr {
        listenerBlocks.append(defaultOutputBlock)
        log("Registered: DEFAULT_OUTPUT_CHANGED listener")
    }
}

// MARK: - Main

print("╔══════════════════════════════════════════════════╗")
print("║         CoreAudio Event Logger for MicGuard      ║")
print("║         Press Ctrl-C to stop                     ║")
print("╚══════════════════════════════════════════════════╝")
print()

logDeviceSnapshot(label: "Initial")
print()

registerGlobalListeners()
if let device = currentInputDevice() {
    registerPerDeviceListeners(for: device.id)
    log("Per-device listeners registered for '\(device.name)' (id=\(device.id))")
}

print()
log("Ready. Waiting for events...")
print()

// Keep running
signal(SIGINT) { _ in
    print("\nStopping...")
    exit(0)
}

RunLoop.main.run()
