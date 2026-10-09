import AVFoundation

extension AudioLevel {
    public static func measure(_ buffer: AVAudioPCMBuffer) throws -> AudioLevel {
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var samples: [Float] = []
        samples.reserveCapacity(frameCount * channelCount)
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                let channelIndex = buffer.format.isInterleaved ? 0 : channel
                let sampleIndex = buffer.format.isInterleaved ? frame * channelCount + channel : frame
                switch buffer.format.commonFormat {
                case .pcmFormatFloat32:
                    guard let channels = buffer.floatChannelData else { throw PraatvolError("Cannot read float audio levels.") }
                    samples.append(channels[channelIndex][sampleIndex])
                case .pcmFormatInt16:
                    guard let channels = buffer.int16ChannelData else { throw PraatvolError("Cannot read 16-bit audio levels.") }
                    samples.append(Float(channels[channelIndex][sampleIndex]) / 32768)
                case .pcmFormatInt32:
                    guard let channels = buffer.int32ChannelData else { throw PraatvolError("Cannot read 32-bit audio levels.") }
                    samples.append(Float(channels[channelIndex][sampleIndex]) / 2147483648)
                default: throw PraatvolError("The capture format cannot supply audio levels.")
                }
            }
        }
        return try measure(samples)
    }
}
