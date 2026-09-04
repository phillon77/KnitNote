import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncAttachmentManifestTests {
    @Test func unchangedSecondPersistDoesNotRehashFiveHundredAttachments() throws {
        let fixture = try AttachmentManifestFixture(realAttachmentCount: 500)
        defer { fixture.remove() }

        try fixture.persistWithoutAttachmentChanges()
        #expect(fixture.readerCounters.hashedFileCount == 500)

        fixture.readerCounters.reset()
        let second = try fixture.persistWithoutAttachmentChanges()

        #expect(fixture.readerCounters.hashedFileCount == 0)
        #expect(second.mutations.isEmpty)
        #expect(second.attachmentManifest.count == 500)
    }

    @Test func replacingOneAttachmentHashesOnlyTheNewVersion() throws {
        let fixture = try AttachmentManifestFixture(realAttachmentCount: 500)
        defer { fixture.remove() }
        try fixture.persistWithoutAttachmentChanges()
        let oldVersionID = try #require(fixture.versionID(at: 211))

        fixture.readerCounters.reset()
        let projection = try fixture.replaceAttachment(at: 211)
        let save = try #require(projection.mutations.single?.savedRecordVersion)
        let attachment = try #require(save.record.payload.attachment)

        #expect(fixture.readerCounters.hashedFileCount == 1)
        #expect(attachment.replacesVersionID == oldVersionID)
        #expect(attachment.versionID != oldVersionID)
    }

    @Test func deletingOneAttachmentDoesNotHashSurvivorsAndDeletesOnlyIssuedVersion() throws {
        // Production break caught: the projector rebuilt immutable record
        // fields when turning an issued attachment into a tombstone.
        let fixture = try AttachmentManifestFixture(realAttachmentCount: 500)
        defer { fixture.remove() }
        let issuance = try fixture.persistWithoutAttachmentChanges()
        let deletedVersionID = try #require(fixture.versionID(at: 211))
        let issuedRecord = try #require(issuance.mutations.compactMap {
            $0.savedRecordVersion?.record
        }.first { $0.id.uuid == deletedVersionID })

        fixture.readerCounters.reset()
        let projection = try fixture.deleteAttachment(at: 211)

        #expect(fixture.readerCounters.hashedFileCount == 0)
        let tombstone = try #require(projection.mutations.single?.savedRecordVersion?.record)
        let deletedAttachment = try #require(tombstone.payload.attachment)
        #expect(tombstone.id == .init(kind: .attachment, uuid: deletedVersionID))
        #expect(tombstone.deletedAt.value != nil)
        #expect(deletedAttachment.versionID == deletedVersionID)
        #expect(projection.mutations.single?.attachmentSource == nil)
        #expect(projection.attachmentManifest.count == 499)
        #expect(
            try SyncAttachmentImmutableSnapshot(record: tombstone).sha256
                == SyncAttachmentImmutableSnapshot(record: issuedRecord).sha256
        )
    }

    @Test func tombstonedHeadIsNeverReusedEvenWhenAStaleManifestStillMatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-deleted-head-stale-manifest-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("photo.jpg")
        try Data("attachment".utf8).write(to: sourceURL)
        let slot = SyncAttachmentSlot(
            owner: .init(kind: .project, uuid: UUID()),
            role: "project-photo",
            slotID: "primary"
        )
        let reference = SyncAttachmentReference(
            slot: slot,
            sourceURL: sourceURL,
            mediaType: "image/jpeg",
            displayFilename: "photo.jpg"
        )
        let before = ProjectArchive(version: 1, projects: [])
        let after = ProjectArchive(version: 2, projects: [])
        let first = try SyncPublicationProjector(
            deviceID: "device",
            attachmentReferences: { $0.version == 1 ? [] : [reference] },
            issuedAttachmentVersions: [:]
        ).project(before: before, after: after, manifest: [:])
        let issued = try #require(
            first.mutations.single?.savedRecordVersion?.record.payload.attachment
        )
        let restoredVersionID = UUID()

        let restored = try SyncPublicationProjector(
            deviceID: "device",
            attachmentReferences: { $0.version == 1 ? [] : [reference] },
            issuedAttachmentVersions: [slot: issued],
            deletedAttachmentVersionIDs: [issued.versionID],
            makeUUID: { restoredVersionID }
        ).project(before: before, after: after, manifest: first.attachmentManifest)

        let replacement = try #require(
            restored.mutations.single?.savedRecordVersion?.record.payload.attachment
        )
        #expect(replacement.versionID == restoredVersionID)
        #expect(replacement.replacesVersionID == issued.versionID)
    }

    @Test func inodeReplacementWithIdenticalPathSizeAndMtimeRehashesAndIssuesNewVersion() throws {
        let fixture = try AttachmentManifestFixture(realAttachmentCount: 500)
        defer { fixture.remove() }
        try fixture.persistWithoutAttachmentChanges()
        let oldEntry = try #require(fixture.entry(at: 211))

        fixture.readerCounters.reset()
        let projection = try fixture.replaceInodePreservingBytesSizeAndMtime(at: 211)
        let newEntry = try #require(fixture.entry(at: 211))
        let attachment = try #require(
            projection.mutations.single?.savedRecordVersion?.record.payload.attachment
        )

        #expect(fixture.readerCounters.hashedFileCount == 1)
        #expect(newEntry.normalizedPath == oldEntry.normalizedPath)
        #expect(newEntry.byteCount == oldEntry.byteCount)
        #expect(newEntry.modificationNanoseconds == oldEntry.modificationNanoseconds)
        #expect(newEntry.inode != oldEntry.inode)
        #expect(newEntry.contentSHA256 == oldEntry.contentSHA256)
        #expect(newEntry.versionID != oldEntry.versionID)
        #expect(attachment.replacesVersionID == oldEntry.versionID)
    }

    @Test func corruptManifestFailsClosedAndPreservesOriginalBytes() throws {
        let fixture = try AttachmentManifestFixture(realAttachmentCount: 1)
        defer { fixture.remove() }
        try fixture.persistWithoutAttachmentChanges()
        let store = SyncAttachmentManifestStore(url: fixture.manifestURL)
        try store.commit(fixture.manifest)
        let corruptBytes = Data("not a sync attachment manifest".utf8)
        try corruptBytes.write(to: fixture.manifestURL, options: .atomic)

        #expect(throws: SyncAttachmentManifestError.corrupt) {
            _ = try store.load()
        }
        #expect(try Data(contentsOf: fixture.manifestURL) == corruptBytes)
    }

    @Test func committedManifestRestartReusesAllHashesAndIssuedVersions() throws {
        let fixture = try AttachmentManifestFixture(realAttachmentCount: 500)
        defer { fixture.remove() }
        try fixture.persistWithoutAttachmentChanges()
        let versionsBefore = fixture.manifest.values.map(\.versionID).sorted {
            $0.uuidString < $1.uuidString
        }
        try SyncAttachmentManifestStore(url: fixture.manifestURL).commit(fixture.manifest)

        fixture.manifest = try SyncAttachmentManifestStore(url: fixture.manifestURL).load()
        fixture.readerCounters.reset()
        let restarted = try fixture.persistWithoutAttachmentChanges()

        #expect(fixture.readerCounters.hashedFileCount == 0)
        #expect(restarted.mutations.isEmpty)
        #expect(fixture.manifest.values.map(\.versionID).sorted {
            $0.uuidString < $1.uuidString
        } == versionsBefore)
    }

    @Test func legacyAttachmentStaysLocalUntilReplacementThenRetainsItsIssuedHistory() throws {
        let fixture = try LegacyAttachmentFixture()
        defer { fixture.remove() }

        let unchanged = try fixture.project(
            before: [fixture.legacyReference],
            after: [fixture.legacyReference],
            manifest: [:],
            issuedVersions: [:]
        )
        #expect(unchanged.mutations.isEmpty)
        #expect(unchanged.attachmentManifest.isEmpty)
        #expect(fixture.readerCounters.hashedFileCount == 0)

        let unissuedDeletion = try fixture.project(
            before: [fixture.legacyReference],
            after: [],
            manifest: [:],
            issuedVersions: [:]
        )
        #expect(unissuedDeletion.mutations.isEmpty)
        #expect(unissuedDeletion.attachmentManifest.isEmpty)

        fixture.readerCounters.reset()
        let replacement = try fixture.project(
            before: [fixture.legacyReference],
            after: [fixture.replacementReference],
            manifest: [:],
            issuedVersions: [:]
        )
        let saved = try #require(replacement.mutations.single?.savedRecordVersion?.record)
        let issuedVersion = try #require(saved.payload.attachment)
        #expect(fixture.readerCounters.hashedFileCount == 1)
        #expect(issuedVersion.replacesVersionID == nil)
        #expect(replacement.attachmentManifest.count == 1)

        try SyncAttachmentManifestStore(url: fixture.manifestURL).commit(
            replacement.attachmentManifest
        )
        let restartedManifest = try SyncAttachmentManifestStore(url: fixture.manifestURL).load()
        fixture.readerCounters.reset()
        let subsequent = try fixture.project(
            before: [fixture.replacementReference],
            after: [fixture.replacementReference],
            manifest: restartedManifest,
            issuedVersions: [fixture.replacementReference.slot: issuedVersion],
            issuedRecords: [fixture.replacementReference.slot: saved]
        )
        #expect(subsequent.mutations.isEmpty)
        #expect(fixture.readerCounters.hashedFileCount == 0)

        let issuedDeletion = try fixture.project(
            before: [fixture.replacementReference],
            after: [],
            manifest: restartedManifest,
            issuedVersions: [fixture.replacementReference.slot: issuedVersion],
            issuedRecords: [fixture.replacementReference.slot: saved]
        )
        let tombstone = try #require(issuedDeletion.mutations.single?.savedRecordVersion?.record)
        let deletedAttachment = try #require(tombstone.payload.attachment)
        #expect(tombstone.id == .init(kind: .attachment, uuid: issuedVersion.versionID))
        #expect(tombstone.deletedAt.value != nil)
        #expect(deletedAttachment == issuedVersion)
        #expect(issuedDeletion.mutations.single?.attachmentSource == nil)
    }
}

