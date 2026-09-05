import CloudKit
import Darwin
import Foundation

enum CloudSyncEngineStateStoreError: Error, Equatable {
    case corrupt
    case unsafeFile
    case unavailable
}

struct FileCloudSyncEngineStateStore: @unchecked Sendable {
    typealias BeforeWriteBoundary = @Sendable (SyncDurableFileWriteBoundary) throws -> Void

    private let file: DescriptorRelativeAtomicFile
    private let accountResetFile: DescriptorRelativeAtomicFile
    private let accountOwnerFile: DescriptorRelativeAtomicFile
    private let url: URL
    var recoveryURLs: [URL] { [url, url.appendingPathExtension("account-reset"), url.appendingPathExtension("account-owner")] }

    init(url: URL) {
        self.init(url: url, beforeWriteBoundary: { _ in })
    }

    init(url: URL, beforeWriteBoundary: @escaping BeforeWriteBoundary) {
        self.url = url
        file = DescriptorRelativeAtomicFile(url: url, beforeWriteBoundary: beforeWriteBoundary)
        accountResetFile = DescriptorRelativeAtomicFile(
            url: url.appendingPathExtension("account-reset")
        )
        accountOwnerFile = DescriptorRelativeAtomicFile(
            url: url.appendingPathExtension("account-owner")
        )
    }

    func relatedURL(pathExtension: String) -> URL {
        url.appendingPathExtension(pathExtension)
    }

    func load() throws -> CKSyncEngine.State.Serialization? {
        do {
            guard let data = try file.read() else { return nil }
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        } catch is DecodingError {
            throw CloudSyncEngineStateStoreError.corrupt
        } catch {
            throw CloudSyncEngineStateStoreError.unavailable
        }
    }

    @discardableResult
    func save(_ state: CKSyncEngine.State.Serialization) throws -> Data {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(state)
        } catch {
            throw CloudSyncEngineStateStoreError.corrupt
        }
        do {
            try file.write(data)
            return data
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        }
    }

    func clear() throws {
        do {
            try file.remove()
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        }
    }

    func beginAccountReset(previous: String?, current: String?) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try accountResetFile.write(encoder.encode(CloudSyncAccountResetMarker(
                version: 1,
                previousAccountIdentifier: previous,
                currentAccountIdentifier: current
            )))
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        } catch {
            throw CloudSyncEngineStateStoreError.corrupt
        }
    }

    func hasPendingAccountReset() throws -> Bool {
        do {
            guard let data = try accountResetFile.read() else { return false }
            let marker = try JSONDecoder().decode(CloudSyncAccountResetMarker.self, from: data)
            guard marker.version == 1 else { throw CloudSyncEngineStateStoreError.corrupt }
            return true
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        } catch let error as CloudSyncEngineStateStoreError {
            throw error
        } catch {
            throw CloudSyncEngineStateStoreError.corrupt
        }
    }

    func completeAccountReset() throws {
        do {
            try accountResetFile.remove()
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        }
    }

    func loadAccountOwner() throws -> String? {
        do {
            guard let data = try accountOwnerFile.read() else { return nil }
            let owner = try JSONDecoder().decode(CloudSyncAccountOwner.self, from: data)
            guard owner.version == 1 else { throw CloudSyncEngineStateStoreError.corrupt }
            return owner.accountIdentifier
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        } catch let error as CloudSyncEngineStateStoreError {
            throw error
        } catch {
            throw CloudSyncEngineStateStoreError.corrupt
        }
    }

    func bindAccountOwner(_ accountIdentifier: String) throws {
        if let existing = try loadAccountOwner() {
            guard existing == accountIdentifier else {
                throw CloudSyncEngineStateStoreError.corrupt
            }
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try accountOwnerFile.write(encoder.encode(CloudSyncAccountOwner(
                version: 1,
                accountIdentifier: accountIdentifier
            )))
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        } catch {
            throw CloudSyncEngineStateStoreError.corrupt
        }
    }

    func clearAccountOwner() throws {
        do {
            try accountOwnerFile.remove()
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        }
    }

    private static func map(
        _ error: DescriptorRelativeAtomicFileError
    ) -> CloudSyncEngineStateStoreError {
        switch error {
        case .corrupt: .corrupt
        case .unsafeFile: .unsafeFile
        case .unavailable: .unavailable
        }
    }
}

