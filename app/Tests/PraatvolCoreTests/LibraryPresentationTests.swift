import Foundation
import Testing

@testable import PraatvolCore

private let utc = TimeZone(identifier: "UTC")!

private func calendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar
}

private func date(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = utc
    return formatter.date(from: text)!
}

private func item(_ kind: String, _ when: String) -> LibraryItem {
    LibraryItem(
        folder: URL(fileURLWithPath: "/tmp/praatvol-tests/\(kind)-\(when)"),
        metadata: ItemMetadata(date: date(when), kind: kind, sources: "test"))
}

@Test func previewParsesSpeakerLines() {
    let markdown = """
        # Transcript: 2026-10-09 12:58:00

        - Duration: 41 s
        - Speakers: 2

        [00:00] Speaker A: Good morning, everyone.
        [00:04] Speaker B: Morning.
        [01:12] Speaker ?: Unknown voice.
        """
    let lines = TranscriptPreview.lines(markdown: markdown, limit: 10)
    #expect(lines.count == 3)
    #expect(lines[0] == TranscriptPreview.Line(time: "00:00", speaker: "A", text: "Good morning, everyone."))
    #expect(lines[2].speaker == "?")
}

@Test func previewRespectsLimitAndIgnoresNoise() {
    let markdown = "No speech was detected.\n[00:01] Speaker A: One\n[00:02] Speaker B: Two\n[00:03] Speaker A: Three\n"
    #expect(TranscriptPreview.lines(markdown: markdown, limit: 2).map(\.text) == ["One", "Two"])
    #expect(TranscriptPreview.lines(markdown: "", limit: 5).isEmpty)
    #expect(TranscriptPreview.lines(markdown: "[bad] Speaker A: x\nSpeaker A: y", limit: 5).isEmpty)
}

@Test func titlesAreDistinctAndReadable() {
    let cal = calendar()
    #expect(ItemPresentation.title(kind: "Room", date: date("2026-10-09T12:58:00Z"), calendar: cal) == "Room · 12:58")
    #expect(ItemPresentation.title(kind: "Call", date: date("2026-10-09T09:05:00Z"), calendar: cal) == "Call · 09:05")
    #expect(
        ItemPresentation.title(kind: "File: New Recording.m4a", date: date("2026-10-09T11:55:00Z"), calendar: cal)
            == "New Recording")
    #expect(ItemPresentation.kind(of: "File: x.m4a") == .file)
    #expect(ItemPresentation.kind(of: "Call") == .call)
    #expect(ItemPresentation.kind(of: "Room") == .room)
}

@Test func sectionsGroupByDayNewestFirst() {
    let cal = calendar()
    let now = date("2026-10-09T15:00:00Z")
    let items = [
        item("Room", "2026-10-09T12:58:00Z"), item("Call", "2026-10-09T11:43:00Z"),
        item("Room", "2026-10-08T10:00:00Z"), item("Room", "2026-10-01T10:00:00Z"),
    ]
    let sections = ItemPresentation.sections(items, now: now, calendar: cal)
    #expect(sections.map(\.title) == ["Today", "Yesterday", "1 Oct 2026"])
    #expect(sections[0].items.count == 2)
    #expect(sections[0].items.first?.metadata.kind == "Room")
    #expect(ItemPresentation.sections([], now: now, calendar: cal).isEmpty)
}

@Test func failuresBecomePlainLanguage() {
    let keychain = ItemPresentation.problem(for: "Keychain access failed (-25293). Allow access for praatvol Dev.")
    #expect(keychain.action == .openSettings)
    #expect(!keychain.summary.contains("-25293"))

    let missingKey = ItemPresentation.problem(
        for: "Set the OpenRouter API key in Settings. The audio stays saved locally.")
    #expect(missingKey.action == .openSettings)

    let timeout = ItemPresentation.problem(for: "Provider returned 524")
    #expect(timeout.action == .retry)
    #expect(timeout.summary.lowercased().contains("timed out"))

    let other = ItemPresentation.problem(for: "Something odd happened.")
    #expect(other.action == .retry)
    #expect(other.detail == "Something odd happened.")
}

@Test func sidebarListsOnlyTranscribedAndFailedItems() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("praatvol-listed-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func folder(_ name: String, files: [String], status: ItemStatus? = nil) throws -> LibraryItem {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files { try Data().write(to: url.appendingPathComponent(file)) }
        var metadata = ItemMetadata(date: date("2026-10-09T12:00:00Z"), kind: "Room", sources: "test")
        if let status { metadata.status = status }
        return LibraryItem(folder: url, metadata: metadata)
    }
    let done = try folder("done", files: ["audio.flac", "transcript.md"])
    let failed = try folder("failed", files: ["audio.flac"], status: .failed)
    let leftover = try folder("leftover", files: ["mic.caf"])
    #expect(ItemPresentation.listed([done, failed, leftover]).map(\.id) == [done.id, failed.id])
}

@Test func fileTitlesDropTheExtension() {
    let when = date("2026-10-09T11:55:00Z")
    #expect(ItemPresentation.title(kind: "File: Team sync.m4a", date: when, calendar: calendar()) == "Team sync")
    #expect(ItemPresentation.title(kind: "File: notes", date: when, calendar: calendar()) == "notes")
}

@Test func customTitlesWinAndBlankNamesReset() {
    var metadata = ItemMetadata(date: date("2026-10-09T12:58:00Z"), kind: "Room", sources: "test")
    #expect(ItemPresentation.title(of: metadata, calendar: calendar()) == "Room · 12:58")
    metadata.title = "Weekly sync"
    #expect(ItemPresentation.title(of: metadata, calendar: calendar()) == "Weekly sync")
    #expect(ItemPresentation.cleanTitle("  Budget\nreview  ") == "Budget review")
    #expect(ItemPresentation.cleanTitle("   \n ") == nil)
    #expect(ItemPresentation.cleanTitle(String(repeating: "a", count: 300))?.count == 120)
}

@Test func renameIsSavedAndKeepsOtherMetadata() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("praatvol-rename-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var metadata = ItemMetadata(date: date("2026-10-09T12:58:00Z"), kind: "Room", sources: "test")
    metadata.speakerCount = 3
    try Library.save(metadata, folder: folder)
    let item = LibraryItem(folder: folder, metadata: metadata)

    try Library.rename(item, to: " Standup ")
    var loaded = try Library.load(folder: folder)
    #expect(loaded.title == "Standup")
    #expect(loaded.speakerCount == 3)

    try Library.rename(item, to: "")
    loaded = try Library.load(folder: folder)
    #expect(loaded.title == nil)
}

@Test func renameWorksForLegacyFoldersWithoutMetadata() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("praatvol-legacy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let item = LibraryItem(
        folder: folder, metadata: ItemMetadata(date: date("2026-10-09T11:55:00Z"), kind: "Room", sources: "Legacy"))
    try Library.rename(item, to: "Old meeting")
    #expect(try Library.load(folder: folder).title == "Old meeting")
}

@Test func metadataWithoutTitleStillDecodes() throws {
    let json = Data(
        """
        {"date":"2026-10-09T12:58:00Z","kind":"Room","sources":"x","durationSeconds":1,"status":"Transcribed",
         "speakerCount":0,"wordCount":0,"offsetSeconds":0}
        """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(ItemMetadata.self, from: json).title == nil)
}

@Test func costFormattingIsCompact() {
    #expect(ItemPresentation.cost(nil) == nil)
    #expect(ItemPresentation.cost(0) == "$0")
    #expect(ItemPresentation.cost(0.004_21) == "$0.0042")
    #expect(ItemPresentation.cost(0.165) == "$0.17")
}
