import Foundation
import Testing
@testable import PraatvolCore

@Test func jobTransitions() throws {
    var job = JobState()
    #expect(job.step == .idle)
    #expect(throws: PraatvolError.self) { try job.advance(to: .saved) }
    for step in [JobStep.starting, .recording, .preparing, .uploading, .transcribing, .saved] {
        try job.advance(to: step)
        #expect(job.step == step)
    }
    try job.advance(to: .preparing)
    try job.advance(to: .failed)
    try job.advance(to: .preparing)
    try job.advance(to: .idle)
    try job.advance(to: .starting)
    try job.advance(to: .idle)
    #expect(job.step == .idle)
}

@Test func progressAndTiers() {
    #expect(JobProgress.fraction(completed: 25, total: 100) == 0.25)
    #expect(JobProgress.fraction(completed: 200, total: 100) == 1)
    #expect(JobProgress.fraction(completed: -1, total: 100) == 0)
    #expect(JobProgress.fraction(completed: 1, total: 0) == 0)
    #expect(JobProgress.estimateSeconds(durationSeconds: 3600) == 68)
    #expect(JobProgress.estimateSeconds(durationSeconds: 5400) == 88)
    #expect(JobProgress.remainingSeconds(durationSeconds: 3600, elapsedSeconds: 70) == 0)
    #expect(JobProgress.remainingSeconds(durationSeconds: 3600, elapsedSeconds: 8) == 60)
    #expect(JobProgress.tierHint(durationSeconds: 3599).contains("64"))
    #expect(JobProgress.tierHint(durationSeconds: 3601).contains("48"))
    #expect(JobProgress.tierHint(durationSeconds: 5401).contains("32"))
}

@Test func levelMeasurements() throws {
    let level = try AudioLevel.measure([0.5, -0.5, 0.5, -0.5])
    #expect(level.rms == 0.5)
    #expect(level.peak == 0.5)
    #expect(abs(level.decibelsFullScale + 6.0206) < 0.001)
    #expect(level.hasSignal)
    let silence = try AudioLevel.measure([])
    #expect(silence == AudioLevel.silence)
    #expect(!silence.hasSignal)
    #expect(silence.decibelsFullScale == -120)
    #expect(throws: PraatvolError.self) { try AudioLevel.measure([.nan]) }
    #expect(throws: PraatvolError.self) { try AudioLevel.measure([.infinity]) }
}

@Test func libraryRoundTripAndRetry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Cannot remove test library: \(error)") }
    }
    #expect(try Library.scan(root: root).isEmpty)
    var older = ItemMetadata(date: Date(timeIntervalSince1970: 1), kind: "Room", sources: "mic")
    let olderFolder = try Storage.createFolder(root: root, date: older.date, kind: older.kind)
    try Library.save(older, folder: olderFolder)
    let newer = ItemMetadata(date: Date(timeIntervalSince1970: 2), kind: "File: memo.m4a", sources: "file")
    let newerFolder = try Storage.createFolder(root: root, date: newer.date, kind: newer.kind)
    try Library.save(newer, folder: newerFolder)
    var items = try Library.scan(root: root)
    #expect(items.map(\.metadata.date) == [newer.date, older.date])
    #expect(items[1].metadata == older)
    #expect(items[1].status == .notTranscribed)
    #expect(!items[1].canRetry)
    try Data([1]).write(to: olderFolder.appendingPathComponent("audio.flac"))
    items = try Library.scan(root: root)
    #expect(items[1].canRetry)
    older.status = .failed
    older.errorMessage = "Missing key"
    older.durationSeconds = 12
    older.model = "test/model"
    older.speakerCount = 2
    older.wordCount = 30
    older.costUsd = 0.001
    try Library.save(older, folder: olderFolder)
    #expect(try Library.load(folder: olderFolder) == older)
    items = try Library.scan(root: root)
    #expect(items[1].status == .failed)
    #expect(items[1].canRetry)
    older.status = .transcribed
    try Library.save(older, folder: olderFolder)
    items = try Library.scan(root: root)
    #expect(items[1].status == .notTranscribed)
    try Data("transcript".utf8).write(to: olderFolder.appendingPathComponent("transcript.md"))
    items = try Library.scan(root: root)
    #expect(items[1].status == .transcribed)
    #expect(!items[1].canRetry)
}

@Test func legacyLibraryAndMalformedMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Cannot remove test library: \(error)") }
    }
    let folder = try Storage.createFolder(root: root, date: Date(), kind: "Room")
    try Data([1]).write(to: folder.appendingPathComponent("upload.m4a"))
    let items = try Library.scan(root: root)
    #expect(items.count == 1)
    #expect(items[0].canRetry)
    #expect(items[0].retrySource?.lastPathComponent == "upload.m4a")
    try Data("invalid".utf8).write(to: folder.appendingPathComponent("item.json"))
    #expect(throws: (any Error).self) { try Library.scan(root: root) }
    #expect(try Library.scan(root: root.appendingPathComponent("absent")).isEmpty)
}
