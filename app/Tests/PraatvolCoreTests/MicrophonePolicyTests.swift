import Foundation
import Testing

@testable import PraatvolCore

@Test func roomMicrophoneCandidates() {
    let microphones = [
        MicrophoneDescriptor(identifier: "bluetooth", name: "Headphones", transport: .bluetooth),
        MicrophoneDescriptor(identifier: "virtual", name: "Virtual input", transport: .virtual),
        MicrophoneDescriptor(identifier: "teams", name: "Microsoft Teams Audio Device", transport: .other),
        MicrophoneDescriptor(identifier: "aggregate", name: "Combined input", transport: .aggregate),
        MicrophoneDescriptor(identifier: "usb", name: "USB microphone", transport: .other),
        MicrophoneDescriptor(identifier: "builtin", name: "MacBook Microphone", transport: .builtIn),
    ]
    #expect(
        MicrophonePolicy.candidates(microphones, call: false, defaultIdentifier: "bluetooth").map(\.identifier)
            == ["builtin", "usb"])
    #expect(
        MicrophonePolicy.candidates(
            microphones, call: false, defaultIdentifier: "bluetooth", excluding: "builtin"
        ).map(\.identifier) == ["usb"])
    #expect(MicrophonePolicy.candidates(Array(microphones.prefix(4)), call: false).isEmpty)
}

@Test func callMicrophoneCandidates() {
    let microphones = [
        MicrophoneDescriptor(identifier: "virtual", name: "Virtual input", transport: .virtual),
        MicrophoneDescriptor(identifier: "aggregate", name: "Combined input", transport: .aggregate),
        MicrophoneDescriptor(identifier: "builtin", name: "MacBook Microphone", transport: .builtIn),
        MicrophoneDescriptor(identifier: "headset", name: "Headset", transport: .bluetooth),
        MicrophoneDescriptor(identifier: "usb", name: "USB microphone", transport: .other),
    ]
    #expect(
        MicrophonePolicy.candidates(microphones, call: true, defaultIdentifier: "builtin").map(\.identifier)
            == ["headset", "builtin", "usb", "virtual", "aggregate"])
    for chosenIdentifier in ["builtin", "headset", "usb"] {
        let expected =
            [chosenIdentifier]
            + ["headset", "builtin", "usb", "virtual", "aggregate"].filter { $0 != chosenIdentifier }
        #expect(
            MicrophonePolicy.candidates(
                microphones, call: true, chosenIdentifier: chosenIdentifier
            ).map(\.identifier) == expected)
    }
    #expect(
        MicrophonePolicy.candidates(
            microphones, call: true, chosenIdentifier: "missing"
        ).map(\.identifier) == ["headset", "builtin", "usb", "virtual", "aggregate"])
    #expect(
        MicrophonePolicy.candidates(
            microphones.filter { $0.identifier != "headset" }, call: true
        ).map(\.identifier) == ["builtin", "usb", "virtual", "aggregate"])
    #expect(
        MicrophonePolicy.candidates(
            microphones, call: true, chosenIdentifier: "headset", excluding: "headset"
        ).map(\.identifier) == ["builtin", "usb", "virtual", "aggregate"])
    #expect(
        MicrophonePolicy.candidates(
            microphones, call: true, chosenIdentifier: "usb", excluding: "builtin"
        ).map(\.identifier) == ["usb", "headset", "virtual", "aggregate"])
}

@Test func emptyRecordedAudioAndRetryEligibility() {
    let message = "No audio was recorded. The microphone did not deliver sound."
    #expect(RecordedAudio.failureMessage(frameCount: nil) == message)
    #expect(RecordedAudio.failureMessage(frameCount: 0) == message)
    #expect(RecordedAudio.failureMessage(frameCount: 1) == nil)
    #expect(!RecordedAudio.canRetry(status: .failed, errorMessage: message, hasSource: true))
    #expect(!RecordedAudio.canRetry(status: .transcribed, errorMessage: nil, hasSource: true))
    #expect(!RecordedAudio.canRetry(status: .failed, errorMessage: "Missing key", hasSource: false))
    #expect(RecordedAudio.canRetry(status: .failed, errorMessage: "Missing key", hasSource: true))
    #expect(RecordedAudio.canRetry(status: .notTranscribed, errorMessage: nil, hasSource: true))
    let problem = ItemPresentation.problem(for: message)
    #expect(problem.summary == "No audio was recorded.")
    #expect(problem.detail == "The microphone did not deliver sound. Start a new recording.")
    let coreAudio = ItemPresentation.problem(
        for: "The operation couldn’t be completed. (com.apple.coreaudio.avfaudio error 1954115647.)")
    #expect(coreAudio.summary == "The saved audio could not be read.")
    #expect(!coreAudio.detail.contains("1954115647"))
}
