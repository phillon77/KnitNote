import CryptoKit
import Foundation

/// A frozen, read-only recovery observation. This is neither a sealed receipt
/// nor cleanup authority. Consumers must authenticate and revalidate it before
/// implementing any subsequent destructive transition.
public struct SyncAccountRecoveryInventory: Sendable {
    public enum Error: Swift.Error, Equatable { case unsafeBinding, unresolvedRecovery, tooLarge }
    public struct Entry: Codable, Equatable, Sendable {
        public let relativePath: String
        public let isDirectory: Bool
        public let byteCount: Int64
        public let sha256: Data
        public let device: UInt64
        public let inode: UInt64
    }

    public let account: SyncAccountIdentity
    public let accountRoot: URL
    public let archiveURL: URL
    public let journalURL: URL
    public let entries: [Entry]
    public let fingerprint: Data
    public let packet: SyncPendingRecoveryPacket
    /// Valid v1 ledger envelope containing only selected groups and all pending
    /// marker authority, normalized in memory without changing the source.
    public let deletionLedger: Data?
    public let deletionFiles: [SyncPendingRecoveryPacket.File]
    public let pendingMarkerVersions: [SyncRecordVersion]

    public static func capture(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths,
                               account: SyncAccountIdentity, journal: FileSyncMutationJournal,
                               archiveURL: URL, maximumBytes: Int = 100_000_000) throws -> Self {
        guard maximumBytes >= 0, maximumBytes <= 100_000_000 else { throw Error.tooLarge }
        return try storage.withRecoveryInventory(paths: paths, account: account, maximumBytes: maximumBytes) { entries in
            let archivePath = try relative(archiveURL, root: paths.accountRoot)
            let journalPath = try relative(journal.recoveryLocation, root: paths.accountRoot)
            guard archiveURL.deletingLastPathComponent().path == paths.workingSet.path,
                  archiveURL.lastPathComponent == "projects-v1.json",
                  !reserved(journalPath), !reserved(archivePath),
                  entries.contains(where: { $0.relativePath == archivePath && !$0.isDirectory }) else { throw Error.unsafeBinding }
            try compatibilityGate(entries)
            try SyncBootstrapTransaction.validateTerminalRecovery(account: account, accountRoot: paths.accountRoot,
                liveRoot: paths.workingSet, journalURL: journal.recoveryLocation, entries: entries)
            let snapshot = try journal.recoverySnapshot(maximumBytes: maximumBytes)
            let ledgerRoot = SyncDeletionLedger.root(archiveURL: archiveURL)
            let ledgerPath = try relative(ledgerRoot, root: paths.accountRoot)
            let export: SyncDeletionLedger.RecoveryExport?
            if entries.contains(where: { $0.relativePath == ledgerPath }) {
                export = try SyncDeletionLedger.recoveryExport(archiveURL: archiveURL, pending: snapshot.mutations, maximumBytes: maximumBytes)
            } else { export = nil }

            let pendingSourcePaths = try Set(snapshot.mutations.compactMap(\.attachmentSource).map {
                try relative($0.fileURL, root: paths.accountRoot)
            })
            guard !pendingSourcePaths.contains(where: reserved) else { throw Error.unsafeBinding }
            if let export {
                let known = Set(export.knownRetainedPaths.map { ledgerPath + "/" + $0 })
                    .union([ledgerPath + "/ledger.json", ledgerPath + "/.ledger.json.lock"])
                    .union(export.terminalSources.keys.map { ledgerPath + "/" + $0 })
                    .union(pendingSourcePaths)
                guard entries.filter({ !$0.isDirectory && $0.relativePath.hasPrefix(ledgerPath + "/") })
                    .allSatisfy({ known.contains($0.relativePath) }) else { throw Error.unresolvedRecovery }
                for (path, source) in export.terminalSources {
                    if let existing = entries.first(where: { $0.relativePath == ledgerPath + "/" + path }) {
                        guard !existing.isDirectory, existing.byteCount == source.byteCount,
                              existing.sha256 == source.contentSHA256 else { throw Error.unresolvedRecovery }
                    }
                }
            }
            let placeholders = (export?.files ?? []).map { proof in
                SyncPendingRecoveryPacket.File(relativePath: ledgerPath + "/" + proof.retainedRelativePath,
                    byteCount: proof.byteCount, sha256: proof.sha256, bytes: Data())
            }
            let fingerprint = Data(SHA256.hash(data: try encoder().encode(entries)))
            let metadata = Payload(accountIDHash: account.accountIDHash, accountRoot: paths.accountRoot,
                archiveURL: archiveURL, journalURL: snapshot.url, entries: entries, fingerprint: fingerprint,
                packet: nil, deletionLedger: export?.manifest, deletionFiles: placeholders,
                pendingMarkerVersions: export?.pendingMarkerVersions ?? [])
            // The omitted packet property adds a comma plus "packet":. The
            // packet preflights its own metadata and all source Base64 expansion.
            var reservedBytes = try encoder().encode(metadata).count + 10
            for file in placeholders {
                guard file.byteCount >= 0, file.byteCount <= Int64(maximumBytes) else { throw Error.tooLarge }
                let expansion = (Int(file.byteCount) + 2) / 3 * 4
                guard expansion <= maximumBytes - min(reservedBytes, maximumBytes) else { throw Error.tooLarge }
                reservedBytes += expansion
            }
            guard reservedBytes <= maximumBytes else { throw Error.tooLarge }
            let packet = try SyncPendingRecoveryPacket.capture(account: account, accountRoot: paths.accountRoot,
                mutations: snapshot.mutations, maximumBytes: maximumBytes - reservedBytes)
            var files: [SyncPendingRecoveryPacket.File] = []
            for file in placeholders {
                guard let observed = entries.first(where: { $0.relativePath == file.relativePath }),
                      !observed.isDirectory, observed.byteCount == file.byteCount, observed.sha256 == file.sha256 else {
                    throw Error.unresolvedRecovery
                }
                let read = try SyncRegularFileReader().read(paths.accountRoot.appendingPathComponent(file.relativePath),
                    maximumBytes: Int(file.byteCount), expected: .init(byteCount: file.byteCount, sha256: file.sha256))
                guard read.device == observed.device, read.inode == observed.inode else { throw Error.unsafeBinding }
                files.append(.init(relativePath: file.relativePath, byteCount: file.byteCount, sha256: file.sha256, bytes: read.data))
            }
            let result = Self(account: account, accountRoot: paths.accountRoot, archiveURL: archiveURL,
                journalURL: snapshot.url, entries: entries, fingerprint: fingerprint, packet: packet,
                deletionLedger: export?.manifest, deletionFiles: files, pendingMarkerVersions: export?.pendingMarkerVersions ?? [])
            _ = try result.encoded(maximumBytes: maximumBytes)
            return result
        }
    }