private struct CloudSyncAccountResetMarker: Codable {
    let version: Int
    let previousAccountIdentifier: String?
    let currentAccountIdentifier: String?
}

private struct CloudSyncAccountOwner: Codable {
    let version: Int
    let accountIdentifier: String
}

enum CloudIncomingBatchStoreError: Error, Equatable {
    case corrupt
    case unsafeFile
    case unavailable
    case capacityExceeded
}

struct CloudIncomingBatchEnvelope: Codable, Equatable, Sendable {
    let batchID: UUID
    let accountIdentifier: String
    let zoneName: String
    let ownerName: String
    var deliveryGeneration: UInt64
    var awaitingSourceRedelivery: Bool
    var acknowledged: Bool
    let records: [SyncRecord]
    let deletedRecordIDs: [SyncEntityID]
    var sourceObservedRecords: [Bool]
    var sourceObservedDeletions: [Bool]

    init(
        batchID: UUID,
        accountIdentifier: String,
        zoneName: String,
        ownerName: String,
        deliveryGeneration: UInt64,
        awaitingSourceRedelivery: Bool,
        acknowledged: Bool,
        records: [SyncRecord],
        deletedRecordIDs: [SyncEntityID],
        sourceObservedRecords: [Bool],
        sourceObservedDeletions: [Bool]
    ) {
        self.batchID = batchID
        self.accountIdentifier = accountIdentifier
        self.zoneName = zoneName
        self.ownerName = ownerName
        self.deliveryGeneration = deliveryGeneration
        self.awaitingSourceRedelivery = awaitingSourceRedelivery
        self.acknowledged = acknowledged
        self.records = records
        self.deletedRecordIDs = deletedRecordIDs
        self.sourceObservedRecords = sourceObservedRecords
        self.sourceObservedDeletions = sourceObservedDeletions
    }

    private enum CodingKeys: String, CodingKey {
        case batchID
        case accountIdentifier
        case zoneName
        case ownerName
        case deliveryGeneration
        case awaitingSourceRedelivery
        case acknowledged
        case records
        case deletedRecordIDs
        case sourceObservedRecords
        case sourceObservedDeletions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        batchID = try container.decode(UUID.self, forKey: .batchID)
        accountIdentifier = try container.decode(String.self, forKey: .accountIdentifier)
        zoneName = try container.decode(String.self, forKey: .zoneName)
        ownerName = try container.decode(String.self, forKey: .ownerName)
        deliveryGeneration = try container.decode(UInt64.self, forKey: .deliveryGeneration)
        awaitingSourceRedelivery = try container.decode(Bool.self, forKey: .awaitingSourceRedelivery)
        acknowledged = try container.decode(Bool.self, forKey: .acknowledged)
        records = try container.decode([SyncRecord].self, forKey: .records)
        deletedRecordIDs = try container.decode([SyncEntityID].self, forKey: .deletedRecordIDs)
        sourceObservedRecords = try container.decodeIfPresent(
            [Bool].self,
            forKey: .sourceObservedRecords
        ) ?? Array(repeating: !awaitingSourceRedelivery, count: records.count)
        sourceObservedDeletions = try container.decodeIfPresent(
            [Bool].self,
            forKey: .sourceObservedDeletions
        ) ?? Array(repeating: !awaitingSourceRedelivery, count: deletedRecordIDs.count)
    }

    func belongs(
        to accountIdentifier: String,
        zoneID: CKRecordZone.ID
    ) -> Bool {
        self.accountIdentifier == accountIdentifier
            && zoneName == zoneID.zoneName
            && ownerName == zoneID.ownerName
    }
}

struct CloudIncomingBatchRecordingResult: Sendable {
    let deliveredEnvelope: CloudIncomingBatchEnvelope?
    let fullyObservedBatchIDs: Set<UUID>
    let partiallyObservedBatchIDs: Set<UUID>
}

struct CloudIncomingBatchSourceObservationSnapshot: Sendable {
    struct Batch: Sendable {
        let awaitingSourceRedelivery: Bool
        let sourceObservedRecords: [Bool]
        let sourceObservedDeletions: [Bool]
    }

    let batches: [UUID: Batch]
}

/// Durable handoff between CKSyncEngine callbacks and the domain committer.
/// Entries remain until a covering engine-state update is durably installed.
struct FileCloudIncomingBatchStore: @unchecked Sendable {
    let recoveryURL: URL
    private static let version = 1
    private static let defaultMaximumBatchCount = 128
    private static let defaultMaximumEncodedBytes = 16 * 1_024 * 1_024

