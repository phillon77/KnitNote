import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

struct SyncAccountStorageTests {
    @Test func identitySeparatesFieldBoundariesContainersAndExactRecordNames() throws {
        let pairs = [("ab", "c"), ("a", "bc"), ("a|b", "c"), ("a", "b|c"),
                     ("a", "é"), ("a", "e\u{301}"), ("a", "C"), ("a", "c")]
        let identities = try pairs.map { try SyncAccountIdentity(containerIdentifier: $0, userRecordName: $1) }
        #expect(Set(identities).count == pairs.count)
        #expect(try SyncAccountIdentity(containerIdentifier: "ab", userRecordName: "c") == identities[0])
        // Fixed v1 vector independently hashed with shasum, guarding persisted
        // namespace stability across builds (and not merely pair separation).
        #expect(identities[0].accountIDHash == "00a65d65e2ffc42711ceda0682b503f4f32bc37fb677cf979cb8678efded8415")
        #expect(identities.allSatisfy { $0.accountIDHash.count == 64 && $0.accountIDHash.allSatisfy { "0123456789abcdef".contains($0) } })
        #expect(throws: SyncAccountStorageError.invalidIdentity) { try SyncAccountIdentity(containerIdentifier: "", userRecordName: "user") }
        #expect(throws: SyncAccountStorageError.invalidIdentity) { try SyncAccountIdentity(containerIdentifier: "container", userRecordName: "") }
    }

