import AVFoundation
import Foundation
import Testing

@testable import PraatvolCore

private func rawTestFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func removeRawTestFolder(_ folder: URL) {
    do { try FileManager.default.removeItem(at: folder) } catch { Issue.record("Cannot remove test tracks: \(error)") }
}

@Test func rawFlacPreservesChannelsAndSamples() throws {
    let folder = try rawTestFolder()
    defer { removeRawTestFolder(folder) }
    let source = folder.appendingPathComponent("mic.caf")
    let format = try #require(
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10000))
    buffer.frameLength = 10000
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<10000 {
        channels[0][frame] = Float(frame % 100) / 128
        channels[1][frame] = -Float(frame % 50) / 128
    }
    do {
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        try file.write(from: buffer)
    }
    var fractions: [Double] = []
    let destination = try RawTracks.compress(source) { fractions.append($0) }
    #expect(destination.lastPathComponent == "mic.flac")
    #expect(!FileManager.default.fileExists(atPath: source.path))
    let decoded = try AVAudioFile(forReading: destination)
    #expect(decoded.processingFormat.sampleRate == 44100)
    #expect(decoded.processingFormat.channelCount == 2)
    #expect(decoded.length == 10000)
    let decodedBuffer = try #require(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 10000))
    try decoded.read(into: decodedBuffer)
    let decodedChannels = try #require(decodedBuffer.floatChannelData)
    for frame in 0..<10000 {
        #expect(decodedChannels[0][frame] == channels[0][frame])
        #expect(decodedChannels[1][frame] == channels[1][frame])
    }
    #expect(fractions.last == 1)
    #expect(fractions == fractions.sorted())
}

@Test func rawFlacRetainsNonrepresentableFloat() throws {
    let folder = try rawTestFolder()
    defer { removeRawTestFolder(folder) }
    let source = folder.appendingPathComponent("system.caf")
    let format = try #require(
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10000))
    buffer.frameLength = 10000
    let samples = try #require(buffer.floatChannelData?[0])
    for frame in 0..<10000 { samples[frame] = 0.00000001 }
    do {
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        try file.write(from: buffer)
    }
    let original = try Data(contentsOf: source)
    #expect(throws: PraatvolError.self) { try RawTracks.compress(source) }
    #expect(try Data(contentsOf: source) == original)
}

@Test(arguments: [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32])
func bufferMeterUsesEveryChannel(format: AVAudioCommonFormat) throws {
    let audioFormat = try #require(
        AVAudioFormat(commonFormat: format, sampleRate: 48000, channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 4))
    buffer.frameLength = 4
    for frame in 0..<4 {
        switch format {
        case .pcmFormatFloat32:
            buffer.floatChannelData?[0][frame] = 0
            buffer.floatChannelData?[1][frame] = 0.5
        case .pcmFormatInt16:
            buffer.int16ChannelData?[0][frame] = 0
            buffer.int16ChannelData?[1][frame] = 16384
        case .pcmFormatInt32:
            buffer.int32ChannelData?[0][frame] = 0
            buffer.int32ChannelData?[1][frame] = 1_073_741_824
        default: Issue.record("Unsupported test format")
        }
    }
    let level = try AudioLevel.measure(buffer)
    #expect(level.peak == 0.5)
    #expect(abs(level.rms - sqrt(0.125)) < 0.000001)
}
