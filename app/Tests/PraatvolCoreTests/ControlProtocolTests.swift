import Foundation
import Testing

@testable import PraatvolCore

@Test func controlRequests() throws {
    for command in ControlRequest.Command.allCases {
        #expect(try ControlRequest.decode(Data("{\"cmd\":\"\(command.rawValue)\"}".utf8)).cmd == command)
    }
    for invalid in ["{}", "{", "{\"cmd\":\"quit\"}", "{\"cmd\":3}", "[]"] {
        #expect(throws: ControlError.self) { try ControlRequest.decode(Data(invalid.utf8)) }
    }
    #expect(throws: ControlError.self) { try ControlRequest.decode(Data(repeating: 32, count: 4097)) }
    #expect(throws: ControlError.self) { try ControlRequest.decode(Data([0xFF, 0xFE])) }
    let utf16 = try #require("{\"cmd\":\"status\"}".data(using: .utf16))
    #expect(throws: ControlError.self) { try ControlRequest.decode(utf16) }
    let request = Data("{\"cmd\":\"status\"}".utf8)
    #expect(try ControlRequest.decode(request + Data(repeating: 32, count: 4096 - request.count)).cmd == .status)
}

@Test(arguments: JobStep.allCases) func controlStepEncoding(step: JobStep) throws {
    let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(ControlStatus(step: step))) as? [String: Any])
    #expect(object["step"] as? String == step.controlKey)
}

@Test func controlStepKeys() {
    #expect(
        JobStep.allCases.map(\.controlKey) == [
            "idle", "starting", "recording", "preparing", "review", "uploading", "transcribing", "saved", "failed",
        ])
}

@Test func controlSnapshotShape() throws {
    let idle = ControlStatus(step: .idle)
    let encoded = try JSONEncoder().encode(idle)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(
        Set(object.keys)
            == Set([
                "v", "step", "kind", "startedAt", "elapsedSeconds", "microphone", "system", "uploadFraction",
                "needsAttention", "message", "stepStartedAt", "estimatedSeconds", "preparingFraction",
                "durationSeconds", "uploadBytes", "warnings",
            ]))
    #expect(object["v"] as? Int == 1)
    #expect(object["step"] as? String == "idle")
    #expect(object["elapsedSeconds"] as? Double == 0)
    #expect(object["needsAttention"] as? Bool == false)
    for key in [
        "kind", "startedAt", "microphone", "system", "uploadFraction", "message", "stepStartedAt",
        "estimatedSeconds", "preparingFraction", "durationSeconds", "uploadBytes", "warnings",
    ] {
        #expect(object[key] is NSNull)
    }
    let room = ControlStatus(
        step: .recording, kind: "room", startedAt: 123.5, elapsedSeconds: 4,
        microphone: .init(name: "Microphone", hasSignal: true, silenceSeconds: 0))
    let roomObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(room)) as? [String: Any])
    #expect(roomObject["system"] is NSNull)
    #expect(roomObject["kind"] as? String == "room")
    let microphone = try #require(roomObject["microphone"] as? [String: Any])
    #expect(Set(microphone.keys) == Set(["name", "hasSignal", "silenceSeconds"]))
    #expect(microphone["hasSignal"] as? Bool == true)
    let call = ControlStatus(
        step: .uploading, kind: "call", system: .init(active: true, hasSignal: false, silenceSeconds: 12.4),
        uploadFraction: 0.5, needsAttention: true, message: "Uploading")
    let callObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(call)) as? [String: Any])
    #expect(callObject["uploadFraction"] as? Double == 0.5)
    #expect(callObject["needsAttention"] as? Bool == true)
    let system = try #require(callObject["system"] as? [String: Any])
    #expect(Set(system.keys) == Set(["active", "hasSignal", "silenceSeconds"]))
    #expect(system["silenceSeconds"] as? Double == 12.4)
}

