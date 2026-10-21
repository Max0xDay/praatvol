public enum CaptureTrackPolicy {
    public static func useSystemOnly(microphoneHasFrames: Bool, systemHasFrames: Bool) -> Bool {
        if microphoneHasFrames { return false }
        return systemHasFrames
    }
}

public struct CaptureFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channelCount: UInt32

    public init(sampleRate: Double, channelCount: UInt32) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var isValid: Bool {
        guard sampleRate.isFinite, sampleRate > 0 else { return false }
        return channelCount > 0
    }
}

public struct CaptureFormatStability {
    private var previous: CaptureFormat?
    private var stableSinceSeconds: Double?

    public init() {}

    public mutating func observe(hardware: CaptureFormat, output: CaptureFormat, at uptimeSeconds: Double) -> Bool {
        guard hardware.isValid, output.isValid, hardware == output else {
            previous = nil
            stableSinceSeconds = nil
            return false
        }
        if previous != hardware {
            previous = hardware
            stableSinceSeconds = uptimeSeconds
            return false
        }
        guard let stableSinceSeconds else { return false }
        // #COMPLETION_DRIVE: Matching formats for 300 ms indicate settling, not a guarantee against a later change.
        // #SUGGEST_VERIFY: Exercise Bluetooth profile switches; the native exception guard covers the remaining race.
        return uptimeSeconds - stableSinceSeconds >= 0.3
    }
}
