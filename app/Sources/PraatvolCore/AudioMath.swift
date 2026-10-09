import Foundation

public enum AudioMath {
    public static let sampleRateHz = 16000.0
    public static let peakLimit: Float = Float(floor(0.95 * 32768) / 32768)

    public static func mono(_ channels: [[Float]]) throws -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.allSatisfy({ $0.count == first.count }) else {
            throw PraatvolError("Audio channels have different lengths.")
        }
        var samples = [Float](repeating: 0, count: first.count)
        for channel in channels {
            for index in samples.indices { samples[index] += channel[index] / Float(channels.count) }
        }
        return samples
    }

    public static func resample(_ samples: [Float], sourceRateHz: Double) throws -> [Float] {
        guard sourceRateHz.isFinite, sourceRateHz > 0 else {
            throw PraatvolError("Audio sample rate must be positive.")
        }
        guard !samples.isEmpty else { return [] }
        if sourceRateHz == sampleRateHz { return samples }
        let filtered = sourceRateHz > sampleRateHz ? boxFilter(samples, sourceRateHz: sourceRateHz) : samples
        let frames = Int((Double(samples.count) * sampleRateHz / sourceRateHz).rounded())
        return (0..<frames).map { index in
            let position = Double(index) * sourceRateHz / sampleRateHz
            let lower = min(Int(position), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            return filtered[lower] * (1 - fraction) + filtered[upper] * fraction
        }
    }

    private static func boxFilter(_ samples: [Float], sourceRateHz: Double) -> [Float] {
        // #COMPLETION_DRIVE: The PoC box filter targets speech rather than high-fidelity audio.
        // #SUGGEST_VERIFY: Listen for artifacts; production file conversion uses AVAudioConverter.
        var width = max(3, Int((3 * sourceRateHz / sampleRateHz).rounded()))
        if width % 2 == 0 { width += 1 }
        let half = width / 2
        var total: Float = 0
        for index in -half...half { total += samples[min(max(index, 0), samples.count - 1)] }
        var filtered = [Float](repeating: 0, count: samples.count)
        for index in samples.indices {
            filtered[index] = total / Float(width)
            total -= samples[min(max(index - half, 0), samples.count - 1)]
            total += samples[min(index + half + 1, samples.count - 1)]
        }
        return filtered
    }

    public static func alignment(offsetSeconds: Double) throws -> (microphone: Int, system: Int) {
        guard offsetSeconds.isFinite else { throw PraatvolError("Invalid capture timestamp.") }
        let frames = Int((abs(offsetSeconds) * sampleRateHz).rounded())
        return offsetSeconds >= 0 ? (0, frames) : (frames, 0)
    }

    public static func mix(microphone: [Float], system: [Float], offsetSeconds: Double) throws -> [Float] {
        let offsets = try alignment(offsetSeconds: offsetSeconds)
        var mixed = [Float](
            repeating: 0, count: max(microphone.count + offsets.microphone, system.count + offsets.system))
        for index in microphone.indices { mixed[index + offsets.microphone] += microphone[index] }
        for index in system.indices { mixed[index + offsets.system] += system[index] }
        guard mixed.allSatisfy(\.isFinite) else { throw PraatvolError("Captured audio contains invalid samples.") }
        let peak = mixed.map { abs($0) }.max() ?? 0
        if peak > peakLimit {
            let gain = peakLimit / peak
            for index in mixed.indices { mixed[index] *= gain }
        }
        return mixed
    }
}
