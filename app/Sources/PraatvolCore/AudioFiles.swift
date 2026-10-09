import AVFoundation
import Foundation

public struct Archive {
    public let url: URL
    public let explanation: String
    public init(url: URL, explanation: String) {
        self.url = url
        self.explanation = explanation
    }
}

public enum AudioFiles {
    public static func duration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    public static func convert(
        source: URL, destination: URL, rateHz: Double = 16000,
        settings: [String: Any]? = nil, progress: (Double) -> Void = { _ in }
    ) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard
            let inputMono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: input.processingFormat.sampleRate, channels: 1, interleaved: false),
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rateHz, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputMono, to: format),
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)
        else {
            throw PraatvolError("The audio format cannot convert to mono audio.")
        }
        let output = try AVAudioFile(
            forWriting: destination, settings: settings ?? format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        try convertBuffers(input: input, output: output, converter: converter, buffer: outputBuffer, progress: progress)
    }

    private static func convertBuffers(
        input: AVAudioFile, output: AVAudioFile,
        converter: AVAudioConverter, buffer: AVAudioPCMBuffer, progress: (Double) -> Void
    ) throws {
        var readError: Error?
        var finished = false
        while !finished {
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { frames, inputStatus in
                if input.framePosition >= input.length {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    let monoBuffer = try readMono(input, frames: max(frames, 1), format: converter.inputFormat)
                    inputStatus.pointee = .haveData
                    return monoBuffer
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if status == .error { throw PraatvolError("Audio conversion failed.") }
            if buffer.frameLength > 0 { try output.write(from: buffer) }
            progress(JobProgress.fraction(completed: input.framePosition, total: input.length))
            finished = status == .endOfStream
            if status == .inputRanDry { throw PraatvolError("Audio conversion stopped before the end.") }
        }
    }

    private static func readMono(_ input: AVAudioFile, frames: UInt32, format: AVAudioFormat) throws -> AVAudioPCMBuffer
    {
        guard let native = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: frames),
            let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
            let channels = native.floatChannelData, let samples = mono.floatChannelData?[0]
        else {
            throw PraatvolError("Cannot allocate a mono audio buffer.")
        }
        try input.read(into: native, frameCount: frames)
        mono.frameLength = native.frameLength
        let channelCount = Int(native.format.channelCount)
        for frame in 0..<Int(native.frameLength) {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            samples[frame] = sum / Float(channelCount)
        }
        return mono
    }

    public static func archive(source: URL, folder: URL, progress: (Double) -> Void = { _ in }) throws -> Archive {
        let destination = folder.appendingPathComponent("audio.flac")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
        ]
        do {
            try convert(source: source, destination: destination, settings: settings, progress: progress)
            return Archive(url: destination, explanation: "FLAC lossless archive")
        } catch {
            // #COMPLETION_DRIVE: Some Apple installations decode FLAC but lack a FLAC encoder.
            // #SUGGEST_VERIFY: The offline codec test checks this machine; other Macs can use WAV.
            let fallback = folder.appendingPathComponent("audio.wav")
            let explanation = "WAV lossless archive; the Apple FLAC encoder is unavailable (\((error as NSError).code))"
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try convert(
                source: source, destination: fallback,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ], progress: progress)
            return Archive(url: fallback, explanation: explanation)
        }
    }

    public static func upload(
        source: URL, folder: URL, durationSeconds: Double,
        progress: (Double) -> Void = { _ in }
    ) throws -> URL {
        let destination = folder.appendingPathComponent("upload.m4a")
        // #COMPLETION_DRIVE: AAC at 22.05 kHz accepts the requested mono bitrate range.
        // #SUGGEST_VERIFY: Offline encoder tests cover each bitrate; assess speech quality manually.
        try convert(
            source: source, destination: destination, rateHz: 22050,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22050, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: UploadRules.bitrate(durationSeconds: durationSeconds),
                AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
            ], progress: progress)
        return destination
    }

    public static func peak(_ url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
            let channels = buffer.floatChannelData
        else { throw PraatvolError("Cannot inspect captured audio.") }
        var peak: Float = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw PraatvolError("Audio inspection made no progress.") }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = channels[channel][frame]
                    guard sample.isFinite else { throw PraatvolError("Audio contains invalid samples.") }
                    peak = max(peak, abs(sample))
                }
            }
        }
        return peak
    }

    public static func mix(
        microphone: URL, system: URL, offsetSeconds: Double, destination: URL,
        progress: (Double) -> Void = { _ in }
    ) throws {
        let microphoneFile = try AVAudioFile(forReading: microphone)
        let systemFile = try AVAudioFile(forReading: system)
        let offsets = try AudioMath.alignment(offsetSeconds: offsetSeconds)
        let length = max(microphoneFile.length + Int64(offsets.microphone), systemFile.length + Int64(offsets.system))
        let format = microphoneFile.processingFormat
        guard format.channelCount == 1, format.sampleRate == 16000,
            systemFile.processingFormat == format,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)
        else {
            throw PraatvolError("The mixer requires converted mono tracks at 16 kHz.")
        }
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        var position: Int64 = 0
        while position < length {
            let frames = Int(min(8192, length - position))
            let microphoneSamples = try alignedSamples(
                microphoneFile, position: position, frames: frames, offset: offsets.microphone)
            let systemSamples = try alignedSamples(
                systemFile, position: position, frames: frames, offset: offsets.system)
            buffer.frameLength = UInt32(frames)
            guard let samples = buffer.floatChannelData?[0] else {
                throw PraatvolError("Cannot write the mixed buffer.")
            }
            for index in 0..<frames { samples[index] = microphoneSamples[index] + systemSamples[index] }
            try output.write(from: buffer)
            position += Int64(frames)
            progress(JobProgress.fraction(completed: position, total: length))
        }
    }

    private static func alignedSamples(_ file: AVAudioFile, position: Int64, frames: Int, offset: Int) throws -> [Float]
    {
        var samples = [Float](repeating: 0, count: frames)
        let sourceStart = max(0, position - Int64(offset))
        let targetStart = Int(max(0, Int64(offset) - position))
        guard targetStart < frames, sourceStart < file.length else { return samples }
        let count = min(frames - targetStart, Int(file.length - sourceStart))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(count)) else {
            throw PraatvolError("Cannot allocate a mix buffer.")
        }
        file.framePosition = sourceStart
        try file.read(into: buffer, frameCount: UInt32(count))
        guard let channel = buffer.floatChannelData?[0] else { throw PraatvolError("Cannot read a mix buffer.") }
        for index in 0..<Int(buffer.frameLength) { samples[targetStart + index] = channel[index] }
        return samples
    }

    public static func normalize(source: URL, destination: URL, progress: (Double) -> Void = { _ in }) throws {
        progress(0)
        let peak = try peak(source)
        let gain = peak > AudioMath.peakLimit ? AudioMath.peakLimit / peak : 1
        let input = try AVAudioFile(forReading: source)
        let output = try AVAudioFile(forWriting: destination, settings: input.processingFormat.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else {
            throw PraatvolError("Cannot allocate a normalization buffer.")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else {
                throw PraatvolError("Cannot read samples for normalization.")
            }
            for frame in 0..<Int(buffer.frameLength) { samples[frame] *= gain }
            try output.write(from: buffer)
            progress(JobProgress.fraction(completed: input.framePosition, total: input.length))
        }
    }
}
