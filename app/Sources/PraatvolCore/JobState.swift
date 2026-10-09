import Foundation

public enum JobStep: String, CaseIterable, Sendable {
    case idle = "Idle"
    case starting = "Starting"
    case recording = "Recording"
    case preparing = "Preparing audio"
    case uploading = "Uploading"
    case transcribing = "Transcribing"
    case saved = "Saved"
    case failed = "Failed"
}

public struct JobState: Sendable {
    public private(set) var step: JobStep = .idle
    public init() {}
    public mutating func advance(to next: JobStep) throws {
        let allowed: [JobStep: Set<JobStep>] = [
            .idle: [.starting, .preparing], .starting: [.recording, .failed, .idle],
            .recording: [.preparing, .failed], .preparing: [.uploading, .failed, .idle],
            .uploading: [.transcribing, .failed], .transcribing: [.saved, .failed],
            .saved: [.starting, .preparing, .idle], .failed: [.starting, .preparing, .idle],
        ]
        guard allowed[step]?.contains(next) == true else {
            throw PraatvolError("Invalid job transition: \(step.rawValue) → \(next.rawValue).")
        }
        step = next
    }
}

public enum JobProgress {
    public static func fraction(completed: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
    public static func estimateSeconds(durationSeconds: Double) -> Double {
        // #COMPLETION_DRIVE: Linear interpolation uses the measured 60/90-minute Opus trials, not an AAC guarantee.
        // #SUGGEST_VERIFY: Compare real AAC latency and update the estimate, never a request timeout.
        max(1, 28 + max(0, durationSeconds) / 90)
    }
    public static func remainingSeconds(durationSeconds: Double, elapsedSeconds: Double) -> Double {
        max(0, estimateSeconds(durationSeconds: durationSeconds) - max(0, elapsedSeconds))
    }
    public static func tierHint(durationSeconds: Double) -> String {
        switch UploadRules.bitrate(durationSeconds: durationSeconds) {
        case 64_000: return "Up to 60 min: best quality upload · AAC 64 kbps"
        case 48_000: return "Over 60–90 min: smaller upload · AAC 48 kbps"
        default: return "Over 90 min: AAC 32 kbps · beyond tested length; timeout risk"
        }
    }
}

public struct AudioLevel: Equatable, Sendable {
    public let rms: Double
    public let peak: Double
    public var decibelsFullScale: Double { max(-120, 20 * log10(max(rms, 0.000001))) }
    // #COMPLETION_DRIVE: -80 dBFS distinguishes signal from digital silence, not speech from room noise.
    // #SUGGEST_VERIFY: Check quiet speech and noisy rooms during manual capture tests.
    public var hasSignal: Bool { peak > 0.0001 }
    public static let silence = AudioLevel(rms: 0, peak: 0)
    public static func measure(_ samples: [Float]) throws -> AudioLevel {
        guard !samples.isEmpty else { return .silence }
        var squares = 0.0
        var peak = 0.0
        for sample in samples {
            guard sample.isFinite else { throw PraatvolError("Audio contains invalid samples.") }
            let value = Double(sample)
            squares += value * value
            peak = max(peak, abs(value))
        }
        return AudioLevel(rms: sqrt(squares / Double(samples.count)), peak: peak)
    }
}
