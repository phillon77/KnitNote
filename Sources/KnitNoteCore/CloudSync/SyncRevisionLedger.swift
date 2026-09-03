import CryptoKit
import Darwin
import Foundation

public enum SyncRevisionLedgerError: Error, Equatable, Sendable {
    case corrupt
    case unsafeFile
    case revisionExhausted
    case unavailable
}

public struct SyncRevisionReceipt: Codable, Equatable, Sendable {
    public let entityID: SyncEntityID
    public let mutationID: UUID
    public let logicalRevision: UInt64
    public let deviceID: String

    public init(
        entityID: SyncEntityID,
        mutationID: UUID,
        logicalRevision: UInt64,
        deviceID: String
    ) {
        self.entityID = entityID
        self.mutationID = mutationID
        self.logicalRevision = logicalRevision
        self.deviceID = deviceID
    }
}

public struct SyncRevisionRequest: Equatable, Sendable {
    public let entityID: SyncEntityID
    public let mutationID: UUID
    public let observedRemoteRevision: UInt64

    public init(
        entityID: SyncEntityID,
        mutationID: UUID,
        observedRemoteRevision: UInt64
    ) {
        self.entityID = entityID
        self.mutationID = mutationID
        self.observedRemoteRevision = observedRemoteRevision
    }
}

struct SyncRevisionLedgerIOCounters: Sendable {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var headLedgerDurableWriteCount = 0
        var receiptLookupCount = 0
        var receiptDirectoryEnumerationCount = 0
        var receiptDirectoryParentSyncCount = 0
    }

    private let storage = Storage()

    var headLedgerDurableWriteCount: Int {
        storage.lock.withLock { storage.headLedgerDurableWriteCount }
    }
    var receiptLookupCount: Int {
        storage.lock.withLock { storage.receiptLookupCount }
    }
    var receiptDirectoryEnumerationCount: Int {
        storage.lock.withLock { storage.receiptDirectoryEnumerationCount }
    }
    var receiptDirectoryParentSyncCount: Int {
        storage.lock.withLock { storage.receiptDirectoryParentSyncCount }
    }

    fileprivate func recordHeadLedgerDurableWrite() {
        storage.lock.withLock { storage.headLedgerDurableWriteCount += 1 }
    }

    fileprivate func recordReceiptLookup() {
        storage.lock.withLock { storage.receiptLookupCount += 1 }
    }

    fileprivate func recordReceiptDirectoryParentSync() {
        storage.lock.withLock { storage.receiptDirectoryParentSyncCount += 1 }
    }
}

enum SyncRevisionLedgerDurabilityBoundary: Equatable, Sendable {
    case afterMarkerSync
    case afterReceiptDirectoryCreation
    case afterReceiptFileRename(Int)
    case afterHeadLedgerSync
    case beforeMarkerRemoval
}

public protocol SyncRevisionAllocating: Sendable {
    func allocate(
        for entityID: SyncEntityID,
        mutationID: UUID,
        observedRemoteRevision: UInt64
    ) throws -> SyncRevisionReceipt

    func allocate(_ requests: [SyncRevisionRequest]) throws -> [SyncRevisionReceipt]
}

public extension SyncRevisionAllocating {
    /// Compatibility adapter for existing allocators. Durable implementations
    /// should override this entry point to commit a whole publication in one
    /// lock/write transaction, as `SyncRevisionLedger` does.
    func allocate(_ requests: [SyncRevisionRequest]) throws -> [SyncRevisionReceipt] {
        try requests.map { request in
            try allocate(
                for: request.entityID,
                mutationID: request.mutationID,
                observedRemoteRevision: request.observedRemoteRevision
            )
        }
    }
}

public final class SyncRevisionLedger: SyncRevisionAllocating, @unchecked Sendable {
    private static let headsVersion = 2
    private static let markerVersion = 1
    private static let maximumHeadsBytes = 16 * 1_024 * 1_024
    private static let maximumMarkerBytes = 16 * 1_024 * 1_024
    private static let maximumReceiptBytes = 64 * 1_024
    private static let sharedLock = NSLock()

    private struct IssuedRevision: Codable, Equatable {
        let entityID: SyncEntityID
        let revision: UInt64
    }

