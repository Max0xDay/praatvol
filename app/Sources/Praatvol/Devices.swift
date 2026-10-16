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
    let transportType: UInt32

    var descriptor: MicrophoneDescriptor {
        let transport: MicrophoneTransport
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: transport = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = .bluetooth
        case kAudioDeviceTransportTypeVirtual: transport = .virtual
        case kAudioDeviceTransportTypeAggregate: transport = .aggregate
        default: transport = .other
        }
        return MicrophoneDescriptor(identifier: uniqueIdentifier, name: name, transport: transport)
    }
}

enum AudioDevices {
    static func property<Value>(
        _ object: AudioObjectID, selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        value: inout Value
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try checkStatus(status, "Read audio device property")
    }

    static func microphones() throws -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        try checkStatus(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size), "List audio devices")
        var identifiers = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try checkStatus(AudioObjectGetPropertyData(system, &address, 0, nil, &size, &identifiers), "Read audio devices")
        var microphones: [MicrophoneDevice] = []
        for identifier in identifiers {
            do {
                if let microphone = try microphone(identifier) { microphones.append(microphone) }
            } catch {
                AppLog.shared.event("microphone-device-read-failed", code: (error as NSError).code)
            }
        }
        return microphones
    }

    private static func microphone(_ identifier: AudioDeviceID) throws -> MicrophoneDevice? {
        guard try hasInput(identifier) else { return nil }
        var name: CFString = "" as CFString
        var uniqueIdentifier: CFString = "" as CFString
        try property(identifier, selector: kAudioObjectPropertyName, value: &name)
        try property(identifier, selector: kAudioDevicePropertyDeviceUID, value: &uniqueIdentifier)
        var transportType: UInt32 = 0
        try property(identifier, selector: kAudioDevicePropertyTransportType, value: &transportType)
        return MicrophoneDevice(
            identifier: identifier, uniqueIdentifier: uniqueIdentifier as String, name: name as String,
            transportType: transportType)
    }

    private static func hasInput(_ identifier: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try checkStatus(AudioObjectGetPropertyDataSize(identifier, &address, 0, nil, &size), "Read input channels")
        guard size > 0 else { return false }
        let memory = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        try checkStatus(AudioObjectGetPropertyData(identifier, &address, 0, nil, &size, memory), "Read input streams")
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    static func candidates(
        call: Bool, chosenIdentifier: String? = nil, excluding identifier: String? = nil
    ) throws -> [MicrophoneDevice] {
        let devices = try microphones()
        let ordered = MicrophonePolicy.candidates(
            devices.map(\.descriptor), call: call, chosenIdentifier: chosenIdentifier, excluding: identifier)
        return ordered.compactMap { descriptor in devices.first { $0.uniqueIdentifier == descriptor.identifier } }
    }

}
