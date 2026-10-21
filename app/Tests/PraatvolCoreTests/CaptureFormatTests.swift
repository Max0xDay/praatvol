import Testing

@testable import PraatvolCore

@Test func systemOnlyRequiresASurvivingSystemTrack() {
    #expect(CaptureTrackPolicy.useSystemOnly(microphoneHasFrames: false, systemHasFrames: true))
    #expect(!CaptureTrackPolicy.useSystemOnly(microphoneHasFrames: true, systemHasFrames: true))
    #expect(!CaptureTrackPolicy.useSystemOnly(microphoneHasFrames: true, systemHasFrames: false))
    #expect(!CaptureTrackPolicy.useSystemOnly(microphoneHasFrames: false, systemHasFrames: false))
}

@Test func microphoneFormatValidity() {
    #expect(CaptureFormat(sampleRate: 16_000, channelCount: 1).isValid)
    for sampleRate in [0.0, -1, .nan, .infinity] {
        #expect(!CaptureFormat(sampleRate: sampleRate, channelCount: 1).isValid)
    }
    #expect(!CaptureFormat(sampleRate: 48_000, channelCount: 0).isValid)
}

@Test func microphoneFormatMustSettleAndMatchHardware() {
    let headset = CaptureFormat(sampleRate: 16_000, channelCount: 1)
    let stereo = CaptureFormat(sampleRate: 48_000, channelCount: 2)
    var stability = CaptureFormatStability()
    #expect(stability.observe(hardware: stereo, output: stereo, at: 0) == false)
    #expect(stability.observe(hardware: stereo, output: stereo, at: 0.2) == false)
    #expect(stability.observe(hardware: headset, output: stereo, at: 0.4) == false)
    #expect(stability.observe(hardware: headset, output: headset, at: 0.5) == false)
    #expect(stability.observe(hardware: headset, output: headset, at: 0.7) == false)
    #expect(stability.observe(hardware: headset, output: headset, at: 0.9) == true)
    #expect(stability.observe(hardware: stereo, output: stereo, at: 1) == false)
    #expect(stability.observe(hardware: stereo, output: stereo, at: 1.4) == true)
}

@Test func microphoneRejectsEitherKindOfFormatMismatch() {
    let hardware = CaptureFormat(sampleRate: 16_000, channelCount: 1)
    for output in [
        CaptureFormat(sampleRate: 48_000, channelCount: 1),
        CaptureFormat(sampleRate: 16_000, channelCount: 2),
        CaptureFormat(sampleRate: .nan, channelCount: 1),
    ] {
        var stability = CaptureFormatStability()
        #expect(stability.observe(hardware: hardware, output: hardware, at: 0) == false)
        #expect(stability.observe(hardware: hardware, output: output, at: 1) == false)
        #expect(stability.observe(hardware: hardware, output: hardware, at: 1.1) == false)
        #expect(stability.observe(hardware: hardware, output: hardware, at: 1.5) == true)
    }
}

@Test func invalidMicrophoneFormatResetsStability() {
    let headset = CaptureFormat(sampleRate: 16_000, channelCount: 1)
    let invalid = CaptureFormat(sampleRate: 0, channelCount: 0)
    var stability = CaptureFormatStability()
    #expect(stability.observe(hardware: headset, output: headset, at: 0) == false)
    #expect(stability.observe(hardware: invalid, output: invalid, at: 0.4) == false)
    #expect(stability.observe(hardware: headset, output: headset, at: 0.5) == false)
    #expect(stability.observe(hardware: headset, output: headset, at: 0.9) == true)
}
