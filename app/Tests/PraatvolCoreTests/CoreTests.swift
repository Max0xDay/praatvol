import Foundation
import Testing

@testable import PraatvolCore

@Test(arguments: [(59, 64_000), (60, 64_000), (61, 48_000), (90, 48_000), (91, 32_000)])
func durationRules(minutes: Int, expected: Int) {
    #expect(UploadRules.bitrate(durationSeconds: Double(minutes * 60)) == expected)
    #expect(UploadRules.isBeyondTestedLength(Double(minutes * 60)) == (minutes > 90))
}

@Test func bodyGuard() throws {
    for (bytes, encoded) in [(0, 0), (1, 4), (2, 4), (3, 4), (4, 8)] {
        #expect(UploadRules.estimatedBodyBytes(audioBytes: bytes) == encoded + 1024)
    }
    let boundary = (50_000_000 - 1024) / 4 * 3
    try UploadRules.validate(audioBytes: boundary)
    #expect(throws: PraatvolError.self) { try UploadRules.validate(audioBytes: boundary + 1) }
}

@Test func requestShape() throws {
    let payload = try TranscriptionRequest.body(audio: Data([1, 2, 3]), format: "m4a", model: "elevenlabs/scribe-v2")
    let dictionary = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    #expect(dictionary["response_format"] as? String == "verbose_json")
    #expect(dictionary["timestamp_granularities"] as? [String] == ["segment", "word"])
    let audio = try #require(dictionary["input_audio"] as? [String: String])
    #expect(audio == ["data": "AQID", "format": "m4a"])
    let provider = try #require(dictionary["provider"] as? [String: Any])
    let options = try #require(provider["options"] as? [String: Any])
    #expect((options["elevenlabs"] as? [String: Bool])?["diarize"] == true)
    let other = try TranscriptionRequest.body(audio: Data(), format: "flac", model: "other/model")
    #expect((try JSONSerialization.jsonObject(with: other) as? [String: Any])?["provider"] == nil)
}

@Test(arguments: ["{\"error\":null}", "{\"error\":\"Provider returned 524\"}", "{\"error\":{\"code\":524}}"])
func errorInSuccess(body: String) {
    #expect(throws: PraatvolError.self) { try Transcript.parse(Data(body.utf8), statusCode: 200) }
}

@Test func responseAndMarkdown() throws {
    let response = Data(
        """
        {"words":[{"start":1,"speaker":0,"word":"Hello"},{"start":2,"speaker":0,"word":"there."},{"start":65,"speaker":1,"word":"Yes."}],"segments":[{"start":0,"text":"wrong"}],"usage":{"seconds":90,"cost":0.000219}}
        """.utf8)
    let transcript = try Transcript.parse(response, statusCode: 200)
    #expect(
        transcript.turns == [
            Turn(start: 1, speaker: "0", text: "Hello there."), Turn(start: 65, speaker: "1", text: "Yes."),
        ])
    let markdown = transcript.markdown(
        date: Date(timeIntervalSince1970: 0), durationSeconds: 90,
        model: "elevenlabs/scribe-v2", sources: "mic: test", archiveName: "audio.flac", uploadDescription: "AAC 64 kbps"
    )
    #expect(markdown.contains("[00:01] Speaker A: Hello there.\n"))
    #expect(markdown.contains("[01:05] Speaker B: Yes.\n"))
    #expect(markdown.contains("- Speakers: 2\n"))
    #expect(markdown.contains("- Duration: 1 min 30 s\n"))
    #expect(markdown.contains("- Cost: $0.000219 (OpenRouter)"))
    #expect(markdown.contains("- Sources: mic: test"))
    #expect(markdown.contains("- Model: elevenlabs/scribe-v2"))
}

@Test func missingLabelsAndFallbacks() throws {
    let segments = try Transcript.parse(
        Data("{\"segments\":[{\"start\":4,\"text\":\"Hello.\"},{\"start\":8,\"text\":\"Again.\"}]}".utf8),
        statusCode: 200)
    #expect(!segments.hasSpeakerLabels)
    #expect(segments.turns.count == 2)
    #expect(
        segments.markdown(
            date: Date(), durationSeconds: 10, model: "test", sources: "file", archiveName: "audio.flac",
            uploadDescription: "FLAC"
        ).contains("Speaker labels: absent"))
    let fallback = try Transcript.parse(Data("{\"text\":\"Hello\"}".utf8), statusCode: 200)
    #expect(fallback.turns == [Turn(start: 0, speaker: nil, text: "Hello")])
    #expect(throws: PraatvolError.self) { try Transcript.parse(Data("{}".utf8), statusCode: 401) }
    #expect(throws: PraatvolError.self) { try Transcript.parse(Data("invalid".utf8), statusCode: 200) }
}

@Test func folderNames() {
    let date = Date(timeIntervalSince1970: 0)
    let timezone = TimeZone(secondsFromGMT: 0)!
    #expect(Storage.relativeFolder(date: date, kind: "Call", timezone: timezone) == "1970/01/01/00-00-00 Call")
    #expect(
        Storage.relativeFolder(date: date, kind: "File: memo/name.m4a", timezone: timezone)
            == "1970/01/01/00-00-00 File: memo-name.m4a")
    #expect(Storage.root(isDevelopment: true).lastPathComponent == "praatvol-dev")
    #expect(Storage.root(isDevelopment: false).lastPathComponent == "praatvol")
}

@Test(arguments: [8000.0, 16000.0, 24000.0, 32000.0, 44100.0, 48000.0])
func resampling(rate: Double) throws {
    let samples = (0..<Int(rate)).map { Float(0.2 * sin(2 * .pi * 1000 * Double($0) / rate)) }
    let converted = try AudioMath.resample(samples, sourceRateHz: rate)
    #expect(converted.count == 16000)
    #expect(converted.map { abs($0) }.max()! > 0.1)
    let toneCorrelation =
        converted.enumerated().reduce(0.0) { sum, sample in
            sum + Double(sample.element) * sin(2 * .pi * 1000 * Double(sample.offset) / 16000)
        } / Double(converted.count)
    #expect(toneCorrelation > 0.07)
    #expect(try AudioMath.resample([], sourceRateHz: rate).isEmpty)
    #expect(
        try AudioMath.resample(Array(repeating: 1, count: 7), sourceRateHz: rate).count
            == Int((7 * 16000 / rate).rounded()))
}

@Test func mixingAlignmentAndPeak() throws {
    let microphone = [Float](repeating: 0.8, count: 16000)
    let system = [Float](repeating: 0.5, count: 16000)
    let positive = try AudioMath.mix(microphone: microphone, system: system, offsetSeconds: 0.125)
    #expect(positive.count == 18000)
    #expect(positive[0] < positive[2000])
    #expect(positive.max()! <= 0.95)
    let negative = try AudioMath.mix(microphone: microphone, system: system, offsetSeconds: -0.125)
    #expect(negative.count == 18000)
    #expect(negative[0] < negative[2000])
    #expect(try AudioMath.mix(microphone: microphone, system: [], offsetSeconds: 0) == microphone)
    #expect(try AudioMath.mono([[0.1, 0.2], [0.3, 0.4]]) == [0.2, 0.3])
    #expect(throws: PraatvolError.self) { try AudioMath.resample([1], sourceRateHz: 0) }
    #expect(throws: PraatvolError.self) { try AudioMath.mix(microphone: [.nan], system: [], offsetSeconds: 0) }
}
