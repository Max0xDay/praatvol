import Foundation

public enum MicrophoneTransport: Sendable {
    case builtIn, bluetooth, virtual, aggregate, other
}

public struct MicrophoneDescriptor: Sendable {
    public let identifier: String
    public let name: String
    public let transport: MicrophoneTransport

    public init(identifier: String, name: String, transport: MicrophoneTransport) {
        self.identifier = identifier
        self.name = name
        self.transport = transport
    }
}

public enum MicrophonePolicy {
    public static func candidates(
        _ microphones: [MicrophoneDescriptor], call: Bool, defaultIdentifier: String? = nil,
        chosenIdentifier: String? = nil, excluding currentIdentifier: String? = nil
    ) -> [MicrophoneDescriptor] {
        let available = microphones.filter { $0.identifier != currentIdentifier }
        if call {
            let remaining = available.filter { $0.identifier != chosenIdentifier }
            return available.filter { $0.identifier == chosenIdentifier }
                + remaining.filter { $0.transport == .bluetooth }
                + remaining.filter { $0.transport == .builtIn }
                + remaining.filter { $0.transport == .other }
                + remaining.filter { isVirtualOrAggregate($0) }
        }
        let allowed = available.filter { allowedForRoom($0) }
        return allowed.filter { $0.transport == .builtIn } + allowed.filter { $0.transport != .builtIn }
    }

    private static func isVirtualOrAggregate(_ microphone: MicrophoneDescriptor) -> Bool {
        switch microphone.transport {
        case .virtual, .aggregate: return true
        default: return false
        }
    }

    private static func allowedForRoom(_ microphone: MicrophoneDescriptor) -> Bool {
        switch microphone.transport {
        case .bluetooth, .virtual, .aggregate: return false
        case .builtIn, .other:
            // #COMPLETION_DRIVE: Some virtual drivers report a non-virtual transport, including Teams Audio Device.
            // #SUGGEST_VERIFY: Check new driver names and extend these exclusions if their transport is misreported.
            let name = microphone.name.lowercased()
            if name.contains("virtual") { return false }
            if name.contains("microsoft teams audio device") { return false }
            return true
        }
    }
}

public enum RecordedAudio {
    public static let noAudioMessage = "No audio was recorded. The microphone did not deliver sound."

    public static func failureMessage(frameCount: Int64?) -> String? {
        guard let frameCount, frameCount > 0 else { return noAudioMessage }
        return nil
    }

    public static func canRetry(status: ItemStatus, errorMessage: String?, hasSource: Bool) -> Bool {
        guard status != .transcribed else { return false }
        guard errorMessage != noAudioMessage else { return false }
        return hasSource
    }
}
