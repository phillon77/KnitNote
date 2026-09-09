import CloudKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing

@testable import KnitNote

@MainActor final class CloudBootstrapFixture {
    let root: URL
    let account: CloudAccountBinding
    let storage: SyncAccountStorage
    let paths: SyncAccountStorage.Paths
    let context: SyncBootstrapContext
    let scope: CloudBootstrapSessionScope
    let projectID = UUID()
    var assetRoot: URL { paths.staging.appendingPathComponent("cloud-assets") }

    init(withArchive: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CloudBootstrap-" + UUID().uuidString)
        account = try CloudAccountBinding(containerIdentifier: "test.container", userRecordName: "bootstrap")
        storage = SyncAccountStorage(baseURL: root)
        if withArchive {
            paths = try storage.open(identity: account.identity)
            let archive = ProjectArchive(version: ProjectArchive.currentVersion,
                projects: [try StoredProject(id: projectID, name: "Bootstrap source")])
            try JSONEncoder().encode(archive).write(to: paths.workingSet.appendingPathComponent("projects-v1.json"))
        } else {
            paths = try storage.openForVerifiedAccount(identity: account.identity, validateAccount: {})
        }
        context = .init(accountIDHash: account.identity.accountIDHash, epoch: UUID(), freezeID: UUID())
        scope = .init(account: account, zoneID: CKRecordZone.ID(zoneName: "BootstrapTest"), context: context)
    }

    func source(_ data: Data) throws -> URL {
        let url = root.appendingPathComponent("input-" + UUID().uuidString)
        try data.write(to: url)
        return url
    }

    // Same real attachment-record construction used by AccountDomainFixture.
    func attachment(bytes: Data, replaces: UUID? = nil, role: String = "cover", byteCount: Int64? = nil) throws -> SyncRecord {
        let version = try SyncAttachmentVersion.issuing(slot: .init(owner: .init(kind: .project, uuid: projectID), role: role, slotID: "main"),
            contentSHA256: Data(SHA256.hash(data: bytes)), byteCount: byteCount ?? Int64(bytes.count),
            mediaType: "application/octet-stream", displayFilename: "display-only.bin", replacesVersionID: replaces)
        let stamp = SyncMutationStamp(logicalRevision: 1, modifiedAt: Date(timeIntervalSince1970: 10), deviceID: "attachment-device")
        return SyncRecord(schemaVersion: 1, id: .init(kind: .attachment, uuid: version.versionID), createdAt: Date(timeIntervalSince1970: 10), entityRevision: 1,
            payload: .init(fields: [:], attachment: version), relationships: [.init(role: "owner", target: version.slot.owner)], deletedAt: .init(value: nil, stamp: stamp))
    }
    func version(_ bytes: Data) throws -> SyncAttachmentVersion { try #require(attachment(bytes: bytes).payload.attachment) }

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
    func entries() throws -> [SyncAccountRecoveryInventory.Entry] {
        try storage.withRecoveryOwnership(paths: paths, account: account.identity, maximumBytes: 100_000_000) { try $0.entries() }
    }
    // Outbound pending owns its journal-staged copy; incoming pending retains
    // the immutable version resolved from the native Installed cache.
    func pending(_ record: SyncRecord, source: SyncAttachmentSource) throws -> SyncMutation {
        let mutation = try SyncMutation.save(recordVersion: .init(record: record), attachmentSource: source, mutationID: UUID())
        let journal = FileSyncMutationJournal(url: paths.mutationJournalURL)
        try journal.enqueue([mutation])
        return try #require(journal.recoverySnapshot().mutations.first)
    }
    func pendingIncoming(_ record: SyncRecord) throws -> CloudIncomingBatchEnvelope {
        let incoming = FileCloudIncomingBatchStore(url: paths.engineState.appendingPathComponent("incoming.json"))
        let generation = try incoming.beginGeneration(accountIdentifier: account.userRecordName,
            zoneID: scope.zoneID, persistedEngineState: nil).generation
        return try #require(incoming.record(records: [record], deletedRecordIDs: [],
            accountIdentifier: account.userRecordName, zoneID: scope.zoneID, generation: generation).deliveredEnvelope)
    }
    func sealedByteCount(maximumBytes: Int) throws -> Int {
        let vault = SyncRecoveryVault(directory: paths.vault, keychain: CloudBootstrapMemoryKeys())
        let transaction = SyncAccountRecoveryTransaction(storage: storage, paths: paths, account: account.identity,
            vault: vault, journal: FileSyncMutationJournal(url: paths.mutationJournalURL), maximumBytes: maximumBytes)
        let now = Date(), receipt = try transaction.seal(transaction.prepare(now: now), now: now)
        return try vault.synchronizedRecoveryPayload(receipt.vaultID, account: account.identity, now: now).count
    }
    func remove() { try? storage.close(); try? FileManager.default.removeItem(at: root) }
}

// Same memory-only key storage used by the account-transition fixtures.
private final class CloudBootstrapMemoryKeys: SyncRecoveryVaultKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: Data] = [:]
    func insert(_ key: Data, for id: UUID) throws { lock.withLock { keys[id] = key } }
    func key(for id: UUID) throws -> Data? { lock.withLock { keys[id] } }
    func remove(for id: UUID) throws { lock.withLock { keys[id] = nil } }
}
