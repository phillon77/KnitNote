import CloudKit
import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import KnitNote

@MainActor @Suite struct AppAccountDomainFactoryTests {
    @Test func recoveredRemoteConflictHeadUsesOwnerIssuedSource() async throws {
        let f = try AccountDomainFixture(media: true, conflict: true)
        defer { f.remove() }
        let handoff = try f.recoveredHandoff()
        let installed = try f.install(bootstrap: handoff)
        #expect(try f.checkpoints().load()?.records.filter { $0.id.kind == .attachment }.count == 2)
        let pending = try f.journal.pending()
        let records = handoff.checkpoint.records
        let resolved = try f.resolver().canonical(records: records, references: f.references(), pending: pending, bootstrap: handoff)
        #expect(resolved.count == 2)
        for mutation in pending {
            if let source = mutation.attachmentSource { #expect(resolved[mutation.recordID.uuid] == source) }
        }
        #expect(installed.resources.store.projects.count == 1)
        await f.stop()
    }

    @Test func corruptPendingSourceCannotBeReplacedByHealthyDisplayedBytes() async throws {
        let f = try AccountDomainFixture(media: true)
        defer { f.remove() }
        let source = try #require(try f.journal.pending().compactMap(\.attachmentSource).first)
        try Data("corrupt pending".utf8).write(to: source.fileURL)
        #expect(throws: (any Error).self) { try f.install(bootstrap: f.handoff) }
        await f.stop()
    }

    @Test func realJournalSourcesKeepExactIdentityAndRejectImmutableRecordCollision() throws {
        let f = try AccountDomainFixture(); defer { f.remove() }
        let bytes = Data("journal immutable bytes".utf8)
        let record = try f.attachment(bytes: bytes)
        let version = try #require(record.payload.attachment)
        let input = f.root.appendingPathComponent("user-input.bin")
        try bytes.write(to: input)
        let save = try SyncSaveMutation(recordVersion: .init(record: record),
            attachmentSource: .init(fileURL: input, contentSHA256: version.contentSHA256, byteCount: version.byteCount), mutationID: UUID())
        try f.journal.enqueue([.save(save)])
        let pending = try f.journal.pending()
        let exact = try #require(pending.first { $0.recordID == record.id }?.attachmentSource)
        #expect(exact.isJournalStaged && exact.fileURL != input)
        let resolved = try f.resolver().canonical(records: [record], references: [], pending: pending, bootstrap: nil)
        #expect(resolved[record.id.uuid] == exact)
        let retry = try SyncSaveMutation(recordVersion: .init(record: record), attachmentSource: save.attachmentSource, mutationID: UUID())
        try f.journal.enqueue([.save(retry)])
        let repeated = try f.journal.pending()
        let repeatedSources = repeated.filter { $0.recordID == record.id }.compactMap(\.attachmentSource)
        #expect(repeatedSources.count == 2)
        let repeatedMap = try f.resolver().canonical(records: [record], references: [], pending: repeated, bootstrap: nil)
        #expect(repeatedSources.contains(try #require(repeatedMap[record.id.uuid])))
        #expect(try f.resolver().canonical(records: [], references: [], pending: pending, bootstrap: nil).isEmpty)
        var collision = record
        collision.entityRevision += 1
        #expect(throws: SyncPublicationError.corruptTransaction) {
            try f.resolver().canonical(records: [collision], references: [], pending: pending, bootstrap: nil)
        }
        try FileManager.default.removeItem(at: exact.fileURL)
        #expect(throws: (any Error).self) {
            try f.resolver().canonical(records: [], references: [], pending: pending, bootstrap: nil)
        }
    }

    @Test func missingConflictHeadBlocksUntilSameAccountCloudOwnerSuppliesIt() throws {
        let f = try AccountDomainFixture(); defer { f.remove() }
        let bytes = Data("head bytes".utf8)
        let a = try f.attachment(bytes: bytes), b = try f.attachment(bytes: bytes)
        let records = [a, b]
        let source = f.root.appendingPathComponent("unrelated-name.bin")
        try bytes.write(to: source)
        let versionA = try #require(a.payload.attachment), versionB = try #require(b.payload.attachment)
        _ = try f.runtime.assets.installDownload(version: versionA, sourceURL: source)
        #expect(throws: (any Error).self) { try f.resolver().canonical(records: records, references: [], pending: [], bootstrap: nil) }
        let urlB = try f.runtime.assets.installDownload(version: versionB, sourceURL: source)
        let map = try f.resolver().canonical(records: records, references: [], pending: [], bootstrap: nil)
        #expect(Set(map.keys) == Set([a.id.uuid, b.id.uuid]))
        #expect(map[b.id.uuid]?.fileURL == urlB)
        #expect(throws: (any Error).self) { try f.resolver().canonical(records: records + [a], references: [], pending: [], bootstrap: nil) }
        try Data("corrupt".utf8).write(to: urlB)
        #expect(throws: (any Error).self) { try f.resolver().canonical(records: records, references: [], pending: [], bootstrap: nil) }
    }

    @Test func replacedAndTombstonedAncestorsNeedNoPhantomSourcesButPartialFetchIncludesAllLiveVersions() throws {
        let f = try AccountDomainFixture(); defer { f.remove() }
        let bytes = Data("lineage".utf8)
        let old = try f.attachment(bytes: bytes)
        var next = try f.attachment(bytes: bytes, replaces: old.id.uuid)
        next.deletedAt = .init(value: Date(timeIntervalSince1970: 50), stamp: next.deletedAt.stamp)
        #expect(try f.resolver().canonical(records: [old, next], references: [], pending: [], bootstrap: nil).isEmpty)
        next.deletedAt = .init(value: nil, stamp: next.deletedAt.stamp)
        let source = f.root.appendingPathComponent("download.bin")
        try bytes.write(to: source)
        _ = try f.runtime.assets.installDownload(version: #require(next.payload.attachment), sourceURL: source)
        #expect(Set(try f.resolver().canonical(records: [old, next], references: [], pending: [], bootstrap: nil).keys) == [next.id.uuid])
        let batch = try SyncRemoteBatch(accountIDHash: f.account.identity.accountIDHash, batchID: UUID(), records: [old, next], deletedRecordIDs: [])
        #expect(throws: (any Error).self) { try f.resolver().fetched(batch: batch) }
        _ = try f.runtime.assets.installDownload(version: #require(old.payload.attachment), sourceURL: source)
        #expect(Set(try f.resolver().fetched(batch: batch).keys) == Set([old.id.uuid, next.id.uuid]))
    }

    @Test(arguments: [("usage-markup", "pattern-markup"), ("legacy-markup", "legacy-pattern-markup")])
    func selectedMarkupAliasesUseServiceReferenceNotDisplayFilename(roles: (String, String)) throws {
        let f = try AccountDomainFixture(); defer { f.remove() }
        let bytes = Data("markup".utf8)
        let record = try f.attachment(bytes: bytes, role: roles.0)
        let version = try #require(record.payload.attachment)
        let url = f.root.appendingPathComponent("service-owned-reference.json")
        try bytes.write(to: url)
        let reference = SyncAttachmentReference(slot: .init(owner: version.slot.owner, role: roles.1, slotID: version.slot.slotID),
            sourceURL: url, mediaType: version.mediaType, displayFilename: "irrelevant-name")
        let sources = try f.resolver().canonical(records: [record], references: [reference], pending: [], bootstrap: nil)
        #expect(sources[record.id.uuid]?.fileURL == url)
        #expect(throws: (any Error).self) { try f.resolver().canonical(records: [record], references: [reference, reference], pending: [], bootstrap: nil) }
        try FileManager.default.removeItem(at: url)
        #expect(throws: (any Error).self) { try f.resolver().canonical(records: [record], references: [reference], pending: [], bootstrap: nil) }
    }

    @Test func declaredLimitRejectsBeforeLocatorAndExactLimitReadsVerifiedBytes() throws {
        let f = try AccountDomainFixture(); defer { f.remove() }
        let bytes = Data(repeating: 0x31, count: 100_000_000)
        let exact = try f.attachment(bytes: bytes)
        let oversized = try f.attachment(bytes: Data(), byteCount: 100_000_001)
        let url = f.root.appendingPathComponent("exact-100MB.bin")
        try bytes.write(to: url)
        let resolver = AppAccountAttachmentResolver(account: f.account.identity, installedDownload: { _ in
            throw AccountDomainTestError.locatorCalled
        }, validateOwnership: f.ownership())
        #expect(throws: SyncRegularFileReadError.tooLarge) {
            try resolver.canonical(records: [oversized], references: [], pending: [], bootstrap: nil)
        }
        let version = try #require(exact.payload.attachment)
        try resolver.verify(.init(fileURL: url, contentSHA256: version.contentSHA256, byteCount: version.byteCount), version: version)
        let batch = try SyncRemoteBatch(accountIDHash: f.account.identity.accountIDHash, batchID: UUID(), records: [oversized], deletedRecordIDs: [])
        #expect(throws: SyncRegularFileReadError.tooLarge) { try resolver.fetched(batch: batch) }
    }

    @Test func fetchedLocatorRevocationAndWrongAccountFailClosed() throws {
        let f = try AccountDomainFixture(); defer { f.remove() }
        let record = try f.attachment(bytes: Data("download".utf8))
        let batch = try SyncRemoteBatch(accountIDHash: f.account.identity.accountIDHash, batchID: UUID(), records: [record], deletedRecordIDs: [])
        let other = try SyncAccountIdentity(containerIdentifier: "test.container", userRecordName: "other")
        let foreign = try SyncRemoteBatch(accountIDHash: other.accountIDHash, batchID: UUID(), records: [record], deletedRecordIDs: [])
        #expect(throws: SyncRemoteBatchError.missingAuthority) { try f.resolver().fetched(batch: foreign) }
        let resolver = AppAccountAttachmentResolver(account: f.account.identity, installedDownload: { _ in
            try f.storage.close()
            return f.root.appendingPathComponent("never-read")
        }, validateOwnership: f.ownership())
        #expect(throws: SyncAccountStorageError.invalidIdentity) { try resolver.fetched(batch: batch) }
    }

    @Test func realIncomingAcknowledgementRequiredBeforeReceiptRetirement() async throws {
        let f = try AccountDomainFixture(); defer { f.remove() }
        let installed = try f.install(bootstrap: f.handoff)
        var record = try #require(try f.checkpoints().load()?.records.first { $0.id.uuid == f.projectID })
        record.payload.fields["name"] = .init(value: .string("Remote"), stamp: .init(logicalRevision: 1000,
            modifiedAt: Date(timeIntervalSince1970: 2_000_000_000), deviceID: "remote"))
        let generation = try f.runtime.incoming.beginGeneration(accountIdentifier: f.account.userRecordName, zoneID: f.runtime.zoneID, persistedEngineState: nil).generation
        let envelope = try #require(try f.runtime.incoming.record(records: [record], deletedRecordIDs: [],
            accountIdentifier: f.account.userRecordName, zoneID: f.runtime.zoneID, generation: generation).deliveredEnvelope)
        let batch = try SyncRemoteBatch(accountIDHash: f.account.identity.accountIDHash, batchID: envelope.batchID, records: [record], deletedRecordIDs: [])
        let epoch = CloudSyncAccountEpoch(accountIdentifier: f.account.userRecordName, zoneID: f.runtime.zoneID,
            generation: generation, containerIdentifier: f.account.containerIdentifier)
        try await installed.fetchedBatchCommitter.commitFetchedBatch(batch: batch, accountEpoch: epoch)
        #expect(installed.resources.store.projects.first?.name == "Remote")
        await #expect(throws: (any Error).self) { try await installed.fetchedBatchCommitter.didAcknowledgeFetchedBatch(batch: batch.identity, accountEpoch: epoch) }
        #expect(try f.checkpoints().load()?.remoteBatchReceipts.count == 1)
        try f.runtime.incoming.acknowledge(batch.identity.batchID, accountIdentifier: f.account.userRecordName, zoneID: f.runtime.zoneID, account: f.account.identity)
        try await installed.fetchedBatchCommitter.didAcknowledgeFetchedBatch(batch: batch.identity, accountEpoch: epoch)
        #expect(try f.checkpoints().load()?.remoteBatchReceipts.isEmpty == true)
        await f.stop()
    }
    @Test func recoveredInstallReopensAndDailyEditsUseCurrentOwnership() async throws {
        let f = try AccountDomainFixture()
        defer { f.remove() }
        let installed = try f.install(bootstrap: f.recoveredHandoff())
        #expect(installed.resources.store.projects.map(\.id) == [f.projectID])
        #expect(installed.resources.presentation?.watch == nil)
        let original = try #require(try installed.recordProvider.record(for: .init(kind: .project, uuid: f.projectID)))
        try f.rename(installed.resources.store, "Daily")
        #expect(try f.journal.pending().contains { $0.recordID.uuid == f.projectID })
        #expect(try installed.recordProvider.record(for: original.id) == original)
        let reopened = try f.install(bootstrap: nil)
        #expect(reopened.resources.store.projects.first?.name == "Daily")
        try f.storage.close()
        #expect(throws: (any Error).self) { try f.rename(reopened.resources.store, "Revoked") }
        await f.stop()
    }

    @Test(arguments: ["missing", "corrupt", "foreign"])
    func invalidCanonicalCannotInstall(kind: String) async throws {
        let f = try AccountDomainFixture()
        defer { f.remove() }
        if kind != "missing" {
            let first = try f.install(bootstrap: f.handoff)
            let canonical = f.paths.workingSet.appendingPathComponent("SyncMetadata/canonical.json")
            if kind == "corrupt" { try Data("bad".utf8).write(to: canonical) }
            else {
                let current = try #require(try f.checkpoints().load())
                let foreign = try SyncCanonicalCheckpoint(accountIDHash: String(repeating: "a", count: 64),
                    commitID: current.commitID, archiveSHA256: current.archiveSHA256, records: current.records,
                    legacyRecordIDsToDelete: current.legacyRecordIDsToDelete)
                try foreign.encoded().write(to: canonical)
            }
            #expect(first.resources.store.projects.count == 1)
        }
        #expect(throws: (any Error).self) { try f.install(bootstrap: nil) }
        await f.stop()
    }

    @Test(arguments: [SyncCanonicalPublicationBoundary.afterIntent, .afterArchive])
    func dailyRecoveryResolvesCoreSelectedCheckpoint(boundary: SyncCanonicalPublicationBoundary) async throws {
        let f = try AccountDomainFixture(media: true)
        defer { f.remove() }
        _ = try f.install(bootstrap: f.handoff)
        try f.journal.acknowledge(Set(f.journal.pending().map(\.identity)))
        let store = JSONProjectStore(url: f.archiveURL,
            backupService: KnitNoteBackupService(liveRoot: f.paths.workingSet, workRoot: f.root.appendingPathComponent("Backup")),
            syncCanonicalPublicationBoundary: { if $0 == boundary { throw SyncPublicationError.pendingRepair } },
            syncMutationSink: JournalSyncMutationSink(journal: f.journal))
        f.stores.append(store)
        try store.activateSyncCanonicalState(checkpointStore: f.checkpoints(), bootstrap: nil, attachmentSources: [:])
        if boundary == .afterIntent {
            #expect(throws: (any Error).self) {
                try store.updateProject(id: f.projectID, name: "Candidate", toolType: nil, toolSize: nil, toolNotes: nil,
                    photoChange: .replace(AccountDomainFixture.jpeg(red: 0.8)))
            }
        } else {
            try store.updateProject(id: f.projectID, name: "Candidate", toolType: nil, toolSize: nil, toolNotes: nil,
                photoChange: .replace(AccountDomainFixture.jpeg(red: 0.8)))
        }
        let installed = try f.install(bootstrap: nil)
        #expect(installed.resources.store.projects.first?.name == (boundary == .afterIntent ? "Before" : "Candidate"))
        #expect(try SyncPublicationTransactionFile(archiveURL: f.archiveURL).load() == nil)
        await f.stop()
    }
}

