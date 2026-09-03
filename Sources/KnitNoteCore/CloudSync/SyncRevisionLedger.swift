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
        var durableWriteCount = 0
    }
    private let storage = Storage()
    var durableWriteCount: Int { storage.lock.withLock { storage.durableWriteCount } }
    fileprivate func recordDurableWrite() {
        storage.lock.withLock { storage.durableWriteCount += 1 }
    }
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
    private static let currentVersion = 1
    private static let sharedLock = NSLock()

    private struct IssuedRevision: Codable {
        let entityID: SyncEntityID
        let revision: UInt64
    }

    private struct Envelope: Codable {
        let version: Int
        let deviceID: String
        var receipts: [SyncRevisionReceipt]
        var issuedRevisions: [IssuedRevision]
    }

    private let url: URL
    private let deviceID: String
    private let counters: SyncRevisionLedgerIOCounters

    public init(url: URL, deviceID: String) {
        self.url = url
        self.deviceID = deviceID
        counters = SyncRevisionLedgerIOCounters()
    }

    init(
        url: URL,
        deviceID: String,
        counters: SyncRevisionLedgerIOCounters
    ) {
        self.url = url
        self.deviceID = deviceID
        self.counters = counters
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
        var requestByMutationID: [UUID: SyncRevisionRequest] = [:]
        for request in requests {
            if let existing = requestByMutationID[request.mutationID], existing != request {
                throw SyncRevisionLedgerError.corrupt
            }
            requestByMutationID[request.mutationID] = request
        }
        guard requestByMutationID.count == requests.count else {
            throw SyncRevisionLedgerError.corrupt
        }
        Self.sharedLock.lock()
        defer { Self.sharedLock.unlock() }

        do {
            return try SyncDurableFile.withExclusiveFileLock(for: url) {
                var state = try load()
                let original = state.receipts
                let protectedIDs = Set(requests.map(\.mutationID))
                let latestIDs = Set(Dictionary(grouping: state.receipts, by: \.entityID)
                    .compactMap { _, receipts in
                        receipts.max { $0.logicalRevision < $1.logicalRevision }?.mutationID
                    })
                state.receipts = state.receipts.filter {
                    protectedIDs.contains($0.mutationID) || latestIDs.contains($0.mutationID)
                }
                var receiptsByMutationID = Dictionary(uniqueKeysWithValues: state.receipts.map {
                    ($0.mutationID, $0)
                })
                var result: [SyncRevisionReceipt] = []
                result.reserveCapacity(requests.count)
                for request in requests {
                    if let receipt = receiptsByMutationID[request.mutationID] {
                        guard receipt.entityID == request.entityID else {
                            throw SyncRevisionLedgerError.corrupt
                        }
                        result.append(receipt)
                        continue
                    }
                    let lastIssued = state.issuedRevisions.first(where: {
                        $0.entityID == request.entityID
                    })?.revision ?? 0
                    let floor = max(lastIssued, request.observedRemoteRevision)
                    guard floor < .max else { throw SyncRevisionLedgerError.revisionExhausted }
                    let receipt = SyncRevisionReceipt(
                        entityID: request.entityID,
                        mutationID: request.mutationID,
                        logicalRevision: floor + 1,
                        deviceID: deviceID
                    )
                    state.receipts.append(receipt)
                    receiptsByMutationID[receipt.mutationID] = receipt
                    if let index = state.issuedRevisions.firstIndex(where: {
                        $0.entityID == request.entityID
                    }) {
                        state.issuedRevisions[index] = IssuedRevision(
                            entityID: request.entityID,
                            revision: receipt.logicalRevision
                        )
                    } else {
                        state.issuedRevisions.append(IssuedRevision(
                            entityID: request.entityID,
                            revision: receipt.logicalRevision
                        ))
                    }
                    result.append(receipt)
                }
                if state.receipts != original {
                    try write(state)
                    counters.recordDurableWrite()
                }
                return result
            }
        } catch let error as SyncDurableFileError {
            switch error {
            case .unsafeFile: throw SyncRevisionLedgerError.unsafeFile
            case .corrupt: throw SyncRevisionLedgerError.corrupt
            case .unavailable: throw SyncRevisionLedgerError.unavailable
            }
        }
    }

    private func load() throws -> Envelope {
        var status = stat()
        let lstatResult = url.path.withCString { Darwin.lstat($0, &status) }
        if lstatResult != 0 {
            guard errno == ENOENT else { throw SyncRevisionLedgerError.unavailable }
            return Envelope(
                version: Self.currentVersion,
                deviceID: deviceID,
                receipts: [],
                issuedRevisions: []
            )
        }
        let data: Data
        do {
            data = try SyncDurableFile.readRegularFile(at: url)
        } catch let error as SyncDurableFileError {
            switch error {
            case .unsafeFile: throw SyncRevisionLedgerError.unsafeFile
            case .corrupt: throw SyncRevisionLedgerError.corrupt
            case .unavailable: throw SyncRevisionLedgerError.unavailable
            }
        } catch {
            throw SyncRevisionLedgerError.corrupt
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard Set(envelope.issuedRevisions.map(\.entityID)).count
                    == envelope.issuedRevisions.count else {
                throw SyncRevisionLedgerError.corrupt
            }
            let greatestReceiptByEntity = Dictionary(grouping: envelope.receipts, by: \.entityID)
                .mapValues { receipts in
                    receipts.map(\.logicalRevision).max()!
                }
            let issuedRevisionByEntity = Dictionary(
                uniqueKeysWithValues: envelope.issuedRevisions.map {
                    ($0.entityID, $0.revision)
                }
            )
            guard envelope.version == Self.currentVersion,
                  envelope.deviceID == deviceID,
                  Set(envelope.receipts.map(\.mutationID)).count == envelope.receipts.count,
                  envelope.receipts.allSatisfy({ $0.deviceID == deviceID }),
                  envelope.receipts.allSatisfy({ $0.logicalRevision > 0 }),
                  envelope.issuedRevisions.allSatisfy({ $0.revision > 0 }),
                  Set(issuedRevisionByEntity.keys) == Set(greatestReceiptByEntity.keys),
                  issuedRevisionByEntity == greatestReceiptByEntity else {
                throw SyncRevisionLedgerError.corrupt
            }
            return envelope
        } catch let error as SyncRevisionLedgerError {
            throw error
        } catch {
            throw SyncRevisionLedgerError.corrupt
        }
    }

    private func write(_ envelope: Envelope) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(envelope)
        } catch {
            throw SyncRevisionLedgerError.corrupt
        }
        do {
            try SyncDurableFile.write(data, to: url)
        } catch let error as SyncDurableFileError {
            switch error {
            case .unsafeFile: throw SyncRevisionLedgerError.unsafeFile
            case .corrupt: throw SyncRevisionLedgerError.corrupt
            case .unavailable: throw SyncRevisionLedgerError.unavailable
            }
        } catch {
            throw SyncRevisionLedgerError.unavailable
        }
    }
}
