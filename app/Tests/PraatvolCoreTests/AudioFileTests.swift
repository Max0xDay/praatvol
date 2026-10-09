import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import PraatvolCore

private func writeTone(_ url: URL, rateHz: Double = 48000, channels: UInt32 = 2) throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rateHz, channels: channels, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rateHz * 3)))
    buffer.frameLength = buffer.frameCapacity
    let samples = try #require(buffer.floatChannelData)
    for channel in 0..<Int(channels) {
        for frame in 0..<Int(buffer.frameLength) {
            samples[channel][frame] = Float(0.8 * sin(2 * .pi * 440 * Double(frame) / rateHz))
        }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private func measuredBitrate(_ url: URL) throws -> UInt32 {
    var audioFile: AudioFileID?
    let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
    guard openStatus == noErr, let audioFile else { throw PraatvolError("Cannot inspect AAC bitrate: \(openStatus)") }
    defer { #expect(AudioFileClose(audioFile) == noErr) }
    var bitrate: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let readStatus = AudioFileGetProperty(audioFile, kAudioFilePropertyBitRate, &size, &bitrate)
    guard readStatus == noErr else { throw PraatvolError("Cannot read AAC bitrate: \(readStatus)") }
    return bitrate
}

@Test func appleCodecsAndStreamingMix() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        do { try FileManager.default.removeItem(at: folder) }
        catch { Issue.record("Cannot remove test audio: \(error)") }
    }
    let source = folder.appendingPathComponent("source.caf")
    try writeTone(source)
    let mono = folder.appendingPathComponent("mono.caf")
    try AudioFiles.convert(source: source, destination: mono)
    #expect(abs(try AudioFiles.duration(mono) - 3) < 0.01)
    #expect(try AudioFiles.peak(mono) > 0.7)
    let archive = try AudioFiles.archive(source: mono, folder: folder)
    #expect(["flac", "wav"].contains(archive.url.pathExtension))
    print("Archive codec check: \(archive.explanation)")
    #expect(abs(try AudioFiles.duration(archive.url) - 3) < 0.01)
    for minutes in [59, 61, 91] {
        let bitrateFolder = folder.appendingPathComponent(String(minutes))
        try FileManager.default.createDirectory(at: bitrateFolder, withIntermediateDirectories: true)
        let upload = try AudioFiles.upload(source: mono, folder: bitrateFolder, durationSeconds: Double(minutes * 60))
        #expect(upload.pathExtension == "m4a")
        #expect(abs(try AudioFiles.duration(upload) - 3) < 0.2)
        let uploadFile = try AVAudioFile(forReading: upload)
        #expect(uploadFile.processingFormat.channelCount == 1)
        #expect(uploadFile.processingFormat.sampleRate == 22050)
        #expect(try AudioFiles.peak(upload) > 0.1)
        let actualBitrate = try measuredBitrate(upload)
        print("AAC bitrate check: \(minutes) minutes selects \(actualBitrate) bits/s")
        // #COMPLETION_DRIVE: A short AAC sample can differ by 10% from the target rate.
        // #SUGGEST_VERIFY: Measure longer speech files; this tolerance still catches adjacent wrong targets.
        let targetBitrate = Double(UploadRules.bitrate(durationSeconds: Double(minutes * 60)))
        #expect(abs(Double(actualBitrate) / targetBitrate - 1) < 0.10)
    }
    let mixed = folder.appendingPathComponent("mixed.caf")
    try AudioFiles.mix(microphone: mono, system: mono, offsetSeconds: 0.125, destination: mixed)
    #expect(abs(try AudioFiles.duration(mixed) - 3.125) < 0.001)
    #expect(try AudioFiles.peak(mixed) > 1.5)
    let normalized = folder.appendingPathComponent("normalized.caf")
    try AudioFiles.normalize(source: mixed, destination: normalized)
    #expect(abs(try AudioFiles.peak(normalized) - AudioMath.peakLimit) < 0.0001)
    let file = try AVAudioFile(forReading: mixed)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2000))
    try file.read(into: buffer)
    let firstSamples = try #require(buffer.floatChannelData?[0])
    #expect((0..<2000).map { abs(firstSamples[$0]) }.max()! < 0.81)
}

@Test(arguments: [(8000.0, 1), (24000.0, 1), (44100.0, 2), (48000.0, 2), (32000.0, 6)])
func nativeChannelAverage(rateHz: Double, channels: Int) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        do { try FileManager.default.removeItem(at: folder) }
        catch { Issue.record("Cannot remove test audio: \(error)") }
    }
    let source = folder.appendingPathComponent("native.caf")
    let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)))
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rateHz, interleaved: false, channelLayout: layout)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rateHz)))
    buffer.frameLength = buffer.frameCapacity
    let samples = try #require(buffer.floatChannelData)
    for channel in 0..<channels {
        for frame in 0..<Int(buffer.frameLength) { samples[channel][frame] = Float(channel + 1) / 10 }
    }
    do {
        let output = try AVAudioFile(forWriting: source, settings: format.settings)
        try output.write(from: buffer)
    }
    let destination = folder.appendingPathComponent("mono.caf")
    try AudioFiles.convert(source: source, destination: destination)
    let file = try AVAudioFile(forReading: destination)
    #expect(file.length == 16000)
    let converted = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000))
    try file.read(into: converted)
    let mono = try #require(converted.floatChannelData?[0])
    let expected = Float(channels + 1) / 20
    #expect(abs(mono[8000] - expected) < 0.0001)
}