private final class AttachmentManifestFixture {
    let root: URL
    let manifestURL: URL
    let readerCounters = AttachmentReaderCounters()
    var manifest: [String: SyncAttachmentManifestEntry] = [:]

    private var references: [SyncAttachmentReference]
    private var issuedVersions: [SyncAttachmentSlot: SyncAttachmentVersion] = [:]
    private var issuedRecords: [SyncAttachmentSlot: SyncRecord] = [:]

    init(realAttachmentCount: Int) throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-attachment-manifest-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
        root = fixtureRoot
        manifestURL = fixtureRoot.appendingPathComponent("attachment-manifest.json")
        let owner = SyncEntityID(kind: .project, uuid: UUID())
        references = try (0..<realAttachmentCount).map { index in
            let filename = String(format: "attachment-%03d.bin", index)
            let url = fixtureRoot.appendingPathComponent(filename)
            try Data("fixture-\(index)".utf8).write(to: url)
            return SyncAttachmentReference(
                slot: .init(owner: owner, role: "fixture", slotID: "item:\(index)"),
                sourceURL: url,
                mediaType: "application/octet-stream",
                displayFilename: filename
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func persistWithoutAttachmentChanges() throws -> SyncPublicationProjection {
        // The first persist models the moment these attachments enter the
        // archive; later persists keep the exact same archive references.
        // This leaves the fixture honest about the projector's incremental
        // boundary and ensures it does not create versions for pre-existing
        // legacy slots.
        let before = manifest.isEmpty && issuedVersions.isEmpty ? [] : references
        return try persist(before: before, after: references)
    }

    func replaceAttachment(at index: Int) throws -> SyncPublicationProjection {
        let before = references
        let reference = references[index]
        try Data("changed-\(index)".utf8).write(to: reference.sourceURL, options: .atomic)
        return try persist(before: before, after: references)
    }

    func deleteAttachment(at index: Int) throws -> SyncPublicationProjection {
        let before = references
        let removed = references.remove(at: index)
        try FileManager.default.removeItem(at: removed.sourceURL)
        return try persist(before: before, after: references)
    }

    func replaceInodePreservingBytesSizeAndMtime(at index: Int) throws -> SyncPublicationProjection {
        let before = references
        let reference = references[index]
        var original = stat()
        #expect(reference.sourceURL.path.withCString { Darwin.lstat($0, &original) } == 0)
        let bytes = try Data(contentsOf: reference.sourceURL)
        try bytes.write(to: reference.sourceURL, options: .atomic)
        var timestamps = [original.st_atimespec, original.st_mtimespec]
        #expect(reference.sourceURL.path.withCString {
            Darwin.utimensat(AT_FDCWD, $0, &timestamps, 0)
        } == 0)
        var replaced = stat()
        #expect(reference.sourceURL.path.withCString { Darwin.lstat($0, &replaced) } == 0)
        #expect(original.st_ino != replaced.st_ino)
        return try persist(before: before, after: references)
    }