    private let file: DescriptorRelativeAtomicFile
    private let maximumBatchCount: Int
    private let maximumEncodedBytes: Int

    init(
        url: URL,
        maximumBatchCount: Int = Self.defaultMaximumBatchCount,
        maximumEncodedBytes: Int = Self.defaultMaximumEncodedBytes
    ) {
        recoveryURL = url
        file = DescriptorRelativeAtomicFile(url: url)
        self.maximumBatchCount = maximumBatchCount
        self.maximumEncodedBytes = maximumEncodedBytes
    }

    func beginGeneration(
        accountIdentifier: String,
        zoneID: CKRecordZone.ID,
        persistedEngineState: Data?
    ) throws -> (generation: UInt64, batches: [CloudIncomingBatchEnvelope]) {
        var store = try load()
        if let staged = store.stagedStateCommit {
            if staged.engineState == persistedEngineState {
                let covered = Set(staged.coveredBatchIDs)
                store.batches.removeAll { covered.contains($0.batchID) }
            }
            store.stagedStateCommit = nil
        }
        let scope = CloudIncomingBatchScope(
            accountIdentifier: accountIdentifier,
            zoneName: zoneID.zoneName,
            ownerName: zoneID.ownerName
        )
        let previous = store.generations.firstIndex { $0.scope == scope }
        let generation: UInt64
        if let previous {
            guard store.generations[previous].generation < UInt64.max else {
                throw CloudIncomingBatchStoreError.corrupt
            }
            generation = store.generations[previous].generation + 1
            store.generations[previous].generation = generation
        } else {
            generation = 1
            store.generations.append(.init(scope: scope, generation: generation))
        }
        for index in store.batches.indices where store.batches[index].belongs(
            to: accountIdentifier,
            zoneID: zoneID
        ) {
            store.batches[index].deliveryGeneration = generation
            store.batches[index].awaitingSourceRedelivery = true
            store.batches[index].acknowledged = false
            store.batches[index].sourceObservedRecords = Array(
                repeating: false,
                count: store.batches[index].records.count
            )
            store.batches[index].sourceObservedDeletions = Array(
                repeating: false,
                count: store.batches[index].deletedRecordIDs.count
            )
        }
        try save(store)
        return (
            generation,
            store.batches.filter { $0.belongs(to: accountIdentifier, zoneID: zoneID) }
        )
    }

