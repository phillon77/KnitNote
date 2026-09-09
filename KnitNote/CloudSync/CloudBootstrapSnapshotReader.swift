import CloudKit
import CryptoKit
import Foundation

final class CloudBootstrapSnapshotLease: @unchecked Sendable {
    private let scope: CloudBootstrapSessionScope
    private let downloads: CloudBootstrapDownloadStore
    private let evidence: BootstrapCollectedEvidence
    private let digest: Data
    private let latch = NSLock()
    private var consumed = false
    fileprivate init(scope: CloudBootstrapSessionScope, downloads: CloudBootstrapDownloadStore, evidence: BootstrapCollectedEvidence) throws {
        self.scope = scope; self.downloads = downloads; self.evidence = evidence
        digest = try evidence.digest()
        try validate()
    }

    func withSnapshot<T>(context: SyncBootstrapContext, counterContext: SyncCounterReminderMergeContext,
        _ body: (SyncBootstrapRemoteSnapshot) throws -> T) throws -> T {
        try scope.withCurrent {
            guard context == scope.context else { throw SyncBootstrapError.contextChanged }
            try validate()
            // Physical deletes end only the remote ID's segment. Native
            // per-record reduction uses fresh context; complete graph checks
            // and legacy migration wait for owned local/remote/pending merge.
            var segments: [SyncEntityID: [SyncRecord]] = [:]
            for event in evidence.observations {
                switch event {
                case let .record(record, _): segments[record.id, default: []].append(record)
                case let .deleted(id, _, _): segments[id] = nil
                case .page: break
                }
            }
            let candidates = segments.keys.sorted { ($0.kind.rawValue, $0.uuid.uuidString) < ($1.kind.rawValue, $1.uuid.uuidString) }
                .flatMap { segments[$0] ?? [] }
            let records = try SyncMergeEngine().reduceBootstrapRemoteRecords(candidates,
                counterReminderContext: counterContext)
            var sources: [UUID: SyncAttachmentSource] = [:]
            for event in evidence.observations {
                if case let .record(record, proof?) = event { sources[record.id.uuid] = proof.source }
            }
            let snapshot = SyncBootstrapRemoteSnapshot(context: context, records: records, attachments: sources, isComplete: true)
            // The reserve covers the temporary unique map as well as retained
            // evidence. Validate the actual encoded result before the body.
            let resultBytes = try bootstrapEncode(BootstrapSnapshotMetadata(records: records, sources: sources)).count
            try evidence.requireSnapshotFits(resultBytes)
            let value = try body(snapshot)
            try validate()
            return value
        }
    }
    func consume() { latch.withLock { consumed = true } }
    private func validate() throws {
        try scope.requireCurrent()
        guard !latch.withLock({ consumed }), evidence.binding.context == scope.context,
              evidence.binding.zoneName == scope.zoneID.zoneName,
              evidence.binding.zoneOwner == scope.zoneID.ownerName,
              evidence.binding.containerIdentifier == scope.account.containerIdentifier,
              evidence.binding.userRecordName == scope.account.userRecordName,
              try evidence.digest() == digest else { throw SyncBootstrapError.contextChanged }
        for event in evidence.observations {
            if case let .record(record, proof?) = event {
                guard let version = record.payload.attachment else { throw CloudBootstrapReadError.invalidAsset }
                try downloads.revalidate(version: version, source: proof.source)
                let native = try downloads.runtimeAssets.existingBootstrapDownload(version: version)
                guard native.0 == proof.source, native.1.device == proof.device, native.1.inode == proof.inode else {
                    throw SyncBootstrapError.sourceChanged
                }
            }
        }
        try scope.requireCurrent()
        guard !latch.withLock({ consumed }) else { throw SyncBootstrapError.contextChanged }
    }
}

