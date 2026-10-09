import AVFoundation
import Foundation

public enum RawTracks {
    public static func compress(_ source: URL, progress: (Double) -> Void = { _ in }) throws -> URL {
        let destination = source.deletingPathExtension().appendingPathExtension("flac")
        try encode(source: source, destination: destination, progress: progress)
        try verify(source: source, destination: destination)
        try FileManager.default.removeItem(at: source)
        return destination
    }

    private static func encode(source: URL, destination: URL, progress: (Double) -> Void) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 24,
        ]
        let output = try AVAudioFile(
            forWriting: destination, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw PraatvolError("Cannot allocate a raw track buffer.")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw PraatvolError("Raw track conversion made no progress.") }
            try output.write(from: buffer)
            progress(JobProgress.fraction(completed: input.framePosition, total: input.length))
        }
    }

    private static func verify(source: URL, destination: URL) throws {
        let original = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let encoded = try AVAudioFile(forReading: destination, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard original.length == encoded.length, original.processingFormat == encoded.processingFormat,
            let originalBuffer = AVAudioPCMBuffer(pcmFormat: original.processingFormat, frameCapacity: 8192),
            let encodedBuffer = AVAudioPCMBuffer(pcmFormat: encoded.processingFormat, frameCapacity: 8192)
        else {
            throw PraatvolError("FLAC verification failed. The original CAF stays saved.")
        }
        while original.framePosition < original.length {
            try original.read(into: originalBuffer)
            try encoded.read(into: encodedBuffer)
            guard originalBuffer.frameLength > 0, originalBuffer.frameLength == encodedBuffer.frameLength,
                let originalChannels = originalBuffer.floatChannelData,
                let encodedChannels = encodedBuffer.floatChannelData
            else {
                throw PraatvolError("Cannot verify raw track samples. The original CAF stays saved.")
            }
            for channel in 0..<Int(original.processingFormat.channelCount) {
                for frame in 0..<Int(originalBuffer.frameLength) {
                    guard originalChannels[channel][frame] == encodedChannels[channel][frame] else {
                        throw PraatvolError(
                            "FLAC cannot preserve these floating-point samples exactly. The original CAF stays saved.")
                    }
                }
            }
        }
    }
}