    func record(
        records: [SyncRecord],
        deletedRecordIDs: [SyncEntityID],
        accountIdentifier: String,
        zoneID: CKRecordZone.ID,
        generation: UInt64,
        allowsReconciliationSpillover: Bool = false
    ) throws -> CloudIncomingBatchRecordingResult {
        var store = try load()
        var matchedRecordIndexes: Set<Int> = []
        var matchedDeletionIndexes: Set<Int> = []
        var touchedBatchIndexes: Set<Int> = []
        var unresolvedOccurrenceCountByEntity: [SyncEntityID: Int] = [:]
        for batch in store.batches where batch.belongs(
            to: accountIdentifier,
            zoneID: zoneID
        ) && batch.deliveryGeneration == generation
            && batch.awaitingSourceRedelivery {
            for index in batch.records.indices where !batch.sourceObservedRecords[index] {
                unresolvedOccurrenceCountByEntity[batch.records[index].id, default: 0] += 1
            }
            for index in batch.deletedRecordIDs.indices
            where !batch.sourceObservedDeletions[index] {
                unresolvedOccurrenceCountByEntity[batch.deletedRecordIDs[index], default: 0] += 1
            }
        }

        for (incomingIndex, record) in records.enumerated() {
            guard unresolvedOccurrenceCountByEntity[record.id] == 1 else { continue }
            for batchIndex in store.batches.indices where store.batches[batchIndex].belongs(
                to: accountIdentifier,
                zoneID: zoneID
            ) && store.batches[batchIndex].deliveryGeneration == generation
                && store.batches[batchIndex].awaitingSourceRedelivery {
                guard let recordIndex = store.batches[batchIndex].records.indices.first(where: {
                    !store.batches[batchIndex].sourceObservedRecords[$0]
                        && store.batches[batchIndex].records[$0] == record
                }) else { continue }
                store.batches[batchIndex].sourceObservedRecords[recordIndex] = true
                touchedBatchIndexes.insert(batchIndex)
                matchedRecordIndexes.insert(incomingIndex)
                break
            }
        }
        for (incomingIndex, deletedRecordID) in deletedRecordIDs.enumerated() {
            guard unresolvedOccurrenceCountByEntity[deletedRecordID] == 1 else { continue }
            for batchIndex in store.batches.indices where store.batches[batchIndex].belongs(
                to: accountIdentifier,
                zoneID: zoneID
            ) && store.batches[batchIndex].deliveryGeneration == generation
                && store.batches[batchIndex].awaitingSourceRedelivery {
                guard let deletionIndex = store.batches[batchIndex].deletedRecordIDs.indices.first(where: {
                    !store.batches[batchIndex].sourceObservedDeletions[$0]
                        && store.batches[batchIndex].deletedRecordIDs[$0] == deletedRecordID
                }) else { continue }
                store.batches[batchIndex].sourceObservedDeletions[deletionIndex] = true
                touchedBatchIndexes.insert(batchIndex)
                matchedDeletionIndexes.insert(incomingIndex)
                break
            }
        }

        // Nonidentical saves and save/delete transitions are ambiguous until
        // a successful fetch boundary. Remember that this callback touched the
        // durable entity so distinct work can spill to the encoded-byte bound,
        // but do not guess causal coverage from revision or content alone.
        let sourceEntityIDs = Set(records.map(\.id)).union(deletedRecordIDs)
        for batchIndex in store.batches.indices where store.batches[batchIndex].belongs(
            to: accountIdentifier,
            zoneID: zoneID
        ) && store.batches[batchIndex].deliveryGeneration == generation
            && store.batches[batchIndex].awaitingSourceRedelivery {
            let hasUnobservedSourceEntity = store.batches[batchIndex].records.indices.contains {
                !store.batches[batchIndex].sourceObservedRecords[$0]
                    && sourceEntityIDs.contains(store.batches[batchIndex].records[$0].id)
            } || store.batches[batchIndex].deletedRecordIDs.indices.contains {
                !store.batches[batchIndex].sourceObservedDeletions[$0]
                    && sourceEntityIDs.contains(store.batches[batchIndex].deletedRecordIDs[$0])
            }
            if hasUnobservedSourceEntity {
                touchedBatchIndexes.insert(batchIndex)
            }
        }
        if records.isEmpty, deletedRecordIDs.isEmpty,
           let emptyIndex = store.batches.indices.first(where: {
               store.batches[$0].belongs(to: accountIdentifier, zoneID: zoneID)
                   && store.batches[$0].deliveryGeneration == generation
                   && store.batches[$0].awaitingSourceRedelivery
                   && store.batches[$0].records.isEmpty
                   && store.batches[$0].deletedRecordIDs.isEmpty
           }) {
            touchedBatchIndexes.insert(emptyIndex)
        }

        var fullyObservedBatchIDs: Set<UUID> = []
        var partiallyObservedBatchIDs: Set<UUID> = []
        for batchIndex in touchedBatchIndexes {
            let isFullyObserved = store.batches[batchIndex].sourceObservedRecords.allSatisfy { $0 }
                && store.batches[batchIndex].sourceObservedDeletions.allSatisfy { $0 }
            if isFullyObserved {
                store.batches[batchIndex].awaitingSourceRedelivery = false
                fullyObservedBatchIDs.insert(store.batches[batchIndex].batchID)
            } else {
                partiallyObservedBatchIDs.insert(store.batches[batchIndex].batchID)
            }
        }

        let unmatchedRecords = records.indices.compactMap {
            matchedRecordIndexes.contains($0) ? nil : records[$0]
        }
        let unmatchedDeletedRecordIDs = deletedRecordIDs.indices.compactMap {
            matchedDeletionIndexes.contains($0) ? nil : deletedRecordIDs[$0]
        }

        guard !unmatchedRecords.isEmpty || !unmatchedDeletedRecordIDs.isEmpty
                || touchedBatchIndexes.isEmpty else {
            try save(store)
            return .init(
                deliveredEnvelope: nil,
                fullyObservedBatchIDs: fullyObservedBatchIDs,
                partiallyObservedBatchIDs: partiallyObservedBatchIDs
            )
        }
        // During reconciliation, a source callback can contain both one piece
        // of old work and new distinct work. Callback splitting is unbounded,
        // so the count limit cannot safely predict the required headroom. The
        // encoded-file byte cap remains the hard durable bound; ordinary new
        // callbacks continue to use the configured batch-count backpressure.
        guard allowsReconciliationSpillover
                || !touchedBatchIndexes.isEmpty
                || store.batches.count < maximumBatchCount else {
            throw CloudIncomingBatchStoreError.capacityExceeded
        }
        let batch = CloudIncomingBatchEnvelope(
            batchID: UUID(),
            accountIdentifier: accountIdentifier,
            zoneName: zoneID.zoneName,
            ownerName: zoneID.ownerName,
            deliveryGeneration: generation,
            awaitingSourceRedelivery: false,
            acknowledged: false,
            records: unmatchedRecords,
            deletedRecordIDs: unmatchedDeletedRecordIDs,
            sourceObservedRecords: Array(repeating: true, count: unmatchedRecords.count),
            sourceObservedDeletions: Array(repeating: true, count: unmatchedDeletedRecordIDs.count)
        )
        store.batches.append(batch)
        fullyObservedBatchIDs.insert(batch.batchID)
        try save(store)
        return .init(
            deliveredEnvelope: batch,
            fullyObservedBatchIDs: fullyObservedBatchIDs,
            partiallyObservedBatchIDs: partiallyObservedBatchIDs
        )
    }