final class CloudBootstrapSnapshotReader: @unchecked Sendable {
    var runtimeAssets: CloudAssetStagingService { downloads.runtimeAssets }
    private let scope: CloudBootstrapSessionScope
    private let driver: any CloudBootstrapPageDriving
    private let downloads: CloudBootstrapDownloadStore
    private let lock = NSLock()
    private var used = false
    init(scope: CloudBootstrapSessionScope, driver: any CloudBootstrapPageDriving, downloads: CloudBootstrapDownloadStore) {
        self.scope = scope; self.driver = driver; self.downloads = downloads
    }
    func read() async throws -> CloudBootstrapSnapshotLease {
        guard lock.withLock({ if used { return false }; used = true; return true }) else { throw CloudBootstrapReadError.reused }
        do {
            try scope.requireCurrent()
            let collector = try BootstrapCollector(scope: scope, downloads: downloads)
            var token: CKServerChangeToken?
            for page in 1...128 {
                try Task.checkCancellation(); try scope.requireCurrent()
                let result = try await driver.fetchPage(zoneID: scope.zoneID, previousToken: token, receive: collector.receive)
                try Task.checkCancellation(); try scope.requireCurrent()
                try collector.finishPage(result)
                if !result.moreComing {
                    return try CloudBootstrapSnapshotLease(scope: scope, downloads: downloads, evidence: collector.finish())
                }
                guard page < 128 else { throw CloudBootstrapReadError.capacity }
                token = result.token
            }
            throw CloudBootstrapReadError.incomplete
        } catch {
            await cancelAndWait()
            throw error
        }
    }
    func cancelAndWait() async { scope.invalidate(); await driver.cancelAndWait() }
}

