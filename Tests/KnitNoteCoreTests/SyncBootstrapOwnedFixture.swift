import CryptoKit
import Foundation
@testable import KnitNoteCore

enum OwnedFixtureFailure: Error { case injected }

/// Real isolated account storage; its source provenance is issued by storage.
struct OwnedBootstrapFixture {
    let source: SourceInventoryFixture
    let context: SyncBootstrapContext

    init() throws {
        source = try SourceInventoryFixture()
        context = .init(accountIDHash: source.account.accountIDHash, epoch: UUID(), freezeID: UUID())
    }

    func input() -> SyncBootstrapOwnedInput {
        .init(local: nil, sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
            remote: .init(context: context, records: [], attachments: [:], isComplete: true),
            pending: nil, counterReminderContext: .init())
    }

    func transaction(maximumBytes: Int = 100_000_000, transactionID: UUID = UUID(),
                     now: Date = Date(),
                     boundary: @escaping (SyncBootstrapOwnedBoundary) throws -> Void = { _ in },
                     io: SyncBootstrapOwnedIO = .init()) throws -> SyncBootstrapOwnedTransaction {
        try .init(storage: source.storage, paths: source.paths, account: source.account,
            context: context, maximumBytes: maximumBytes, transactionID: transactionID, now: now,
            validateContext: { candidate in
                guard candidate == context else { throw SyncBootstrapError.contextChanged }
            }, boundary: boundary, io: io)
    }

    var namespace: URL {
        let live = source.paths.workingSet.deletingLastPathComponent().standardizedFileURL
            .appendingPathComponent(source.paths.workingSet.lastPathComponent, isDirectory: true)
        let hash = Data(SHA256.hash(data: Data(live.path.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        return source.paths.accountRoot.appendingPathComponent(".KnitNote-SyncBootstrap")
            .appendingPathComponent(source.account.accountIDHash).appendingPathComponent(hash)
    }

    func remove() { source.remove() }

    func manifest() throws -> BootstrapManifestV3 {
        try BootstrapManifestV3.decodeEnvelope(Data(contentsOf: namespace.appendingPathComponent("active.json")))
    }
}

/// Isolated test vault storage, never the system Keychain.
final class OwnedBootstrapTestKeys: SyncRecoveryVaultKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Data] = [:]
    func insert(_ key: Data, for vaultID: UUID) throws {
        try lock.withLock {
            guard values[vaultID] == nil else { throw OwnedFixtureFailure.injected }
            values[vaultID] = key
        }
    }
    func key(for vaultID: UUID) throws -> Data? { lock.withLock { values[vaultID] } }
    func remove(for vaultID: UUID) throws { lock.withLock { values[vaultID] = nil } }
}
