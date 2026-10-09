import Foundation

public struct PraatvolError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum UploadRules {
    public static let maximumBodyBytes = 50_000_000
    public static func bitrate(durationSeconds: Double) -> Int {
        if durationSeconds <= 3600 { return 64_000 }
        if durationSeconds <= 5400 { return 48_000 }
        // #COMPLETION_DRIVE: 32 kbps reduces size beyond tested length, not timeout risk.
        // #SUGGEST_VERIFY: Test real AAC recordings over 90 minutes before claiming support.
        return 32_000
    }
    public static func isBeyondTestedLength(_ durationSeconds: Double) -> Bool { durationSeconds > 5400 }
    public static func estimatedBodyBytes(audioBytes: Int) -> Int {
        // #COMPLETION_DRIVE: 1024 bytes covers typical request metadata, as in the PoC.
        // #SUGGEST_VERIFY: Also check the serialized body before sending.
        ((audioBytes + 2) / 3) * 4 + 1024
    }
    public static func validate(audioBytes: Int) throws {
        guard audioBytes >= 0 else { throw PraatvolError("Invalid audio size.") }
        guard audioBytes <= maximumBodyBytes else { throw sizeError() }
        guard estimatedBodyBytes(audioBytes: audioBytes) <= maximumBodyBytes else { throw sizeError() }
    }
    private static func sizeError() -> PraatvolError {
        PraatvolError(
            "The base64 request exceeds the 50,000,000-byte safety limit. The audio stays saved locally. Select a shorter file or turn off Send lossless."
        )
    }
}

public enum Storage {
    public static func root(isDevelopment: Bool) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
            .appendingPathComponent(isDevelopment ? "praatvol-dev" : "praatvol")
    }
    public static func relativeFolder(date: Date, kind: String, timezone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy/MM/dd/HH-mm-ss"
        let safeKind = kind.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "\(formatter.string(from: date)) \(safeKind)"
    }
    public static func createFolder(root: URL, date: Date, kind: String) throws -> URL {
        let folder = root.appendingPathComponent(relativeFolder(date: date, kind: kind))
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw PraatvolError("An item already exists at this second. Wait one second and try again.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

public enum TranscriptionRequest {
    public static func body(audio: Data, format: String, model: String) throws -> Data {
        try UploadRules.validate(audioBytes: audio.count)
        var payload: [String: Any] = [
            "model": model, "input_audio": ["data": audio.base64EncodedString(), "format": format],
            "response_format": "verbose_json", "timestamp_granularities": ["segment", "word"],
        ]
        if model.hasPrefix("elevenlabs/") {
            payload["provider"] = ["options": ["elevenlabs": ["diarize": true]]]
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        guard body.count <= UploadRules.maximumBodyBytes else {
            throw PraatvolError("The complete request exceeds 50,000,000 bytes. The audio stays saved locally.")
        }
        return body
    }
}

public struct Turn: Equatable, Sendable {
    public let start: Double
    public let speaker: String?
    public var text: String
    public init(start: Double, speaker: String?, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }
}

public struct Transcript {
    public let turns: [Turn]
    public let costUsd: Double?
    public var hasSpeakerLabels: Bool { turns.contains { $0.speaker != nil } }

    public static func parse(_ response: Data, statusCode: Int) throws -> Transcript {
        guard statusCode == 200 else {
            throw PraatvolError(
                statusCode == 401
                    ? "OpenRouter rejected the API key. Check Settings."
                    : "OpenRouter returned HTTP \(statusCode). The audio stays saved locally.")
        }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: response) } catch {
            throw PraatvolError("OpenRouter returned invalid JSON. The audio stays saved locally.")
        }
        guard let dictionary = object as? [String: Any] else {
            throw PraatvolError("OpenRouter returned an invalid JSON response.")
        }
        if dictionary.keys.contains("error") {
            // Never surface an untrusted provider body: it can contain private audio text.
            throw PraatvolError(
                "OpenRouter reported a provider failure or timeout. The audio stays saved locally. No request was retried."
            )
        }
        let words = dictionary["words"] as? [[String: Any]] ?? []
        let segments = dictionary["segments"] as? [[String: Any]] ?? []
        let useWords = words.contains { speakerValue($0["speaker"]) != nil }
        let items = useWords ? words : segments
        var turns = group(items, textKey: useWords ? "word" : "text")
        if turns.isEmpty, let text = dictionary["text"] as? String, !text.isEmpty {
            // #COMPLETION_DRIVE: Text without timestamps starts at zero, matching the PoC.
            // #SUGGEST_VERIFY: Check the raw response if a model omits timed items.
            turns = [Turn(start: 0, speaker: nil, text: text)]
        }
        let usage = dictionary["usage"] as? [String: Any]
        return Transcript(turns: turns, costUsd: usage?["cost"] as? Double)
    }

    private static func speakerValue(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        if let label = value as? String, !label.isEmpty { return label }
        return nil
    }

    private static func group(_ items: [[String: Any]], textKey: String) -> [Turn] {
        var turns: [Turn] = []
        for item in items {
            guard let text = (item[textKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { continue }
            let start = item["start"] as? Double ?? 0
            let speaker = speakerValue(item["speaker"])
            if continues(turns.last, speaker: speaker) {
                turns[turns.count - 1].text += " " + text
            } else {
                turns.append(Turn(start: start.isFinite ? max(0, start) : 0, speaker: speaker, text: text))
            }
        }
        return turns
    }

    private static func continues(_ previous: Turn?, speaker: String?) -> Bool {
        guard let speaker else { return false }
        return previous?.speaker == speaker
    }

    public func markdown(
        date: Date, durationSeconds: Double, model: String, sources: String,
        archiveName: String, uploadDescription: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateText = formatter.string(from: date)
        let speakers = Array(Set(turns.compactMap(\.speaker))).sorted { first, second in
            if let firstNumber = Int(first), let secondNumber = Int(second) { return firstNumber < secondNumber }
            return first < second
        }
        let costText = costUsd.map { String(format: "$%.6f (OpenRouter)", $0) } ?? "not reported"
        var lines = [
            "# Transcript: \(dateText)", "", "- Source audio: \(archiveName)",
            "- Sources: \(sources)", "- Date/time: \(dateText)",
            "- Duration: \(Self.duration(durationSeconds))", "- Speakers: \(speakers.count)",
            "- Model: \(model)", "- Cost: \(costText)", "- Upload: \(uploadDescription)",
        ]
        if !hasSpeakerLabels { lines.append("- Speaker labels: absent; lines use Speaker ?.") }
        lines.append("")
        if turns.isEmpty { lines.append("No speech was detected.") }
        for turn in turns {
            let label = Self.label(turn.speaker, speakers: speakers)
            lines.append("[\(Self.timestamp(turn.start))] Speaker \(label): \(turn.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func label(_ speaker: String?, speakers: [String]) -> String {
        guard let speaker else { return "?" }
        let index = Int(speaker) ?? speakers.firstIndex(of: speaker) ?? 0
        if index >= 0 && index < 26 { return String(UnicodeScalar(65 + index)!) }
        return speaker
    }
    public static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
    public static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        if total >= 3600 { return "\(total / 3600) h \(total / 60 % 60) min \(total % 60) s" }
        if total >= 60 { return "\(total / 60) min \(total % 60) s" }
        return "\(total) s"
    }
}
