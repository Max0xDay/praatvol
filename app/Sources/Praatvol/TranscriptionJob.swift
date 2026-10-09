import Foundation
import PraatvolCore

struct PreparedItem {
    let folder: URL
    let date: Date
    let archive: Archive
    let upload: URL
    let durationSeconds: Double
    let sources: String
    let warnings: [String]
}

struct TranscriptionCompletion {
    let transcript: URL
    let hasSpeakerLabels: Bool
    let metadata: ItemMetadata
}

struct ProgressUpdate: Sendable {
    let step: JobStep
    let message: String
    let fraction: Double
    var sentBytes: Int64 = 0
    var totalBytes: Int64 = 0
}

// #COMPLETION_DRIVE: Reporters enqueue UI updates on the main queue; delegate callbacks use a serial queue.
// #SUGGEST_VERIFY: Keep reporters immutable and retain the main-queue hop if strict Swift concurrency is enabled.
typealias JobReporter = (ProgressUpdate) -> Void

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: JobReporter
    init(report: @escaping JobReporter) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let fraction = JobProgress.fraction(completed: totalBytesSent, total: totalBytesExpectedToSend)
        let step: JobStep = fraction == 1 ? .transcribing : .uploading
        report(ProgressUpdate(step: step, message: step == .transcribing ? "The provider processes the audio." : "Send audio to OpenRouter",
                              fraction: fraction, sentBytes: totalBytesSent, totalBytes: totalBytesExpectedToSend))
    }
}

enum TranscriptionJob {
    static func prepare(capture: CapturedItem, report: @escaping JobReporter) throws -> PreparedItem {
        let folder = capture.folder
        var warnings = capture.warnings
        let microphone = compressTrack(capture.microphone, warnings: &warnings, report: report)
        let microphoneMono = folder.appendingPathComponent(".mic-mono.caf")
        try AudioFiles.convert(source: microphone, destination: microphoneMono,
                               progress: stage("Convert microphone", report: report))
        let source: URL
        if let rawSystem = capture.system {
            let system = compressTrack(rawSystem, warnings: &warnings, report: report)
            let systemMono = folder.appendingPathComponent(".system-mono.caf")
            try AudioFiles.convert(source: system, destination: systemMono, progress: stage("Convert system audio", report: report))
            let mixed = folder.appendingPathComponent(".mixed.caf")
            try AudioFiles.mix(microphone: microphoneMono, system: systemMono,
                offsetSeconds: capture.offsetSeconds, destination: mixed, progress: stage("Mix tracks", report: report))
            source = mixed
            if try isSilent(systemMono) { warnings.append(Recorder.systemHelp) }
        } else { source = microphoneMono }
        if try isSilent(microphoneMono) { warnings.append(Recorder.microphoneHelp) }
        return try prepareAudio(source: source, folder: folder, date: capture.date,
                                sources: capture.sources, warnings: warnings, report: report)
    }

    static func prepare(file: URL, folder: URL, report: @escaping JobReporter) throws -> PreparedItem {
        let original = folder.appendingPathComponent("original.\(file.pathExtension)")
        report(ProgressUpdate(step: .preparing, message: "Preserve the original file", fraction: 0))
        try FileManager.default.copyItem(at: file, to: original)
        let metadata = try Library.load(folder: folder)
        return try prepareAudio(source: original, folder: folder, date: metadata.date,
                                sources: metadata.sources, warnings: [], report: report)
    }

