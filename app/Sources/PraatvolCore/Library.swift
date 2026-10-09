import Foundation

public enum ItemStatus: String, Codable, Sendable {
    case transcribed = "Transcribed"
    case failed = "Failed"
    case notTranscribed = "Not transcribed"
}

public struct ItemMetadata: Codable, Equatable, Sendable {
    public var date: Date
    public var kind: String
    public var sources: String
    public var durationSeconds: Double = 0
    public var status: ItemStatus = .notTranscribed
    public var errorMessage: String?
    public var costUsd: Double?
    public var model: String?
    public var speakerCount: Int = 0
    public var wordCount: Int = 0
    public var offsetSeconds: Double = 0
    public init(date: Date, kind: String, sources: String) {
        self.date = date
        self.kind = kind
        self.sources = sources
    }
}

public struct LibraryItem: Identifiable, Sendable {
    public let folder: URL
    public let metadata: ItemMetadata
    public var id: String { folder.path }
    public var transcript: URL { folder.appendingPathComponent("transcript.md") }
    public var status: ItemStatus {
        if metadata.status == .failed { return .failed }
        if FileManager.default.fileExists(atPath: transcript.path) { return .transcribed }
        return .notTranscribed
    }
    public var retrySource: URL? {
        let names = ["audio.flac", "audio.wav", "upload.m4a", "mic.flac", "mic.caf"]
        for name in names {
            let source = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) { return source }
        }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            return files.first { $0.lastPathComponent.hasPrefix("original.") }
        } catch {
            NSLog("praatvol: retry source scan failed (code %ld)", (error as NSError).code)
            return nil
        }
    }
    public var canRetry: Bool {
        guard status != .transcribed else { return false }
        return retrySource != nil
    }
}

public enum Library {
    public static func save(_ metadata: ItemMetadata, folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: folder.appendingPathComponent("item.json"), options: .atomic)
    }
    public static func load(folder: URL) throws -> ItemMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ItemMetadata.self, from: Data(contentsOf: folder.appendingPathComponent("item.json")))
    }
    public static func scan(root: URL) throws -> [LibraryItem] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var traversalError: Error?
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, error in
                    traversalError = error
                    return false
                })
        else {
            throw PraatvolError("Cannot scan the library folder.")
        }
        var folders = Set<URL>()
        for case let file as URL in enumerator {
            if isItemFile(file.lastPathComponent) { folders.insert(file.deletingLastPathComponent()) }
        }
        if let traversalError { throw traversalError }
        return try folders.map { folder in
            let metadata: ItemMetadata
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("item.json").path) {
                metadata = try load(folder: folder)
            } else {
                let values = try folder.resourceValues(forKeys: [.creationDateKey])
                // #COMPLETION_DRIVE: Legacy folders lack metadata; creation date and folder label identify the item.
                // #SUGGEST_VERIFY: Check imported beta folders; no Markdown parsing or invented cost is used.
                metadata = ItemMetadata(
                    date: values.creationDate ?? .distantPast,
                    kind: String(folder.lastPathComponent.dropFirst(9)), sources: "Legacy audio")
            }
            return LibraryItem(folder: folder, metadata: metadata)
        }.sorted { $0.metadata.date > $1.metadata.date }
    }
    private static func isItemFile(_ name: String) -> Bool {
        if name.hasPrefix("original.") { return true }
        return ["item.json", "transcript.md", "audio.flac", "audio.wav", "upload.m4a", "mic.caf", "mic.flac"].contains(
            name)
    }
}
