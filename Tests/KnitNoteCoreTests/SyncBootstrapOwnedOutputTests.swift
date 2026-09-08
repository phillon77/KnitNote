import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

struct SyncBootstrapOwnedOutputTests {
    @Test(arguments: [SyncBootstrapOwnedSelectorPoint.afterNextCreation, .afterNextWrite, .afterNextSynchronize, .beforeRename, .afterRename, .afterSelectedSynchronize])
    func selectorCutsNeverAllocateUUIDOrHistory(point: SyncBootstrapOwnedSelectorPoint) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let tx = try f.transaction(boundary: { if $0 == .selector(point) { throw OwnedFixtureFailure.injected } })
        #expect(throws: OwnedFixtureFailure.injected) { try tx.prepare(f.input()) }
        let names = try FileManager.default.contentsOfDirectory(atPath: f.namespace.path)
        #expect(names.allSatisfy { $0 == "active.json" || $0 == "active-next.json" })
        #expect(!names.isEmpty)
        if names.contains("active.json") {
            _ = try f.transaction().recover()
            guard case let .abortedPreparation(body) = try f.manifest().body else { Issue.record("expected abort"); return }
            #expect(body.frozenOutputEntries.isEmpty)
        } else {
            let before = try f.source.diskBytes()
            #expect(throws: (any Error).self) { try f.transaction().recover() }
            #expect(try f.source.diskBytes() == before)
        }
    }

    @Test func noAllocatedOutputBeforeDurablePreparing() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let before = try f.source.diskBytes()
        var hit = false
        let tx = try f.transaction { point in
            if point == .beforePreparingPublication { hit = true; throw OwnedFixtureFailure.injected }
        }
        #expect(throws: OwnedFixtureFailure.injected) { try tx.prepare(f.input()) }
        #expect(hit)
        #expect(try f.source.diskBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: f.namespace.path))
    }

    @Test func abortBeforeRootFreezesExactAbsence() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        var aborting = false, barriers: [String] = []
        let tx = try f.transaction(boundary: { point in
            if point == .afterPreparingPublication { aborting = true; throw OwnedFixtureFailure.injected }
            if point == .beforeAbortPublication { #expect(barriers == [f.namespace.path]) }
        }, io: .init(synchronize: { fd in
            try SyncBootstrapOwnedPOSIX.synchronize(fd)
            if aborting { barriers.append(try Self.path(fd)) }
        }))
        #expect(throws: OwnedFixtureFailure.injected) { try tx.prepare(f.input()) }
        _ = try f.transaction().recover()
        let terminal = try f.manifest()
        guard case let .abortedPreparation(body) = terminal.body else {
            Issue.record("expected abortedPreparation"); return
        }
        #expect(body.frozenOutputEntries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.namespace.appendingPathComponent(terminal.id.uuidString).path))
        #expect(!FileManager.default.fileExists(atPath: f.source.archiveURL.path))
    }

    @Test func emptyPreparationRunsActualBackupAndLeavesLiveAbsent() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let prepared = try f.transaction().prepare(f.input())
        let manifest = try f.manifest()
        guard case let .prepared(body) = manifest.body else { Issue.record("expected prepared"); return }
        #expect(prepared.transactionID == manifest.id)
        #expect(prepared.accountOwnedRoots == [f.namespace])
        #expect(body.installed["projects-v1.json"] != nil)
        #expect(!FileManager.default.fileExists(atPath: f.source.archiveURL.path))
        let root = f.namespace.appendingPathComponent(manifest.id.uuidString)
        let packages = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("ValidationMerged"), includingPropertiesForKeys: nil)
        #expect(packages.count == 1)
        _ = try KnitNoteBackupService(liveRoot: root.appendingPathComponent("Staged"),
            workRoot: root.appendingPathComponent("ValidationMerged")).inspectPackage(at: #require(packages.first))
    }

    @Test func realPartialStagedWriteIsFrozenAndNoForwardOutputFollows() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let before = try f.source.diskBytes()
        var partial: String?, writesAfterFailure = 0
        let io = SyncBootstrapOwnedIO(write: { fd, bytes in
            let path = try Self.path(fd)
            if partial != nil { writesAfterFailure += 1 }
            if path.contains("/Staged/.projects-v1.json.") {
                partial = path
                try SyncBootstrapOwnedPOSIX.write(fd, Data(bytes.prefix(7)))
                throw OwnedFixtureFailure.injected
            }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        })
        #expect(throws: OwnedFixtureFailure.injected) { try f.transaction(io: io).prepare(f.input()) }
        let retained = try #require(partial)
        #expect(try Data(contentsOf: URL(fileURLWithPath: retained)).count == 7)
        #expect(writesAfterFailure == 0)
        let terminal = try f.manifest()
        guard case let .abortedPreparation(body) = terminal.body else { Issue.record("expected abort"); return }
        #expect(body.frozenOutputEntries.contains { $0.relativePath.hasSuffix(URL(fileURLWithPath: retained).lastPathComponent) && $0.byteCount == 7 })
        let after = try f.source.diskBytes()
        #expect(before.allSatisfy { after[$0.key] == $0.value })
        _ = try f.transaction().recover()
        #expect(try f.source.diskBytes() == after)
    }

    @Test func abortSynchronizesFrozenFilesThenBottomUpDirectoriesBeforePublication() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        var partial: String?, barriers: [String] = [], atPublication: [String] = []
        let io = SyncBootstrapOwnedIO(write: { fd, bytes in
            let path = try Self.path(fd)
            if path.contains("/Staged/.projects-v1.json.") {
                try SyncBootstrapOwnedPOSIX.write(fd, Data(bytes.prefix(7)))
                partial = path
                throw OwnedFixtureFailure.injected
            }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        }, synchronize: { fd in
            try SyncBootstrapOwnedPOSIX.synchronize(fd)
            if partial != nil { barriers.append(try Self.path(fd)) }
        })
        let tx = try f.transaction(boundary: { point in
            if point == .beforeAbortPublication { atPublication = barriers }
            if partial != nil, point == .selector(.afterNextCreation) {
                #expect(!atPublication.isEmpty)
                #expect(barriers == atPublication)
            }
        }, io: io)
        #expect(throws: OwnedFixtureFailure.injected) { try tx.prepare(f.input()) }
        let retained = try #require(partial)
        let terminal = try f.manifest()
        guard case let .abortedPreparation(body) = terminal.body else { Issue.record("expected durable abort"); return }
        let files = body.frozenOutputEntries.filter { !$0.isDirectory }.map { f.source.paths.accountRoot.appendingPathComponent($0.relativePath).path }
        let directories = body.frozenOutputEntries.filter(\.isDirectory).map { f.source.paths.accountRoot.appendingPathComponent($0.relativePath).path }
        #expect(atPublication.contains(retained))
        for file in files {
            let fileIndex = try #require(atPublication.firstIndex(of: file))
            for directory in directories { #expect(fileIndex < (try #require(atPublication.firstIndex(of: directory)))) }
        }
        for child in directories {
            let childIndex = try #require(atPublication.firstIndex(of: child))
            let parent = URL(fileURLWithPath: child).deletingLastPathComponent().path
            #expect(childIndex < (try #require(atPublication.firstIndex(of: parent))))
        }
        #expect(atPublication.last == f.namespace.path)
        let selected = try Data(contentsOf: f.namespace.appendingPathComponent("active.json"))
        try Data(repeating: 0x78, count: 7).write(to: URL(fileURLWithPath: retained))
        let changed = try f.source.diskBytes()
        #expect(throws: (any Error).self) { try f.transaction().recover() }
        #expect(try f.source.diskBytes() == changed)
        #expect(try Data(contentsOf: f.namespace.appendingPathComponent("active.json")) == selected)
    }

    private enum AbortSyncFailure: Error { case injected }

    @Test(arguments: [false, true])
    func abortSyncFailureRetainsPreparingAndPartialBytesUntilRecovery(directory: Bool) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        var partial: String?, failed = false, published = false
        let io = SyncBootstrapOwnedIO(write: { fd, bytes in
            let path = try Self.path(fd)
            if path.contains("/Staged/.projects-v1.json.") {
                try SyncBootstrapOwnedPOSIX.write(fd, Data(bytes.prefix(7)))
                partial = path
                throw OwnedFixtureFailure.injected
            }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        }, synchronize: { fd in
            if let partial {
                let target = directory ? URL(fileURLWithPath: partial).deletingLastPathComponent().path : partial
                if try Self.path(fd) == target { failed = true; throw AbortSyncFailure.injected }
            }
            try SyncBootstrapOwnedPOSIX.synchronize(fd)
        })
        do {
            _ = try f.transaction(boundary: { if $0 == .beforeAbortPublication { published = true } }, io: io).prepare(f.input())
            Issue.record("expected original and abort failure")
        } catch let failure as SyncBootstrapOwnedTransaction.PreparationFailure {
            #expect(failure.original is OwnedFixtureFailure)
            #expect(failure.abort is AbortSyncFailure)
        } catch { Issue.record("expected both diagnostics, got \(error)") }
        #expect(failed && !published)
        guard case .preparing = try f.manifest().body else { Issue.record("sync uncertainty must retain preparing"); return }
        let path = try #require(partial), retained = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(retained.count == 7)
        var before = stat(); #expect(lstat(path, &before) == 0)
        _ = try f.transaction().recover()
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == retained)
        var after = stat(); #expect(lstat(path, &after) == 0)
        #expect(before.st_ino == after.st_ino && before.st_dev == after.st_dev)
        guard case .abortedPreparation = try f.manifest().body else { Issue.record("healthy retry must synchronize and abort"); return }
        let terminal = try f.source.diskBytes()
        _ = try f.transaction().recover()
        #expect(try f.source.diskBytes() == terminal)
    }

    @Test func abortRejectsSameByteInodeReplacementDuringSynchronization() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        var partial: String?, replaced = false, published = false
        let io = SyncBootstrapOwnedIO(write: { fd, bytes in
            let path = try Self.path(fd)
            if path.contains("/Staged/.projects-v1.json.") {
                try SyncBootstrapOwnedPOSIX.write(fd, Data(bytes.prefix(7)))
                partial = path
                throw OwnedFixtureFailure.injected
            }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        }, synchronize: { fd in
            try SyncBootstrapOwnedPOSIX.synchronize(fd)
            if let partial, !replaced, try Self.path(fd) == partial {
                let url = URL(fileURLWithPath: partial), bytes = try Data(contentsOf: url)
                // Atomic replacement keeps the bytes but gives the name a new inode.
                try bytes.write(to: url, options: .atomic)
                var opened = stat(), named = stat()
                #expect(fstat(fd, &opened) == 0 && lstat(partial, &named) == 0)
                #expect(opened.st_ino != named.st_ino)
                replaced = true
            }
        })
        #expect(throws: SyncBootstrapOwnedTransaction.PreparationFailure.self) {
            try f.transaction(boundary: { if $0 == .beforeAbortPublication { published = true } }, io: io).prepare(f.input())
        }
        #expect(replaced && !published)
        guard case .preparing = try f.manifest().body else { Issue.record("replacement must retain preparing"); return }
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(partial))).count == 7)
    }

    @Test func afterPreparedFaultDoesNotAbortOrWriteMoreOutput() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        var snapshot: [String: Data]?
        let tx = try f.transaction(boundary: { point in
            if point == .afterPreparedPublication {
                snapshot = try f.source.diskBytes()
                throw OwnedFixtureFailure.injected
            }
        })
        #expect(throws: OwnedFixtureFailure.injected) { try tx.prepare(f.input()) }
        #expect(try f.source.diskBytes() == snapshot)
        guard case .prepared = try f.manifest().body else { Issue.record("prepared must stay selected"); return }
    }

    @Test func archiveWithRealPendingJournalExecutesOriginalBackup() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        _ = try BackupFixture.writeCompleteArchive(to: f.paths.workingSet)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: f.archiveURL))
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "fixture")
        let journal = FileSyncMutationJournal(url: f.paths.mutationJournalURL)
        try journal.enqueue(local.records.map { try SyncMutation.save(recordVersion: .init(record: $0),
            attachmentSource: local.attachments[$0.id.uuid], mutationID: UUID()) })
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let ordinary = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context, validateContext: { _ in })
        let pending = try SyncBootstrapPendingSnapshot(mutations: journal.pending(), sourceTreeFingerprint: ordinary.sourceFingerprint())
        let before = try f.diskBytes()
        let tx = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, validateContext: { _ in })
        let result = try tx.prepare(.init(local: local, sourceArchive: archive,
            remote: .init(context: context, records: [], attachments: [:], isComplete: true), pending: pending, counterReminderContext: .init()))
        let root = result.originalBackupRoot.deletingLastPathComponent()
        let packages = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("ValidationOriginal"), includingPropertiesForKeys: nil)
        #expect(packages.count == 1)
        #expect(try journal.pending() == pending.mutations)
        let after = try f.diskBytes()
        #expect(before.allSatisfy { after[$0.key] == $0.value })
    }

    @Test @MainActor func actualDeletionValidationRunsWithSupportingSourcesAndEmptyRestoration() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let remoteRoot = f.source.base.appendingPathComponent("remote-package")
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        _ = try BackupFixture.writeCompleteArchive(to: remoteRoot)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: remoteRoot.appendingPathComponent("projects-v1.json")))
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: remoteRoot, deviceID: "remote")
        let deleted = try SyncDeletionCaptureProgramTests.request(root: remoteRoot)
        let result = try f.transaction().prepare(.init(local: nil, sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
            remote: .init(context: f.context, records: package.records + deleted.currentRecords, attachments: package.attachments, isComplete: true),
            pending: nil, counterReminderContext: .init()))
        let root = result.originalBackupRoot.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Staged/.sync-deletions/ledger.json").path))
        guard case .prepared = try f.manifest().body else { Issue.record("expected prepared deletion"); return }
    }

    @Test func changedBootstrapSiblingRejectsRecoveryWithoutSelectorWrite() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        #expect(throws: OwnedFixtureFailure.injected) {
            try f.transaction(boundary: { if $0 == .afterPreparingPublication { throw OwnedFixtureFailure.injected } }).prepare(f.input())
        }
        let sibling = f.namespace.deletingLastPathComponent().appendingPathComponent("unexplained")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        let before = try f.source.diskBytes()
        #expect(throws: (any Error).self) { try f.transaction().recover() }
        #expect(try f.source.diskBytes() == before)
    }

    @Test func unknownUUIDStopsBeforeSelectedRootCreation() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let id = UUID()
        let tx = try f.transaction(transactionID: id, boundary: { point in
            if point == .beforeTransactionRootCreation {
                try FileManager.default.createDirectory(at: f.namespace.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: false)
            }
        })
        #expect(throws: (any Error).self) { try tx.prepare(f.input()) }
        #expect(!FileManager.default.fileExists(atPath: f.namespace.appendingPathComponent(id.uuidString).path))
    }

    @Test func historyPrefixRepairUsesSameInodeAndRetainsOldSource() throws {
        let f = try LegacyFixture(); defer { f.source.remove() }
        var cutPath: String?, cutInode: ino_t?
        let io = SyncBootstrapOwnedIO(write: { fd, bytes in
            let path = try Self.path(fd)
            if cutPath == nil && path.contains("/History/") {
                cutPath = path
                var info = stat(); #expect(fstat(fd, &info) == 0); cutInode = info.st_ino
                try SyncBootstrapOwnedPOSIX.write(fd, Data(bytes.prefix(7)))
                throw OwnedFixtureFailure.injected
            }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        })
        let tx = try f.transaction(io: io)
        let program = try tx.plan(f.input)
        let planned = try BootstrapManifestV3.decodeEnvelope(program.preparingEnvelope)
        guard case let .preparing(body) = planned.body else { Issue.record("expected preparing"); return }
        let pending = try #require(body.predecessor)
        #expect(throws: OwnedFixtureFailure.injected) { try tx.prepare(f.input) }
        let path = try #require(cutPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == pending.record)
        var after = stat(); #expect(lstat(path, &after) == 0); #expect(after.st_ino == cutInode)
        let active = f.source.paths.accountRoot.appendingPathComponent(OwnedBootstrapCodec.parent(planned.transactionRelativePath) + "/active.json")
        guard case let .abortedPreparation(aborted) = try BootstrapManifestV3.decodeEnvelope(Data(contentsOf: active)).body else { Issue.record("expected abort"); return }
        #expect(aborted.frozenOutputEntries.isEmpty)
    }

    @Test func conflictingCompleteLegacyDerivativeRemainsUntouched() throws {
        let f = try LegacyFixture(); defer { f.source.remove() }
        let tx = try f.transaction(boundary: { if $0 == .selector(.beforeRename) { throw OwnedFixtureFailure.injected } })
        let p = try tx.plan(f.input)
        var candidate = try BootstrapManifestV3.decodeEnvelope(p.preparingEnvelope)
        guard case let .preparing(body) = candidate.body else { Issue.record("expected preparing"); return }
        candidate.body = .preparing(.init(sourceControlSHA256: body.sourceControlSHA256,
            pendingSnapshotSHA256: Data(repeating: 9, count: 32), outputAllocation: body.outputAllocation, predecessor: body.predecessor))
        #expect(throws: OwnedFixtureFailure.injected) { try tx.prepare(f.input) }
        let next = f.source.paths.accountRoot.appendingPathComponent(OwnedBootstrapCodec.parent(candidate.transactionRelativePath) + "/active-next.json")
        try candidate.encoded().write(to: next)
        let before = try f.source.diskBytes()
        #expect(throws: (any Error).self) { try f.transaction().recover() }
        #expect(try f.source.diskBytes() == before)
    }

    @Test func changedHistoricalOriginalRejectsBeforeHistoryCreation() throws {
        let f = try LegacyFixture(); defer { f.source.remove() }
        let initial = try f.transaction().plan(f.input)
        let manifest = try BootstrapManifestV3.decodeEnvelope(initial.preparingEnvelope)
        guard case let .preparing(body) = manifest.body else { Issue.record("expected preparing"); return }
        let record = try BootstrapHistoryRecordV1.decodeEnvelope(#require(body.predecessor).record)
        let history = f.source.paths.accountRoot.appendingPathComponent(OwnedBootstrapCodec.parent(manifest.transactionRelativePath) + "/History")
        let tx = try f.transaction(boundary: { point in
            if point == .afterPreparingPublication {
                try Data("corrupt predecessor".utf8).write(to: f.source.paths.accountRoot.appendingPathComponent(record.transactionRelativePath + "/Original/projects-v1.json"))
            }
        })
        #expect(throws: (any Error).self) { try tx.prepare(f.input) }
        #expect(!FileManager.default.fileExists(atPath: history.path))
    }

    @Test(arguments: [false, true]) func changedControlOrUnrelatedTemporaryStopsBeforeRoot(control: Bool) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let id = UUID()
        var changed: [String: Data]?
        let tx = try f.transaction(transactionID: id, boundary: { point in
            if point == .afterPreparingPublication {
                if control {
                    let path = f.source.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
                    var bytes = try Data(contentsOf: path); bytes.append(0x20); try bytes.write(to: path)
                } else {
                    try Data("unresolved".utf8).write(to: f.source.paths.workingSet.appendingPathComponent("unrelated.tmp"))
                }
                changed = try f.source.diskBytes()
            }
        })
        #expect(throws: (any Error).self) { try tx.prepare(f.input()) }
        #expect(!FileManager.default.fileExists(atPath: f.namespace.appendingPathComponent(id.uuidString).path))
        #expect(try f.source.diskBytes() == changed)
    }

    @Test func actualBackupInspectorRejectsChangedPackageManifestAndRetainsIt() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let id = UUID()
        let planning = try f.transaction(transactionID: id).plan(f.input())
        let package = try #require(planning.backupPackages.first)
        let packageRoot = f.namespace.appendingPathComponent(id.uuidString + "/ValidationMerged/" + package.packageID.uuidString + ".knitnote-backup")
        let manifest = packageRoot.appendingPathComponent("manifest.json")
        var corrupted = false
        let tx = try f.transaction(transactionID: id, boundary: { point in
            if case .afterPreparationOutput = point, !corrupted, FileManager.default.fileExists(atPath: manifest.path) {
                corrupted = true
                try Data("invalid package manifest".utf8).write(to: manifest)
            }
        })
        #expect(throws: KnitNoteBackupError.invalidManifest) { try tx.prepare(f.input()) }
        #expect(corrupted)
        #expect(try Data(contentsOf: manifest) == Data("invalid package manifest".utf8))
        guard case .abortedPreparation = try f.manifest().body else { Issue.record("expected inspector failure abort"); return }
    }

    @Test func compactHeadFsyncFailureRetainsCompleteFixedTemp() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        var retained: String?
        let io = SyncBootstrapOwnedIO(synchronize: { fd in
            let path = try Self.path(fd)
            if retained == nil, path.contains("/Staged/SyncMetadata/.attachment-versions.json.") && path.hasSuffix(".tmp") {
                retained = path; throw OwnedFixtureFailure.injected
            }
            try SyncBootstrapOwnedPOSIX.synchronize(fd)
        })
        #expect(throws: OwnedFixtureFailure.injected) { try f.transaction(io: io).prepare(f.input()) }
        let path = try #require(retained)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(!bytes.isEmpty)
        guard case let .abortedPreparation(body) = try f.manifest().body else { Issue.record("expected head failure abort"); return }
        #expect(body.frozenOutputEntries.contains { $0.byteCount == bytes.count && $0.sha256 == Data(SHA256.hash(data: bytes)) })
    }

    @Test func conflictingPreparingDerivativeCannotBeOverwrittenByAbort() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        var snapshot: [String: Data]?
        let tx = try f.transaction(boundary: { point in
            if point == .afterPreparingPublication {
                let selected = try f.manifest()
                guard case let .preparing(body) = selected.body else { throw OwnedFixtureFailure.injected }
                let different = UUID()
                let conflict = BootstrapManifestV3(id: different, context: selected.context, livePath: selected.livePath,
                    journalPath: selected.journalPath, sourceProof: selected.sourceProof, original: selected.original,
                    historyHead: selected.historyHead, body: .preparing(.init(sourceControlSHA256: body.sourceControlSHA256,
                        pendingSnapshotSHA256: body.pendingSnapshotSHA256,
                        outputAllocation: .init(transactionID: different, allowedRoles: body.outputAllocation.allowedRoles,
                            roleLimits: body.outputAllocation.roleLimits), predecessor: body.predecessor)))
                try conflict.encoded().write(to: f.namespace.appendingPathComponent("active-next.json"))
                snapshot = try f.source.diskBytes()
                throw OwnedFixtureFailure.injected
            }
        })
        #expect(throws: (any Error).self) { try tx.prepare(f.input()) }
        #expect(try f.source.diskBytes() == snapshot)
    }

    @Test func sharedDependencyObservationMatchesActualInventoryWithoutMutation() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let inventory = try f.source.capture()
        let before = try f.source.diskBytes()
        let result = try SyncAccountRecoveryInventory.captureSourceDependencies(paths: f.source.paths,
            journal: f.source.journal, archiveURL: f.source.archiveURL, entries: inventory.entries, maximumBytes: 100_000_000)
        #expect(result.snapshot.mutations == inventory.packet.mutations)
        #expect(result.export == nil)
        #expect(result.placeholders.isEmpty)
        #expect(try result.baseline == SyncAccountSourceBaseline.digest(entries: inventory.entries,
            accountRoot: inventory.accountRoot, journalURL: inventory.journalURL, mutations: inventory.packet.mutations,
            selectedFiles: inventory.packet.files + inventory.deletionFiles, deletionLedger: inventory.deletionLedger,
            pendingMarkerVersions: inventory.pendingMarkerVersions))
        #expect(try f.source.diskBytes() == before)
    }

    @Test func actualOutputTraceMatchesCompositionWithConsumedRoleDeclaration() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let id = UUID(), now = Date(timeIntervalSince1970: 100)
        let plan = try f.transaction(transactionID: id, now: now).plan(f.input())
        var indices: [Int] = [], writes: [String] = []
        let io = SyncBootstrapOwnedIO(write: { fd, bytes in
            writes.append(try Self.path(fd))
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        })
        _ = try f.transaction(transactionID: id, now: now, boundary: { point in
            if case let .afterPreparationOutput(index) = point { indices.append(index) }
        }, io: io).prepare(f.input())
        #expect(indices == Array(plan.actions.indices))
        let expected = plan.actions.compactMap { action -> String? in
            guard case let .write(role, path, _, temporaryID) = action else { return nil }
            let file = URL(fileURLWithPath: path)
            let temporary = "." + file.lastPathComponent + "." + temporaryID.uuidString + ".tmp"
            return f.namespace.appendingPathComponent(id.uuidString + "/" + role.rawValue)
                .appendingPathComponent(OwnedBootstrapCodec.parent(path)).appendingPathComponent(temporary).path
        }
        #expect(writes == expected)
    }

    @Test func actualEmptySourceMapperCannotSatisfyMissingRestorationSlot() throws {
        let actual = try ProjectArchiveSyncMapper.materialize(records: [], attachments: [:],
            baseArchive: .init(version: ProjectArchive.currentVersion, projects: []))
        let slot = SyncAttachmentSlot(owner: .init(kind: .project, uuid: UUID()), role: "cover", slotID: "cover")
        do {
            try SyncDeletionLedger.validateOwnedMaterialization(actual, comparison: .restorationPaths([slot: "missing/cover.jpg"]))
            Issue.record("missing restoration slot must reject")
        } catch SyncDeletionLedgerError.witnessMismatch { }
        try SyncDeletionLedger.validateOwnedMaterialization(actual, comparison: .restorationPaths([:]))
    }

    @Test func immutableReuseParentFsyncFailureAllocatesNoReuseTemp() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        _ = try BackupFixture.writeCompleteArchive(to: f.paths.workingSet)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: f.archiveURL))
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "reuse")
        let records = local.records.filter { $0.id.kind == .attachment }
        try SyncAttachmentPublicationEvidenceFile(url: f.paths.workingSet.appendingPathComponent("SyncMetadata/attachment-versions.json"))
            .save(.init(versions: records.compactMap(\.payload.attachment), attachmentRecords: records))
        let currentLocal = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "reuse")
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let input = SyncBootstrapOwnedInput(local: currentLocal, sourceArchive: archive,
            remote: .init(context: context, records: [], attachments: [:], isComplete: true), pending: nil, counterReminderContext: .init())
        let id = UUID(), now = Date(timeIntervalSince1970: 100)
        let plan = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, transactionID: id, now: now, validateContext: { _ in }).plan(input)
        let reusePath = try #require(plan.publication.actions.compactMap { action -> String? in
            if case let .reuseExact(_, path, _) = action { return path }; return nil
        }.first)
        let planned = try BootstrapManifestV3.decodeEnvelope(plan.preparingEnvelope)
        let staged = f.paths.accountRoot.appendingPathComponent(planned.transactionRelativePath + "/Staged")
        let reused = staged.appendingPathComponent(reusePath)
        var publicationLocked = false, failed = false, laterWrites = 0
        let io = SyncBootstrapOwnedIO(write: { fd, bytes in
            if failed { laterWrites += 1 }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        }, synchronize: { fd in
            let path = try Self.path(fd)
            if path == staged.appendingPathComponent("SyncMetadata/.attachment-versions.json.lock").path { publicationLocked = true }
            if publicationLocked, !failed, path == reused.deletingLastPathComponent().path {
                failed = true; throw OwnedFixtureFailure.injected
            }
            try SyncBootstrapOwnedPOSIX.synchronize(fd)
        })
        let tx = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, transactionID: id, now: now, validateContext: { _ in }, io: io)
        #expect(throws: OwnedFixtureFailure.injected) { try tx.prepare(input) }
        #expect(failed && laterWrites == 0)
        #expect(try Data(contentsOf: reused) == Data(contentsOf: f.paths.workingSet.appendingPathComponent(reusePath)))
        let files = try FileManager.default.contentsOfDirectory(atPath: reused.deletingLastPathComponent().path)
        #expect(!files.contains { $0.hasPrefix("." + reused.lastPathComponent + ".") && $0.hasSuffix(".tmp") })
    }

    @Test func unresolvedAbortedDerivativeIsNotReportedRecovered() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        #expect(throws: OwnedFixtureFailure.injected) {
            try f.transaction(boundary: { if $0 == .afterPreparingPublication { throw OwnedFixtureFailure.injected } }).prepare(f.input())
        }
        try Data("incomplete later attempt".utf8).write(to: f.namespace.appendingPathComponent("active-next.json"))
        let before = try f.source.diskBytes()
        #expect(throws: (any Error).self) { try f.transaction().recover() }
        #expect(try f.source.diskBytes() == before)
    }

    @Test func aliasedBootstrapRootRejectsLegacyDerivativeRepair() throws {
        let f = try LegacyFixture(); defer { f.source.remove() }
        #expect(throws: OwnedFixtureFailure.injected) {
            try f.transaction(boundary: { if $0 == .selector(.beforeRename) { throw OwnedFixtureFailure.injected } }).prepare(f.input)
        }
        try FileManager.default.createDirectory(at: f.source.paths.accountRoot.appendingPathComponent(".KnítNote-SyncBootstrap"), withIntermediateDirectories: false)
        let before = try f.source.diskBytes()
        #expect(throws: (any Error).self) { try f.transaction().recover() }
        #expect(try f.source.diskBytes() == before)
    }

    @Test(arguments: [SyncBootstrapOwnedSelectorPoint.afterNextCreation, .afterNextWrite, .afterNextSynchronize, .beforeRename])
    func legacyMainDerivativeIsRecoveredWithoutNewOutputs(point: SyncBootstrapOwnedSelectorPoint) throws {
        let f = try LegacyFixture(); defer { f.source.remove() }
        let tx = try f.transaction(boundary: { if $0 == .selector(point) { throw OwnedFixtureFailure.injected } })
        let program = try tx.plan(f.input)
        let manifest = try BootstrapManifestV3.decodeEnvelope(program.preparingEnvelope)
        let namespace = f.source.paths.accountRoot.appendingPathComponent(OwnedBootstrapCodec.parent(manifest.transactionRelativePath))
        let old = try Data(contentsOf: namespace.appendingPathComponent("active.json"))
        #expect(throws: OwnedFixtureFailure.injected) { try tx.prepare(f.input) }
        #expect(try Data(contentsOf: namespace.appendingPathComponent("active.json")) == old)
        _ = try f.transaction().recover()
        #expect(try Data(contentsOf: namespace.appendingPathComponent("active.json")) == old)
        #expect(!FileManager.default.fileExists(atPath: namespace.appendingPathComponent("active-next.json").path))
        #expect(!FileManager.default.fileExists(atPath: namespace.appendingPathComponent(manifest.id.uuidString).path))
        #expect(!FileManager.default.fileExists(atPath: namespace.appendingPathComponent("History").path))
        _ = try f.transaction().plan(f.input)
    }

    private struct LegacyFixture {
        let source: RecoveryInventoryFixture
        let context: SyncBootstrapContext
        let input: SyncBootstrapOwnedInput
        init() throws {
            source = try RecoveryInventoryFixture()
            let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "original")])
            try JSONEncoder().encode(archive).write(to: source.archiveURL)
            let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: source.paths.workingSet, deviceID: "legacy")
            context = .init(accountIDHash: source.account.accountIDHash, epoch: UUID(), freezeID: UUID())
            let remote = SyncBootstrapRemoteSnapshot(context: context, records: [], attachments: [:], isComplete: true)
            let ordinary = try SyncBootstrapTransaction(liveRoot: source.paths.workingSet, context: context, validateContext: { _ in })
            let prepared = try ordinary.prepare(local: local, sourceArchive: archive, remote: remote)
            try ordinary.install(prepared); try ordinary.rollback(prepared)
            input = .init(local: local, sourceArchive: archive, remote: remote, pending: nil, counterReminderContext: .init())
        }
        func transaction(boundary: @escaping (SyncBootstrapOwnedBoundary) throws -> Void = { _ in },
                         io: SyncBootstrapOwnedIO = .init()) throws -> SyncBootstrapOwnedTransaction {
            try .init(storage: source.storage, paths: source.paths, account: source.account, context: context,
                validateContext: { _ in }, boundary: boundary, io: io)
        }
    }

    private static func path(_ fd: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { throw OwnedFixtureFailure.injected }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    @Test func abruptPartialWriteReopensSameOwnedRoot() throws {
        guard ProcessInfo.processInfo.environment["KNITNOTE_OWNED_CRASH_CHILD"] == nil else { return }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("owned-crash-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "KNITNOTE_RUN_CLOUDKIT_INTEGRATION")
        environment["KNITNOTE_OWNED_CRASH_CHILD"] = "1"
        environment["KNITNOTE_OWNED_CRASH_ROOT"] = root.path
        let child = Process()
        let executable = try #require(Bundle.main.executableURL)
        #expect(executable.lastPathComponent == "swiftpm-testing-helper")
        child.executableURL = executable
        var arguments: [String] = [], skipNext = false
        for argument in CommandLine.arguments.dropFirst() {
            if skipNext { skipNext = false; continue }
            if argument == "--filter" { skipNext = true; continue }
            arguments.append(argument)
        }
        arguments += ["--filter", "SyncBootstrapOwnedOutputTests/abruptCrashWorker"]
        child.arguments = arguments; child.environment = environment
        print("OWNED-CRASH runner=\(executable.path) arguments=\(arguments)")
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        let deadline = Date().addingTimeInterval(60)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning {
            child.terminate()
            let grace = Date().addingTimeInterval(2)
            while child.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            Issue.record("crash child timeout: abrupt termination evidence incomplete"); return
        }
        #expect(child.terminationReason == .exit)
        guard child.terminationStatus == 86 else { Issue.record("crash child exited \(child.terminationStatus), expected 86"); return }
        let account = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "owned-crash")
        let accountRoot = root.appendingPathComponent(account.accountIDHash)
        let files = try #require(FileManager.default.enumerator(at: accountRoot, includingPropertiesForKeys: [.isRegularFileKey]))
        var partial: URL?
        for case let url as URL in files where url.lastPathComponent.hasPrefix(".projects-v1.json.") && url.path.contains("/Staged/") { partial = url }
        let retained = try #require(partial)
        let before = try Data(contentsOf: retained)
        #expect(before.count == 7)
        var first = stat(); #expect(lstat(retained.path, &first) == 0)
        let storage = SyncAccountStorage(baseURL: root)
        let paths = try storage.openExistingAccount(identity: account, validateAccount: {})
        defer { try? storage.close() }
        let context = SyncBootstrapContext(accountIDHash: account.accountIDHash, epoch: UUID(), freezeID: UUID())
        _ = try SyncBootstrapOwnedTransaction(storage: storage, paths: paths, account: account, context: context, validateContext: { _ in }).recover()
        #expect(try Data(contentsOf: retained) == before)
        var after = stat(); #expect(lstat(retained.path, &after) == 0)
        #expect(first.st_dev == after.st_dev && first.st_ino == after.st_ino)
        let namespace = retained.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let terminal = try BootstrapManifestV3.decodeEnvelope(Data(contentsOf: namespace.appendingPathComponent("active.json")))
        guard case let .abortedPreparation(body) = terminal.body else { Issue.record("crash reopen did not freeze abort"); return }
        #expect(body.frozenOutputEntries.contains { $0.inode == UInt64(first.st_ino) && $0.byteCount == 7 })
        #expect(!(try FileSyncMutationJournal(url: paths.mutationJournalURL).pending()).isEmpty)
    }

    @Test func abruptCrashWorker() throws {
        guard ProcessInfo.processInfo.environment["KNITNOTE_OWNED_CRASH_CHILD"] == "1",
              let selected = ProcessInfo.processInfo.environment["KNITNOTE_OWNED_CRASH_ROOT"] else { return }
        let root = URL(fileURLWithPath: selected)
        guard root.lastPathComponent.hasPrefix("owned-crash-"),
              !FileManager.default.fileExists(atPath: root.path) else { throw OwnedFixtureFailure.injected }
        let account = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "owned-crash")
        let storage = SyncAccountStorage(baseURL: root)
        let paths = try storage.open(identity: account)
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "durable pending")])
        try JSONEncoder().encode(archive).write(to: paths.workingSet.appendingPathComponent("projects-v1.json"))
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: paths.workingSet, deviceID: "crash-fixture")
        let journal = FileSyncMutationJournal(url: paths.mutationJournalURL)
        try journal.enqueue(local.records.map { try SyncMutation.save(recordVersion: .init(record: $0), mutationID: UUID()) })
        let context = SyncBootstrapContext(accountIDHash: account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let ordinary = try SyncBootstrapTransaction(liveRoot: paths.workingSet, context: context, validateContext: { _ in })
        let pending = try SyncBootstrapPendingSnapshot(mutations: journal.pending(), sourceTreeFingerprint: ordinary.sourceFingerprint())
        let io = SyncBootstrapOwnedIO(write: { fd, bytes in
            if try Self.path(fd).contains("/Staged/.projects-v1.json.") {
                try SyncBootstrapOwnedPOSIX.write(fd, Data(bytes.prefix(7)))
                Darwin._exit(86)
            }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        })
        _ = try SyncBootstrapOwnedTransaction(storage: storage, paths: paths, account: account, context: context,
            validateContext: { _ in }, io: io).prepare(.init(local: local, sourceArchive: archive,
                remote: .init(context: context, records: [], attachments: [:], isComplete: true), pending: pending, counterReminderContext: .init()))
        Issue.record("crash worker did not reach actual partial Staged write")
    }
}