    @Test func pathsAndDiagnosticsNeverExposeRawIdentity() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let raw = "private-user/../../record-secret"
        let identity = try SyncAccountIdentity(containerIdentifier: "iCloud.private-container", userRecordName: raw)
        let storage = SyncAccountStorage(baseURL: fixture.root)
        let paths = try storage.open(identity: identity); defer { try? storage.close() }
        #expect(!String(reflecting: identity).contains(raw))
        #expect(!String(reflecting: storage).contains(raw))
        #expect(!String(reflecting: paths).contains("private-container"))
        for url in paths.persistentRoots + [paths.decryptedTemporary] {
            #expect(url.path.hasPrefix(paths.accountRoot.path + "/"))
            #expect(!url.path.contains("record-secret"))
            var directory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue)
        }
        #expect(Set(paths.persistentRoots).count == 6)
    }

    @Test func twoAccountsHaveSeparateStableRootsAndPreservePendingSourcesOnClose() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let a = SyncAccountStorage(baseURL: fixture.root), b = SyncAccountStorage(baseURL: fixture.root)
        let pa = try a.open(identity: fixture.identity("A")), pb = try b.open(identity: fixture.identity("B"))
        defer { try? a.close(); try? b.close() }
        #expect(Set(pa.persistentRoots).isDisjoint(with: pb.persistentRoots))
        for root in pa.persistentRoots + pb.persistentRoots {
            try Data("pending-original".utf8).write(to: root.appendingPathComponent("source"))
        }
        for relative in [".sync-deletions/retained/proof", "SyncMetadata/journal-source"] {
            let file = pa.workingSet.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("plaintext-to-seal-first".utf8).write(to: file)
        }
        // Bootstrap puts original/staged/backup beside liveRoot, not inside it.
        let bootstrap = pa.accountRoot.appendingPathComponent(".KnitNote-SyncBootstrap/original/source")
        try FileManager.default.createDirectory(at: bootstrap.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original-bootstrap".utf8).write(to: bootstrap)
        let nested = pa.decryptedTemporary.appendingPathComponent("nested/decoded")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("decrypted".utf8).write(to: nested)
        try a.close(); try a.close()
        #expect(!FileManager.default.fileExists(atPath: pa.decryptedTemporary.path))
        #expect(FileManager.default.fileExists(atPath: pb.decryptedTemporary.path))
        for root in pa.persistentRoots + pb.persistentRoots {
            #expect(try Data(contentsOf: root.appendingPathComponent("source")) == Data("pending-original".utf8))
        }
        #expect(try Data(contentsOf: pa.workingSet.appendingPathComponent(".sync-deletions/retained/proof")) == Data("plaintext-to-seal-first".utf8))
        #expect(try Data(contentsOf: bootstrap) == Data("original-bootstrap".utf8))
        let reopened = try a.open(identity: fixture.identity("A"))
        #expect(reopened.persistentRoots == pa.persistentRoots)
        #expect(reopened.decryptedTemporary != pa.decryptedTemporary)
    }

    @Test func doubleOpenAndConcurrentAccountOwnerAreRejected() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = SyncAccountStorage(baseURL: fixture.root), other = SyncAccountStorage(baseURL: fixture.root)
        _ = try storage.open(identity: fixture.identity("A")); defer { try? storage.close(); try? other.close() }
        #expect(throws: SyncAccountStorageError.alreadyOpen) { try storage.open(identity: fixture.identity("B")) }
        #expect(throws: SyncAccountStorageError.accountInUse) { try other.open(identity: fixture.identity("A")) }
        try storage.close()
        _ = try other.open(identity: fixture.identity("A"))
    }

    @Test func abandonedOwnedTemporaryIsRecoveredButPersistentStagingSurvives() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var storage: SyncAccountStorage? = SyncAccountStorage(baseURL: fixture.root)
        let paths = try #require(storage).open(identity: fixture.identity("A"))
        try Data("secret".utf8).write(to: paths.decryptedTemporary.appendingPathComponent("decoded"))
        try Data("upload".utf8).write(to: paths.staging.appendingPathComponent("pending"))
        // Dropping an unclosed handle releases descriptors; next open owns recovery.
        storage = nil
        let reopened = SyncAccountStorage(baseURL: fixture.root)
        _ = try reopened.open(identity: fixture.identity("A")); defer { try? reopened.close() }
        #expect(!FileManager.default.fileExists(atPath: paths.decryptedTemporary.path))
        #expect(try Data(contentsOf: paths.staging.appendingPathComponent("pending")) == Data("upload".utf8))
    }

    @Test func refusesUnownedTemporaryRootWithoutDeletingItsContents() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = SyncAccountStorage(baseURL: fixture.root)
        let paths = try storage.open(identity: fixture.identity("A"))
        try storage.close()
        let owner = paths.decryptedTemporary.deletingLastPathComponent().appendingPathComponent(".owner-v1")
        try FileManager.default.removeItem(at: owner)
        let unknown = owner.deletingLastPathComponent().appendingPathComponent("unknown")
        try Data("not-owned".utf8).write(to: unknown)
        #expect(throws: SyncAccountStorageError.unsafePath) { try storage.open(identity: fixture.identity("A")) }
        #expect(try Data(contentsOf: unknown) == Data("not-owned".utf8))
    }

    @Test func rejectsSymlinkAtEveryStorageBoundaryWithoutTouchingTarget() throws {
        for boundary in 0..<9 {
            let fixture = try Fixture(); defer { fixture.remove() }
            let storage = SyncAccountStorage(baseURL: fixture.root)
            let paths = try storage.open(identity: fixture.identity("A")); try storage.close()
            let targets = [paths.accountRoot] + paths.persistentRoots + [paths.decryptedTemporary.deletingLastPathComponent(), fixture.root]
            let target = targets[boundary]
            let saved = target.appendingPathExtension("saved")
            try FileManager.default.moveItem(at: target, to: saved)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: fixture.outside)
            #expect(throws: SyncAccountStorageError.unsafePath) { try storage.open(identity: fixture.identity("A")) }
            #expect(try Data(contentsOf: fixture.sentinel) == Data("outside".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outside.path) == ["sentinel"])
        }
    }

    @Test func rejectsNestedPersistentSymlinkAndHardlink() throws {
        for hardlink in [false, true] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let storage = SyncAccountStorage(baseURL: fixture.root)
            let paths = try storage.open(identity: fixture.identity("A")); try storage.close()
            let nested = paths.staging.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            let link = nested.appendingPathComponent("link")
            if hardlink { try FileManager.default.linkItem(at: fixture.sentinel, to: link) }
            else { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.outside) }
            #expect(throws: SyncAccountStorageError.unsafePath) { try storage.open(identity: fixture.identity("A")) }
            #expect(try Data(contentsOf: fixture.sentinel) == Data("outside".utf8))
        }
    }

    @Test func closeRejectsSymlinkWithoutFollowingOrDeletingAndCanRetry() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = SyncAccountStorage(baseURL: fixture.root)
        let paths = try storage.open(identity: fixture.identity("A")); defer { try? storage.close() }
        let regular = paths.decryptedTemporary.appendingPathComponent("plain")
        try Data("owned".utf8).write(to: regular)
        let link = paths.decryptedTemporary.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.outside)
        #expect(throws: SyncAccountStorageError.unsafePath) { try storage.close() }
        #expect(try Data(contentsOf: fixture.sentinel) == Data("outside".utf8))
        #expect(try Data(contentsOf: regular) == Data("owned".utf8))
        try FileManager.default.removeItem(at: link)
        try storage.close()
        #expect(!FileManager.default.fileExists(atPath: paths.decryptedTemporary.path))
    }

    @Test func closeRejectsReplacedTemporaryRootAndPreservesReplacement() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = SyncAccountStorage(baseURL: fixture.root)
        let paths = try storage.open(identity: fixture.identity("A"))
        let saved = paths.decryptedTemporary.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: paths.decryptedTemporary, to: saved)
        try FileManager.default.createDirectory(at: paths.decryptedTemporary, withIntermediateDirectories: false)
        let replacement = paths.decryptedTemporary.appendingPathComponent("foreign")
        try Data("preserve".utf8).write(to: replacement)
        #expect(throws: SyncAccountStorageError.unsafePath) { try storage.close() }
        #expect(try Data(contentsOf: replacement) == Data("preserve".utf8))
        try FileManager.default.removeItem(at: paths.decryptedTemporary)
        try FileManager.default.moveItem(at: saved, to: paths.decryptedTemporary)
        try storage.close()
    }

    @Test func rejectsUnsafeBootstrapSiblingBeforeCleaningAbandonedTemporary() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var storage: SyncAccountStorage? = SyncAccountStorage(baseURL: fixture.root)
        let paths = try #require(storage).open(identity: fixture.identity("A"))
        let decoded = paths.decryptedTemporary.appendingPathComponent("decoded")
        try Data("owned-copy".utf8).write(to: decoded)
        storage = nil
        let bootstrap = paths.accountRoot.appendingPathComponent(".KnitNote-SyncBootstrap")
        try FileManager.default.createSymbolicLink(at: bootstrap, withDestinationURL: fixture.outside)
        let next = SyncAccountStorage(baseURL: fixture.root); defer { try? next.close() }
        #expect(throws: SyncAccountStorageError.unsafePath) { try next.open(identity: fixture.identity("A")) }
        #expect(try Data(contentsOf: decoded) == Data("owned-copy".utf8))
        #expect(try Data(contentsOf: fixture.sentinel) == Data("outside".utf8))
    }

    private struct Fixture {
        let container: URL
        let root: URL
        let outside: URL
        var sentinel: URL { outside.appendingPathComponent("sentinel") }
        init() throws {
            container = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("account-storage-\(UUID().uuidString)")
            root = container.appendingPathComponent("sync")
            outside = container.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("outside".utf8).write(to: sentinel)
        }
        func identity(_ account: String) throws -> SyncAccountIdentity {
            try .init(containerIdentifier: "iCloud.test", userRecordName: account)
        }
        func remove() { try? FileManager.default.removeItem(at: container) }
    }
}