private struct BootstrapBinding: Codable {
    let requestID: UUID
    let context: SyncBootstrapContext
    let containerIdentifier: String
    let userRecordName: String
    let zoneName: String
    let zoneOwner: String
}
private enum BootstrapObservation: Codable {
    case record(SyncRecord, BootstrapAttachmentProof?)
    case deleted(SyncEntityID, recordName: String, recordType: String)
    case page(token: Data, moreComing: Bool)
}
private struct BootstrapAttachmentProof: Codable {
    let versionID: UUID
    let source: SyncAttachmentSource
    let device: UInt64
    let inode: UInt64
}
private struct BootstrapSnapshotMetadata: Encodable {
    let records: [SyncRecord]
    let sources: [UUID: SyncAttachmentSource]
}
private func bootstrapEncode<T: Encodable>(_ value: T) throws -> Data {
    // Process-only evidence may retain decode-only legacy input until owned
    // migration. This encoder is never used for ordinary record publication.
    let encoder = SyncRecordVersion.deterministicEncoder(allowingLegacyStandaloneReminder: true)
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

/// Every retained observation, deletion, token and source proof is charged by
/// actual encoded length. A second copy reserves candidate/map/result metadata;
/// no raw CKRecord, CKAsset or temporary URL survives callback admission.
struct CloudBootstrapMetadataBudget {
    private(set) var used = 0
    static let maximumBytes = 16 * 1024 * 1024
    mutating func retain(encodedBytes: Int) throws {
        guard encodedBytes >= 0 else { throw CloudBootstrapReadError.capacity }
        let (next, overflow) = used.addingReportingOverflow(encodedBytes)
        guard !overflow, next <= Self.maximumBytes else { throw CloudBootstrapReadError.capacity }
        used = next
    }
}
private struct BootstrapCollectedEvidence {
    let binding: BootstrapBinding
    let observations: [BootstrapObservation]
    let encodedBytes: Int
    func digest() throws -> Data {
        var hash = SHA256()
        hash.update(data: try bootstrapEncode(binding))
        for observation in observations { hash.update(data: try bootstrapEncode(observation)) }
        return Data(hash.finalize())
    }
    func requireSnapshotFits(_ bytes: Int) throws {
        var budget = CloudBootstrapMetadataBudget()
        try budget.retain(encodedBytes: encodedBytes)
        try budget.retain(encodedBytes: bytes)
    }
}
private final class BootstrapCollector: @unchecked Sendable {
    private let scope: CloudBootstrapSessionScope
    private let downloads: CloudBootstrapDownloadStore
    private let lock = NSLock()
    private let binding: BootstrapBinding
    private var observations: [BootstrapObservation] = []
    private var budget = CloudBootstrapMetadataBudget()
    private var encodedBytes: Int
    private var finished = false
    private var terminal = false
    init(scope: CloudBootstrapSessionScope, downloads: CloudBootstrapDownloadStore) throws {
        self.scope = scope; self.downloads = downloads
        binding = .init(requestID: UUID(), context: scope.context, containerIdentifier: scope.account.containerIdentifier,
            userRecordName: scope.account.userRecordName, zoneName: scope.zoneID.zoneName, zoneOwner: scope.zoneID.ownerName)
        encodedBytes = try bootstrapEncode(binding).count
        try budget.retain(encodedBytes: encodedBytes)
        // JSON container punctuation and the final snapshot's fixed shape.
        try budget.retain(encodedBytes: 64)
    }
    func receive(_ event: CloudBootstrapPageEvent) throws {
        try lock.withLock {
            try scope.requireCurrent()
            guard !finished, !terminal else { throw CloudBootstrapReadError.invalidCallback }
            switch event {
            case let .record(cloud):
                guard cloud.recordID.zoneID == scope.zoneID else { throw CloudBootstrapReadError.invalidCallback }
                let record = try CloudRecordCodec().decodeBootstrapRecord(cloud)
                if record.payload.attachment != nil {
                    let identity = try SyncAttachmentImmutableSnapshot(record: record).sha256
                    for event in observations {
                        if case let .record(prior, _) = event, prior.id == record.id {
                            guard try SyncAttachmentImmutableSnapshot(record: prior).sha256 == identity else {
                                throw SyncMergeError.corruptAttachmentVersion(record.id.uuid)
                            }
                        }
                    }
                }
                var proof: BootstrapAttachmentProof?
                if let version = record.payload.attachment, record.deletedAt.value == nil {
                    guard let url = (cloud["asset"] as? CKAsset)?.fileURL else { throw CloudBootstrapReadError.invalidAsset }
                    // Count the native Installed locator before performing IO;
                    // only the actual DownloadStore return grants source proof.
                    let prospective = try SyncAttachmentSource(fileURL: downloads.runtimeAssets.installedRootURL
                        .appendingPathComponent(version.versionID.uuidString.lowercased() + ".asset"),
                        contentSHA256: version.contentSHA256, byteCount: version.byteCount)
                    let prospectiveProof = BootstrapAttachmentProof(versionID: version.versionID,
                        source: prospective, device: .max, inode: .max)
                    try reserve(.record(record, prospectiveProof))
                    // The store's issued registry retains its own UUID/source/
                    // inode tuple. Charge that separate copy before accepting IO,
                    // using maximum-width native identity integers until issued.
                    let registryBytes = try bootstrapEncode(prospectiveProof).count
                    try budget.retain(encodedBytes: registryBytes)
                    encodedBytes += registryBytes
                    let source = try downloads.accept(version: version, sourceURL: url)
                    guard source == prospective else { throw SyncBootstrapError.sourceChanged }
                    let native = try downloads.runtimeAssets.existingBootstrapDownload(version: version)
                    guard native.0 == source else { throw SyncBootstrapError.sourceChanged }
                    proof = .init(versionID: version.versionID, source: source, device: native.1.device, inode: native.1.inode)
                } else {
                    try reserve(.record(record, nil))
                }
                observations.append(.record(record, proof))
            case let .deleted(id, type):
                guard id.zoneID == scope.zoneID, let kind = SyncEntityKind(rawValue: type),
                      CloudRecordCodec.recordType(for: kind) == type else { throw CloudBootstrapReadError.invalidCallback }
                let prefix = type + "-"
                guard id.recordName.hasPrefix(prefix), let uuid = UUID(uuidString: String(id.recordName.dropFirst(prefix.count))),
                      id.recordName == prefix + uuid.uuidString.lowercased() else { throw CloudRecordCodecError.recordIdentityMismatch }
                let event = BootstrapObservation.deleted(.init(kind: kind, uuid: uuid), recordName: id.recordName, recordType: type)
                try reserve(event); observations.append(event)
            }
            try scope.requireCurrent()
        }
    }
    private func reserve(_ observation: BootstrapObservation) throws {
        let count = try bootstrapEncode(observation).count
        var next = budget
        try next.retain(encodedBytes: count)
        try next.retain(encodedBytes: count)
        budget = next
        encodedBytes += count // bounded by the checked, doubled admission above
    }
    func finishPage(_ result: CloudBootstrapPageResult) throws {
        try lock.withLock {
            try scope.requireCurrent()
            guard !finished, !terminal, result.zoneID == scope.zoneID else { throw CloudBootstrapReadError.invalidCallback }
            let token = try NSKeyedArchiver.archivedData(withRootObject: result.token, requiringSecureCoding: true)
            let event = BootstrapObservation.page(token: token, moreComing: result.moreComing)
            try reserve(event); observations.append(event)
            terminal = !result.moreComing
        }
    }
    func finish() throws -> BootstrapCollectedEvidence {
        try lock.withLock {
            guard terminal, !finished else { throw CloudBootstrapReadError.incomplete }
            finished = true
            return .init(binding: binding, observations: observations, encodedBytes: encodedBytes)
        }
    }
}