    /// At a successful fetch boundary, the last source occurrence observed for
    /// an entity is the fetched frontier. It can therefore cover any remaining
    /// durable history for that entity without inventing an order between
    /// equal-revision records or save/delete transitions mid-fetch.
    func completeSourceObservation(
        entityIDs: Set<SyncEntityID>,
        accountIdentifier: String,
        zoneID: CKRecordZone.ID,
        generation: UInt64
    ) throws -> CloudIncomingBatchRecordingResult {
        guard !entityIDs.isEmpty else {
            return .init(
                deliveredEnvelope: nil,
                fullyObservedBatchIDs: [],
                partiallyObservedBatchIDs: []
            )
        }
        var store = try load()
        var touchedBatchIndexes: Set<Int> = []
        for batchIndex in store.batches.indices where store.batches[batchIndex].belongs(
            to: accountIdentifier,
            zoneID: zoneID
        ) && store.batches[batchIndex].deliveryGeneration == generation
            && store.batches[batchIndex].awaitingSourceRedelivery {
            for recordIndex in store.batches[batchIndex].records.indices
            where !store.batches[batchIndex].sourceObservedRecords[recordIndex]
                && entityIDs.contains(store.batches[batchIndex].records[recordIndex].id) {
                store.batches[batchIndex].sourceObservedRecords[recordIndex] = true
                touchedBatchIndexes.insert(batchIndex)
            }
            for deletionIndex in store.batches[batchIndex].deletedRecordIDs.indices
            where !store.batches[batchIndex].sourceObservedDeletions[deletionIndex]
                && entityIDs.contains(store.batches[batchIndex].deletedRecordIDs[deletionIndex]) {
                store.batches[batchIndex].sourceObservedDeletions[deletionIndex] = true
                touchedBatchIndexes.insert(batchIndex)
            }
        }
        var fullyObservedBatchIDs: Set<UUID> = []
        var partiallyObservedBatchIDs: Set<UUID> = []
        for batchIndex in touchedBatchIndexes {
            let isFullyObserved = store.batches[batchIndex].sourceObservedRecords.allSatisfy { $0 }
                && store.batches[batchIndex].sourceObservedDeletions.allSatisfy { $0 }
            if isFullyObserved {
                store.batches[batchIndex].awaitingSourceRedelivery = false
                fullyObservedBatchIDs.insert(store.batches[batchIndex].batchID)
            } else {
                partiallyObservedBatchIDs.insert(store.batches[batchIndex].batchID)
            }
        }
        if !touchedBatchIndexes.isEmpty {
            try save(store)
        }
        return .init(
            deliveredEnvelope: nil,
            fullyObservedBatchIDs: fullyObservedBatchIDs,
            partiallyObservedBatchIDs: partiallyObservedBatchIDs
        )
    }