    private struct HeadsEnvelope: Codable {
        let version: Int
        let deviceID: String
        var issuedRevisions: [IssuedRevision]
    }

    private struct LegacyEnvelope: Codable {
        let version: Int
        let deviceID: String
        let receipts: [SyncRevisionReceipt]
        let issuedRevisions: [IssuedRevision]
    }

    private enum MarkerPurpose: String, Codable {
        case allocation
        case migration
    }

    private struct TransactionMarker: Codable {
        let version: Int
        let purpose: MarkerPurpose
        let deviceID: String
        let newReceipts: [SyncRevisionReceipt]
        let targetEntityHeads: [IssuedRevision]
        let sourceLegacyLedgerSHA256: Data?
    }

    private enum StoredLedger {
        case missing
        case legacy(LegacyEnvelope, Data)
        case heads(HeadsEnvelope)
    }

    private let url: URL
    private let deviceID: String
    private let counters: SyncRevisionLedgerIOCounters
    private let fileReader: any SyncRegularFileReading
    private let afterDurabilityBoundary: (SyncRevisionLedgerDurabilityBoundary) throws -> Void

    private var receiptsRootURL: URL {
        url.deletingPathExtension().appendingPathExtension("receipts")
    }

    private var transactionURL: URL {
        url.deletingPathExtension().appendingPathExtension("transaction.json")
    }

    public init(url: URL, deviceID: String) {
        self.url = url
        self.deviceID = deviceID
        counters = SyncRevisionLedgerIOCounters()
        fileReader = SyncRegularFileReader()
        afterDurabilityBoundary = { _ in }
    }

    init(
        url: URL,
        deviceID: String,
        counters: SyncRevisionLedgerIOCounters,
        fileReader: any SyncRegularFileReading = SyncRegularFileReader(),
        afterDurabilityBoundary: @escaping (
            SyncRevisionLedgerDurabilityBoundary
        ) throws -> Void = { _ in }
    ) {
        self.url = url
        self.deviceID = deviceID
        self.counters = counters
        self.fileReader = fileReader
        self.afterDurabilityBoundary = afterDurabilityBoundary
    }

    public func allocate(
        for entityID: SyncEntityID,
        mutationID: UUID,
        observedRemoteRevision: UInt64
    ) throws -> SyncRevisionReceipt {
        try allocate([SyncRevisionRequest(
            entityID: entityID,
            mutationID: mutationID,
            observedRemoteRevision: observedRemoteRevision
        )])[0]
    }

    public func allocate(
        _ requests: [SyncRevisionRequest]
    ) throws -> [SyncRevisionReceipt] {
        guard !requests.isEmpty else { return [] }
        try validate(requests)
        return try locked {
            if let marker = try loadMarker() {
                try replay(marker)
            }
            switch try storedLedger() {
            case .missing:
                return try allocate(
                    requests,
                    from: HeadsEnvelope(
                        version: Self.headsVersion,
                        deviceID: deviceID,
                        issuedRevisions: []
                    )
                )
            case let .heads(heads):
                return try allocate(requests, from: heads)
            case let .legacy(legacy, sourceBytes):
                return try allocateMigrating(
                    requests,
                    legacy: legacy,
                    sourceBytes: sourceBytes
                )
            }
        }
    }

