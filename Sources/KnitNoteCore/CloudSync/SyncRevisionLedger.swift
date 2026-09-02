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

public protocol SyncRevisionAllocating: Sendable {
    func allocate(
        for entityID: SyncEntityID,
        mutationID: UUID,
        observedRemoteRevision: UInt64
    ) throws -> SyncRevisionReceipt
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

    public init(url: URL, deviceID: String) {
        self.url = url
        self.deviceID = deviceID
    }

    public func allocate(
        for entityID: SyncEntityID,
        mutationID: UUID,
        observedRemoteRevision: UInt64
    ) throws -> SyncRevisionReceipt {
        Self.sharedLock.lock()
        defer { Self.sharedLock.unlock() }

        do {
            return try SyncDurableFile.withExclusiveFileLock(for: url) {
                var state = try load()
                if let receipt = state.receipts.first(where: { $0.mutationID == mutationID }) {
                    guard receipt.entityID == entityID else {
                        throw SyncRevisionLedgerError.corrupt
                    }
                    return receipt
                }
                let lastIssued = state.issuedRevisions.first(where: {
                    $0.entityID == entityID
                })?.revision ?? 0
                let floor = max(lastIssued, observedRemoteRevision)
                guard floor < .max else { throw SyncRevisionLedgerError.revisionExhausted }
                let receipt = SyncRevisionReceipt(
                    entityID: entityID,
                    mutationID: mutationID,
                    logicalRevision: floor + 1,
                    deviceID: deviceID
                )
                state.receipts.append(receipt)
                if let index = state.issuedRevisions.firstIndex(where: {
                    $0.entityID == entityID
                }) {
                    state.issuedRevisions[index] = IssuedRevision(
                        entityID: entityID,
                        revision: receipt.logicalRevision
                    )
                } else {
                    state.issuedRevisions.append(IssuedRevision(
                        entityID: entityID,
                        revision: receipt.logicalRevision
                    ))
                }
                try write(state)
                return receipt
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
            guard envelope.version == Self.currentVersion,
                  envelope.deviceID == deviceID,
                  Set(envelope.receipts.map(\.mutationID)).count == envelope.receipts.count,
                  Set(envelope.issuedRevisions.map(\.entityID)).count == envelope.issuedRevisions.count,
                  envelope.receipts.allSatisfy({ $0.deviceID == deviceID }),
                  envelope.receipts.allSatisfy({ receipt in
                      envelope.issuedRevisions.contains {
                          $0.entityID == receipt.entityID && $0.revision >= receipt.logicalRevision
                      }
                  }) else {
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