    func sourceObservationSnapshot(
        accountIdentifier: String,
        zoneID: CKRecordZone.ID,
        generation: UInt64
    ) throws -> CloudIncomingBatchSourceObservationSnapshot {
        let store = try load()
        var batches: [UUID: CloudIncomingBatchSourceObservationSnapshot.Batch] = [:]
        for batch in store.batches where batch.belongs(
            to: accountIdentifier,
            zoneID: zoneID
        ) && batch.deliveryGeneration == generation {
            batches[batch.batchID] = .init(
                awaitingSourceRedelivery: batch.awaitingSourceRedelivery,
                sourceObservedRecords: batch.sourceObservedRecords,
                sourceObservedDeletions: batch.sourceObservedDeletions
            )
        }
        return .init(batches: batches)
    }

    func restoreSourceObservation(
        _ snapshot: CloudIncomingBatchSourceObservationSnapshot,
        accountIdentifier: String,
        zoneID: CKRecordZone.ID,
        generation: UInt64
    ) throws -> (currentBatchIDs: Set<UUID>, awaitingSourceRedeliveryBatchIDs: Set<UUID>) {
        var store = try load()
        var currentBatchIDs: Set<UUID> = []
        var awaitingSourceRedeliveryBatchIDs: Set<UUID> = []
        for index in store.batches.indices where store.batches[index].belongs(
            to: accountIdentifier,
            zoneID: zoneID
        ) && store.batches[index].deliveryGeneration == generation {
            let batchID = store.batches[index].batchID
            currentBatchIDs.insert(batchID)
            if let original = snapshot.batches[batchID] {
                guard original.sourceObservedRecords.count
                        == store.batches[index].records.count,
                      original.sourceObservedDeletions.count
                        == store.batches[index].deletedRecordIDs.count else {
                    throw CloudIncomingBatchStoreError.corrupt
                }
                store.batches[index].awaitingSourceRedelivery = original.awaitingSourceRedelivery
                store.batches[index].sourceObservedRecords = original.sourceObservedRecords
                store.batches[index].sourceObservedDeletions = original.sourceObservedDeletions
            } else {
                store.batches[index].awaitingSourceRedelivery = true
                store.batches[index].sourceObservedRecords = Array(
                    repeating: false,
                    count: store.batches[index].records.count
                )
                store.batches[index].sourceObservedDeletions = Array(
                    repeating: false,
                    count: store.batches[index].deletedRecordIDs.count
                )
            }
            if store.batches[index].awaitingSourceRedelivery {
                awaitingSourceRedeliveryBatchIDs.insert(batchID)
            }
        }
        if !currentBatchIDs.isEmpty {
            try save(store)
        }
        return (currentBatchIDs, awaitingSourceRedeliveryBatchIDs)
    }

    func acknowledge(
        _ batchID: UUID,
        accountIdentifier: String,
        zoneID: CKRecordZone.ID
    ) throws {
        var store = try load()
        guard let index = store.batches.firstIndex(where: {
            $0.batchID == batchID && $0.belongs(to: accountIdentifier, zoneID: zoneID)
        }) else {
            throw CloudSyncTransportError.unknownFetchedBatch
        }
        guard !store.batches[index].acknowledged else { return }
        store.batches[index].acknowledged = true
        try save(store)
    }

    func stageStateCommit(engineState: Data, coveredBatchIDs: Set<UUID>) throws {
        var store = try load()
        guard coveredBatchIDs.isSubset(of: Set(store.batches.map(\.batchID))) else {
            throw CloudIncomingBatchStoreError.corrupt
        }
        store.stagedStateCommit = .init(
            engineState: engineState,
            coveredBatchIDs: coveredBatchIDs.sorted { $0.uuidString < $1.uuidString }
        )
        try save(store)
    }

    func completeStateCommit(engineState: Data) throws {
        var store = try load()
        guard let staged = store.stagedStateCommit,
              staged.engineState == engineState else {
            throw CloudIncomingBatchStoreError.corrupt
        }
        let covered = Set(staged.coveredBatchIDs)
        store.batches.removeAll { covered.contains($0.batchID) }
        store.stagedStateCommit = nil
        try save(store)
    }

    /// Called only after the opaque CKSyncEngine state has been durably cleared.
    /// Any account can then safely refetch work represented by these envelopes.
    func retireAllAfterEngineStateReset() throws {
        var store = try load()
        store.batches.removeAll(keepingCapacity: false)
        store.generations.removeAll(keepingCapacity: false)
        store.stagedStateCommit = nil
        try save(store)
    }

    func containsForeignAccount(_ accountIdentifier: String) throws -> Bool {
        let store = try load()
        return store.batches.contains { $0.accountIdentifier != accountIdentifier }
            || store.generations.contains {
                $0.scope.accountIdentifier != accountIdentifier
            }
    }

