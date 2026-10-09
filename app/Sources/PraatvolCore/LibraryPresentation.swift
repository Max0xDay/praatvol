import Foundation

/// Reads the speaker lines of a saved `transcript.md` for previews.
public enum TranscriptPreview {
    public struct Line: Equatable, Sendable {
        public let time: String
        public let speaker: String
        public let text: String
        public init(time: String, speaker: String, text: String) {
            self.time = time
            self.speaker = speaker
            self.text = text
        }
    }

    /// Parses lines in the form `[mm:ss] Speaker X: text`. Other lines are ignored.
    public static func lines(markdown: String, limit: Int) -> [Line] {
        var result: [Line] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            guard result.count < limit, let line = parse(String(raw)) else { continue }
            result.append(line)
        }
        return result
    }

    private static func parse(_ line: String) -> Line? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let time = String(line[line.index(after: line.startIndex)..<close])
        guard time.count >= 5, time.allSatisfy({ $0.isNumber || $0 == ":" }) else { return nil }
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("Speaker "), let colon = rest.firstIndex(of: ":") else { return nil }
        let speaker = rest[rest.index(rest.startIndex, offsetBy: 8)..<colon].trimmingCharacters(in: .whitespaces)
        let text = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !speaker.isEmpty else { return nil }
        return Line(time: time, speaker: speaker, text: text)
    }
}

/// Display rules for library items: titles, day sections, plain-language problems, and costs.
public enum ItemPresentation {
    public enum Kind: Sendable { case call, room, file }

    public enum Action: Sendable { case openSettings, retry }

    public struct Problem: Equatable, Sendable {
        public let summary: String
        public let detail: String
        public let action: Action
    }

    public struct Section: Sendable {
        public let title: String
        public let items: [LibraryItem]
    }

    public static func kind(of kind: String) -> Kind {
        if kind == "Call" { return .call }
        if kind == "Room" { return .room }
        return .file
    }

    /// Items worth showing: finished transcripts and failures with a fix. Unfinished leftovers stay on disk only.
    public static func listed(_ items: [LibraryItem]) -> [LibraryItem] {
        items.filter { $0.status != .notTranscribed }
    }

    /// The user's name for the item, or the generated title.
    public static func title(of metadata: ItemMetadata, calendar: Calendar = .current) -> String {
        if let custom = metadata.title, !custom.isEmpty { return custom }
        return title(kind: metadata.kind, date: metadata.date, calendar: calendar)
    }

    /// Normalises a typed name: single line, trimmed, at most 120 characters. Blank input returns nil.
    public static func cleanTitle(_ input: String) -> String? {
        let words = input.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        return String(words.joined(separator: " ").prefix(120))
    }

    /// Calls and rooms get their start time, so items on the same day stay distinct. Files keep their name.
    public static func title(kind: String, date: Date, calendar: Calendar = .current) -> String {
        if kind.hasPrefix("File: ") {
            let name = String(kind.dropFirst(6))
            let stem = (name as NSString).deletingPathExtension
            return stem.isEmpty ? name : stem
        }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%@ · %02d:%02d", kind, parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Groups items by calendar day, newest first: "Today", "Yesterday", then "1 Oct 2026".
    public static func sections(_ items: [LibraryItem], now: Date = Date(), calendar: Calendar = .current)
        -> [Section]
    {
        let sorted = items.sorted { $0.metadata.date > $1.metadata.date }
        var sections: [Section] = []
        var currentDay: Date?
        var bucket: [LibraryItem] = []
        for item in sorted {
            let day = calendar.startOfDay(for: item.metadata.date)
            if day != currentDay, let previous = currentDay {
                sections.append(Section(title: dayTitle(previous, now: now, calendar: calendar), items: bucket))
                bucket = []
            }
            currentDay = day
            bucket.append(item)
        }
        if let currentDay {
            sections.append(Section(title: dayTitle(currentDay, now: now, calendar: calendar), items: bucket))
        }
        return sections
    }

    private static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        if day == today { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "Yesterday"
        }
        let parts = calendar.dateComponents([.day, .month, .year], from: day)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let month = months[max(0, min(11, (parts.month ?? 1) - 1))]
        return "\(parts.day ?? 1) \(month) \(parts.year ?? 0)"
    }

    /// Turns a stored error message into a short summary and the one action that fixes it.
    public static func problem(for message: String) -> Problem {
        let lowered = message.lowercased()
        if lowered.contains("keychain") {
            return Problem(
                summary: "praatvol couldn't read your OpenRouter key.",
                detail: "macOS blocked access to the saved key. Save the key again in Settings, then transcribe again.",
                action: .openSettings)
        }
        if lowered.contains("api key") {
            return Problem(
                summary: "No OpenRouter key was saved.",
                detail: "Add your key in Settings, then transcribe again.", action: .openSettings)
        }
        if lowered.contains("524") || lowered.contains("timed out") || lowered.contains("timeout") {
            return Problem(
                summary: "The transcription service timed out.",
                detail: "Long recordings can exceed the provider's limit. The audio stays saved.", action: .retry)
        }
        return Problem(summary: "Transcription failed.", detail: message, action: .retry)
    }

    public static func cost(_ value: Double?) -> String? {
        guard let value else { return nil }
        if value == 0 { return "$0" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }
}
