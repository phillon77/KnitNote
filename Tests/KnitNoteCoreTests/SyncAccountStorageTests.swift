import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

struct SyncAccountStorageTests {
    @Test func existingEmptyNamespaceCannotMintFreshnessOrChangeFiles() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let account = try fixture.identity("existing-empty")
        let storage = SyncAccountStorage(baseURL: fixture.root)
        let paths = try storage.open(identity: account)
        try storage.close()
        let markerURL = paths.accountRoot.appendingPathComponent(".decrypted-temporary/.owner-v1")
        let marker = try Data(contentsOf: markerURL)
        #expect(throws: (any Error).self) { try storage.openForVerifiedAccount(identity: account, validateAccount: {}) }
        #expect(throws: (any Error).self) { try storage.openExistingAccount(identity: account, validateAccount: {}) }
        #expect(try Data(contentsOf: markerURL) == marker)
        #expect(!FileManager.default.fileExists(atPath: paths.accountRoot.appendingPathComponent(".sealed-recovery-v1").path))
        let missing = try fixture.identity("never-created")
        #expect(throws: (any Error).self) { try storage.openExistingAccount(identity: missing, validateAccount: {}) }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(missing.accountIDHash).path))
    }

    @Test func corruptedExistingArchiveNeverReceivesFreshState() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let account = try fixture.identity("corrupt-archive")
        let storage = SyncAccountStorage(baseURL: fixture.root)
        let paths = try storage.open(identity: account)
        let archive = paths.workingSet.appendingPathComponent("projects-v1.json")
        let bytes = Data("corrupt archive".utf8)
        try bytes.write(to: archive); try storage.close()
        let reopened = try storage.openExistingAccount(identity: account, validateAccount: {})
        defer { try? storage.close() }
        #expect(try Data(contentsOf: archive) == bytes)
        try storage.withRecoveryOwnership(paths: reopened, account: account, maximumBytes: 100_000_000) { access in
            let observation = try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access)
            #expect(observation.state == nil)
        }
    }

    @Test func accountValidatorRunsOutsideMutexAndRejectsGenerationChange() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let account = try fixture.identity("generation")
        let storage = SyncAccountStorage(baseURL: fixture.root)
        var calls = 0
        #expect(throws: SourceOpenFailure.changed) {
            try storage.openForVerifiedAccount(identity: account, validateAccount: {
                calls += 1
                // Reentrant close proves the validation callback does not hold storage's mutex.
                try storage.close()
                if calls == 2 { throw SourceOpenFailure.changed }
            })
        }
        #expect(calls == 2)
        _ = try storage.openExistingAccount(identity: account, validateAccount: {})
        try storage.close()
    }

    @Test func rejectedVerifiedGenerationPreservesAbandonedTemporaryBytes() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let account = try fixture.identity("preserve-temporary")
        var old: SyncAccountStorage? = SyncAccountStorage(baseURL: fixture.root)
        let paths = try old!.open(identity: account)
        let bytes = Data("owned but still inventoried".utf8)
        try Data("archive".utf8).write(to: paths.workingSet.appendingPathComponent("projects-v1.json"))
        let abandoned = paths.decryptedTemporary.deletingLastPathComponent().appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        let temporaryFile = abandoned.appendingPathComponent("copy")
        try bytes.write(to: temporaryFile)
        old = nil
        let storage = SyncAccountStorage(baseURL: fixture.root)
        var validations = 0
        #expect(throws: SourceOpenFailure.changed) {
            try storage.openExistingAccount(identity: account, validateAccount: {
                validations += 1
                if validations == 2 { throw SourceOpenFailure.changed }
            })
        }
        #expect(FileManager.default.fileExists(atPath: temporaryFile.path))
        if FileManager.default.fileExists(atPath: temporaryFile.path) {
            #expect(try Data(contentsOf: temporaryFile) == bytes)
        }
    }

    @Test(arguments: Array(1...10)) func freshDurabilityFaultNeverCreatesNewAuthorityOnReopen(failAt: Int) throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let account = try fixture.identity("fault")
        let fault = SourceOpenSyncFault(failAt: failAt)
        let failing = SyncAccountStorage(baseURL: fixture.root, synchronize: { try fault.sync($0) })
        #expect(throws: (any Error).self) { try failing.openForVerifiedAccount(identity: account, validateAccount: {}) }
        let root = fixture.root.appendingPathComponent(account.accountIDHash)
        let main = root.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let original = try? Data(contentsOf: main)
        let storage = SyncAccountStorage(baseURL: fixture.root)
        if let original {
            _ = try storage.openExistingAccount(identity: account, validateAccount: {})
            #expect(try Data(contentsOf: main) == original)
            try storage.close()
        } else {
            #expect(throws: (any Error).self) { try storage.openForVerifiedAccount(identity: account, validateAccount: {}) }
        }
    }

    @Test func freshScaffoldCannotChangeDuringInitialDurabilityBarrier() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let account = try fixture.identity("changed-scaffold")
        let injected = fixture.root.appendingPathComponent(account.accountIDHash).appendingPathComponent("staging/injected")
        let storage = SyncAccountStorage(baseURL: fixture.root, synchronize: { fd in
            if !FileManager.default.fileExists(atPath: injected.path) { try Data("unexpected source".utf8).write(to: injected) }
            guard fsync(fd) == 0 else { throw SourceOpenFailure.changed }
        })
        #expect(throws: (any Error).self) { try storage.openForVerifiedAccount(identity: account, validateAccount: {}) }
        #expect(try Data(contentsOf: injected) == Data("unexpected source".utf8))
    }

    @Test func finalSourceBarrierRejectsChangesBeforePathsAreExposed() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let account = try fixture.identity("final-barrier")
        let root = fixture.root.appendingPathComponent(account.accountIDHash)
        let injected = root.appendingPathComponent("working-set/injected")
        let storage = SyncAccountStorage(baseURL: fixture.root, synchronize: { fd in
            let sessions = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".decrypted-temporary").path)
            if sessions.contains(where: { UUID(uuidString: $0) != nil }) {
                try Data("late source".utf8).write(to: injected)
            }
            guard fsync(fd) == 0 else { throw SourceOpenFailure.changed }
        })
        #expect(throws: (any Error).self) { try storage.openForVerifiedAccount(identity: account, validateAccount: {}) }
        #expect(try Data(contentsOf: injected) == Data("late source".utf8))
    }

    @Test(arguments: ["owner", "root", "symlink", "interrupted"])
    func verifiedReopenRejectsInvalidOwnershipWithoutRepair(kind: String) throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let account = try fixture.identity("invalid")
        let storage = SyncAccountStorage(baseURL: fixture.root)
        let paths = try storage.openForVerifiedAccount(identity: account, validateAccount: {})
        try storage.close()
        let main = paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let bytes = try Data(contentsOf: main)
        if kind == "owner" {
            try Data("bad owner".utf8).write(to: paths.accountRoot.appendingPathComponent(".decrypted-temporary/.owner-v1"))
        } else if kind == "root" {
            let moved = fixture.root.appendingPathComponent("old-root")
            try FileManager.default.moveItem(at: paths.accountRoot, to: moved)
            try FileManager.default.copyItem(at: moved, to: paths.accountRoot)
        } else if kind == "symlink" {
            try FileManager.default.createSymbolicLink(at: paths.workingSet.appendingPathComponent("projects-v1.json"), withDestinationURL: main)
        } else {
            try FileManager.default.moveItem(at: main, to: main.deletingLastPathComponent().appendingPathComponent("intent-next.json"))
        }
        #expect(throws: (any Error).self) { try storage.openExistingAccount(identity: account, validateAccount: {}) }
        let remaining = kind == "interrupted" ? main.deletingLastPathComponent().appendingPathComponent("intent-next.json") : main
        #expect(try Data(contentsOf: remaining) == bytes)
    }

    @Test func freshAllocationOnlyComesFromActualDirectoryCreation() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("source-state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let account = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "fresh")
        let storage = SyncAccountStorage(baseURL: base)
        let paths = try storage.openForVerifiedAccount(identity: account, validateAccount: {})
        defer { try? storage.close() }
        try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: 100_000_000) { access in
            let control = SyncAccountRecoveryControlFile(synchronize: { _ in })
            guard case .absentSource(let state)? = try control.observe(access: access).state else {
                Issue.record("Actual fresh allocation did not persist absence provenance"); return
            }
            #expect(state.accountIDHash == account.accountIDHash)
            #expect(state.archiveURL == paths.workingSet.appendingPathComponent("projects-v1.json"))
            #expect(state.journalURL == paths.mutationJournalURL)
            let before = try access.entries()
            let snapshot = try FileSyncMutationJournal(url: paths.mutationJournalURL).recoverySnapshot()
            #expect(snapshot.mutations.isEmpty)
            #expect(try access.entries() == before)
            #expect(try SyncAccountSourceBaseline.digest(entries: before, accountRoot: paths.accountRoot,
                journalURL: paths.mutationJournalURL, mutations: [], selectedFiles: [], deletionLedger: nil,
                pendingMarkerVersions: []) == state.baselineSHA256)
        }
    }

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

    @Test(arguments: ["main", "next", "unknown", "oversized", "directory"])
    func genericOpenNeverDeletesAbandonedCopiesWithRecoveryControlEvidence(kind: String) throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let identity = try fixture.identity("A")
        var original: SyncAccountStorage? = SyncAccountStorage(baseURL: fixture.root)
        let paths = try original!.open(identity: identity)
        let abandoned = paths.decryptedTemporary.deletingLastPathComponent().appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        let copy = abandoned.appendingPathComponent("captured")
        let bytes = Data("retained encrypted-recovery input".utf8)
        try bytes.write(to: copy)
        let control = paths.accountRoot.appendingPathComponent(".sealed-recovery-v1")
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false)
        let name = kind == "next" ? "intent-next.json" : kind == "unknown" ? "other" : "intent.json"
        let file = control.appendingPathComponent(name)
        if kind == "directory" { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false) }
        else { try Data(repeating: 1, count: kind == "oversized" ? 8193 : 8).write(to: file) }
        original = nil
        let reopened = SyncAccountStorage(baseURL: fixture.root)
        defer { try? reopened.close() }
        if kind == "main" || kind == "next" { _ = try reopened.open(identity: identity) }
        else { #expect(throws: (any Error).self) { try reopened.open(identity: identity) } }
        #expect(try Data(contentsOf: copy) == bytes)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func abandonedOwnedTemporaryIsRecoveredButPersistentStagingSurvives() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var storage: SyncAccountStorage? = SyncAccountStorage(baseURL: fixture.root)
        let paths = try #require(storage).open(identity: fixture.identity("A"))
        let abandoned = paths.decryptedTemporary.deletingLastPathComponent().appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        try Data("secret".utf8).write(to: abandoned.appendingPathComponent("decoded"))
        try Data("upload".utf8).write(to: paths.staging.appendingPathComponent("pending"))
        // A synthetic abandoned sibling survives this owner's normal ARC close.
        // No process crash is simulated by dropping the current owner.
        storage = nil
        #expect(FileManager.default.fileExists(atPath: abandoned.path))
        let reopened = SyncAccountStorage(baseURL: fixture.root)
        _ = try reopened.open(identity: fixture.identity("A")); defer { try? reopened.close() }
        #expect(!FileManager.default.fileExists(atPath: paths.decryptedTemporary.path))
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(try Data(contentsOf: paths.staging.appendingPathComponent("pending")) == Data("upload".utf8))
    }

    @Test(arguments: [false, true])
    func ordinaryARCReleaseUsesValidatedCloseAndPreservesUnsafeEvidence(unsafe: Bool) throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var storage: SyncAccountStorage? = SyncAccountStorage(baseURL: fixture.root)
        let paths = try storage!.open(identity: fixture.identity("A"))
        let copy = paths.decryptedTemporary.appendingPathComponent("copy")
        try Data("temporary copy".utf8).write(to: copy)
        let link = paths.decryptedTemporary.appendingPathComponent("unsafe")
        if unsafe {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.outside)
            #expect(throws: SyncAccountStorageError.unsafePath) { try storage!.close() }
        }
        storage = nil
        if unsafe {
            #expect(try Data(contentsOf: copy) == Data("temporary copy".utf8))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == fixture.outside.path)
            #expect(try Data(contentsOf: fixture.sentinel) == Data("outside".utf8))
        } else { #expect(!FileManager.default.fileExists(atPath: paths.decryptedTemporary.path)) }
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
        let abandoned = paths.decryptedTemporary.deletingLastPathComponent().appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        let decoded = abandoned.appendingPathComponent("decoded")
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

private enum SourceOpenFailure: Error { case changed }
private final class SourceOpenSyncFault: @unchecked Sendable {
    var remaining: Int
    init(failAt: Int) { remaining = failAt }
    func sync(_ fd: Int32) throws {
        remaining -= 1
        if remaining == 0 { throw SourceOpenFailure.changed }
        guard fsync(fd) == 0 else { throw SourceOpenFailure.changed }
    }
}
