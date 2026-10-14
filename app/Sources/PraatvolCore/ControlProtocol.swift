import Foundation

public enum ControlError: String, Error, CaseIterable, Sendable {
    case badRequest, busy, notRecording, notReviewing, denied

    public var message: String {
        switch self {
        case .badRequest: return "Expected a supported cmd in a JSON object."
        case .busy: return "The app cannot start another recording yet."
        case .notRecording: return "No recording or capture setup is active."
        case .notReviewing: return "No recording is waiting for a decision."
        case .denied: return "Only the current user may control the app."
        }
    }
}

public struct ControlRequest: Decodable, Sendable {
    public enum Command: String, Decodable, CaseIterable, Sendable {
        case status, subscribe
        case recordRoom = "record-room"
        case recordCall = "record-call"
        case stop, transcribe, keep
    }
    public let cmd: Command

    public static func decode(_ line: Data) throws -> ControlRequest {
        guard line.count <= ControlLineFramer.maximumLineBytes else { throw ControlError.badRequest }
        guard String(data: line, encoding: .utf8) != nil else { throw ControlError.badRequest }
        guard !line.contains(0) else { throw ControlError.badRequest }
        do { return try JSONDecoder().decode(Self.self, from: line) } catch { throw ControlError.badRequest }
    }

    public static func rejection(_ command: Command, step: JobStep, canStart: Bool) -> ControlError? {
        switch command {
        case .recordRoom, .recordCall:
            if step == .review { return .busy }
            return canStart ? nil : .busy
        case .transcribe, .keep: return step == .review ? nil : .notReviewing
        case .stop:
            switch step {
            case .starting, .recording: return nil
            default: return .notRecording
            }
        case .status, .subscribe: return nil
        }
    }
}

extension JobStep {
    public var controlKey: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .preparing: return "preparing"
        case .review: return "review"
        case .uploading: return "uploading"
        case .transcribing: return "transcribing"
        case .saved: return "saved"
        case .failed: return "failed"
        }
    }
}

public struct ControlStatus: Encodable, Sendable, Equatable {
    public struct Microphone: Encodable, Sendable, Equatable {
        public let name: String
        public let hasSignal: Bool
        public let silenceSeconds: Double
        public init(name: String, hasSignal: Bool, silenceSeconds: Double) {
            self.name = name
            self.hasSignal = hasSignal
            self.silenceSeconds = silenceSeconds
        }
    }
    public struct System: Encodable, Sendable, Equatable {
        public let active: Bool
        public let hasSignal: Bool
        public let silenceSeconds: Double
        public init(active: Bool, hasSignal: Bool, silenceSeconds: Double) {
            self.active = active
            self.hasSignal = hasSignal
            self.silenceSeconds = silenceSeconds
        }
    }
    public let step: String
    public let kind: String?
    public let startedAt: Double?
    public let elapsedSeconds: Double
    public let microphone: Microphone?
    public let system: System?
    public let uploadFraction: Double?
    public let stepStartedAt: Double?
    public let estimatedSeconds: Double?
    public let preparingFraction: Double?
    public let durationSeconds: Double?
    public let uploadBytes: Int64?
    public let warnings: [String]?
    public let needsAttention: Bool
    public let message: String?

    public init(
        step: JobStep, kind: String? = nil, startedAt: Double? = nil, elapsedSeconds: Double = 0,
        microphone: Microphone? = nil, system: System? = nil, uploadFraction: Double? = nil,
        needsAttention: Bool = false, message: String? = nil,
        stepStartedAt: Double? = nil, estimatedSeconds: Double? = nil, preparingFraction: Double? = nil,
        durationSeconds: Double? = nil, uploadBytes: Int64? = nil, warnings: [String]? = nil
    ) {
        self.step = step.controlKey
        self.kind = kind
        self.startedAt = startedAt
        self.elapsedSeconds = elapsedSeconds
        self.microphone = microphone
        self.system = system
        self.uploadFraction = uploadFraction
        self.needsAttention = needsAttention
        self.message = message
        self.stepStartedAt = stepStartedAt
        self.estimatedSeconds = estimatedSeconds
        self.preparingFraction = preparingFraction
        self.durationSeconds = durationSeconds
        self.uploadBytes = uploadBytes
        self.warnings = warnings
    }

    private enum CodingKeys: String, CodingKey {
        case v, step, kind, startedAt, elapsedSeconds, microphone, system, uploadFraction, needsAttention, message
        case stepStartedAt, estimatedSeconds, preparingFraction, durationSeconds, uploadBytes, warnings
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .v)
        try container.encode(step, forKey: .step)
        try container.encode(kind, forKey: .kind)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(elapsedSeconds, forKey: .elapsedSeconds)
        try container.encode(microphone, forKey: .microphone)
        try container.encode(system, forKey: .system)
        try container.encode(uploadFraction, forKey: .uploadFraction)
        try container.encode(needsAttention, forKey: .needsAttention)
        try container.encode(message, forKey: .message)
        try container.encode(stepStartedAt, forKey: .stepStartedAt)
        try container.encode(estimatedSeconds, forKey: .estimatedSeconds)
        try container.encode(preparingFraction, forKey: .preparingFraction)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(uploadBytes, forKey: .uploadBytes)
        try container.encode(warnings, forKey: .warnings)
    }
}

public struct ControlLineFramer: Sendable {
    public static let maximumLineBytes = 4096
    private var pending = Data()
    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        var lines: [Data] = []
        for byte in bytes {
            if byte == 10 {
                lines.append(pending)
                pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < Self.maximumLineBytes else { throw ControlError.badRequest }
                pending.append(byte)
            }
        }
        return lines
    }
}