    func versionID(at index: Int) -> UUID? {
        entry(at: index)?.versionID
    }

    func entry(at index: Int) -> SyncAttachmentManifestEntry? {
        let slot = references[index].slot
        return manifest.values.first { $0.slot == slot }
    }

    private func persist(
        before: [SyncAttachmentReference],
        after: [SyncAttachmentReference]
    ) throws -> SyncPublicationProjection {
        let beforeArchive = ProjectArchive(version: 1, projects: [])
        let afterArchive = ProjectArchive(version: 2, projects: [])
        let projector = SyncPublicationProjector(
            deviceID: "manifest-fixture",
            attachmentReferences: { archive in
                archive.version == beforeArchive.version ? before : after
            },
            issuedAttachmentVersions: issuedVersions,
            issuedAttachmentRecords: issuedRecords,
            fileReader: CountingSyncRegularFileReader(counters: readerCounters)
        )
        let projection = try projector.project(
            before: beforeArchive,
            after: afterArchive,
            manifest: manifest
        )
        for mutation in projection.mutations {
            switch mutation {
            case let .save(save):
                if let attachment = save.recordVersion.record.payload.attachment {
                    issuedVersions[attachment.slot] = attachment
                    if save.recordVersion.record.deletedAt.value == nil {
                        issuedRecords[attachment.slot] = save.recordVersion.record
                    }
                }
            case let .delete(delete):
                issuedVersions = issuedVersions.filter { $0.value.versionID != delete.recordID.uuid }
                issuedRecords = issuedRecords.filter { $0.value.id != delete.recordID }
            }
        }
        manifest = projection.attachmentManifest
        return projection
    }
}