@MainActor private final class AccountDomainFixture {
    let root: URL
    let account: CloudAccountBinding
    let storage: SyncAccountStorage
    let paths: SyncAccountStorage.Paths
    let journal: FileSyncMutationJournal
    let projectID: UUID
    let handoff: SyncCanonicalBootstrapHandoff
    let defaults: UserDefaults
    let suite: String
    let runtime: AppAccountDomainRuntime
    var stores: [JSONProjectStore] = []
    var sessions: [AppSessionResources] = []
    var archiveURL: URL { paths.workingSet.appendingPathComponent("projects-v1.json") }
    var context: AppAccountDomainContext {
        .init(account: account, paths: paths, journal: journal, validateOwnership: ownership())
    }
    init(media: Bool = false, conflict: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("AccountDomain-\(UUID())")
        account = try CloudAccountBinding(containerIdentifier: "test.container", userRecordName: "account-domain")
        storage = SyncAccountStorage(baseURL: root)
        paths = try storage.open(identity: account.identity)
        var project = try StoredProject(name: "Before")
        if media {
            let service = ProjectPhotoFileService(directory: paths.workingSet.appendingPathComponent("ProjectPhotos"))
            project.setPhotoFilename(try service.save(data: Self.jpeg(), projectID: project.id))
        }
        projectID = project.id
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [project])
        try JSONEncoder().encode(archive).write(to: paths.workingSet.appendingPathComponent("projects-v1.json"))
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: paths.workingSet, deviceID: "account-domain-device")
        let remote = conflict ? try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: paths.workingSet, deviceID: "remote-device") : nil
        let bootstrapContext = SyncBootstrapContext(accountIDHash: account.identity.accountIDHash, epoch: UUID(), freezeID: UUID())
        let transaction = try SyncBootstrapTransaction(liveRoot: paths.workingSet, context: bootstrapContext,
            validateContext: { guard $0 == bootstrapContext else { throw SyncBootstrapError.contextChanged } })
        let prepared = try transaction.prepare(local: local, sourceArchive: archive,
            remote: .init(context: bootstrapContext, records: remote?.records ?? [], attachments: remote?.attachments ?? [:], isComplete: true))
        try transaction.install(prepared)
        _ = try transaction.commit(prepared)
        handoff = try transaction.canonicalHandoff(prepared)
        journal = FileSyncMutationJournal(url: paths.mutationJournalURL)
        runtime = try .init(assets: CloudAssetStagingService(rootURL: paths.staging.appendingPathComponent("cloud-assets"), accountIdentifier: account.userRecordName),
            incoming: FileCloudIncomingBatchStore(url: paths.engineState.appendingPathComponent("incoming.json")),
            zoneID: CKRecordZone.ID(zoneName: "AccountDomain"))
        suite = "AccountDomain.\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
    }
    func ownership() -> () throws -> Void {
        let storage = storage, paths = paths, account = account.identity
        return { try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: 100_000_000) { try $0.validate() } }
    }
    func resolver() -> AppAccountAttachmentResolver {
        .init(account: account.identity, installedDownload: { try self.runtime.assets.installedDownload(version: $0) }, validateOwnership: ownership())
    }
    func references() throws -> [SyncAttachmentReference] {
        try SyncArchiveAttachmentReferences(liveRoot: paths.workingSet).references(in: JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL)))
    }
    func attachment(bytes: Data, replaces: UUID? = nil, role: String = "cover", byteCount: Int64? = nil) throws -> SyncRecord {
        let version = try SyncAttachmentVersion.issuing(slot: .init(owner: .init(kind: .project, uuid: projectID), role: role, slotID: "main"),
            contentSHA256: Data(SHA256.hash(data: bytes)), byteCount: byteCount ?? Int64(bytes.count),
            mediaType: "application/octet-stream", displayFilename: "display-only.bin", replacesVersionID: replaces)
        let stamp = SyncMutationStamp(logicalRevision: 1, modifiedAt: Date(timeIntervalSince1970: 10), deviceID: "attachment-device")
        return SyncRecord(schemaVersion: 1, id: .init(kind: .attachment, uuid: version.versionID), createdAt: Date(timeIntervalSince1970: 10), entityRevision: 1,
            payload: .init(fields: [:], attachment: version), relationships: [.init(role: "owner", target: version.slot.owner)], deletedAt: .init(value: nil, stamp: stamp))
    }
    static func jpeg(red: CGFloat = 0.3) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let bytes = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(output, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(output))
        return bytes as Data
    }
    func checkpoints() throws -> SyncCanonicalCheckpointStore {
        try .init(liveRoot: paths.workingSet, account: account.identity, validateOwnership: ownership())
    }
    func recoveredHandoff() throws -> SyncCanonicalBootstrapHandoff {
        let context = SyncBootstrapContext(accountIDHash: account.identity.accountIDHash, epoch: UUID(), freezeID: UUID())
        let validate = ownership()
        let transaction = try SyncBootstrapTransaction(liveRoot: paths.workingSet, context: context,
            validateContext: { guard $0 == context else { throw SyncBootstrapError.contextChanged }; try validate() })
        return try #require(try transaction.recoverUnderCurrentContext())
    }
    func install(bootstrap: SyncCanonicalBootstrapHandoff?) throws -> AppAccountInstalledDomain {
        let factory = AppAccountDomainFactory(entitlement: .configured(screenshotMode: true), backupHistory: BackupHistory(defaults: defaults))
        let installed = try factory.install(context: context, runtime: runtime, bootstrap: bootstrap)
        stores.append(installed.resources.store); sessions.append(installed.resources)
        return installed
    }
    func rename(_ store: JSONProjectStore, _ name: String) throws {
        try store.updateProject(id: projectID, name: name, toolType: nil, toolSize: nil, toolNotes: nil, photoChange: .unchanged)
    }
    func stop() async {
        for session in sessions { session.presentation?.patternInboxProcessor.stopForSessionTransition() }
        for store in stores { store.revokeSessionWrites() }
        for session in sessions { try? await session.presentation?.patternInboxProcessor.waitForStoppedOperations() }
        for store in stores { try? await store.waitForTrackedBackgroundWritesAfterRevocation() }
    }
    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? storage.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private enum AccountDomainTestError: Error { case locatorCalled }
