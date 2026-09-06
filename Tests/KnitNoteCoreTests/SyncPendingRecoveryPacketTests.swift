import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncPendingRecoveryPacketTests {
    @Test func realJournalCapturesOnlyPendingExactVersionsAndStagedSourceURLs() throws {
        let f = try PacketFixture(); defer { f.remove() }
        let firstBytes = Data("version one".utf8), secondBytes = Data("version two".utf8)
        let first = try f.attachment(firstBytes)
        try f.journal.enqueue(first)
        let firstVersion = try #require(first.savedRecordVersion?.record.payload.attachment?.versionID)
        let second = try f.attachment(secondBytes, replacing: firstVersion)
        try f.journal.enqueue(second)
        let deleted = SyncMutation.delete(.init(kind: .yarn, uuid: UUID()), mutationID: UUID())
        let acknowledged = SyncMutation.delete(.init(kind: .project, uuid: UUID()), mutationID: UUID())
        try f.journal.enqueue([deleted, acknowledged])
        try f.journal.acknowledge([acknowledged.identity])
        let pending = try f.journal.pending()
        // The real journal staged ordinary mutable sources before capture.
        try FileManager.default.removeItem(at: f.source)
        let packet = try SyncPendingRecoveryPacket.capture(account: f.account, accountRoot: f.root, journal: f.journal)
        #expect(packet.mutations == pending)
        #expect(packet.files.count == 2)
        #expect(Set(packet.files.map(\.bytes)) == Set([firstBytes, secondBytes]))
        #expect(!packet.mutations.contains(where: { $0.identity == acknowledged.identity }))
        let bytes = try packet.encoded()
        let restored = try SyncPendingRecoveryPacket.decode(bytes, account: f.account, accountRoot: f.root)
        #expect(restored.mutations == pending)
        #expect(restored.files == packet.files)
        #expect(restored.mutations.compactMap(\.attachmentSource).allSatisfy { $0.isJournalStaged })
        for source in pending.compactMap(\.attachmentSource) {
            let file = try #require(restored.files.first { f.root.appendingPathComponent($0.relativePath) == source.fileURL })
            #expect(file.sha256 == source.contentSHA256)
            #expect(file.byteCount == source.byteCount)
        }
    }

    @Test func encodedLimitCountsOverheadAndDecodeRejectsWrongAccountOrRoot() throws {
        let f = try PacketFixture(); defer { f.remove() }
        try f.journal.enqueue(f.attachment(Data([1, 2, 3])))
        let before = try f.journal.pending()
        let packet = try SyncPendingRecoveryPacket.capture(account: f.account, accountRoot: f.root, journal: f.journal)
        let bytes = try packet.encoded()
        #expect(bytes.count > 3)
        #expect(throws: (any Error).self) { try packet.encoded(maximumBytes: bytes.count - 1) }
        #expect(try packet.encoded(maximumBytes: bytes.count) == bytes)
        #expect(throws: (any Error).self) {
            try SyncPendingRecoveryPacket.decode(bytes, account: f.account, accountRoot: f.root, maximumBytes: bytes.count - 1)
        }
        let other = try SyncAccountIdentity(containerIdentifier: "test.container", userRecordName: "B")
        #expect(throws: (any Error).self) { try SyncPendingRecoveryPacket.decode(bytes, account: other, accountRoot: f.root) }
        #expect(throws: (any Error).self) {
            try SyncPendingRecoveryPacket.decode(bytes, account: f.account, accountRoot: f.root.appendingPathComponent("other"))
        }
        #expect(try f.journal.pending() == before)
    }

    @Test func captureRejectsChangedEscapingOrLinkedSourceWithoutChangingJournal() throws {
        let f = try PacketFixture(); defer { f.remove() }
        try f.journal.enqueue(f.attachment(Data([1, 2, 3])))
        let pending = try f.journal.pending()
        let snapshot = PacketJournalSnapshot(mutations: pending)
        let source = try #require(pending.first?.attachmentSource)
        try Data([4, 5, 6]).write(to: source.fileURL)
        #expect(throws: (any Error).self) {
            try SyncPendingRecoveryPacket.capture(account: f.account, accountRoot: f.root, journal: snapshot)
        }
        try Data([1, 2, 3]).write(to: source.fileURL)
        let outside = f.base.appendingPathComponent("outside.asset")
        try Data([1, 2, 3]).write(to: outside)
        let escaped = try pending[0].replacingAttachmentSource(.init(fileURL: outside,
            contentSHA256: source.contentSHA256, byteCount: source.byteCount))
        #expect(throws: (any Error).self) {
            try SyncPendingRecoveryPacket.capture(account: f.account, accountRoot: f.root,
                journal: PacketJournalSnapshot(mutations: [escaped]))
        }
        try FileManager.default.removeItem(at: source.fileURL)
        try FileManager.default.createSymbolicLink(at: source.fileURL, withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try SyncPendingRecoveryPacket.capture(account: f.account, accountRoot: f.root, journal: snapshot)
        }
        #expect(try Data(contentsOf: outside) == Data([1, 2, 3]))
    }

    @Test func decodingRejectsDuplicatesMissingFilesForgedHashesAndTraversal() throws {
        let f = try PacketFixture(); defer { f.remove() }
        try f.journal.enqueue(f.attachment(Data([1, 2, 3])))
        let packet = try SyncPendingRecoveryPacket.capture(account: f.account, accountRoot: f.root, journal: f.journal)
        let object = try #require(JSONSerialization.jsonObject(with: packet.encoded()) as? [String: Any])
        for change in ["duplicateMutation", "duplicateFile", "missingFile", "hash", "count", "path", "account", "format"] {
            var changed = object
            var files = try #require(object["files"] as? [[String: Any]])
            switch change {
            case "duplicateMutation":
                let mutations = try #require(object["mutations"] as? [Any]); changed["mutations"] = mutations + mutations
            case "duplicateFile": changed["files"] = files + files
            case "missingFile": changed["files"] = []
            case "hash": files[0]["sha256"] = Data(repeating: 0, count: 32).base64EncodedString(); changed["files"] = files
            case "count": files[0]["byteCount"] = 4; changed["files"] = files
            case "path": files[0]["relativePath"] = "../outside.asset"; changed["files"] = files
            case "account": changed["accountIDHash"] = String(repeating: "0", count: 64)
            default: changed["formatVersion"] = 2
            }
            let bytes = try JSONSerialization.data(withJSONObject: changed)
            #expect(throws: (any Error).self) {
                try SyncPendingRecoveryPacket.decode(bytes, account: f.account, accountRoot: f.root)
            }
        }
    }

    @Test func aggregateLimitIsCheckedBeforeReadingAnySourceBytes() throws {
        let f = try PacketFixture(); defer { f.remove() }
        try f.journal.enqueue(f.attachment(Data([1, 2, 3])))
        let pending = try f.journal.pending()
        let valid = try SyncPendingRecoveryPacket.capture(account: f.account, accountRoot: f.root, journal: f.journal)
        let bound = try valid.encoded().count - 1
        let source = try #require(pending.first?.attachmentSource)
        try Data([9, 9, 9]).write(to: source.fileURL)
        // If capture read before aggregate preflight, this would be a hash error.
        #expect(throws: SyncPendingRecoveryPacketError.tooLarge) {
            try SyncPendingRecoveryPacket.capture(account: f.account, accountRoot: f.root,
                journal: PacketJournalSnapshot(mutations: pending), maximumBytes: bound)
        }
        #expect(try Data(contentsOf: source.fileURL) == Data([9, 9, 9]))
    }

    @Test func vaultRoundtripCanReplayExactStagedMutationIntoSameAccountJournal() throws {
        let f = try PacketFixture(); defer { f.remove() }
        try f.journal.enqueue(f.attachment(Data([1, 2, 3])))
        let pending = try f.journal.pending()
        let packet = try SyncPendingRecoveryPacket.capture(account: f.account, accountRoot: f.root, journal: f.journal)
        let vaultRoot = f.base.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        let vault = SyncRecoveryVault(directory: vaultRoot, keychain: PacketVaultKeys())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = try vault.seal(packet.encoded(), account: f.account, now: now)
        // Fixture-only replay proves existing journal enqueue accepts the exact
        // recovered sources. Production cleanup/installation belongs to Task 2.
        try FileManager.default.removeItem(at: f.root)
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let recovered = try SyncPendingRecoveryPacket.decode(vault.restore(id, account: f.account, now: now),
            account: f.account, accountRoot: f.root)
        for file in recovered.files {
            let url = f.root.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.bytes.write(to: url)
        }
        let replay = FileSyncMutationJournal(url: f.root.appendingPathComponent("pending.json"))
        try replay.enqueue(recovered.mutations)
        #expect(try replay.pending() == pending)
        #expect(try FileSyncMutationJournal(url: f.root.appendingPathComponent("pending.json")).pending() == pending)
    }

    @Test func rejectsSymlinkAncestorAndConflictingVersionForSharedSource() throws {
        let f = try PacketFixture(); defer { f.remove() }
        let original = try f.attachment(Data([1, 2, 3]))
        try f.journal.enqueue(original)
        let pending = try f.journal.pending()
        let source = try #require(pending[0].attachmentSource)
        let second = try f.attachment(Data([1, 2, 3]))
        let conflict = try second.replacingAttachmentSource(source)
        #expect(throws: (any Error).self) {
            try SyncPendingRecoveryPacket.capture(account: f.account, accountRoot: f.root,
                journal: PacketJournalSnapshot(mutations: pending + [conflict]))
        }
        let parent = source.fileURL.deletingLastPathComponent()
        let moved = f.base.appendingPathComponent("moved-attachments")
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
        #expect(throws: (any Error).self) {
            try SyncPendingRecoveryPacket.capture(account: f.account, accountRoot: f.root,
                journal: PacketJournalSnapshot(mutations: pending))
        }
        #expect(try Data(contentsOf: moved.appendingPathComponent(source.fileURL.lastPathComponent)) == Data([1, 2, 3]))
    }
}

