import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncBootstrapOwnedDurabilityMatrixTests {
    @Test func nativePerFileReadCapIsInclusiveWithoutAccountWrites() throws {
        let f = try OwnedMatrixFixture(media: false); defer { f.remove() }
        let url = f.root.appendingPathComponent("bounded-read"), bytes = Data(repeating: 0x58, count: 7)
        try bytes.write(to: url)
        let parent = Darwin.open(f.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw OwnedFixtureFailure.injected }; defer { Darwin.close(parent) }
        let before = try OwnedMatrixFixture.files(f.paths.accountRoot)
        #expect(try SyncBootstrapOwnedPOSIX.read(url.lastPathComponent, parent: parent, maximumBytes: 7) == bytes)
        #expect(throws: (any Error).self) { try SyncBootstrapOwnedPOSIX.read(url.lastPathComponent, parent: parent, maximumBytes: 6) }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == before)
        #expect(!FileManager.default.fileExists(atPath: f.namespace.path))
    }

    @Test func installedCommitMatchesOrdinaryJournalAndContinuesAcrossOrdinaryReopen() throws {
        let f = try OwnedMatrixFixture(legacyJournal: true, media: false); defer { f.remove() }
        let tx = try f.transaction(), input = try f.input(), plan = try tx.plan(input)
        let prepared = try tx.prepare(input)
        try tx.install(prepared)
        let expectedRoot = f.root.appendingPathComponent("ordinary")
        let metadata = f.paths.workingSet.appendingPathComponent("SyncMetadata")
        // This clone is only an ordinary-journal byte parity oracle. Ownership
        // recovery below always operates on the original account/inodes.
        try FileManager.default.copyItem(at: metadata, to: expectedRoot)
        let expected = FileSyncMutationJournal(url: expectedRoot.appendingPathComponent("pending.json"))
        try expected.enqueue(plan.mutations)
        _ = try tx.commit(prepared)
        func journalFiles(_ root: URL) throws -> [String: Data] {
            try OwnedMatrixFixture.files(root).filter { $0.key != "bootstrap-receipt.json" }
        }
        #expect(try journalFiles(metadata) == journalFiles(expectedRoot))
        #expect(try f.journal.recoverySnapshot().mutations == expected.recoverySnapshot().mutations)
        // Ordinary reopen must preserve the native checkpoint/frame sequence.
        // Vault restore instead replays a semantic packet into a fresh journal;
        // that separately tested workflow does not promise original wire bytes.
        let restored = FileSyncMutationJournal(url: f.paths.mutationJournalURL), next = OwnedMatrixFixture.mutation(909)
        try restored.enqueue(next); try restored.enqueue(next)
        try expected.enqueue(next); try expected.enqueue(next)
        #expect(try restored.pending() == expected.pending())
        #expect(try journalFiles(metadata) == journalFiles(expectedRoot))
        try restored.acknowledge([next.identity]); try expected.acknowledge([next.identity])
        #expect(try FileSyncMutationJournal(url: f.paths.mutationJournalURL).pending() == expected.pending())
        #expect(try journalFiles(metadata) == journalFiles(expectedRoot))
    }

    @Test(arguments: ["live", "undeclared-role", "extra-uuid"])
    func exactFailedPartialNameHasNoAuthorityOutsideFrozenFailed(location: String) throws {
        let f = try OwnedMatrixFixture(media: false); defer { f.remove() }
        let source = try OwnedMatrixFixture.files(f.paths.workingSet)
        var armed = false, hit = false, partialName: String?
        let tx = try f.transaction(boundary: { if $0 == .afterInstalled { armed = true } }, io: .init(write: { fd, bytes in
            let path = try OwnedMatrixFixture.descriptorPath(fd)
            if hit {
                #expect(path.hasSuffix("/active-next.json"))
                switch try BootstrapManifestV3.decodeEnvelope(bytes).body {
                case .rollingBack, .rolledBack: break
                default: Issue.record("forward selector after failed commit output")
                }
            }
            if armed && !hit && path.contains("/.bootstrap-receipt.json.") && path.hasSuffix(".tmp") {
                hit = true; partialName = URL(fileURLWithPath: path).lastPathComponent
                try SyncBootstrapOwnedPOSIX.write(fd, Data(bytes.prefix(7)))
                throw OwnedFixtureFailure.injected
            }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        }))
        let prepared = try tx.prepare(f.input()); try tx.install(prepared)
        #expect(throws: (any Error).self) { try tx.commit(prepared) }
        #expect(hit)
        #expect(try OwnedMatrixFixture.files(f.paths.workingSet) == source)
        let manifest = try OwnedMatrixFixture.manifest(f.paths, account: f.account)
        guard case let .rolledBack(rollback) = manifest.body else { Issue.record("missing frozen Failed"); return }
        let name = try #require(partialName)
        let retained = try #require(rollback.frozenTransactionEntries.first { $0.relativePath.hasSuffix("/Failed/SyncMetadata/" + name) })
        let bytes = try Data(contentsOf: f.paths.accountRoot.appendingPathComponent(retained.relativePath))
        #expect(bytes.count == 7 && retained.sha256 == OwnedBootstrapCodec.hash(bytes))
        _ = try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
            journal: f.journal, archiveURL: f.paths.workingSet.appendingPathComponent("projects-v1.json"))
        let valid = try OwnedMatrixFixture.files(f.paths.accountRoot)
        _ = try f.transaction().recover()
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == valid)
        let parent: URL
        switch location {
        case "live": parent = f.paths.workingSet.appendingPathComponent("SyncMetadata")
        case "undeclared-role": parent = f.paths.accountRoot.appendingPathComponent(manifest.transactionRelativePath + "/Undeclared")
        default: parent = f.namespace.appendingPathComponent(UUID().uuidString)
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try bytes.write(to: parent.appendingPathComponent(name))
        let changed = try OwnedMatrixFixture.files(f.paths.accountRoot)
        #expect(throws: (any Error).self) { try f.transaction().recover() }
        #expect(throws: (any Error).self) {
            try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
                journal: f.journal, archiveURL: f.paths.workingSet.appendingPathComponent("projects-v1.json"))
        }
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == changed)
        #expect(try Data(contentsOf: f.paths.accountRoot.appendingPathComponent(retained.relativePath)) == bytes)
    }

    @Test(arguments: ["file", "parent"], [false, true])
    func actualHistoryDurabilityCutsRepairSameRecord(target: String, after: Bool) throws {
        let f = try OwnedMatrixFixture(media: false); defer { f.remove() }
        let first = try f.transaction(boundary: { if $0 == .beforeTransactionRootCreation { throw OwnedFixtureFailure.injected } })
        #expect(throws: (any Error).self) { try first.prepare(f.input()) }
        let old = try Data(contentsOf: f.namespace.appendingPathComponent("active.json"))
        var hit = false, sawFile = false, record: String?, inode: UInt64?
        let retry = try f.transaction(io: .init(synchronize: { fd in
            let path = try OwnedMatrixFixture.descriptorPath(fd)
            let isFile = path.contains("/History/") && path.hasSuffix(".json")
            if isFile {
                sawFile = true; record = path
                var info = stat(); #expect(fstat(fd, &info) == 0)
                if inode == nil { inode = info.st_ino } else { #expect(info.st_ino == inode) }
            }
            let matches = target == "file" ? isFile : sawFile && path.hasSuffix("/History")
            if matches && !hit {
                hit = true
                if after { try SyncBootstrapOwnedPOSIX.synchronize(fd) }
                throw OwnedFixtureFailure.injected
            }
            try SyncBootstrapOwnedPOSIX.synchronize(fd)
        }))
        #expect(throws: (any Error).self) { try retry.prepare(f.input()) }
        #expect(hit)
        let url = URL(fileURLWithPath: try #require(record)), bytes = try Data(contentsOf: url)
        #expect(try BootstrapHistoryRecordV1.decodeEnvelope(bytes).terminalEnvelope == old)
        var info = stat(); #expect(lstat(url.path, &info) == 0); #expect(info.st_ino == inode)
        let frozen = try OwnedMatrixFixture.files(f.paths.accountRoot)
        _ = try f.transaction().recover()
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == frozen)
        try OwnedMatrixFixture.authenticate(storage: f.storage, paths: f.paths, account: f.account)
    }
}
