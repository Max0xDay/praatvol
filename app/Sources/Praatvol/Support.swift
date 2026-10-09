import AppKit
import Foundation
import PraatvolCore
import Security

struct AppIdentity {
    // #COMPLETION_DRIVE: A bare SwiftPM executable defaults to dev identity, never production.
    // #SUGGEST_VERIFY: Launch a built app bundle for correct TCC attribution and preferences.
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.praatvol.app.dev"
    static let isDevelopment = bundleIdentifier.hasSuffix(".dev")
    static let name = isDevelopment ? "praatvol Dev" : "praatvol"
    static let root = Storage.root(isDevelopment: isDevelopment)
    static let keychainService = bundleIdentifier
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
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
            let file = try FileHandle(forWritingTo: url)
            defer { do { try file.close() } catch { NSLog("praatvol: log close failed") } }
            try file.seekToEnd()
            let suffix = code.map { " code=\($0)" } ?? ""
            try file.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(name)\(suffix)\n".utf8))
        } catch { NSLog("praatvol: log write failed") }
    }
}

enum Keychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: AppIdentity.keychainService,
         kSecAttrAccount as String: "openrouter-api-key"]
    }
    static func read() throws -> String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let bytes = item as? Data,
              let key = String(data: bytes, encoding: .utf8) else {
            throw PraatvolError("Keychain access failed (\(status)). Allow access for \(AppIdentity.name).")
        }
        return key
    }
    static func save(_ key: String) throws {
        let bytes = Data(key.utf8)
        let updates: [String: Any] = [kSecValueData as String: bytes]
        var status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = bytes
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PraatvolError("Cannot save the API key in Keychain (\(status)).") }
    }
}

struct Preferences {
    let model: String
    let microphoneIdentifier: String
    let lossless: Bool
    static func read() -> Preferences {
        let defaults = UserDefaults.standard
        return Preferences(model: defaults.string(forKey: "model") ?? "elevenlabs/scribe-v2",
                           microphoneIdentifier: defaults.string(forKey: "microphone") ?? "",
                           lossless: defaults.bool(forKey: "lossless"))
    }
}

func showAlert(_ message: String, title: String = AppIdentity.name) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
