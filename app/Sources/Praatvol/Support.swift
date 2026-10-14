import AppKit
import Foundation
import PraatvolCore

struct AppIdentity {
    // #COMPLETION_DRIVE: A bare SwiftPM executable defaults to dev identity, never production.
    // #SUGGEST_VERIFY: Launch a built app bundle for correct TCC attribution and preferences.
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.praatvol.app.dev"
    static let isDevelopment = bundleIdentifier.hasSuffix(".dev")
    static let name = isDevelopment ? "praatvol Dev" : "praatvol"
    static let root = Storage.root(isDevelopment: isDevelopment)
    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")
        .appendingPathComponent(root.lastPathComponent)
    static let controlSocket = supportDirectory.appendingPathComponent("control.sock")
}

final class AppLog {
    static let shared = AppLog()
    private let lock = NSLock()
    private let url: URL
    private init() {
        url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
            .appendingPathComponent(AppIdentity.isDevelopment ? "praatvol-dev" : "praatvol")
            .appendingPathComponent("app.log")
    }
    // Callers supply fixed event names and numeric codes, never payloads or keys.
    func event(_ name: String, code: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
            let file = try FileHandle(forWritingTo: url)
            defer { do { try file.close() } catch { NSLog("praatvol: log close failed") } }
            try file.seekToEnd()
            let suffix = code.map { " code=\($0)" } ?? ""
            try file.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(name)\(suffix)\n".utf8))
        } catch { NSLog("praatvol: log write failed") }
    }
}

enum KeyStore {
    private static let store = FileKeyStore(directory: AppIdentity.supportDirectory)
    private static let lock = NSLock()

    static func read() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return try store.read()
    }

    static func save(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try store.save(key)
    }
}

struct Preferences {
    let model: String
    let microphoneIdentifier: String
    let lossless: Bool
    let askBeforeTranscribing: Bool
    let controlSocketEnabled: Bool
    static func read() -> Preferences {
        let defaults = UserDefaults.standard
        return Preferences(
            model: defaults.string(forKey: "model") ?? "elevenlabs/scribe-v2",
            microphoneIdentifier: defaults.string(forKey: "microphone") ?? "",
            lossless: defaults.bool(forKey: "lossless"),
            askBeforeTranscribing: defaults.bool(forKey: "askBeforeTranscribing"),
            controlSocketEnabled: defaults.object(forKey: "controlSocketEnabled") as? Bool ?? true)
    }
}

enum AppModal {
    static var attentionChanged: (Bool) -> Void = { _ in }

    static func run(_ action: () -> NSApplication.ModalResponse) -> NSApplication.ModalResponse {
        attentionChanged(true)
        defer { attentionChanged(false) }
        return action()
    }
}

func showAlert(_ message: String, title: String = AppIdentity.name) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    _ = AppModal.run { alert.runModal() }
}