    private func allocate(
        _ requests: [SyncRevisionRequest],
        from heads: HeadsEnvelope
    ) throws -> [SyncRevisionReceipt] {
        var headByEntity = Dictionary(uniqueKeysWithValues: heads.issuedRevisions.map {
            ($0.entityID, $0.revision)
        })
        let originalHeads = headByEntity
        var newReceipts: [SyncRevisionReceipt] = []
        var result: [SyncRevisionReceipt] = []
        result.reserveCapacity(requests.count)

        for request in requests {
            if let receipt = try receipt(for: request.mutationID, countLookup: true) {
                guard receipt.entityID == request.entityID else {
                    throw SyncRevisionLedgerError.corrupt
                }
                headByEntity[request.entityID] = max(
                    headByEntity[request.entityID] ?? 0,
                    receipt.logicalRevision
                )
                result.append(receipt)
                continue
            }
            let floor = max(
                headByEntity[request.entityID] ?? 0,
                request.observedRemoteRevision
            )
            guard floor < .max else { throw SyncRevisionLedgerError.revisionExhausted }
            let receipt = SyncRevisionReceipt(
                entityID: request.entityID,
                mutationID: request.mutationID,
                logicalRevision: floor + 1,
                deviceID: deviceID
            )
            headByEntity[request.entityID] = receipt.logicalRevision
            newReceipts.append(receipt)
            result.append(receipt)
        }

        let touchedEntities = Set(newReceipts.map(\.entityID)).union(
            headByEntity.compactMap { entity, revision in
                originalHeads[entity] == revision ? nil : entity
            }
        )
        guard !newReceipts.isEmpty || !touchedEntities.isEmpty else {
            return result
        }
        let marker = try validatedMarker(TransactionMarker(
            version: Self.markerVersion,
            purpose: .allocation,
            deviceID: deviceID,
            newReceipts: sorted(newReceipts),
            targetEntityHeads: sorted(touchedEntities.map {
                IssuedRevision(entityID: $0, revision: headByEntity[$0]!)
            }),
            sourceLegacyLedgerSHA256: nil
        ))
        try preflightReplay(marker, current: .heads(heads))
        try writeMarker(marker)
        try replay(marker)
        return result
    }

    private func allocateMigrating(
        _ requests: [SyncRevisionRequest],
        legacy: LegacyEnvelope,
        sourceBytes: Data
    ) throws -> [SyncRevisionReceipt] {
        var headByEntity = Dictionary(uniqueKeysWithValues: legacy.issuedRevisions.map {
            ($0.entityID, $0.revision)
        })
        let legacyByMutationID = Dictionary(uniqueKeysWithValues: legacy.receipts.map {
            ($0.mutationID, $0)
        })
        var markerReceiptByMutationID = legacyByMutationID
        var result: [SyncRevisionReceipt] = []
        result.reserveCapacity(requests.count)

        for request in requests {
            let existing: SyncRevisionReceipt?
            if let legacyReceipt = legacyByMutationID[request.mutationID] {
                existing = legacyReceipt
            } else {
                existing = try receipt(for: request.mutationID, countLookup: true)
            }
            if let existing {
                guard existing.entityID == request.entityID else {
                    throw SyncRevisionLedgerError.corrupt
                }
                markerReceiptByMutationID[existing.mutationID] = existing
                headByEntity[request.entityID] = max(
                    headByEntity[request.entityID] ?? 0,
                    existing.logicalRevision
                )
                result.append(existing)
                continue
            }
            let floor = max(
                headByEntity[request.entityID] ?? 0,
                request.observedRemoteRevision
            )
            guard floor < .max else { throw SyncRevisionLedgerError.revisionExhausted }
            let receipt = SyncRevisionReceipt(
                entityID: request.entityID,
                mutationID: request.mutationID,
                logicalRevision: floor + 1,
                deviceID: deviceID
            )
            markerReceiptByMutationID[receipt.mutationID] = receipt
            headByEntity[request.entityID] = receipt.logicalRevision
            result.append(receipt)
        }

        let marker = try validatedMarker(TransactionMarker(
            version: Self.markerVersion,
            purpose: .migration,
            deviceID: deviceID,
            newReceipts: sorted(Array(markerReceiptByMutationID.values)),
            targetEntityHeads: sorted(headByEntity.map {
                IssuedRevision(entityID: $0.key, revision: $0.value)
            }),
            sourceLegacyLedgerSHA256: Data(SHA256.hash(data: sourceBytes))
        ))
        try preflightReplay(
            marker,
            current: .legacy(legacy, sourceBytes)
        )
        try writeMarker(marker)
        try replay(marker)
        return result
    }