    /// Aggregate size includes journal mutations, exact source bytes, selected
    /// ledger envelope/files, markers, account bindings and complete inventory.
    public func encoded(maximumBytes: Int = 100_000_000) throws -> Data {
        guard maximumBytes >= 0, maximumBytes <= 100_000_000 else { throw Error.tooLarge }
        let bytes = try Self.encoder().encode(Payload(accountIDHash: account.accountIDHash,
            accountRoot: accountRoot, archiveURL: archiveURL, journalURL: journalURL, entries: entries,
            fingerprint: fingerprint, packet: packet, deletionLedger: deletionLedger,
            deletionFiles: deletionFiles, pendingMarkerVersions: pendingMarkerVersions))
        guard bytes.count <= maximumBytes else { throw Error.tooLarge }
        return bytes
    }

    /// Only the transaction calls this after vault authentication. Decode still
    /// validates every binding and selected dependency; authenticated bytes alone
    /// are not permission to interpret arbitrary names as cleanup targets.
    static func decodeRecovery(_ data: Data, account: SyncAccountIdentity, paths: SyncAccountStorage.Paths,
                               journalURL: URL, maximumBytes: Int) throws -> Self {
        guard maximumBytes >= 0, maximumBytes <= 100_000_000, data.count <= maximumBytes else { throw Error.tooLarge }
        let value = try JSONDecoder().decode(Payload.self, from: data)
        guard value.accountIDHash == account.accountIDHash, value.accountRoot == paths.accountRoot,
              value.archiveURL == paths.workingSet.appendingPathComponent("projects-v1.json"),
              value.journalURL == journalURL, let packet = value.packet,
              packet.accountIDHash == account.accountIDHash, packet.accountRoot == paths.accountRoot else { throw Error.unsafeBinding }
        let archivePath = try relative(value.archiveURL, root: paths.accountRoot)
        let journalPath = try relative(value.journalURL, root: paths.accountRoot)
        guard !reserved(journalPath), !reserved(archivePath), !journalPath.hasPrefix(".decrypted-temporary/") else { throw Error.unsafeBinding }
        var indexed: [String: Entry] = [:]
        for entry in value.entries {
            let path = entry.relativePath
            guard !path.hasPrefix("/"), !path.utf8.contains(0), !path.isEmpty,
                  path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  path != "vault", !path.hasPrefix("vault/"), path != ".storage-lock",
                  path != SyncAccountStorage.recoveryControlName, !path.hasPrefix(SyncAccountStorage.recoveryControlName + "/"),
                  path != ".decrypted-temporary/.owner-v1", indexed[path] == nil,
                  entry.device > 0, entry.inode > 0, entry.byteCount >= 0,
                  entry.isDirectory ? (entry.byteCount == 0 && entry.sha256.isEmpty) : entry.sha256.count == 32 else { throw Error.unsafeBinding }
            if path.contains("/") {
                let parent = path.split(separator: "/").dropLast().joined(separator: "/")
                guard indexed[parent]?.isDirectory == true else { throw Error.unsafeBinding }
            }
            indexed[path] = entry
        }
        guard value.fingerprint == Data(SHA256.hash(data: try encoder().encode(value.entries))),
              indexed[archivePath]?.isDirectory == false,
              ["working-set", "journal", "engine-state", "staging", "quarantine", ".decrypted-temporary"].allSatisfy({ indexed[$0]?.isDirectory == true }) else { throw Error.unsafeBinding }
        try compatibilityGate(value.entries)
        var selectedPaths = Set<String>()
        for file in packet.files + value.deletionFiles {
            guard !reserved(file.relativePath), !file.relativePath.hasPrefix(".decrypted-temporary/"),
                  let observed = indexed[file.relativePath], !observed.isDirectory,
                  observed.byteCount == file.byteCount, observed.sha256 == file.sha256,
                  file.byteCount == Int64(file.bytes.count), file.sha256 == Data(SHA256.hash(data: file.bytes)) else { throw Error.unsafeBinding }
        }
        for file in value.deletionFiles {
            guard selectedPaths.insert(file.relativePath).inserted else { throw Error.unsafeBinding }
        }
        if let ledger = value.deletionLedger {
            try SyncDeletionLedger.validateRecoveryPayload(ledger, archiveURL: value.archiveURL,
                pending: packet.mutations, files: value.deletionFiles, markers: value.pendingMarkerVersions)
        } else if !value.deletionFiles.isEmpty || !value.pendingMarkerVersions.isEmpty { throw Error.unsafeBinding }
        _ = try packet.encoded(maximumBytes: maximumBytes)
        return Self(account: account, accountRoot: value.accountRoot, archiveURL: value.archiveURL,
            journalURL: value.journalURL, entries: value.entries, fingerprint: value.fingerprint, packet: packet,
            deletionLedger: value.deletionLedger, deletionFiles: value.deletionFiles, pendingMarkerVersions: value.pendingMarkerVersions)
    }