private final class PacketVaultKeys: SyncRecoveryVaultKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: Data] = [:]
    func insert(_ key: Data, for vaultID: UUID) throws { lock.withLock { keys[vaultID] = key } }
    func key(for vaultID: UUID) throws -> Data? { lock.withLock { keys[vaultID] } }
    func remove(for vaultID: UUID) throws { _ = lock.withLock { keys.removeValue(forKey: vaultID) } }
}

private struct PacketJournalSnapshot: SyncMutationJournalProtocol {
    let mutations: [SyncMutation]
    func pending() throws -> [SyncMutation] { mutations }
    func pendingVersioned() throws -> [SyncVersionedMutation] { throw SyncConflictError.missingAuthority }
    func acknowledgeCurrentVersion(_ token: SyncMutationVersionToken) throws -> SyncVersionedAcknowledgementResult {
        throw SyncConflictError.missingAuthority
    }
    func enqueue(_ mutations: [SyncMutation]) throws { throw SyncMutationJournalError.corrupt }
    func acknowledge(_ identities: Set<SyncMutationIdentity>) throws { throw SyncMutationJournalError.corrupt }
}

private struct PacketFixture {
    let base: URL
    let root: URL
    let account = try! SyncAccountIdentity(containerIdentifier: "test.container", userRecordName: "A")
    let owner = SyncEntityID(kind: .project, uuid: UUID())
    let journal: FileSyncMutationJournal
    var source: URL { root.appendingPathComponent("mutable.asset") }
    init() throws {
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("packet-tests-" + UUID().uuidString)
        root = base.appendingPathComponent(account.accountIDHash)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        journal = FileSyncMutationJournal(url: root.appendingPathComponent("pending.json"))
    }
    func attachment(_ bytes: Data, replacing: UUID? = nil) throws -> SyncMutation {
        try bytes.write(to: source)
        let digest = Data(SHA256.hash(data: bytes))
        let version = try SyncAttachmentVersion.issuing(slot: .init(owner: owner, role: "project-photo", slotID: "primary"),
            contentSHA256: digest, byteCount: Int64(bytes.count), mediaType: "image/jpeg", displayFilename: "photo.jpg",
            replacesVersionID: replacing)
        let stamp = SyncMutationStamp(logicalRevision: 1, modifiedAt: Date(timeIntervalSince1970: 1), deviceID: "test")
        let record = SyncRecord(schemaVersion: 1, id: .init(kind: .attachment, uuid: version.versionID),
            createdAt: Date(timeIntervalSince1970: 1), entityRevision: 1,
            payload: .init(fields: [:], attachment: version), relationships: [.init(role: "owner", target: owner)],
            deletedAt: .init(value: nil, stamp: stamp))
        return try .save(recordVersion: SyncRecordVersion(record: record),
            attachmentSource: .init(fileURL: source, contentSHA256: digest, byteCount: Int64(bytes.count)), mutationID: UUID())
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
