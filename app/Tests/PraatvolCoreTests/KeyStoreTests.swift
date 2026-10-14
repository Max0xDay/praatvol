import Foundation
import Testing

@testable import PraatvolCore

private func withKeyStore(_ action: (FileKeyStore, URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        if FileManager.default.fileExists(atPath: folder.path) {
            do { try FileManager.default.removeItem(at: folder) } catch {
                Issue.record("Cannot remove key store test folder: \(error)")
            }
        }
    }
    try action(FileKeyStore(directory: folder), folder)
}

@Test func missingKeyFileReturnsEmptyString() throws {
    try withKeyStore { store, _ in
        let key = try store.read()
        #expect(key == "")
    }
}

@Test(arguments: ["synthetic-key", "  synthetic-key\n\t", ""])
func keyFileRoundTripPreservesContents(key: String) throws {
    try withKeyStore { store, _ in
        try store.save(key)
        #expect(try store.read() == key)
    }
}

@Test func keyFileAndDirectoryArePrivate() throws {
    try withKeyStore { store, folder in
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try store.save("synthetic-key")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent("api-key").path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

@Test func keyFileOverwriteReplacesContents() throws {
    try withKeyStore { store, folder in
        try store.save("long-synthetic-key")
        try store.save("short")
        #expect(try store.read() == "short")
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent("api-key").path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["api-key"])
    }
}