    private func load() throws -> CloudIncomingBatchStoreFile {
        do {
            guard let data = try file.read(), !data.isEmpty else {
                return .init(
                    version: Self.version,
                    generations: [],
                    batches: [],
                    stagedStateCommit: nil
                )
            }
            guard data.count <= maximumEncodedBytes else {
                throw CloudIncomingBatchStoreError.capacityExceeded
            }
            let decoded = try JSONDecoder().decode(CloudIncomingBatchStoreFile.self, from: data)
            guard decoded.version == Self.version,
                  Set(decoded.batches.map(\.batchID)).count == decoded.batches.count,
                  decoded.batches.allSatisfy({
                      $0.sourceObservedRecords.count == $0.records.count
                          && $0.sourceObservedDeletions.count == $0.deletedRecordIDs.count
                  }),
                  Set(decoded.generations.map(\.scope)).count == decoded.generations.count else {
                throw CloudIncomingBatchStoreError.corrupt
            }
            return decoded
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        } catch let error as CloudIncomingBatchStoreError {
            throw error
        } catch {
            throw CloudIncomingBatchStoreError.corrupt
        }
    }

    private func save(_ store: CloudIncomingBatchStoreFile) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(store)
            let restartSafeData = try encoder.encode(worstCaseRestartProjection(of: store))
            guard data.count <= maximumEncodedBytes,
                  restartSafeData.count <= maximumEncodedBytes else {
                throw CloudIncomingBatchStoreError.capacityExceeded
            }
            try file.write(data)
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        } catch let error as CloudIncomingBatchStoreError {
            throw error
        } catch {
            throw CloudIncomingBatchStoreError.corrupt
        }
    }

    /// Observation and acknowledgement booleans use variable-width JSON tokens:
    /// `false` is one byte longer than `true`. Reserve the largest next-restart
    /// representation before admitting work so resetting durable coverage can
    /// never make an otherwise valid spool exceed its byte cap.
    private func worstCaseRestartProjection(
        of store: CloudIncomingBatchStoreFile
    ) -> CloudIncomingBatchStoreFile {
        var projection = store
        var nextGenerationByScope: [CloudIncomingBatchScope: UInt64] = [:]
        for index in projection.generations.indices {
            let current = projection.generations[index].generation
            let next = current == UInt64.max ? current : current + 1
            projection.generations[index].generation = next
            nextGenerationByScope[projection.generations[index].scope] = next
        }
        for index in projection.batches.indices {
            let scope = CloudIncomingBatchScope(
                accountIdentifier: projection.batches[index].accountIdentifier,
                zoneName: projection.batches[index].zoneName,
                ownerName: projection.batches[index].ownerName
            )
            if let nextGeneration = nextGenerationByScope[scope] {
                projection.batches[index].deliveryGeneration = nextGeneration
            }
            projection.batches[index].awaitingSourceRedelivery = true
            projection.batches[index].acknowledged = false
            projection.batches[index].sourceObservedRecords = Array(
                repeating: false,
                count: projection.batches[index].records.count
            )
            projection.batches[index].sourceObservedDeletions = Array(
                repeating: false,
                count: projection.batches[index].deletedRecordIDs.count
            )
        }
        return projection
    }

    private static func map(
        _ error: DescriptorRelativeAtomicFileError
    ) -> CloudIncomingBatchStoreError {
        switch error {
        case .corrupt: .corrupt
        case .unsafeFile: .unsafeFile
        case .unavailable: .unavailable
        }
    }
}

private struct CloudIncomingBatchStoreFile: Codable {
    let version: Int
    var generations: [CloudIncomingBatchGeneration]
    var batches: [CloudIncomingBatchEnvelope]
    var stagedStateCommit: CloudIncomingBatchStateCommit?
}

private struct CloudIncomingBatchScope: Codable, Equatable, Hashable {
    let accountIdentifier: String
    let zoneName: String
    let ownerName: String
}

private struct CloudIncomingBatchGeneration: Codable {
    let scope: CloudIncomingBatchScope
    var generation: UInt64
}

private struct CloudIncomingBatchStateCommit: Codable {
    let engineState: Data
    let coveredBatchIDs: [UUID]
}

enum DescriptorRelativeAtomicFileError: Error, Equatable {
    case corrupt
    case unsafeFile
    case unavailable
}

