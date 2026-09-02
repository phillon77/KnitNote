import Foundation
import Testing
@testable import KnitNoteCore

struct SyncInstallationIdentityTests {
    @Test func identityPersistsAcrossRestartAndDoesNotDependOnStorePath() throws {
        let rootA = try temporaryDirectory()
        let rootB = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        let first = try SyncInstallationIdentityStore(
            url: rootA.appending(path: "identity.json")
        ).loadOrCreate()
        let restarted = try SyncInstallationIdentityStore(
            url: rootA.appending(path: "identity.json")
        ).loadOrCreate()
        let otherInstallation = try SyncInstallationIdentityStore(
            url: rootB.appending(path: "identity.json")
        ).loadOrCreate()

        #expect(first == restarted)
        #expect(first != otherInstallation)
    }

    @Test func corruptIdentityFailsClosedWithoutReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "identity.json")
        let bytes = Data("not-json".utf8)
        try bytes.write(to: url)

        #expect(throws: SyncInstallationIdentityError.corrupt) {
            _ = try SyncInstallationIdentityStore(url: url).loadOrCreate()
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func unsafeExistingIdentityFailsClosedWithoutReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "identity.json")
        let target = root.appending(path: "identity-target.json")
        let bytes = Data("keep".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)

        #expect(throws: SyncInstallationIdentityError.unsafeFile) {
            _ = try SyncInstallationIdentityStore(url: destination).loadOrCreate()
        }
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test func competingCreationNeverClobbersTheInstalledIdentityBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "identity.json")
        let competingBytes = Data("competing-corrupt-identity".utf8)
        let store = SyncInstallationIdentityStore(url: url, beforeCreate: {
            try competingBytes.write(to: url, options: .atomic)
        })

        #expect(throws: SyncInstallationIdentityError.corrupt) {
            _ = try store.loadOrCreate()
        }
        #expect(try Data(contentsOf: url) == competingBytes)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-installation-identity-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