@Test func controlDecisions() {
    for step in JobStep.allCases {
        for command in [ControlRequest.Command.recordRoom, .recordCall] {
            #expect(ControlRequest.rejection(command, step: step, canStart: false) == .busy)
            #expect(ControlRequest.rejection(command, step: step, canStart: true) == (step == .review ? .busy : nil))
        }
        let canStop = step == .starting || step == .recording
        #expect(ControlRequest.rejection(.stop, step: step, canStart: false) == (canStop ? nil : .notRecording))
        #expect(ControlRequest.rejection(.status, step: step, canStart: false) == nil)
        #expect(ControlRequest.rejection(.subscribe, step: step, canStart: false) == nil)
    }
    #expect(ControlError.allCases.map(\.rawValue) == ["badRequest", "busy", "notRecording", "notReviewing", "denied"])
    #expect(ControlError.notReviewing.message == "No recording is waiting for a decision.")
    #expect(ControlError.allCases.allSatisfy { !$0.message.isEmpty })
}

@Test func reviewCommands() throws {
    #expect(try ControlRequest.decode(Data("{\"cmd\":\"transcribe\"}".utf8)).cmd == .transcribe)
    #expect(try ControlRequest.decode(Data("{\"cmd\":\"keep\"}".utf8)).cmd == .keep)
    #expect(JobStep.review.rawValue == "Review")
    for step in JobStep.allCases {
        for command in [ControlRequest.Command.transcribe, .keep] {
            #expect(
                ControlRequest.rejection(command, step: step, canStart: false)
                    == (step == .review ? nil : .notReviewing))
        }
    }
}

@Test func reviewTransitions() throws {
    for next in [JobStep.uploading, .preparing, .saved, .idle, .failed] {
        var state = JobState()
        try state.advance(to: .starting)
        try state.advance(to: .recording)
        try state.advance(to: .preparing)
        try state.advance(to: .review)
        #expect(throws: PraatvolError.self) { try state.advance(to: .recording) }
        try state.advance(to: next)
        #expect(state.step == next)
    }
}

@Test func reviewWarningsAreSafe() {
    #expect(JobProgress.reviewWarnings(preparationWarnings: [], durationSeconds: 120).isEmpty)
    #expect(
        JobProgress.reviewWarnings(preparationWarnings: [], durationSeconds: 5401) == [
            "Beyond tested length; may time out"
        ])
    #expect(
        JobProgress.reviewWarnings(preparationWarnings: ["failure at /private/audio.caf"], durationSeconds: 120)
            == ["Audio preparation reported warnings; check the saved audio before transcribing."])
}

@Test func reviewSnapshotValues() throws {
    let status = ControlStatus(
        step: .review, stepStartedAt: 123.5, estimatedSeconds: 40, preparingFraction: 0.75,
        durationSeconds: 120, uploadBytes: 960_000, warnings: ["Beyond tested length; may time out"])
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
    #expect(object["stepStartedAt"] as? Double == 123.5)
    #expect(object["estimatedSeconds"] as? Double == 40)
    #expect(object["preparingFraction"] as? Double == 0.75)
    #expect(object["durationSeconds"] as? Double == 120)
    #expect(object["uploadBytes"] as? Int == 960_000)
    #expect(object["warnings"] as? [String] == ["Beyond tested length; may time out"])
    #expect(object["needsAttention"] as? Bool == false)
}

@Test func controlFraming() throws {
    var framing = ControlLineFramer()
    #expect(try framing.append(Data("{\"cmd\":".utf8)).isEmpty)
    #expect(
        try framing.append(Data("\"status\"}\nnext\npartial".utf8)) == [
            Data("{\"cmd\":\"status\"}".utf8), Data("next".utf8),
        ])
    #expect(try framing.append(Data("\n".utf8)) == [Data("partial".utf8)])
    var boundary = ControlLineFramer()
    #expect(try boundary.append(Data(repeating: 32, count: 4096)).isEmpty)
    #expect(try boundary.append(Data([10])).first?.count == 4096)
    #expect(throws: ControlError.self) { try boundary.append(Data(repeating: 32, count: 4097)) }
    var terminated = ControlLineFramer()
    #expect(throws: ControlError.self) { try terminated.append(Data(repeating: 32, count: 4097) + Data([10])) }
}