private final class LegacyAttachmentFixture {
    let root: URL
    let manifestURL: URL
    let readerCounters = AttachmentReaderCounters()
    let legacyReference: SyncAttachmentReference
    let replacementReference: SyncAttachmentReference

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-legacy-attachment-manifest-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manifestURL = root.appendingPathComponent("attachment-manifest.json")
        let owner = SyncEntityID(kind: .project, uuid: UUID())
        let slot = SyncAttachmentSlot(owner: owner, role: "project-photo", slotID: "photo")
        let legacyURL = root.appendingPathComponent("legacy-photo.jpg")
        let replacementURL = root.appendingPathComponent("replacement-photo.jpg")
        try Data("legacy-photo".utf8).write(to: legacyURL)
        try Data("replacement-photo".utf8).write(to: replacementURL)
        legacyReference = .init(
            slot: slot,
            sourceURL: legacyURL,
            mediaType: "image/jpeg",
            displayFilename: legacyURL.lastPathComponent
        )
        replacementReference = .init(
            slot: slot,
            sourceURL: replacementURL,
            mediaType: "image/jpeg",
            displayFilename: replacementURL.lastPathComponent
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func project(
        before: [SyncAttachmentReference],
        after: [SyncAttachmentReference],
        manifest: [String: SyncAttachmentManifestEntry],
        issuedVersions: [SyncAttachmentSlot: SyncAttachmentVersion],
        issuedRecords: [SyncAttachmentSlot: SyncRecord] = [:]
    ) throws -> SyncPublicationProjection {
        let beforeArchive = ProjectArchive(version: 1, projects: [])
        let afterArchive = ProjectArchive(version: 2, projects: [])
        return try SyncPublicationProjector(
            deviceID: "legacy-manifest-fixture",
            attachmentReferences: { archive in
                archive.version == beforeArchive.version ? before : after
            },
            issuedAttachmentVersions: issuedVersions,
            issuedAttachmentRecords: issuedRecords,
            fileReader: CountingSyncRegularFileReader(counters: readerCounters)
        ).project(before: beforeArchive, after: afterArchive, manifest: manifest)
    }
}

private final class AttachmentReaderCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var hashedFileCount: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }

    func reset() {
        lock.withLock { count = 0 }
    }
}

private struct CountingSyncRegularFileReader: SyncRegularFileReading {
    let counters: AttachmentReaderCounters

    func read(
        _ url: URL,
        maximumBytes: Int,
        expected: SyncRegularFileExpectation?
    ) throws -> SyncRegularFileRead {
        counters.increment()
        return try SyncRegularFileReader().read(
            url,
            maximumBytes: maximumBytes,
            expected: expected
        )
    }

    func observe(
        _ url: URL,
        declaredByteCount: Int64,
        maximumBytes: Int
    ) throws -> SyncRegularFileObservation {
        counters.increment()
        return try SyncRegularFileReader().observe(
            url,
            declaredByteCount: declaredByteCount,
            maximumBytes: maximumBytes
        )
    }
}

private extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}