struct DescriptorRelativeAtomicFile: @unchecked Sendable {
    typealias BeforeWriteBoundary = @Sendable (SyncDurableFileWriteBoundary) throws -> Void

    private let parentURL: URL
    private let fileName: String
    private let beforeWriteBoundary: BeforeWriteBoundary

    init(url: URL, beforeWriteBoundary: @escaping BeforeWriteBoundary = { _ in }) {
        parentURL = url.deletingLastPathComponent()
        fileName = url.lastPathComponent
        self.beforeWriteBoundary = beforeWriteBoundary
    }

    func read() throws -> Data? {
        let parentDescriptor = try openParent(createIfMissing: false)
        guard parentDescriptor >= 0 else { return nil }
        defer { Darwin.close(parentDescriptor) }
        let descriptor = fileName.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw DescriptorRelativeAtomicFileError.unsafeFile }
            throw DescriptorRelativeAtomicFileError.unavailable
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            throw DescriptorRelativeAtomicFileError.unsafeFile
        }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw DescriptorRelativeAtomicFileError.unavailable }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              after.st_dev == status.st_dev,
              after.st_ino == status.st_ino,
              after.st_size == status.st_size,
              data.count == Int(status.st_size) else {
            throw DescriptorRelativeAtomicFileError.corrupt
        }
        return data
    }

    func write(_ data: Data) throws {
        let parentDescriptor = try openParent(createIfMissing: true)
        defer { Darwin.close(parentDescriptor) }
        let original = try destinationIdentity(parentDescriptor: parentDescriptor)
        let temporaryName = ".\(fileName).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw DescriptorRelativeAtomicFileError.unavailable }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary {
                _ = temporaryName.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) }
            }
        }
        try writeAll(data, descriptor: descriptor)
        try beforeWriteBoundary(.beforeFileSync)
        guard Darwin.fsync(descriptor) == 0 else {
            throw DescriptorRelativeAtomicFileError.unavailable
        }
        try beforeWriteBoundary(.beforeRename)
        let current = try destinationIdentity(parentDescriptor: parentDescriptor)
        guard current == original else { throw DescriptorRelativeAtomicFileError.unsafeFile }
        let renameResult = temporaryName.withCString { temporaryPath in
            fileName.withCString { destinationPath in
                Darwin.renameat(
                    parentDescriptor,
                    temporaryPath,
                    parentDescriptor,
                    destinationPath
                )
            }
        }
        guard renameResult == 0 else { throw DescriptorRelativeAtomicFileError.unavailable }
        shouldRemoveTemporary = false
        try beforeWriteBoundary(.beforeDirectorySync)
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw DescriptorRelativeAtomicFileError.unavailable
        }
    }

    func remove() throws {
        let parentDescriptor = try openParent(createIfMissing: false)
        guard parentDescriptor >= 0 else { return }
        defer { Darwin.close(parentDescriptor) }
        guard try destinationIdentity(parentDescriptor: parentDescriptor) != nil else { return }
        let result = fileName.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) }
        guard result == 0 else { throw DescriptorRelativeAtomicFileError.unavailable }
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw DescriptorRelativeAtomicFileError.unavailable
        }
    }

    private func openParent(createIfMissing: Bool) throws -> Int32 {
        guard !fileName.isEmpty, fileName != ".", fileName != ".." else {
            throw DescriptorRelativeAtomicFileError.unsafeFile
        }
        if createIfMissing {
            do {
                try FileManager.default.createDirectory(
                    at: parentURL,
                    withIntermediateDirectories: true
                )
            } catch {
                throw DescriptorRelativeAtomicFileError.unavailable
            }
        }
        let descriptor = parentURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT, !createIfMissing { return -1 }
            if errno == ELOOP { throw DescriptorRelativeAtomicFileError.unsafeFile }
            throw DescriptorRelativeAtomicFileError.unavailable
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(descriptor)
            throw DescriptorRelativeAtomicFileError.unsafeFile
        }
        return descriptor
    }

    private func destinationIdentity(parentDescriptor: Int32) throws -> FileIdentity? {
        var status = stat()
        let result = fileName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw DescriptorRelativeAtomicFileError.unavailable
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw DescriptorRelativeAtomicFileError.unsafeFile
        }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw DescriptorRelativeAtomicFileError.unavailable }
                offset += count
            }
        }
    }
}

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}
