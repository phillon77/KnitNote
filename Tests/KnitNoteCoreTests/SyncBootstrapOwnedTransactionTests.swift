import Foundation
import Testing
@testable import KnitNoteCore

struct SyncBootstrapOwnedTransactionTests {
    @Test(arguments: [false, true]) func unresolvedControlDerivativeRejectsWithoutChangingEitherSlot(removeMain: Bool) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let main = f.source.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let next = main.deletingLastPathComponent().appendingPathComponent("intent-next.json")
        let bytes = try Data(contentsOf: main)
        let state = try SyncAccountRecoveryControlFile.decode(bytes)
        let derivative = try SyncAccountRecoveryControlFile.encode(state, predecessorSHA256: OwnedBootstrapCodec.hash(bytes))
        try derivative.write(to: next)
        if removeMain { try FileManager.default.removeItem(at: main) }
        let before = try f.source.diskBytes()
        #expect(throws: (any Error).self) { _ = try f.transaction().plan(f.input()) }
        #expect(try f.source.diskBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: f.namespace.path))
    }

    @Test func unexplainedRawSpellingSiblingNamespaceRejectsEvenWhenEmpty() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
        try JSONEncoder().encode(archive).write(to: f.archiveURL)
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "fixture")
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let raw = OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(f.paths.workingSet.path.utf8)))
        let normalized = OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(f.paths.workingSet.standardizedFileURL.path.utf8)))
        #expect(raw != normalized)
        let sibling = f.paths.accountRoot.appendingPathComponent(".KnitNote-SyncBootstrap/" + f.account.accountIDHash + "/" + raw)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) {
            _ = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
                context: context, validateContext: { _ in }).plan(.init(local: local, sourceArchive: archive,
                    remote: .init(context: context, records: [], attachments: [:], isComplete: true),
                    pending: nil, counterReminderContext: .init()))
        }
        #expect(try f.diskBytes() == before)
        #expect(FileManager.default.fileExists(atPath: sibling.path))
        #expect(!FileManager.default.fileExists(atPath: sibling.deletingLastPathComponent().appendingPathComponent(normalized).path))
    }

    @Test @MainActor func incomingMediaFreeDeletionRetainsSupportingMediaAndLocalValidationIndexes() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let remoteRoot = f.source.base.appendingPathComponent("remote-package")
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        _ = try BackupFixture.writeCompleteArchive(to: remoteRoot)
        let archive = try JSONDecoder().decode(ProjectArchive.self,
            from: Data(contentsOf: remoteRoot.appendingPathComponent("projects-v1.json")))
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: remoteRoot, deviceID: "remote")
        let deleted = try SyncDeletionCaptureProgramTests.request(root: remoteRoot)
        let before = try f.source.diskBytes()
        let p = try f.transaction().plan(.init(local: nil,
            sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
            remote: .init(context: f.context, records: package.records + deleted.currentRecords,
                attachments: package.attachments, isComplete: true),
            pending: nil, counterReminderContext: .init()))
        #expect(p.deletionRequests.count == 1)
        #expect(p.deletionRequests[0].supportingAttachments == package.attachments.mapValues {
            SyncBootstrapOutputProof(byteCount: $0.byteCount, sha256: $0.contentSHA256)
        })
        #expect(p.deletionRequests[0].attachments.isEmpty)
        let validations = p.deletion.steps.enumerated().compactMap { index, step -> (Int, SyncDeletionCaptureProgram.Validation)? in
            if case let .validate(value) = step { return (index, value) }; return nil
        }
        #expect(validations.count == 2)
        for (index, validation) in validations {
            #expect(!validation.sources.isEmpty)
            for stepIndex in validation.sources.values {
                #expect(stepIndex < index)
                guard case .output = p.deletion.steps[stepIndex] else { Issue.record("invalid local output index"); continue }
            }
        }
        let finalLedger = try #require(p.deletion.finalManifestBytes)
        let ledgerAtPublication = try #require(p.publication.expectedInitialTree.files.first { $0.path == ".sync-deletions/ledger.json" })
        #expect(ledgerAtPublication.proof == SyncBootstrapOwnedProgramBuilder.proof(finalLedger))
        let merged = try #require(p.steps.compactMap { step -> KnitNoteBackupFrozenTree? in
            if case let .backup(index, initial, _) = step, p.backupPackages[index].role == .validationMerged { return initial }
            return nil
        }.last)
        for file in p.publication.finalFiles { #expect(merged.files[file.path] == file.proof) }
        #expect(try f.source.diskBytes() == before)
    }

    @Test func actualLegacyArchiveRollbackBecomesExactPendingHistoryWithoutWrites() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "original")])
        try JSONEncoder().encode(archive).write(to: f.archiveURL)
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "legacy")
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let ordinary = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context, validateContext: { _ in })
        let remote = SyncBootstrapRemoteSnapshot(context: context, records: [], attachments: [:], isComplete: true)
        let prior = try ordinary.prepare(local: local, sourceArchive: archive, remote: remote)
        try ordinary.install(prior); try ordinary.rollback(prior)
        let before = try f.diskBytes()
        let p = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, validateContext: { _ in }).plan(.init(local: local, sourceArchive: archive,
                remote: remote, pending: nil, counterReminderContext: .init()))
        let manifest = try BootstrapManifestV3.decodeEnvelope(p.preparingEnvelope)
        guard case let .preparing(body) = manifest.body else { Issue.record("expected preparing"); return }
        #expect(manifest.livePath == f.paths.workingSet.standardizedFileURL.path)
        let pending = try #require(body.predecessor)
        let record = try BootstrapHistoryRecordV1.decodeEnvelope(pending.record)
        #expect(record.transactionID == prior.transactionID)
        #expect(record.previous == nil)
        #expect(!record.treeEntries.isEmpty)
        let active = OwnedBootstrapCodec.parent(manifest.transactionRelativePath) + "/active.json"
        #expect(record.terminalEnvelope == before[f.paths.accountRoot.appendingPathComponent(active).path])
        #expect(try f.diskBytes() == before)
    }

    @Test func selectedRecoveryRejectsAndRealConsumedRestoreAdmitsWithoutOwnedWrites() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let tx = try f.transaction()
        _ = try tx.plan(f.input())
        let vault = SyncRecoveryVault(directory: f.source.paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.source.storage, paths: f.source.paths,
            account: f.source.account, vault: vault, journal: f.source.journal)
        let now = Date()
        let receipt = try recovery.seal(recovery.prepare(now: now), now: now)
        let selected = try f.source.diskBytes()
        #expect(throws: SyncBootstrapError.sourceChanged) { _ = try tx.plan(f.input()) }
        #expect(try f.source.diskBytes() == selected)
        try recovery.cleanup(receipt)
        try recovery.restore(vaultID: receipt.vaultID, now: now)
        #expect(try recovery.consumeRestoredSelection(vaultID: receipt.vaultID, now: now))
        let source = try #require(try recovery.sourceState(now: now))
        guard case let .restoredSelection(vaultID, captureID, _, _, _) = source.origin else {
            Issue.record("expected actual authenticated restored provenance"); return
        }
        #expect(vaultID == receipt.vaultID && captureID == receipt.captureID)
        let ordinary = try SyncBootstrapTransaction(liveRoot: f.source.paths.workingSet,
            context: f.context, validateContext: { _ in })
        let restoredInventory = try f.source.capture()
        let pending = SyncBootstrapPendingSnapshot(mutations: restoredInventory.packet.mutations,
            sourceTreeFingerprint: try ordinary.sourceFingerprint())
        let before = try f.source.diskBytes(), input = f.input()
        let p = try tx.plan(.init(local: nil, sourceArchive: input.sourceArchive, remote: input.remote,
            pending: pending, counterReminderContext: .init()))
        #expect(p.initialControl.state == .absentSource(source))
        #expect(try f.source.diskBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: f.namespace.path))
    }

    @Test func fullLifetimeCapIsInclusiveAndAllocationAloneDoesNotAdmitAttempt() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let id = UUID(), now = Date(timeIntervalSince1970: 100)
        let before = try f.source.diskBytes()
        let full = try f.transaction(transactionID: id, now: now).plan(f.input())
        let cap = full.maximumRecoveryEnvelopeBytes
        let exact = try f.transaction(maximumBytes: cap, transactionID: id, now: now).plan(f.input())
        #expect(exact.preparingEnvelope == full.preparingEnvelope)
        #expect(exact.maximumRecoveryEnvelopeBytes == cap)
        #expect(throws: (any Error).self) {
            _ = try f.transaction(maximumBytes: cap - 1, transactionID: id, now: now).plan(f.input())
        }
        #expect(full.reservation.reservedEncodedEntryBytes < cap - 1)
        #expect(full.preparingEnvelope.count < cap - 1)
        #expect(full.lifetimeScenarios.map(\.name) == ["abortedPreparing", "abortedPreparingNextRetry",
            "preparedRolledBack", "preparedRolledBackNextRetry", "journalFailedRolledBack",
            "journalFailedRolledBackNextRetry", "committed"])
        #expect(full.lifetimeScenarios.map(\.recoveryEnvelopeBytes).max() == cap)
        print("OWNED-BUDGET fresh preparing=\(full.preparingEnvelope.count) entryAllocation=\(full.reservation.reservedEncodedEntryBytes) maxRecovery=\(cap)")
        for scenario in full.lifetimeScenarios {
            print("OWNED-BUDGET \(scenario.name) inventory=\(scenario.inventoryBytes) envelope=\(scenario.recoveryEnvelopeBytes) retryPreparing=\(scenario.nextRetryPreparingBytes.map(String.init) ?? "none")")
        }
        let committed = try #require(full.lifetimeScenarios.first { $0.name == "committed" })
        #expect(full.preparingEnvelope.count < committed.recoveryEnvelopeBytes - 1)
        #expect(throws: (any Error).self) {
            _ = try f.transaction(maximumBytes: committed.recoveryEnvelopeBytes - 1,
                transactionID: id, now: now).plan(f.input())
        }
        #expect(try f.source.diskBytes() == before)
    }

    @Test func journalSuffixUsesNativeTraceAndExactReceiptBinding() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        _ = try BackupFixture.writeCompleteArchive(to: f.paths.workingSet)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: f.archiveURL))
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "owned")
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let p = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, validateContext: { _ in }).plan(.init(local: local, sourceArchive: archive,
                remote: .init(context: context, records: [], attachments: [:], isComplete: true),
                pending: nil, counterReminderContext: .init()))
        let prefix = Array(p.commitProgram.operations.dropLast(2))
        var ids = prefix.compactMap { operation -> UUID? in
            switch operation {
            case let .replace(_, _, _, id), let .copyAttachment(_, _, _, id): return id
            default: return nil
            }
        }
        let native = try FileSyncMutationJournal(url: f.paths.mutationJournalURL).planOwnedEnqueueProjection(
            p.mutations, accountRoot: f.paths.accountRoot, inventoryEntries: p.initialInventory.entries,
            preflightSources: p.attachmentSources.filter { id, _ in p.mutations.contains { $0.recordID.uuid == id && $0.attachmentSource != nil } },
            temporaryID: { ids.removeFirst() })
        #expect(native.commitProgram.operations == prefix)
        #expect(native.commitProgram.initialJournalFiles == p.commitProgram.initialJournalFiles)
        #expect(native.commitProgram.initialJournalDirectories == p.commitProgram.initialJournalDirectories)
        #expect(ids.isEmpty)
        guard case let .replace(path, old, bytes, _) = p.commitProgram.operations[prefix.count] else {
            Issue.record("receipt must use the native replace grammar"); return
        }
        #expect(path == "SyncMetadata/bootstrap-receipt.json")
        #expect(old == nil)
        let receipt = try JSONDecoder().decode(SyncBootstrapReceipt.self, from: bytes)
        #expect(receipt.transactionID == p.transactionID)
        #expect(receipt.accountIDHash == f.account.accountIDHash)
        let expectedArchive = try Data(contentsOf: f.archiveURL)
        #expect(receipt.sourceProof == .archive(sha256: OwnedBootstrapCodec.hash(expectedArchive)))
        #expect(p.commitProgram.operations.last == .synchronize(path: "SyncMetadata"))
        #expect(p.attachmentIdentities.count == p.attachmentSources.count)
    }

    @Test func changedSourceAndStalePendingFingerprintRejectUnchanged() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let before = try f.source.diskBytes()
        let input = f.input()
        let wrong = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "not admitted")])
        #expect(throws: (any Error).self) {
            _ = try f.transaction().plan(.init(local: nil, sourceArchive: wrong, remote: input.remote,
                pending: nil, counterReminderContext: .init()))
        }
        let stale = SyncBootstrapPendingSnapshot(mutations: [], sourceTreeFingerprint: Data(repeating: 1, count: 32))
        #expect(throws: SyncBootstrapError.sourceChanged) {
            _ = try f.transaction().plan(.init(local: nil, sourceArchive: input.sourceArchive, remote: input.remote,
                pending: stale, counterReminderContext: .init()))
        }
        #expect(try f.source.diskBytes() == before)
    }

    @Test func originalCopyPreservesOrdinaryLexicalInterleavingAndEarlierOrigins() throws {
        let proof = SyncBootstrapOutputProof(byteCount: 1, sha256: Data(repeating: 1, count: 32))
        var tree = SyncBootstrapOwnedProgramBuilder.Tree()
        tree.directories.formUnion(["a", "z"])
        for path in ["a/child", "m-file", "z/child"] {
            tree.files[path] = .init(proof: proof, origin: .live(path: "working-set/" + path, proof: proof))
        }
        var builder = SyncBootstrapOwnedProgramBuilder()
        try builder.copy(tree, to: .original)
        let copied = builder.actions.map { action -> String in
            switch action {
            case let .directory(_, path): return path + "/"
            case let .write(_, path, _, _): return path
            default: return "unexpected"
            }
        }
        #expect(copied == ["/", "a/", "a/child", "m-file", "z/", "z/child"])
        try builder.copy(builder.trees[.original]!, to: .staged)
        let source = try #require(builder.trees[.staged]?.files["m-file"])
        guard case let .output(index, _) = source.origin,
              case let .output(output) = builder.steps[index],
              case let .copy(.output(originalIndex, _))? = output.content else {
            Issue.record("initial Staged copy must retain the earlier Original output identity"); return
        }
        #expect(originalIndex < index)
    }

    @Test func replanningOneAttemptKeepsEveryGeneratedOutputIdentityAndExactEnvelope() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let tx = try f.transaction()
        let first = try tx.plan(f.input())
        let second = try tx.plan(f.input())
        #expect(first.transactionID == second.transactionID)
        #expect(first.actions == second.actions)
        #expect(first.preparingEnvelope == second.preparingEnvelope)
        #expect(first.maximumRecoveryEnvelopeBytes == second.maximumRecoveryEnvelopeBytes)
    }

    @Test func archiveMediaPlanRetainsBackupAndValidationOrderWithoutWriting() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        _ = try BackupFixture.writeCompleteArchive(to: f.paths.workingSet)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: f.archiveURL))
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "owned-fixture")
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let id = UUID(), now = Date(timeIntervalSince1970: 100)
        let tx = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, transactionID: id, now: now, validateContext: { candidate in
                guard candidate == context else { throw SyncBootstrapError.contextChanged }
            })
        let before = try f.diskBytes()
        let p = try tx.plan(.init(local: local, sourceArchive: archive,
            remote: .init(context: context, records: [], attachments: [:], isComplete: true),
            pending: nil, counterReminderContext: .init()))
        #expect(p.backupPackages.map(\.role) == [.validationOriginal, .validationMerged])
        let significant = p.steps.compactMap { step -> String? in
            switch step {
            case let .backup(index, _, _): return p.backupPackages[index].role == .validationOriginal ? "originalBackup" : "mergedBackup"
            case .validateLocal: return "localRoundtrip"
            case .validateMaterialization: return "materialization"
            case .deletion: return "deletion"
            case .publication: return "publication"
            case .output: return nil
            }
        }
        #expect(significant == ["originalBackup", "localRoundtrip", "materialization", "deletion", "publication", "mergedBackup"])
        #expect(!p.projection.files.isEmpty)
        #expect(p.publication.expectedInitialTree.files.contains { $0.path == "SyncMetadata/bootstrap-canonical.json" })
        #expect(p.reservation.reservations.count == 5)
        let abortRetry = try #require(p.lifetimeScenarios.first { $0.name == "abortedPreparingNextRetry" })
        #expect(p.reservation.reservedEncodedEntryBytes < abortRetry.recoveryEnvelopeBytes - 1)
        #expect(throws: (any Error).self) {
            let bounded = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
                context: context, maximumBytes: abortRetry.recoveryEnvelopeBytes - 1,
                transactionID: id, now: now, validateContext: { _ in })
            _ = try bounded.plan(.init(local: local, sourceArchive: archive,
                remote: .init(context: context, records: [], attachments: [:], isComplete: true),
                pending: nil, counterReminderContext: .init()))
        }
        #expect(try f.diskBytes() == before)
    }

    @Test func legacyMissingRollbackWithoutDurableSourceControlRejectsUnchanged() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let journal = try f.makeMissingArchiveRollback()
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let ordinary = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context, validateContext: { _ in })
        let pending = try SyncBootstrapPendingSnapshot(mutations: journal.pending(), sourceTreeFingerprint: ordinary.sourceFingerprint())
        let before = try f.diskBytes()
        let tx = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, validateContext: { _ in })
        #expect(throws: SyncBootstrapError.sourceChanged) {
            _ = try tx.plan(.init(local: nil, sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
                remote: .init(context: context, records: [], attachments: [:], isComplete: true),
                pending: pending, counterReminderContext: .init()))
        }
        #expect(try f.diskBytes() == before)
    }

    @Test func selectedRemoteSymlinkAncestorRejectsBeforeAnyOwnedOutput() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let remoteRoot = f.source.base.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        _ = try BackupFixture.writeCompleteArchive(to: remoteRoot)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: remoteRoot.appendingPathComponent("projects-v1.json")))
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: remoteRoot, deviceID: "remote")
        let alias = f.source.base.appendingPathComponent("remote-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: remoteRoot)
        var sources = package.attachments
        let id = try #require(sources.keys.first)
        let source = try #require(sources[id])
        let relative = String(source.fileURL.path.dropFirst(remoteRoot.path.count + 1))
        sources[id] = try .init(fileURL: alias.appendingPathComponent(relative),
            contentSHA256: source.contentSHA256, byteCount: source.byteCount)
        let before = try f.source.diskBytes()
        #expect(throws: (any Error).self) {
            _ = try f.transaction().plan(.init(local: nil,
                sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
                remote: .init(context: f.context, records: package.records, attachments: sources, isComplete: true),
                pending: nil, counterReminderContext: .init()))
        }
        #expect(try f.source.diskBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: f.namespace.path))
    }

    @Test func freshMissingSourcePlanLeavesCompleteDiskAndControlUntouched() throws {
        let fixture = try OwnedBootstrapFixture()
        defer { fixture.remove() }
        let before = try fixture.source.capture()
        let disk = try fixture.source.diskBytes()
        let program = try fixture.transaction().plan(fixture.input())
        #expect(program.maximumRecoveryEnvelopeBytes > program.reservation.reservedEncodedEntryBytes)
        #expect(program.maximumRecoveryEnvelopeBytes <= 100_000_000)
        #expect(program.backupPackages.count == 1)
        #expect(program.backupPackages.first?.role == .validationMerged)
        #expect(!program.preparingEnvelope.isEmpty)
        #expect(try fixture.source.capture().entries == before.entries)
        #expect(try fixture.source.diskBytes() == disk)
        #expect(!FileManager.default.fileExists(atPath: fixture.namespace.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.source.archiveURL.path))
    }

    @Test func unaffordablePlanCreatesNoSelectorHistoryOrTransactionTree() throws {
        let fixture = try OwnedBootstrapFixture()
        defer { fixture.remove() }
        let before = try fixture.source.capture()
        let disk = try fixture.source.diskBytes()
        #expect(throws: (any Error).self) {
            _ = try fixture.transaction(maximumBytes: 1).plan(fixture.input())
        }
        #expect(try fixture.source.capture().entries == before.entries)
        #expect(try fixture.source.diskBytes() == disk)
        #expect(!FileManager.default.fileExists(atPath: fixture.namespace.path))
    }
}
