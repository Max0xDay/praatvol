import AudioToolbox
import CoreAudio
import Foundation
import PraatvolCore

func checkStatus(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw PraatvolError("\(operation) failed (Core Audio status \(status)).") }
}

struct MicrophoneDevice {
    let identifier: AudioDeviceID
    let uniqueIdentifier: String
    let name: String
}

enum AudioDevices {
    static func property<Value>(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                value: inout Value) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try checkStatus(status, "Read audio device property")
    }

    static func microphones() throws -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        try checkStatus(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size), "List audio devices")
        var identifiers = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try checkStatus(AudioObjectGetPropertyData(system, &address, 0, nil, &size, &identifiers), "Read audio devices")
        var microphones: [MicrophoneDevice] = []
        for identifier in identifiers {
            if try hasInput(identifier) {
                var name: CFString = "" as CFString
                var uniqueIdentifier: CFString = "" as CFString
                try property(identifier, selector: kAudioObjectPropertyName, value: &name)
                try property(identifier, selector: kAudioDevicePropertyDeviceUID, value: &uniqueIdentifier)
                microphones.append(MicrophoneDevice(identifier: identifier, uniqueIdentifier: uniqueIdentifier as String, name: name as String))
            }
        }
        return microphones
    }

    private static func hasInput(_ identifier: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try checkStatus(AudioObjectGetPropertyDataSize(identifier, &address, 0, nil, &size), "Read input channels")
        guard size > 0 else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        try checkStatus(AudioObjectGetPropertyData(identifier, &address, 0, nil, &size, memory), "Read input streams")
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    static func selected(_ uniqueIdentifier: String) throws -> MicrophoneDevice {
        let devices = try microphones()
        if !uniqueIdentifier.isEmpty {
            guard let device = devices.first(where: { $0.uniqueIdentifier == uniqueIdentifier }) else {
                throw PraatvolError("The selected microphone is unavailable. Choose an input in Settings.")
            }
            return device
        }
        var identifier = AudioDeviceID(kAudioObjectUnknown)
        try property(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice, value: &identifier)
        guard let device = devices.first(where: { $0.identifier == identifier }) else {
            throw PraatvolError("No default microphone exists. Select an input in System Settings > Sound > Input.")
        }
        return device
    }
}