    /// Restores receipt authority duplicated in a durable publication marker
    /// before replaying that publication after process restart.
    func restore(_ receipts: [SyncRevisionReceipt]) throws {
        guard !receipts.isEmpty else { return }
        try locked {
            let heads = try loadRecoveringAndMigrating()
            var headByEntity = Dictionary(uniqueKeysWithValues: heads.issuedRevisions.map {
                ($0.entityID, $0.revision)
            })
            var missing: [SyncRevisionReceipt] = []
            var seen: Set<UUID> = []
            for receipt in receipts {
                guard seen.insert(receipt.mutationID).inserted else {
                    throw SyncRevisionLedgerError.corrupt
                }
                try validate(receipt)
                if let existing = try self.receipt(
                    for: receipt.mutationID,
                    countLookup: true
                ) {
                    guard existing == receipt else { throw SyncRevisionLedgerError.corrupt }
                } else {
                    missing.append(receipt)
                }
                headByEntity[receipt.entityID] = max(
                    headByEntity[receipt.entityID] ?? 0,
                    receipt.logicalRevision
                )
            }
            guard !missing.isEmpty else { return }
            let touchedEntities = Set(receipts.map(\.entityID))
            let marker = try validatedMarker(TransactionMarker(
                version: Self.markerVersion,
                purpose: .allocation,
                deviceID: deviceID,
                newReceipts: sorted(missing),
                targetEntityHeads: sorted(touchedEntities.map {
                    IssuedRevision(entityID: $0, revision: headByEntity[$0]!)
                }),
                sourceLegacyLedgerSHA256: nil
            ))
            try preflightReplay(marker, current: .heads(heads))
            try writeMarker(marker)
            try replay(marker)
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        Self.sharedLock.lock()
        defer { Self.sharedLock.unlock() }
        do {
            return try SyncDurableFile.withExclusiveFileLock(for: url, body)
        } catch let error as SyncDurableFileError {
            throw map(error)
        }
    }

    private func validate(_ requests: [SyncRevisionRequest]) throws {
        var byMutationID: [UUID: SyncRevisionRequest] = [:]
        for request in requests {
            if let existing = byMutationID[request.mutationID], existing != request {
                throw SyncRevisionLedgerError.corrupt
            }
            byMutationID[request.mutationID] = request
        }
        guard byMutationID.count == requests.count, !deviceID.isEmpty else {
            throw SyncRevisionLedgerError.corrupt
        }
    }

    private func validate(_ receipt: SyncRevisionReceipt) throws {
        guard receipt.deviceID == deviceID,
              !receipt.deviceID.isEmpty,
              receipt.logicalRevision > 0 else {
            throw SyncRevisionLedgerError.corrupt
        }
    }

    private func loadRecoveringAndMigrating() throws -> HeadsEnvelope {
        if let marker = try loadMarker() {
            try replay(marker)
        }
        switch try storedLedger() {
        case .missing:
            return HeadsEnvelope(
                version: Self.headsVersion,
                deviceID: deviceID,
                issuedRevisions: []
            )
        case let .heads(heads):
            return heads
        case let .legacy(legacy, bytes):
            try migrate(legacy, sourceBytes: bytes)
            guard case let .heads(heads) = try storedLedger() else {
                throw SyncRevisionLedgerError.corrupt
            }
            return heads
        }
    }

    private func storedLedger() throws -> StoredLedger {
        guard let data = try regularFileDataIfPresent(
            at: url,
            maximumBytes: Self.maximumHeadsBytes
        ) else { return .missing }
        let version: Int
        do {
            version = try JSONDecoder().decode(VersionProbe.self, from: data).version
        } catch {
            throw SyncRevisionLedgerError.corrupt
        }
        do {
            if version == Self.headsVersion {
                return .heads(try validatedHeads(
                    JSONDecoder().decode(HeadsEnvelope.self, from: data)
                ))
            }
            if version == 1 {
                return .legacy(try validatedLegacy(
                    JSONDecoder().decode(LegacyEnvelope.self, from: data)
                ), data)
            }
            throw SyncRevisionLedgerError.corrupt
        } catch let error as SyncRevisionLedgerError {
            throw error
        } catch {
            throw SyncRevisionLedgerError.corrupt
        }
    }

    private struct VersionProbe: Decodable { let version: Int }

    private func validatedHeads(_ envelope: HeadsEnvelope) throws -> HeadsEnvelope {
        guard envelope.version == Self.headsVersion,
              envelope.deviceID == deviceID,
              envelope.issuedRevisions == sorted(envelope.issuedRevisions),
              Set(envelope.issuedRevisions.map(\.entityID)).count
                == envelope.issuedRevisions.count,
              envelope.issuedRevisions.allSatisfy({ $0.revision > 0 }) else {
            throw SyncRevisionLedgerError.corrupt
        }
        return envelope
    }

    private func validatedLegacy(_ envelope: LegacyEnvelope) throws -> LegacyEnvelope {
        let greatestReceiptByEntity = Dictionary(grouping: envelope.receipts, by: \.entityID)
            .mapValues { $0.map(\.logicalRevision).max()! }
        var issuedRevisionByEntity: [SyncEntityID: UInt64] = [:]
        for issued in envelope.issuedRevisions {
            guard issuedRevisionByEntity.updateValue(
                issued.revision,
                forKey: issued.entityID
            ) == nil else {
                throw SyncRevisionLedgerError.corrupt
            }
        }
        guard envelope.version == 1,
              envelope.deviceID == deviceID,
              Set(envelope.receipts.map(\.mutationID)).count == envelope.receipts.count,
              Set(envelope.receipts.map {
                  "\(entitySortKey($0.entityID)):\($0.logicalRevision)"
              }).count == envelope.receipts.count,
              envelope.receipts.allSatisfy({
                  $0.deviceID == deviceID && $0.logicalRevision > 0
              }),
              Set(envelope.issuedRevisions.map(\.entityID)).count
                == envelope.issuedRevisions.count,
              envelope.issuedRevisions.allSatisfy({ $0.revision > 0 }),
              issuedRevisionByEntity == greatestReceiptByEntity else {
            throw SyncRevisionLedgerError.corrupt
        }
        return envelope
    }

    private func migrate(_ legacy: LegacyEnvelope, sourceBytes: Data) throws {
        let marker = try validatedMarker(TransactionMarker(
            version: Self.markerVersion,
            purpose: .migration,
            deviceID: deviceID,
            newReceipts: sorted(legacy.receipts),
            targetEntityHeads: sorted(legacy.issuedRevisions),
            sourceLegacyLedgerSHA256: Data(SHA256.hash(data: sourceBytes))
        ))
        try preflightReplay(marker, current: .legacy(legacy, sourceBytes))
        try writeMarker(marker)
        try replay(marker)
    }

    private func loadMarker() throws -> TransactionMarker? {
        guard let data = try regularFileDataIfPresent(
            at: transactionURL,
            maximumBytes: Self.maximumMarkerBytes
        ) else { return nil }
        do {
            return try validatedMarker(JSONDecoder().decode(
                TransactionMarker.self,
                from: data
            ))
        } catch let error as SyncRevisionLedgerError {
            throw error
        } catch {
            throw SyncRevisionLedgerError.corrupt
        }
    }

    private func validatedMarker(_ marker: TransactionMarker) throws -> TransactionMarker {
        var headsByEntity: [SyncEntityID: UInt64] = [:]
        for head in marker.targetEntityHeads {
            guard headsByEntity.updateValue(head.revision, forKey: head.entityID) == nil else {
                throw SyncRevisionLedgerError.corrupt
            }
        }
        guard marker.version == Self.markerVersion,
              marker.deviceID == deviceID,
              marker.newReceipts == sorted(marker.newReceipts),
              marker.targetEntityHeads == sorted(marker.targetEntityHeads),
              Set(marker.newReceipts.map(\.mutationID)).count
                == marker.newReceipts.count,
              Set(marker.newReceipts.map {
                  "\(entitySortKey($0.entityID)):\($0.logicalRevision)"
              }).count == marker.newReceipts.count,
              Set(marker.targetEntityHeads.map(\.entityID)).count
                == marker.targetEntityHeads.count,
              marker.newReceipts.allSatisfy({
                  $0.deviceID == deviceID && $0.logicalRevision > 0
                    && (headsByEntity[$0.entityID] ?? 0) >= $0.logicalRevision
              }),
              marker.targetEntityHeads.allSatisfy({ $0.revision > 0 }),
              marker.purpose == .migration
                ? marker.sourceLegacyLedgerSHA256?.count == SHA256.byteCount
                : marker.sourceLegacyLedgerSHA256 == nil else {
            throw SyncRevisionLedgerError.corrupt
        }
        return marker
    }

    private func writeMarker(_ marker: TransactionMarker) throws {
        let data = try encode(marker)
        guard data.count <= Self.maximumMarkerBytes else {
            throw SyncRevisionLedgerError.corrupt
        }
        try durableWrite(data, to: transactionURL)
        try afterDurabilityBoundary(.afterMarkerSync)
    }

    private struct ReplayPlan {
        let heads: HeadsEnvelope
        let headsAlreadyCommitted: Bool
    }

    @discardableResult
    private func preflightReplay(
        _ marker: TransactionMarker,
        current: StoredLedger
    ) throws -> ReplayPlan {
        _ = try validatedMarker(marker)
        let plan: ReplayPlan
        let requireExistingReceipts: Bool
        switch current {
        case .missing:
            guard marker.purpose == .allocation else {
                throw SyncRevisionLedgerError.corrupt
            }
            plan = try allocationReplayPlan(marker, currentHeads: [])
            requireExistingReceipts = false
        case let .heads(heads):
            if marker.purpose == .migration {
                guard heads.issuedRevisions == marker.targetEntityHeads else {
                    throw SyncRevisionLedgerError.corrupt
                }
                plan = ReplayPlan(heads: heads, headsAlreadyCommitted: true)
                requireExistingReceipts = true
            } else {
                plan = try allocationReplayPlan(
                    marker,
                    currentHeads: heads.issuedRevisions
                )
                requireExistingReceipts = false
            }
        case let .legacy(legacy, sourceBytes):
            guard marker.purpose == .migration else {
                throw SyncRevisionLedgerError.corrupt
            }
            let canonicalHeads = try canonicalMigrationHeads(
                marker,
                legacy: legacy,
                sourceBytes: sourceBytes
            )
            plan = ReplayPlan(
                heads: HeadsEnvelope(
                    version: Self.headsVersion,
                    deviceID: deviceID,
                    issuedRevisions: canonicalHeads
                ),
                headsAlreadyCommitted: false
            )
            requireExistingReceipts = false
        }
        guard try encode(plan.heads).count <= Self.maximumHeadsBytes else {
            throw SyncRevisionLedgerError.corrupt
        }
        try preflightReceiptDestinations(
            marker.newReceipts,
            requireExisting: requireExistingReceipts
        )
        return plan
    }

    private func allocationReplayPlan(
        _ marker: TransactionMarker,
        currentHeads: [IssuedRevision]
    ) throws -> ReplayPlan {
        var headByEntity = Dictionary(uniqueKeysWithValues: currentHeads.map {
            ($0.entityID, $0.revision)
        })
        for target in marker.targetEntityHeads {
            guard (headByEntity[target.entityID] ?? 0) <= target.revision else {
                throw SyncRevisionLedgerError.corrupt
            }
            headByEntity[target.entityID] = target.revision
        }
        return ReplayPlan(
            heads: try validatedHeads(HeadsEnvelope(
                version: Self.headsVersion,
                deviceID: deviceID,
                issuedRevisions: sorted(headByEntity.map {
                    IssuedRevision(entityID: $0.key, revision: $0.value)
                })
            )),
            headsAlreadyCommitted: false
        )
    }

    private func canonicalMigrationHeads(
        _ marker: TransactionMarker,
        legacy: LegacyEnvelope,
        sourceBytes: Data
    ) throws -> [IssuedRevision] {
        guard marker.sourceLegacyLedgerSHA256 == Data(SHA256.hash(data: sourceBytes)) else {
            throw SyncRevisionLedgerError.corrupt
        }
        let legacyByMutationID = Dictionary(uniqueKeysWithValues: legacy.receipts.map {
            ($0.mutationID, $0)
        })
        let markerByMutationID = Dictionary(uniqueKeysWithValues: marker.newReceipts.map {
            ($0.mutationID, $0)
        })
        guard legacyByMutationID.allSatisfy({ markerByMutationID[$0.key] == $0.value }) else {
            throw SyncRevisionLedgerError.corrupt
        }
        let legacyHeadByEntity = Dictionary(uniqueKeysWithValues: legacy.issuedRevisions.map {
            ($0.entityID, $0.revision)
        })
        var canonicalHeadByEntity = legacyHeadByEntity
        for receipt in marker.newReceipts where legacyByMutationID[receipt.mutationID] == nil {
            guard receipt.logicalRevision > (legacyHeadByEntity[receipt.entityID] ?? 0) else {
                throw SyncRevisionLedgerError.corrupt
            }
            canonicalHeadByEntity[receipt.entityID] = max(
                canonicalHeadByEntity[receipt.entityID] ?? 0,
                receipt.logicalRevision
            )
        }
        let canonicalHeads = sorted(canonicalHeadByEntity.map {
            IssuedRevision(entityID: $0.key, revision: $0.value)
        })
        guard marker.targetEntityHeads == canonicalHeads else {
            throw SyncRevisionLedgerError.corrupt
        }
        return canonicalHeads
    }

    private func replay(_ marker: TransactionMarker) throws {
        let plan = try preflightReplay(marker, current: storedLedger())
        try ensureReceiptDirectories(for: marker.newReceipts)
        for (index, receipt) in marker.newReceipts.enumerated() {
            try install(receipt, index: index)
        }
        if !plan.headsAlreadyCommitted {
            let data = try encode(plan.heads)
            guard data.count <= Self.maximumHeadsBytes else {
                throw SyncRevisionLedgerError.corrupt
            }
            try durableWrite(data, to: url)
            counters.recordHeadLedgerDurableWrite()
            try afterDurabilityBoundary(.afterHeadLedgerSync)
        }
        try afterDurabilityBoundary(.beforeMarkerRemoval)
        do {
            try SyncDurableFile.removeRegularFile(at: transactionURL)
        } catch let error as SyncDurableFileError {
            throw map(error)
        }
    }

    private func receipt(
        for mutationID: UUID,
        countLookup: Bool
    ) throws -> SyncRevisionReceipt? {
        if countLookup { counters.recordReceiptLookup() }
        let fileURL = receiptURL(for: mutationID)
        guard let data = try regularFileDataIfPresent(
            at: fileURL,
            maximumBytes: Self.maximumReceiptBytes
        ) else { return nil }
        do {
            let receipt = try JSONDecoder().decode(SyncRevisionReceipt.self, from: data)
            try validate(receipt)
            guard receipt.mutationID == mutationID,
                  data == (try encode(receipt)) else {
                throw SyncRevisionLedgerError.corrupt
            }
            return receipt
        } catch let error as SyncRevisionLedgerError {
            throw error
        } catch {
            throw SyncRevisionLedgerError.corrupt
        }
    }

    private func preflightReceiptDestinations(
        _ receipts: [SyncRevisionReceipt],
        requireExisting: Bool
    ) throws {
        guard !receipts.isEmpty else { return }
        for receipt in receipts {
            guard try encode(receipt).count <= Self.maximumReceiptBytes else {
                throw SyncRevisionLedgerError.corrupt
            }
        }
        try validateDirectoryIfPresent(receiptsRootURL)
        for shardURL in receiptShardURLs(for: receipts) {
            try validateDirectoryIfPresent(shardURL)
        }
        for proposed in receipts {
            let existing = try receipt(for: proposed.mutationID, countLookup: false)
            guard existing == nil || existing == proposed else {
                throw SyncRevisionLedgerError.corrupt
            }
            if requireExisting, existing == nil {
                throw SyncRevisionLedgerError.corrupt
            }
        }
    }

    private func ensureReceiptDirectories(for receipts: [SyncRevisionReceipt]) throws {
        guard !receipts.isEmpty else { return }
        try ensureDirectory(receiptsRootURL)
        for shardURL in receiptShardURLs(for: receipts) {
            try ensureDirectory(shardURL)
        }
    }

    private func receiptShardURLs(for receipts: [SyncRevisionReceipt]) -> [URL] {
        Array(Set(receipts.map {
            receiptURL(for: $0.mutationID).deletingLastPathComponent()
        })).sorted { $0.path < $1.path }
    }

    private func validateDirectoryIfPresent(_ directory: URL) throws {
        var status = stat()
        let result = directory.path.withCString { Darwin.lstat($0, &status) }
        if result != 0 {
            guard errno == ENOENT else { throw SyncRevisionLedgerError.unavailable }
            return
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            throw SyncRevisionLedgerError.unsafeFile
        }
    }

    private func install(_ receipt: SyncRevisionReceipt, index: Int) throws {
        try validate(receipt)
        let data = try encode(receipt)
        guard data.count <= Self.maximumReceiptBytes else {
            throw SyncRevisionLedgerError.corrupt
        }
        let fileURL = receiptURL(for: receipt.mutationID)
        do {
            if try SyncDurableFile.createNoClobber(
                data,
                at: fileURL,
                afterRename: {
                    try afterDurabilityBoundary(.afterReceiptFileRename(index))
                }
            ) {
                return
            }
            guard try regularFileDataIfPresent(
                at: fileURL,
                maximumBytes: Self.maximumReceiptBytes
            ) == data else {
                throw SyncRevisionLedgerError.corrupt
            }
            // A previous attempt may have installed the name and failed before
            // syncing its directory. Re-syncing makes recovery idempotent and
            // closes that uncertain durability window before heads advance.
            try SyncDurableFile.synchronizeDirectory(
                fileURL.deletingLastPathComponent()
            )
        } catch let error as SyncRevisionLedgerError {
            throw error
        } catch let error as SyncDurableFileError {
            throw map(error)
        }
    }

    private func receiptURL(for mutationID: UUID) -> URL {
        let hex = mutationID.uuidString.lowercased()
        return receiptsRootURL
            .appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(hex).json")
    }

    private func ensureDirectory(_ directory: URL) throws {
        var status = stat()
        let result = directory.path.withCString { Darwin.lstat($0, &status) }
        if result != 0 {
            guard errno == ENOENT else { throw SyncRevisionLedgerError.unavailable }
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false
                )
            } catch {
                throw SyncRevisionLedgerError.unavailable
            }
            try afterDurabilityBoundary(.afterReceiptDirectoryCreation)
            guard directory.path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
                throw SyncRevisionLedgerError.unavailable
            }
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            throw SyncRevisionLedgerError.unsafeFile
        }
        do {
            try SyncDurableFile.synchronizeDirectory(
                directory.deletingLastPathComponent()
            )
            counters.recordReceiptDirectoryParentSync()
        } catch let error as SyncDurableFileError {
            throw map(error)
        }
    }

    private func regularFileDataIfPresent(
        at fileURL: URL,
        maximumBytes: Int
    ) throws -> Data? {
        var status = stat()
        let result = fileURL.path.withCString { Darwin.lstat($0, &status) }
        if result != 0 {
            guard errno == ENOENT else { throw SyncRevisionLedgerError.unavailable }
            return nil
        }
        do {
            return try fileReader.read(
                fileURL,
                maximumBytes: maximumBytes,
                expected: nil
            ).data
        } catch let error as SyncRegularFileReadError {
            switch error {
            case .unsafeFile, .replaced:
                throw SyncRevisionLedgerError.unsafeFile
            case .unavailable:
                throw SyncRevisionLedgerError.unavailable
            case .tooLarge, .changed, .expectationMismatch:
                throw SyncRevisionLedgerError.corrupt
            }
        }
    }

    private func durableWrite(_ data: Data, to fileURL: URL) throws {
        do {
            try SyncDurableFile.write(data, to: fileURL)
        } catch let error as SyncDurableFileError {
            throw map(error)
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        } catch {
            throw SyncRevisionLedgerError.corrupt
        }
    }

    private func sorted(_ receipts: [SyncRevisionReceipt]) -> [SyncRevisionReceipt] {
        receipts.sorted { $0.mutationID.uuidString < $1.mutationID.uuidString }
    }

    private func sorted(_ heads: [IssuedRevision]) -> [IssuedRevision] {
        heads.sorted { entitySortKey($0.entityID) < entitySortKey($1.entityID) }
    }

    private func entitySortKey(_ entityID: SyncEntityID) -> String {
        "\(entityID.kind.rawValue):\(entityID.uuid.uuidString)"
    }

    private func map(_ error: SyncDurableFileError) -> SyncRevisionLedgerError {
        switch error {
        case .unsafeFile: .unsafeFile
        case .corrupt: .corrupt
        case .unavailable: .unavailable
        }
    }
}