    static func prepareRetry(item: LibraryItem, report: @escaping JobReporter) throws -> PreparedItem {
        let folder = item.folder
        guard let source = item.retrySource else { throw PraatvolError("The saved audio is unavailable.") }
        if isSavedArchive(source) {
            let durationSeconds = try AudioFiles.duration(source)
            let temporary = folder.appendingPathComponent(".retry-source.caf")
            try AudioFiles.convert(source: source, destination: temporary, progress: stage("Prepare saved archive", report: report))
            let upload = try AudioFiles.upload(source: temporary, folder: folder, durationSeconds: durationSeconds,
                                              progress: stage("Encode AAC upload", report: report))
            try FileManager.default.removeItem(at: temporary)
            var metadata = try Library.load(folder: folder)
            metadata.durationSeconds = durationSeconds
            try Library.save(metadata, folder: folder)
            return PreparedItem(folder: folder, date: item.metadata.date,
                archive: Archive(url: source, explanation: "Saved lossless archive"), upload: upload,
                durationSeconds: durationSeconds, sources: item.metadata.sources, warnings: [])
        }
        if source.lastPathComponent.hasPrefix("mic.") {
            let system = ["system.flac", "system.caf"].map { folder.appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            let capture = CapturedItem(folder: folder, date: item.metadata.date, microphone: source, system: system,
                offsetSeconds: item.metadata.offsetSeconds, sources: item.metadata.sources, warnings: [])
            return try prepare(capture: capture, report: report)
        }
        return try prepareAudio(source: source, folder: folder, date: item.metadata.date,
                                sources: item.metadata.sources, warnings: [], report: report)
    }

    private static func isSavedArchive(_ source: URL) -> Bool {
        ["audio.flac", "audio.wav"].contains(source.lastPathComponent)
    }

    private static func progressAdvanced(_ fraction: Double, since previous: Double) -> Bool {
        if fraction == 1 { return true }
        return fraction - previous >= 0.01
    }

    private static func stage(_ message: String, report: @escaping JobReporter) -> (Double) -> Void {
        var lastFraction = -1.0
        return { fraction in
            guard progressAdvanced(fraction, since: lastFraction) else { return }
            lastFraction = fraction
            report(ProgressUpdate(step: .preparing, message: message, fraction: fraction))
        }
    }

    private static func compressTrack(_ source: URL, warnings: inout [String], report: @escaping JobReporter) -> URL {
        guard source.pathExtension == "caf" else { return source }
        do {
            return try RawTracks.compress(source, progress: stage("Compress \(source.lastPathComponent)", report: report))
        } catch {
            AppLog.shared.event("raw-flac-failed", code: (error as NSError).code)
            warnings.append("\(source.lastPathComponent) stays saved: \(error.localizedDescription)")
            let partial = source.deletingPathExtension().appendingPathExtension("flac")
            do {
                if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
            } catch { AppLog.shared.event("partial-flac-cleanup-failed", code: (error as NSError).code) }
            return source
        }
    }

    private static func isSilent(_ url: URL) throws -> Bool {
        // #COMPLETION_DRIVE: The proven helper treats peak <= 0.00001 as silence, not speech detection.
        // #SUGGEST_VERIFY: Inspect quiet speech before changing the threshold.
        try AudioFiles.peak(url) <= 0.00001
    }

    private static func prepareAudio(source: URL, folder: URL, date: Date,
                                     sources: String, warnings: [String], report: @escaping JobReporter) throws -> PreparedItem {
        let normalized = folder.appendingPathComponent(".normalized.caf")
        let mono = folder.appendingPathComponent(".source-mono.caf")
        try AudioFiles.convert(source: source, destination: mono, progress: stage("Convert audio", report: report))
        try AudioFiles.normalize(source: mono, destination: normalized, progress: stage("Normalize audio", report: report))
        report(ProgressUpdate(step: .preparing, message: "Save the lossless archive", fraction: 0))
        let archive = try AudioFiles.archive(source: normalized, folder: folder,
                                             progress: stage("Save the lossless archive", report: report))
        let durationSeconds = try AudioFiles.duration(archive.url)
        guard durationSeconds > 0 else { throw PraatvolError("The audio contains no frames. Check capture permissions.") }
        var metadata = try Library.load(folder: folder)
        metadata.durationSeconds = durationSeconds
        try Library.save(metadata, folder: folder)
        guard try !isSilent(archive.url) else { throw PraatvolError("The audio is silent. Check microphone and system audio permissions.") }
        let upload = try AudioFiles.upload(source: normalized, folder: folder, durationSeconds: durationSeconds,
                                          progress: stage("Encode AAC upload", report: report))
        for name in [".mic-mono.caf", ".system-mono.caf", ".mixed.caf", ".normalized.caf", ".source-mono.caf"] {
            let temporary = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
        }
        return PreparedItem(folder: folder, date: date, archive: archive, upload: upload,
                            durationSeconds: durationSeconds, sources: sources, warnings: warnings)
    }

    static func transcribe(item: PreparedItem, preferences: Preferences, apiKey: String,
                           report: @escaping JobReporter) async throws -> TranscriptionCompletion {
        guard !apiKey.isEmpty else { throw PraatvolError("Set the OpenRouter API key in Settings, then choose Transcribe again.") }
        let upload = preferences.lossless ? item.archive.url : item.upload
        let audio = try Data(contentsOf: upload)
        let body = try TranscriptionRequest.body(audio: audio, format: upload.pathExtension, model: preferences.model)
        let description = String(format: "%@ · %.2f MB audio · %.2f MB request", upload.pathExtension.uppercased(),
                                 Double(audio.count) / 1_000_000, Double(body.count) / 1_000_000)
        report(ProgressUpdate(step: .uploading, message: description, fraction: 0, totalBytes: Int64(body.count)))
        let start = Date()
        let response = try await send(body: body, apiKey: apiKey, folder: item.folder, report: report)
        let transcript = try Transcript.parse(response.body, statusCode: response.status)
        try response.body.write(to: item.folder.appendingPathComponent("transcript.json"), options: .atomic)
        let markdownURL = item.folder.appendingPathComponent("transcript.md")
        let markdown = transcript.markdown(date: item.date, durationSeconds: item.durationSeconds,
            model: preferences.model, sources: ([item.sources] + item.warnings).joined(separator: "; "),
            archiveName: item.archive.url.lastPathComponent,
            uploadDescription: description + String(format: "; request took %.1f s; %@", Date().timeIntervalSince(start), item.archive.explanation))
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        var metadata = try Library.load(folder: item.folder)
        metadata.status = .transcribed
        metadata.errorMessage = nil
        metadata.model = preferences.model
        metadata.costUsd = transcript.costUsd
        metadata.speakerCount = Set(transcript.turns.compactMap(\.speaker)).count
        metadata.wordCount = transcript.turns.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        try Library.save(metadata, folder: item.folder)
        return TranscriptionCompletion(transcript: markdownURL, hasSpeakerLabels: transcript.hasSpeakerLabels, metadata: metadata)
    }

    private static func send(body: Data, apiKey: String, folder: URL, report: @escaping JobReporter) async throws -> (body: Data, status: Int) {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = false
        let delegate = UploadProgressDelegate(report: report)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        AppLog.shared.event("transcription-post-started")
        // Exactly one paid POST. Never retry an ambiguous or failed request automatically.
        let (response, metadata) = try await session.upload(for: request, from: body)
        // Save before parsing so errors, malformed JSON, and error-in-200 bodies survive.
        let errorURL = folder.appendingPathComponent("transcript-error.json")
        try response.write(to: errorURL, options: .atomic)
        guard let metadata = metadata as? HTTPURLResponse else { throw PraatvolError("OpenRouter returned no HTTP response.") }
        AppLog.shared.event("transcription-response", code: metadata.statusCode)
        _ = try Transcript.parse(response, statusCode: metadata.statusCode)
        try FileManager.default.removeItem(at: errorURL)
        return (response, metadata.statusCode)
    }
}
