import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncBootstrapOwnedPhysicalHistoryTests {
    private struct Chain {
        let fixture: OwnedBootstrapFixture
        let terminals: [Data]
        let contexts: [SyncBootstrapContext]
        let records: [Data]
    }

    private func context(_ f: OwnedBootstrapFixture) -> SyncBootstrapContext {
        .init(accountIDHash: f.source.account.accountIDHash, epoch: UUID(), freezeID: UUID())
    }
    private func input(_ context: SyncBootstrapContext) -> SyncBootstrapOwnedInput {
        .init(local: nil, sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
            remote: .init(context: context, records: [], attachments: [:], isComplete: true),
            pending: nil, counterReminderContext: .init())
    }
    private func transaction(_ f: OwnedBootstrapFixture, context: SyncBootstrapContext, id: UUID = UUID(),
        maximumBytes: Int = 100_000_000, now: Date = Date(),
        boundary: @escaping (SyncBootstrapOwnedBoundary) throws -> Void = { _ in }) throws -> SyncBootstrapOwnedTransaction {
        try .init(storage: f.source.storage, paths: f.source.paths, account: f.source.account, context: context,
            maximumBytes: maximumBytes, transactionID: id, now: now,
            validateContext: { guard $0 == context else { throw SyncBootstrapError.contextChanged } },
            boundary: boundary)
    }

    // Every predecessor comes from actual owned execution and real source
    // handoff. No copied tree or synthetic history record issues authority.
    private func chain() throws -> Chain {
        let f = try OwnedBootstrapFixture()
        do {
            let before = try OwnedMatrixFixture.files(f.source.paths.workingSet)
            var terminals: [Data] = [], contexts: [SyncBootstrapContext] = []
            var generations = Set<UUID>(), authority: UUID?
            for attempt in 0..<4 {
                let c = context(f), id = UUID()
                contexts.append(c)
                var hit = false
                let tx = try transaction(f, context: c, id: id, boundary: { point in
                    if attempt == 0, case .afterPreparationOutput = point,
                       try OwnedMatrixFixture.files(f.namespace.appendingPathComponent(id.uuidString)).values.contains(where: { !$0.isEmpty }) {
                        hit = true; throw OwnedFixtureFailure.injected
                    }
                    if attempt == 1, point == .afterTransactionRootCreation {
                        hit = true; throw OwnedFixtureFailure.injected
                    }
                    if attempt == 2, point == .afterInstalled {
                        hit = true; throw OwnedFixtureFailure.injected
                    }
                })
                if attempt < 2 {
                    #expect(throws: (any Error).self) { try tx.prepare(input(c)) }
                } else {
                    let prepared = try tx.prepare(input(c))
                    if attempt == 2 { #expect(throws: (any Error).self) { try tx.install(prepared) } }
                    // The last retry is deliberately recovered from unspent
                    // prepared state, giving the next plan an admissible terminal.
                }
                if attempt < 3 { try #require(hit) }
                _ = try transaction(f, context: context(f)).recover()
                let terminalBytes = try Data(contentsOf: f.namespace.appendingPathComponent("active.json"))
                let terminal = try BootstrapManifestV3.decodeEnvelope(terminalBytes)
                #expect(terminal.id == id && terminal.context == c)
                if attempt < 2 {
                    guard case .abortedPreparation = terminal.body else { throw OwnedFixtureFailure.injected }
                } else {
                    guard case .rolledBack = terminal.body else { throw OwnedFixtureFailure.injected }
                }
                #expect(terminal.historyHead?.recordCount ?? 0 == attempt)
                let control = try SyncAccountRecoveryControlFile.decode(Data(contentsOf:
                    f.source.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")))
                guard case let .absentSource(source) = control else { throw OwnedFixtureFailure.injected }
                if let authority { #expect(source.authorityID == authority) } else { authority = source.authorityID }
                #expect(generations.insert(source.generation).inserted)
                #expect(source.origin == .bootstrapRollback(transactionID: id,
                    activeRelativePath: OwnedBootstrapCodec.parent(terminal.transactionRelativePath) + "/active.json",
                    activeEnvelopeSHA256: OwnedBootstrapCodec.hash(terminalBytes)))
                #expect(try OwnedMatrixFixture.files(f.source.paths.workingSet) == before)
                terminals.append(terminalBytes)
            }
            let captured = try f.source.capture()
            let evidence = try #require(captured.bootstrapEvidence)
            #expect(evidence.activeEnvelope == terminals[3])
            #expect(evidence.historyRecords.count == 3)
            let decoded = try evidence.historyRecords.map { try BootstrapHistoryRecordV1.decodeEnvelope($0) }
            #expect(decoded.map(\.terminalEnvelope) == Array(terminals.prefix(3).reversed()))
            #expect(try decoded.map { try BootstrapManifestV3.decodeEnvelope($0.terminalEnvelope).context }
                == Array(contexts.prefix(3).reversed()))
            let head = try #require(try f.manifest().historyHead)
            #expect(head.chainByteCount == evidence.historyRecords.reduce(Int64(0)) { $0 + Int64($1.count) })
            // Positive control: a fifth preflight is valid before any tampering.
            let next = context(f)
            _ = try transaction(f, context: next).plan(input(next))
            return .init(fixture: f, terminals: terminals, contexts: contexts, records: evidence.historyRecords)
        } catch { f.remove(); throw error }
    }

    @Test func realFourAttemptLineageReopensAndAuthenticatesExactHistory() throws {
        let history = try chain(), f = history.fixture; defer { f.remove() }
        let frozen = try snapshot(f.source.paths.accountRoot)
        let retryContext = context(f), retryID = UUID(), retryNow = Date(timeIntervalSince1970: 123)
        let full = try transaction(f, context: retryContext, id: retryID, now: retryNow).plan(input(retryContext))
        let cap = full.maximumRecoveryEnvelopeBytes
        let exact = try transaction(f, context: retryContext, id: retryID,
            maximumBytes: cap, now: retryNow).plan(input(retryContext))
        #expect(exact.preparingEnvelope == full.preparingEnvelope)
        #expect(exact.maximumRecoveryEnvelopeBytes == cap)
        #expect(full.reservation.reservedEncodedEntryBytes < cap - 1)
        #expect(throws: SyncAccountRecoveryTransaction.Error.tooLarge) {
            _ = try transaction(f, context: retryContext, id: retryID,
                maximumBytes: cap - 1, now: retryNow).plan(input(retryContext))
        }
        #expect(try snapshot(f.source.paths.accountRoot) == frozen)
        try f.source.storage.close()
        let reopened = SyncAccountStorage(baseURL: f.source.base)
        let paths = try reopened.openExistingAccount(identity: f.source.account, validateAccount: {})
        defer { try? reopened.close() }
        let afterOpen = try snapshot(paths.accountRoot)
        try expectOnlyEmptySessionRotation(before: frozen, after: afterOpen)
        let c = context(f)
        let tx = try SyncBootstrapOwnedTransaction(storage: reopened, paths: paths, account: f.source.account,
            context: c, validateContext: { guard $0 == c else { throw SyncBootstrapError.contextChanged } })
        _ = try tx.recover()
        #expect(try snapshot(paths.accountRoot) == afterOpen)
        let inventory = try SyncAccountRecoveryInventory.capture(storage: reopened, paths: paths,
            account: f.source.account, journal: FileSyncMutationJournal(url: paths.mutationJournalURL),
            archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"))
        #expect(inventory.bootstrapEvidence?.historyRecords == history.records)
        try OwnedMatrixFixture.authenticate(storage: reopened, paths: paths, account: f.source.account)
    }

    private struct DiskEntry: Equatable {
        let mode: UInt32
        let device: UInt64
        let inode: UInt64
        let links: UInt64
        let bytes: Data?
        let destination: String?
    }
    private func expectOnlyEmptySessionRotation(before: [String: DiskEntry], after: [String: DiskEntry]) throws {
        // Storage.close removes its uncaptured empty session; the next open
        // creates a new UUID session (Storage.swift:239,383). That lifecycle
        // change is not bootstrap-history mutation or captured-data cleanup.
        let removed = Set(before.keys).subtracting(after.keys)
        let added = Set(after.keys).subtracting(before.keys)
        try #require(removed.count == 1 && added.count == 1)
        let old = try #require(removed.first), new = try #require(added.first)
        for (path, entries) in [(old, before), (new, after)] {
            let parts = path.split(separator: "/")
            #expect(parts.count == 2 && parts.first == ".decrypted-temporary")
            #expect(UUID(uuidString: String(try #require(parts.last))) != nil)
            #expect((entries[path]?.mode ?? 0) & UInt32(S_IFMT) == UInt32(S_IFDIR))
            #expect(!entries.keys.contains { $0.hasPrefix(path + "/") })
        }
        #expect(before[old]?.mode == after[new]?.mode)
        #expect(before.filter { !removed.contains($0.key) } == after.filter { !added.contains($0.key) })
    }
    private func snapshot(_ root: URL) throws -> [String: DiskEntry] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [String: DiskEntry] = [:]
        for case let url as URL in enumerator {
            var info = stat()
            try #require(lstat(url.path, &info) == 0)
            result[String(url.path.dropFirst(root.path.count + 1))] = .init(mode: UInt32(info.st_mode),
                device: UInt64(info.st_dev), inode: UInt64(info.st_ino), links: UInt64(info.st_nlink),
                bytes: info.st_mode & S_IFMT == S_IFREG ? try Data(contentsOf: url) : nil,
                destination: info.st_mode & S_IFMT == S_IFLNK ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil)
        }
        return result
    }

    private func overwrite(_ bytes: Data, at url: URL) throws {
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.truncate(atOffset: 0); try file.write(contentsOf: bytes)
    }

    @Test func oldestPhysicalEvidenceAndUnreferencedNamesRejectWithoutFurtherWrites() throws {
        let history = try chain(), f = history.fixture; defer { f.remove() }
        let oldestBytes = try #require(history.records.last)
        let oldest = try BootstrapHistoryRecordV1.decodeEnvelope(oldestBytes)
        let recordURL = f.namespace.appendingPathComponent("History/" + OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(oldestBytes)) + ".json")
        let treeFile = f.source.paths.accountRoot.appendingPathComponent(try #require(oldest.treeEntries.first { !$0.isDirectory && $0.byteCount > 0 }).relativePath)
        let treeRoot = f.source.paths.accountRoot.appendingPathComponent(oldest.transactionRelativePath)
        let pristine = try snapshot(f.source.paths.accountRoot)
        let parking = f.source.base.appendingPathComponent("history-test-parking")
        for damage in ["record-byte", "tree-byte", "root-inode", "symlink", "hardlink", "unreferenced-record", "extra-UUID"] {
            var restore: () throws -> Void = {}
            switch damage {
            case "record-byte", "tree-byte":
                let target = damage == "record-byte" ? recordURL : treeFile
                let bytes = try Data(contentsOf: target)
                var changed = bytes; changed[changed.startIndex] ^= 1
                try overwrite(changed, at: target)
                restore = { try self.overwrite(bytes, at: target) }
            case "root-inode":
                try FileManager.default.moveItem(at: treeRoot, to: parking)
                try FileManager.default.createDirectory(at: treeRoot, withIntermediateDirectories: false)
                let children = try FileManager.default.contentsOfDirectory(atPath: parking.path)
                for child in children { try FileManager.default.moveItem(at: parking.appendingPathComponent(child), to: treeRoot.appendingPathComponent(child)) }
                restore = {
                    for child in children { try FileManager.default.moveItem(at: treeRoot.appendingPathComponent(child), to: parking.appendingPathComponent(child)) }
                    try FileManager.default.removeItem(at: treeRoot)
                    try FileManager.default.moveItem(at: parking, to: treeRoot)
                }
            case "symlink":
                try FileManager.default.moveItem(at: treeFile, to: parking)
                try FileManager.default.createSymbolicLink(at: treeFile, withDestinationURL: parking)
                restore = { try FileManager.default.removeItem(at: treeFile); try FileManager.default.moveItem(at: parking, to: treeFile) }
            case "hardlink":
                try FileManager.default.linkItem(at: treeFile, to: parking)
                restore = { try FileManager.default.removeItem(at: parking) }
            case "unreferenced-record":
                // Valid checksummed envelope, distinct exact bytes and hash,
                // but no history link authorizes this second physical name.
                let bytes = oldestBytes + Data([10])
                #expect(try BootstrapHistoryRecordV1.decodeEnvelope(bytes).terminalEnvelope == oldest.terminalEnvelope)
                let extra = f.namespace.appendingPathComponent("History/" + OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(bytes)) + ".json")
                try bytes.write(to: extra)
                restore = { try FileManager.default.removeItem(at: extra) }
            default:
                let extra = f.namespace.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: false)
                restore = { try FileManager.default.removeItem(at: extra) }
            }
            do {
                let damaged = try snapshot(f.source.paths.accountRoot)
                #expect(damaged != pristine)
                let c = context(f)
                #expect(throws: (any Error).self) { try transaction(f, context: c).plan(input(c)) }
                #expect(throws: (any Error).self) { try transaction(f, context: c).recover() }
                #expect(try snapshot(f.source.paths.accountRoot) == damaged)
            } catch { try restore(); throw error }
            try restore()
            #expect(try snapshot(f.source.paths.accountRoot) == pristine)
            let c = context(f)
            _ = try transaction(f, context: c).plan(input(c))
        }
    }
}
