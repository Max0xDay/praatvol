import Darwin
import Foundation

public struct FileKeyStore {
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("api-key") }

    public init(directory: URL) {
        self.directory = directory
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    public func read() throws -> String {
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return ""
        }
    }

    public func save(_ key: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporaryFile = directory.appendingPathComponent(".api-key-\(UUID().uuidString)")
        guard manager.createFile(atPath: temporaryFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw PraatvolError("Cannot create the private API key file.") }
        defer {
            if manager.fileExists(atPath: temporaryFile.path) {
                do { try manager.removeItem(at: temporaryFile) } catch {
                    NSLog("praatvol: key store temporary file cleanup failed")
                }
            }
        }
        try Data(key.utf8).write(to: temporaryFile)
        guard rename(temporaryFile.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
