import CloudKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNote

@Suite(.serialized) @MainActor struct AppAccountBootstrapBridgeTests {
    // Fails if the bridge does not drive the real reader and commit actual
    // source data, including the storage-issued fresh absence.
    @Test(arguments: [false, true]) func fullEmptyZoneInstallsRealSource(withArchive: Bool) async throws {
        let f = try CloudBootstrapFixture(withArchive: withArchive); defer { f.remove() }
        let bridge = try makeBridge(f, schedule: { op, completed in
            BootstrapControlledOperations.emitSuccessfulEmptyZone(op); completed()
        })
        let handoff = try await bridge.install()
        try handoff.revalidate()
        let archive = try JSONDecoder().decode(ProjectArchive.self,
            from: Data(contentsOf: f.paths.workingSet.appendingPathComponent("projects-v1.json")))
        #expect(archive.projects.map(\.name) == (withArchive ? ["Bootstrap source"] : []))
        let selected = try manifest(f)
        guard case .committed = selected.body else { Issue.record("not committed"); return }
        #expect(handoff.transactionID == selected.id)
        #expect(handoff.checkpoint.records.filter { $0.id.kind == .project }.map(\.id.uuid)
            == (withArchive ? [f.projectID] : []))
    }

    @Test func partialLastPageKeepsOriginalSourceAndNoSelector() async throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        let operations = BootstrapControlledOperations(), bridge = try makeBridge(f, schedule: operations.schedule)
        let before = try f.entries(), task = Task { _ = try await bridge.install() }
        let first = await operations.next()
        BootstrapControlledOperations.emitSuccessfulEmptyZone(first, moreComing: true); operations.completeSuccessfully(first)
        let last = await operations.next()
        last.recordZoneFetchResultBlock?(f.scope.zoneID, .failure(CKError(.changeTokenExpired)))
        last.fetchRecordZoneChangesResultBlock?(.failure(CKError(.partialFailure))); operations.completeSuccessfully(last)
        await #expect(throws: (any Error).self) { try await task.value }
        await bridge.waitUntilStopped()
        #expect(try f.entries() == before)
        #expect(throws: (any Error).self) { try f.scope.requireCurrent() }
    }

    @Test func sourceEditDuringHeldPageIsRecapturedWithActualPayload() async throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        let operations = BootstrapControlledOperations(), bridge = try makeBridge(f, schedule: operations.schedule)
        let result = BridgeInstallResult()
        let task = Task { result.handoff = try await bridge.install() }, op = await operations.next()
        let archive = ProjectArchive(version: ProjectArchive.currentVersion,
            projects: [try StoredProject(id: f.projectID, name: "Edited while fetching")])
        try JSONEncoder().encode(archive).write(to: f.paths.workingSet.appendingPathComponent("projects-v1.json"))
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op); operations.completeSuccessfully(op)
        try await task.value
        let handoff = try #require(result.handoff)
        #expect(handoff.checkpoint.records.contains { $0.payload.fields["name"]?.value == .string("Edited while fetching") })
        #expect(try FileSyncMutationJournal(url: f.paths.mutationJournalURL).pending().contains {
            $0.savedRecordVersion?.record.payload.fields["name"]?.value == .string("Edited while fetching")
        })
    }

    @Test func archiveLocalOnlyPhotoAndPendingKeepExactBytesAndFIFO() async throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        let bytes = try CloudBootstrapFixture.jpeg()
        var project = try StoredProject(id: f.projectID, name: "Photo source")
        let filename = try ProjectPhotoFileService(directory: f.paths.workingSet.appendingPathComponent("ProjectPhotos"))
            .save(data: bytes, projectID: project.id)
        // The photo service intentionally normalizes input JPEGs. Bootstrap
        // must retain the actual saved source, not the pre-import encoding.
        let savedBytes = try Data(contentsOf: f.paths.workingSet.appendingPathComponent("ProjectPhotos/" + filename))
        project.setPhotoFilename(filename)
        try JSONEncoder().encode(ProjectArchive(version: ProjectArchive.currentVersion, projects: [project]))
            .write(to: f.paths.workingSet.appendingPathComponent("projects-v1.json"))
        let journal = FileSyncMutationJournal(url: f.paths.mutationJournalURL)
        let first = try SyncMutation.save(recordVersion: .init(record: projectRecord(f.projectID, name: "Pending one", revision: 10)), mutationID: UUID())
        let second = try SyncMutation.save(recordVersion: .init(record: projectRecord(f.projectID, name: "Pending two", revision: 11)), mutationID: UUID())
        try journal.enqueue([first, second])
        let bridge = try makeBridge(f, schedule: completeEmpty)
        let handoff = try await bridge.install(), pending = try journal.pending()
        #expect(Array(pending.prefix(2)) == [first, second])
        #expect(handoff.checkpoint.records.contains { $0.payload.fields["name"]?.value == .string("Pending two") })
        let version = try #require(handoff.checkpoint.records.compactMap(\.payload.attachment).first)
        let staged = try #require(try handoff.stagedAttachmentSource(version))
        #expect(try Data(contentsOf: staged.fileURL) == savedBytes)
        let outbound = try #require(pending.first { $0.recordID.uuid == version.versionID }?.attachmentSource)
        #expect(try Data(contentsOf: outbound.fileURL) == savedBytes)
        #expect(outbound.isJournalStaged)
    }

    @Test func realDownloadedAttachmentIsCommittedAndUsesExactRuntimeAssets() async throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        let operations = BootstrapControlledOperations(), bridge = try makeBridge(f, schedule: operations.schedule)
        let remoteRoot = f.root.appendingPathComponent("remote-domain")
        var remoteProject = try StoredProject(id: f.projectID, name: "Remote photo")
        let filename = try ProjectPhotoFileService(directory: remoteRoot.appendingPathComponent("ProjectPhotos"))
            .save(data: CloudBootstrapFixture.jpeg(red: 0.8), projectID: f.projectID)
        remoteProject.setPhotoFilename(filename)
        let exported = try ProjectArchiveSyncMapper.export(archive: .init(version: ProjectArchive.currentVersion,
            projects: [remoteProject]), liveRoot: remoteRoot, deviceID: "remote-device")
        let record = try #require(exported.records.first { $0.payload.attachment != nil })
        let remoteSource = try #require(exported.attachments[record.id.uuid])
        let bytes = try Data(contentsOf: remoteSource.fileURL)
        let result = BridgeInstallResult()
        let task = Task { result.handoff = try await bridge.install() }, op = await operations.next()
        for candidate in exported.records {
            let cloud = try CloudRecordCodec().encode(candidate, zoneID: f.scope.zoneID)
            if let source = exported.attachments[candidate.id.uuid] { cloud["asset"] = CKAsset(fileURL: source.fileURL) }
            op.recordWasChangedBlock?(cloud.recordID, .success(cloud))
        }
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op); operations.completeSuccessfully(op)
        try await task.value
        let handoff = try #require(result.handoff), version = try #require(record.payload.attachment)
        let source = try #require(try handoff.stagedAttachmentSource(version))
        #expect(try Data(contentsOf: source.fileURL) == bytes)
        #expect(try Data(contentsOf: bridge.runtimeAssets.existingBootstrapDownload(version: version).0.fileURL) == bytes)
        #expect(handoff.checkpoint.records.contains(record))
    }

    @Test func stopRejectsSecondInstallAndCancelledWaiterStillJoinsNativeCompletion() async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let operations = BootstrapControlledOperations(), bridge = try makeBridge(f, schedule: operations.schedule)
        let task = Task { _ = try await bridge.install() }, op = await operations.next()
        await #expect(throws: (any Error).self) { _ = try await bridge.install() }
        bridge.stop()
        #expect(throws: (any Error).self) { try f.scope.requireCurrent() }
        let waiter = Task { await bridge.waitUntilStopped(); operations.markCompleted() }
        waiter.cancel()
        for _ in 0..<5 { await Task.yield() }
        #expect(!operations.readerCompleted)
        operations.completeSuccessfully(op)
        await #expect(throws: (any Error).self) { try await task.value }
        await waiter.value
        #expect(operations.readerCompleted)
        #expect(!FileManager.default.fileExists(atPath: f.paths.workingSet.appendingPathComponent("projects-v1.json").path))
    }

    @Test(arguments: ["nilStorage", "sourceStorage", "sourcePaths", "readerScope", "downloadScope", "driverScope", "contextAccount", "journal"])
    func mismatchedCompositionCannotFetchOrWrite(mode: String) async throws {
        let f = try CloudBootstrapFixture(), other = try CloudBootstrapFixture(); defer { f.remove(); other.remove() }
        let twin = CloudBootstrapSessionScope(account: f.account, zoneID: f.scope.zoneID, context: f.context)
        let operations = BootstrapControlledOperations()
        let reader = CloudBootstrapSnapshotReader(scope: mode == "readerScope" ? twin : f.scope,
            driver: CloudBootstrapPageDriver(scope: mode == "driverScope" ? twin : f.scope, schedule: { op, done in
                operations.markCompleted(); BootstrapControlledOperations.emitSuccessfulEmptyZone(op); done()
            }), downloads: try .init(storage: f.storage, paths: f.paths,
                scope: mode == "downloadScope" ? twin : f.scope, maximumBytes: 100_000_000))
        let account = mode == "contextAccount" ? try CloudAccountBinding(containerIdentifier: "foreign", userRecordName: "foreign") : f.account
        let context = AppAccountDomainContext(account: account, paths: f.paths,
            journal: .init(url: mode == "journal" ? other.paths.mutationJournalURL : f.paths.mutationJournalURL),
            storage: mode == "nilStorage" ? nil : f.storage, validateOwnership: appContext(f).validateOwnership)
        let source = SyncBootstrapSourceAccess(storage: mode == "sourceStorage" ? other.storage : f.storage,
            paths: mode == "sourcePaths" ? other.paths : f.paths, account: f.account.identity, maximumBytes: 100_000_000)
        let bridge = AppAccountBootstrapBridge(context: context, scope: f.scope, reader: reader, source: source, deviceID: "stable")
        let before = try f.entries()
        await #expect(throws: (any Error).self) { _ = try await bridge.install() }
        #expect(!operations.readerCompleted)
        #expect(try f.entries() == before)
    }

    @Test(arguments: ["prepared", "installed", "committed"])
    func legacyRecoveryPrecedesFetchAndCommittedV1ReturnsExistingHandoff(phase: String) async throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        let source = try SyncBootstrapSourceAccess(storage: f.storage, paths: f.paths, account: f.account.identity,
            maximumBytes: 100_000_000).capture(deviceID: "legacy")
        let legacy = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: f.context, validateContext: { _ in })
        let prepared = try legacy.prepare(local: #require(source.local), sourceArchive: source.archive,
            remote: .init(context: f.context, records: [], attachments: [:], isComplete: true))
        if phase != "prepared" { try legacy.install(prepared) }
        if phase == "committed" { _ = try legacy.commit(prepared) }
        let operations = BootstrapControlledOperations()
        let bridge = try makeBridge(f, schedule: { op, done in
            operations.markCompleted(); BootstrapControlledOperations.emitSuccessfulEmptyZone(op); done()
        })
        let handoff = try await bridge.install()
        #expect(operations.readerCompleted == (phase != "committed"))
        #expect((handoff.transactionID == prepared.transactionID) == (phase == "committed"))
        #expect(handoff.checkpoint.records.contains { $0.payload.fields["name"]?.value == .string("Bootstrap source") })
    }

    @Test func committedV2LegacyMissingArchiveReturnsWithoutFetch() async throws {
        // Legacy v2 predates the durable fresh-absence control. Construct its
        // genuine source using legacy open, then native prepare/install/commit.
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        try FileManager.default.removeItem(at: f.paths.workingSet.appendingPathComponent("projects-v1.json"))
        let legacy = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: f.context, validateContext: { _ in })
        let prepared = try legacy.prepareReconstruction(remote: .init(context: f.context, records: [], attachments: [:], isComplete: true),
            pendingSnapshot: .init(mutations: [], sourceTreeFingerprint: legacy.sourceFingerprint()))
        try legacy.install(prepared); _ = try legacy.commit(prepared)
        let operations = BootstrapControlledOperations()
        let bridge = try makeBridge(f, schedule: { op, done in
            operations.markCompleted(); BootstrapControlledOperations.emitSuccessfulEmptyZone(op); done()
        })
        let handoff = try await bridge.install()
        #expect(handoff.transactionID == prepared.transactionID)
        #expect(handoff.checkpoint.records.isEmpty)
        #expect(!operations.readerCompleted)
    }

    @Test func revocationImmediatelyBeforePreparingCannotPublishSelectorOrOutputs() async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let before = try f.entries()
        let bridge = try makeBridge(f, schedule: completeEmpty, boundary: { point in
            if point == .beforePreparingPublication { f.scope.invalidate() }
        })
        await #expect(throws: (any Error).self) { _ = try await bridge.install() }
        #expect(try f.entries() == before)
    }

    @Test(arguments: ["abort", "prepare", "install", "commit"])
    func nativeFailureRetainsEvidenceAndFreshBridgeRetries(cut: String) async throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        let failing = try makeBridge(f, schedule: completeEmpty, boundary: { point in
            if (cut == "abort" && point == .beforeTransactionRootCreation)
                || (cut == "prepare" && point == .afterPreparedPublication)
                || (cut == "install" && point == .afterInstalled)
                || (cut == "commit" && point == .afterReceipt) { throw BridgeTestError.injected }
        })
        await #expect(throws: (any Error).self) { _ = try await failing.install() }
        let old = try manifest(f)
        let nextScope = CloudBootstrapSessionScope(account: f.account, zoneID: f.scope.zoneID,
            context: .init(accountIDHash: f.context.accountIDHash, epoch: UUID(), freezeID: UUID()))
        let retry = try makeBridge(f, scope: nextScope, schedule: completeEmpty)
        let handoff = try await retry.install()
        #expect(handoff.transactionID != old.id)
        #expect(handoff.checkpoint.records.contains { $0.payload.fields["name"]?.value == .string("Bootstrap source") })
        #expect(try manifest(f).historyHead != nil)
    }

    @Test func commitBeforeReturnRevocationRecoversWithoutRefetch() async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let first = try makeBridge(f, schedule: completeEmpty, boundary: { point in
            if point == .selector(.afterSelectedSynchronize),
               case .committed = try manifest(f).body { f.scope.invalidate() }
        })
        await #expect(throws: (any Error).self) { _ = try await first.install() }
        let committed = try manifest(f)
        guard case .committed = committed.body else { Issue.record("commit was not selected"); return }
        let nextScope = CloudBootstrapSessionScope(account: f.account, zoneID: f.scope.zoneID,
            context: .init(accountIDHash: f.context.accountIDHash, epoch: UUID(), freezeID: UUID()))
        let operations = BootstrapControlledOperations()
        let retry = try makeBridge(f, scope: nextScope, schedule: { op, done in
            operations.markCompleted(); BootstrapControlledOperations.emitSuccessfulEmptyZone(op); done()
        })
        let handoff = try await retry.install()
        #expect(handoff.transactionID == committed.id)
        #expect(!operations.readerCompleted)
        try handoff.revalidate()
    }

    @Test(arguments: [false, true])
    func authenticatedSealRestorePendingInstallsExactPayloadAndAttachmentBytes(missingArchive: Bool) async throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        var project = try StoredProject(id: f.projectID, name: "Restored source")
        let photo = ProjectPhotoFileService(directory: f.paths.workingSet.appendingPathComponent("ProjectPhotos"))
        let filename = try photo.save(data: CloudBootstrapFixture.jpeg(), projectID: project.id)
        project.setPhotoFilename(filename)
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [project])
        try JSONEncoder().encode(archive).write(to: f.paths.workingSet.appendingPathComponent("projects-v1.json"))
        let export = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "restored-device")
        let journal = FileSyncMutationJournal(url: f.paths.mutationJournalURL)
        let original = try export.records.map { record in
            try SyncMutation.save(recordVersion: .init(record: record), attachmentSource: export.attachments[record.id.uuid], mutationID: UUID())
        }
        try journal.enqueue(original)
        let before = try journal.recoverySnapshot().mutations
        let bytes = try Data(contentsOf: photo.url(filename: filename))
        if missingArchive {
            try FileManager.default.removeItem(at: f.paths.workingSet.appendingPathComponent("projects-v1.json"))
            let legacy = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: f.context, validateContext: { _ in })
            let token = try legacy.prepareReconstruction(remote: .init(context: f.context, records: [], attachments: [:], isComplete: true),
                pendingSnapshot: .init(mutations: before, sourceTreeFingerprint: legacy.sourceFingerprint()))
            try legacy.install(token)
            _ = try legacy.recoverInterruptedInstallation()
        }
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: BridgeMemoryKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account.identity,
            vault: vault, journal: journal)
        let now = Date(), sealed = try recovery.seal(recovery.prepare(now: now), now: now)
        try recovery.cleanup(sealed); try recovery.restore(vaultID: sealed.vaultID, now: now)
        #expect(try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: now))
        // Native vault restore replays pending recovery data and issues a real
        // absent-source selection even when the sealed input had an archive.
        #expect(!FileManager.default.fileExists(atPath: f.paths.workingSet.appendingPathComponent("projects-v1.json").path))
        let bridge = try makeBridge(f, schedule: completeEmpty)
        let handoff = try await bridge.install(), pending = try journal.pending()
        #expect(Array(pending.prefix(before.count)).map(\.mutationID) == before.map(\.mutationID))
        #expect(Array(pending.prefix(before.count)).map(\.savedRecordVersion) == before.map(\.savedRecordVersion))
        for mutation in pending.prefix(before.count) {
            if let source = mutation.attachmentSource { #expect(try Data(contentsOf: source.fileURL) == bytes) }
        }
        #expect(handoff.checkpoint.records.contains { $0.payload.fields["name"]?.value == .string("Restored source") })
    }

    @Test(arguments: ["spend", "install", "receipt", "selector"])
    func staleNativeBoundariesRetainSelectedEvidenceWithoutCommit(cut: String) async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let bridge = try makeBridge(f, schedule: completeEmpty, boundary: { point in
            if (cut == "spend" && point == .beforeSourceSpend)
                || (cut == "install" && point == .afterInstalled)
                || (cut == "receipt" && point == .afterReceipt)
                || (cut == "selector" && point == .selector(.beforeRename)) { f.scope.invalidate() }
        })
        await #expect(throws: (any Error).self) { _ = try await bridge.install() }
        if cut == "selector" {
            #expect(throws: (any Error).self) { _ = try manifest(f) }
        } else {
            let selected = try manifest(f)
            if case .committed = selected.body { Issue.record("stale scope committed") }
        }
        if cut == "spend" || cut == "selector" {
            #expect(!FileManager.default.fileExists(atPath: f.paths.workingSet.appendingPathComponent("projects-v1.json").path))
        }
        await bridge.waitUntilStopped()
    }

    @Test func appOwnershipRevokedWhilePageHeldRejectsBeforeLocalWrites() async throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        var current = true
        let base = appContext(f), context = AppAccountDomainContext(account: base.account, paths: base.paths,
            journal: base.journal, storage: base.storage, validateOwnership: {
                guard current else { throw SyncBootstrapError.contextChanged }; try base.validateOwnership()
            })
        let operations = BootstrapControlledOperations()
        let reader = CloudBootstrapSnapshotReader(scope: f.scope, driver: CloudBootstrapPageDriver(scope: f.scope, schedule: operations.schedule),
            downloads: try .init(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000))
        let bridge = AppAccountBootstrapBridge(context: context, scope: f.scope, reader: reader,
            source: .init(storage: f.storage, paths: f.paths, account: f.account.identity, maximumBytes: 100_000_000), deviceID: "stable")
        let before = try f.entries(), task = Task { _ = try await bridge.install() }, op = await operations.next()
        current = false
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op); operations.completeSuccessfully(op)
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try f.entries() == before)
    }

    @Test(arguments: ["archive", "control", "selector", "foreignSelector"])
    func corruptOrForeignRecoveryCannotBeTreatedAsAbsence(mode: String) async throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        if mode == "archive" { try Data("corrupt archive".utf8).write(to: f.paths.workingSet.appendingPathComponent("projects-v1.json")) }
        else if mode == "control" {
            let root = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try Data("corrupt control".utf8).write(to: root.appendingPathComponent("intent.json"))
        } else {
            _ = try await makeBridge(f, schedule: completeEmpty).install()
            let selected = try manifest(f), path = f.paths.accountRoot.appendingPathComponent(selected.transactionRelativePath)
                .deletingLastPathComponent().appendingPathComponent("active.json")
            if mode == "selector" { try Data("corrupt selector".utf8).write(to: path) }
            else {
                let other = try CloudBootstrapFixture(); defer { other.remove() }
                _ = try await makeBridge(other, schedule: completeEmpty).install()
                let foreign = try manifest(other), foreignPath = other.paths.accountRoot.appendingPathComponent(foreign.transactionRelativePath)
                    .deletingLastPathComponent().appendingPathComponent("active.json")
                try Data(contentsOf: foreignPath).write(to: path)
            }
        }
        let operations = BootstrapControlledOperations(), before = try f.entries()
        let bridge = try makeBridge(f, schedule: { op, done in
            operations.markCompleted(); BootstrapControlledOperations.emitSuccessfulEmptyZone(op); done()
        })
        await #expect(throws: (any Error).self) { _ = try await bridge.install() }
        #expect(!operations.readerCompleted)
        #expect(try f.entries() == before)
    }

    @Test func unlinkedLocalPatternAssetRemainsInArchiveWithExactBytes() async throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        let mutable = NSMutableData(), consumer = try #require(CGDataConsumer(data: mutable))
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPDFPage(nil); pdf.endPDFPage(); pdf.closePDF()
        let bytes = mutable as Data
        let assetID = UUID()
        let asset = PatternAsset(id: assetID, sha256: Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined(),
            kind: .pdf, storedFilename: assetID.uuidString + ".pdf", byteCount: Int64(bytes.count), pageCount: 1)
        let directory = f.paths.workingSet.appendingPathComponent("Patterns/Assets")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent(asset.storedFilename))
        try JSONEncoder().encode(ProjectArchive(version: ProjectArchive.currentVersion,
            projects: [try StoredProject(id: f.projectID, name: "Local auxiliary")], patternAssets: [asset]))
            .write(to: f.paths.workingSet.appendingPathComponent("projects-v1.json"))
        let handoff = try await makeBridge(f, schedule: completeEmpty).install()
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: f.paths.workingSet.appendingPathComponent("projects-v1.json")))
        #expect(archive.patternAssets == [asset])
        #expect(try Data(contentsOf: directory.appendingPathComponent(asset.storedFilename)) == bytes)
        #expect(!handoff.checkpoint.records.contains { $0.id.uuid == asset.id })
    }

    @Test func heldPageUsesFreshWatchProcessedEvidenceInOwnedMerge() async throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        let counterID = UUID(), command = WatchCounterCommand(id: UUID(), projectID: f.projectID,
            counterID: counterID, operation: .increment, createdAt: Date(timeIntervalSince1970: 1))
        let prepared = PreparedWatchCommand(command: command, expectedCounterRevision: 4, expectedCounterValue: 9)
        let current = ProjectCounter(id: counterID, defaultOrdinal: 1, value: 10, mutationRevision: 5)
        let project = try StoredProject(id: f.projectID, name: "Watch source", counters: [current])
        try JSONEncoder().encode(ProjectArchive(version: ProjectArchive.currentVersion, projects: [project]))
            .write(to: f.paths.workingSet.appendingPathComponent("projects-v1.json"))
        let operations = BootstrapControlledOperations(), bridge = try makeBridge(f, schedule: operations.schedule)
        let result = BridgeInstallResult(), task = Task { result.handoff = try await bridge.install() }
        let op = await operations.next()
        var ledger = ProcessedWatchCommandLedger()
        ledger.record(command.id, preparedCommand: prepared, effectProof: .init(counter: current), at: Date(timeIntervalSince1970: 2))
        try AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: WatchSyncPaths.processedLedger(in: f.paths.workingSet)).save(ledger)
        let stamp = SyncMutationStamp(logicalRevision: 4, modifiedAt: Date(timeIntervalSince1970: 1), deviceID: "stale-watch")
        let stale = SyncRecord(schemaVersion: 1, id: .init(kind: .projectCounter, uuid: counterID),
            createdAt: Date(timeIntervalSince1970: 0), entityRevision: 4,
            payload: .init(fields: [:], atomicDomain: .init(value: .projectCounter(.init(
                counter: .init(id: counterID, defaultOrdinal: 1, value: 9, mutationRevision: 4), reminders: [],
                preparedCommand: nil, processedCommandIDs: [], occurrence: nil)), stamp: stamp)),
            relationships: [.init(role: "project", target: .init(kind: .project, uuid: f.projectID))],
            deletedAt: .init(value: nil, stamp: stamp))
        let cloud = try CloudRecordCodec().encode(stale, zoneID: f.scope.zoneID)
        op.recordWasChangedBlock?(cloud.recordID, .success(cloud))
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op); operations.completeSuccessfully(op)
        try await task.value
        let handoff = try #require(result.handoff), state = try #require(handoff.checkpoint.counterStates[counterID])
        #expect(state.counter.value == 10)
        #expect(state.processedCommandIDs.contains(command.id))
    }

    @Test func genuineHandoffAdoptsActualAppFactoryAndSurvivesJournalAcknowledgement() async throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        let bridge = try makeBridge(f, schedule: completeEmpty), handoff = try await bridge.install()
        let suite = "BridgeFactory-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let factory = AppAccountDomainFactory(entitlement: .configured(screenshotMode: true), backupHistory: .init(defaults: defaults))
        let installed = try factory.install(context: appContext(f), runtime: .init(assets: bridge.runtimeAssets,
            incoming: .init(url: f.paths.engineState.appendingPathComponent("incoming.json")), zoneID: f.scope.zoneID), bootstrap: handoff)
        #expect(installed.resources.store.projects.map(\.name) == ["Bootstrap source"])
        let journal = FileSyncMutationJournal(url: f.paths.mutationJournalURL)
        for mutation in try journal.pending() { try journal.acknowledge(recordID: mutation.recordID, mutationID: mutation.mutationID) }
        try handoff.revalidate()
        installed.resources.stopForSessionTransition(); try await installed.resources.waitForStoppedOperations()
    }

    private nonisolated func completeEmpty(_ op: CKFetchRecordZoneChangesOperation, _ done: @escaping @Sendable () -> Void) {
        BootstrapControlledOperations.emitSuccessfulEmptyZone(op); done()
    }
    private func projectRecord(_ id: UUID, name: String, revision: UInt64) -> SyncRecord {
        let stamp = SyncMutationStamp(logicalRevision: revision, modifiedAt: Date(timeIntervalSince1970: Double(revision)), deviceID: "pending")
        return .init(schemaVersion: 1, id: .init(kind: .project, uuid: id), createdAt: Date(timeIntervalSince1970: 1),
            entityRevision: revision, payload: .init(fields: ["name": .init(value: .string(name), stamp: stamp)]),
            relationships: [], deletedAt: .init(value: nil, stamp: stamp))
    }

    private func makeBridge(_ f: CloudBootstrapFixture, scope requested: CloudBootstrapSessionScope? = nil,
        schedule: @escaping @Sendable (CKFetchRecordZoneChangesOperation, @escaping @Sendable () -> Void) -> Void,
        boundary: @escaping (SyncBootstrapOwnedBoundary) throws -> Void = { _ in }) throws -> AppAccountBootstrapBridge {
        let scope = requested ?? f.scope
        let reader = CloudBootstrapSnapshotReader(scope: scope,
            driver: CloudBootstrapPageDriver(scope: scope, schedule: schedule),
            downloads: try .init(storage: f.storage, paths: f.paths, scope: scope, maximumBytes: 100_000_000))
        return .init(context: appContext(f), scope: scope, reader: reader,
            source: .init(storage: f.storage, paths: f.paths, account: f.account.identity, maximumBytes: 100_000_000),
            deviceID: "bridge-installation-device", boundary: boundary)
    }
    private func appContext(_ f: CloudBootstrapFixture) -> AppAccountDomainContext {
        .init(account: f.account, paths: f.paths, journal: .init(url: f.paths.mutationJournalURL),
            storage: f.storage, validateOwnership: {
                try f.storage.withRecoveryOwnership(paths: f.paths, account: f.account.identity, maximumBytes: 100_000_000) { try $0.validate() }
            })
    }
    private func manifest(_ f: CloudBootstrapFixture) throws -> BootstrapManifestV3 {
        let hash = Data(SHA256.hash(data: Data(f.paths.workingSet.standardizedFileURL.path.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        return try .decodeEnvelope(Data(contentsOf: f.paths.accountRoot.appendingPathComponent(
            ".KnitNote-SyncBootstrap/" + f.account.identity.accountIDHash + "/" + hash + "/active.json")))
    }
}

@MainActor private final class BridgeInstallResult { var handoff: SyncCanonicalBootstrapHandoff? }
private enum BridgeTestError: Error { case injected }
private final class BridgeMemoryKeys: SyncRecoveryVaultKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: Data] = [:]
    func insert(_ key: Data, for id: UUID) throws { lock.withLock { keys[id] = key } }
    func key(for id: UUID) throws -> Data? { lock.withLock { keys[id] } }
    func remove(for id: UUID) throws { lock.withLock { keys[id] = nil } }
}