    private struct Payload: Codable {
        let accountIDHash: String
        let accountRoot: URL
        let archiveURL: URL
        let journalURL: URL
        let entries: [Entry]
        let fingerprint: Data
        let packet: SyncPendingRecoveryPacket?
        let deletionLedger: Data?
        let deletionFiles: [SyncPendingRecoveryPacket.File]
        let pendingMarkerVersions: [SyncRecordVersion]
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }
    private static func relative(_ url: URL, root: URL) throws -> String {
        guard url.isFileURL, url.query == nil, url.fragment == nil, url.host == nil || url.host == "",
              url.path.hasPrefix(root.path + "/") else { throw Error.unsafeBinding }
        let path = String(url.path.dropFirst(root.path.count + 1))
        guard !path.utf8.contains(0), path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Error.unsafeBinding }
        return path
    }
    private static func reserved(_ path: String) -> Bool {
        path == "vault" || path.hasPrefix("vault/") || path == ".storage-lock"
            || path == ".decrypted-temporary/.owner-v1" || path.hasPrefix(".KnitNote-SyncBootstrap/")
            || path == SyncAccountStorage.recoveryControlName || path.hasPrefix(SyncAccountStorage.recoveryControlName + "/")
    }
    private static func compatibilityGate(_ entries: [Entry]) throws {
        for entry in entries {
            let path = entry.relativePath
            // This fixed canonical candidate slot is unresolved even when its
            // bytes are partial or a directory occupies the reserved name.
            if path == "working-set/SyncMetadata/.canonical-next.json" {
                throw Error.unresolvedRecovery
            }
            guard !entry.isDirectory else { continue }
            if path.hasSuffix(".sync-publication.json")
                || path.hasSuffix(".transaction.json") || path.hasSuffix(".tmp") {
                throw Error.unresolvedRecovery
            }
        }
    }
}
