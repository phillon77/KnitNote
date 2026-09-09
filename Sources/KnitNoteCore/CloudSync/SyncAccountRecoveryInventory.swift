import CryptoKit
import Darwin
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
    let sourceAuthority: SyncAccountRecoverySourceAuthority?
    var bootstrapEvidence: BootstrapEvidence? = nil

    /// Exact owned terminal/history bytes. Capture validates physical evidence;
    /// decoding accepts them only through the authenticated terminal validator.
    struct BootstrapEvidence: Codable, Sendable {
        let activeEnvelope: Data
        let historyRecords: [Data]
    }

    /// Uses the actual payload codec while keeping future selected file bytes
    /// unallocated. This count is not a decodable inventory or source authority.
    func projectedEncodedByteCount(entries: [Entry], packetByteCount: Int,
        deletionFiles: [SyncPendingRecoveryPacket.File],
        sourceAuthority: SyncAccountRecoverySourceAuthority?, bootstrapEvidence: BootstrapEvidence?,
        deletionLedgerBytes: Data? = nil, markers: [SyncRecordVersion]? = nil,
        futureActiveEnvelopeByteCount: Int? = nil, futureRollbackEnvelopeByteCount: Int? = nil,
        futureHistoryRecordByteCounts: [Int] = []) throws -> Int {
        guard (0...100_000_000).contains(packetByteCount),
              bootstrapEvidence == nil || sourceAuthority != nil else { throw Error.tooLarge }
        let placeholders = deletionFiles.map {
            SyncPendingRecoveryPacket.File(relativePath: $0.relativePath, byteCount: $0.byteCount,
                sha256: $0.sha256, bytes: Data())
        }
        let payload = Payload(accountIDHash: account.accountIDHash, accountRoot: accountRoot,
            archiveURL: archiveURL, journalURL: journalURL, entries: entries,
            fingerprint: try Self.fingerprint(entries, authority: sourceAuthority), packet: nil,
            deletionLedger: deletionLedgerBytes ?? deletionLedger, deletionFiles: placeholders,
            pendingMarkerVersions: markers ?? pendingMarkerVersions)
        var count = try Self.encodePayload(payload, authority: sourceAuthority,
            bootstrapEvidence: bootstrapEvidence).count
        count = try SyncBootstrapRecoveryBudget.add(count, 10, packetByteCount)
        for file in placeholders {
            count = try SyncBootstrapRecoveryBudget.add(count, Self.base64Count(file.byteCount))
        }
        for value in [futureActiveEnvelopeByteCount, futureRollbackEnvelopeByteCount].compactMap({ $0 })
            + futureHistoryRecordByteCounts {
            count = try SyncBootstrapRecoveryBudget.add(count, SyncBootstrapRecoveryBudget.base64Bytes(value))
        }
        return count
    }

    public static func capture(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths,
                               account: SyncAccountIdentity, journal: FileSyncMutationJournal,
                               archiveURL: URL, maximumBytes: Int = 100_000_000) throws -> Self {
        guard maximumBytes >= 0, maximumBytes <= 100_000_000 else { throw Error.tooLarge }
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            let control = try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access)
            return try capture(access: access, paths: paths, account: account, journal: journal,
                archiveURL: archiveURL, control: control, maximumBytes: maximumBytes)
        }
    }

    /// Caller already owns storage and the producer freeze. maximumBytes is the
    /// complete raw inventory allowance after the transaction's outer preflight.
    static func capture(access: SyncAccountStorage.RecoveryAccess, paths: SyncAccountStorage.Paths,
                        account: SyncAccountIdentity, journal: FileSyncMutationJournal, archiveURL: URL,
                        control: SyncAccountControlObservation, maximumBytes: Int) throws -> Self {
        guard maximumBytes >= 0, maximumBytes <= 100_000_000 else { throw Error.tooLarge }
        let observer = SyncAccountRecoveryControlFile(synchronize: { _ in })
        guard try observer.observe(access: access) == control else { throw Error.unsafeBinding }
        let entries = try access.entries()
        let archivePath = try relative(archiveURL, root: paths.accountRoot)
        let journalPath = try relative(journal.recoveryLocation, root: paths.accountRoot)
        guard archiveURL.deletingLastPathComponent().path == paths.workingSet.path,
              archiveURL.lastPathComponent == "projects-v1.json",
              !reserved(journalPath), !reserved(archivePath) else { throw Error.unsafeBinding }
        let owned = try SyncBootstrapOwnedTerminalEvidence.read(account: account, accountRoot: paths.accountRoot,
            liveRoot: paths.workingSet, journalURL: journal.recoveryLocation, entries: entries, maximumBytes: maximumBytes) { path in
                guard let entry = entries.first(where: { $0.relativePath == path && !$0.isDirectory }) else { throw Error.unsafeBinding }
                let value = try SyncRegularFileReader().read(paths.accountRoot.appendingPathComponent(path),
                    maximumBytes: min(maximumBytes, Int(entry.byteCount)), expected: .init(byteCount: entry.byteCount, sha256: entry.sha256))
                guard value.device == entry.device, value.inode == entry.inode else { throw Error.unsafeBinding }
                return value.data
            }
        let bootstrap = owned.map { BootstrapEvidence(activeEnvelope: $0.activeEnvelope, historyRecords: $0.historyRecords) }
        if let owned {
            func readOriginal(_ path: String) throws -> Data? {
                guard let entry = entries.first(where: { $0.relativePath == path && !$0.isDirectory }) else { return nil }
                let value = try SyncRegularFileReader().read(paths.accountRoot.appendingPathComponent(path),
                    maximumBytes: min(maximumBytes, Int(entry.byteCount)), expected: .init(byteCount: entry.byteCount, sha256: entry.sha256))
                guard value.device == entry.device, value.inode == entry.inode else { throw Error.unsafeBinding }
                return value.data
            }
            if case .committed = owned.manifest.body {
                try SyncBootstrapOwnedTransaction.validateCommitPrefix(owned.manifest, at: "working-set", entries: entries,
                    complete: true, read: readOriginal)
                guard let archive = try readOriginal(archivePath) else { throw Error.unsafeBinding }
                _ = try JSONDecoder().decode(ProjectArchive.self, from: archive)
            }
            for terminal in [owned.activeEnvelope] + (try owned.historyRecords.map { try BootstrapHistoryRecordV1.decodeEnvelope($0).terminalEnvelope }) {
                struct Version: Decodable { let version: Int }
                if try JSONDecoder().decode(Version.self, from: OwnedBootstrapCodec.envelopePayload(terminal)).version == 3 {
                    let manifest = try BootstrapManifestV3.decodeEnvelope(terminal)
                    if case .rolledBack = manifest.body {
                        let failed = manifest.transactionRelativePath + "/Failed"
                        if entries.contains(where: { $0.relativePath == failed }) {
                            try SyncBootstrapOwnedTransaction.validateCommitPrefix(manifest, at: failed, entries: entries,
                                complete: false, read: readOriginal)
                        }
                    }
                }
            }
        }
        try compatibilityGate(entries.filter { !(owned?.abandonedEntries.contains($0) ?? false) })
        let dependencies = try captureSourceDependencies(paths: paths, journal: journal, archiveURL: archiveURL,
            entries: entries, maximumBytes: maximumBytes)
        let snapshot = dependencies.snapshot, export = dependencies.export
        let placeholders = dependencies.placeholders, baseline = dependencies.baseline
        let authority: SyncAccountRecoverySourceAuthority?
        let archivePresent = entries.contains { $0.relativePath == archivePath && !$0.isDirectory }
        if let owned, case .committed = owned.manifest.body {
            guard let archive = entries.first(where: { $0.relativePath == archivePath && !$0.isDirectory }) else { throw Error.unsafeBinding }
            try validateOwnedControl(control, terminal: owned, account: account, paths: paths)
            authority = .archive(relativePath: archivePath, sha256: archive.sha256)
        } else if let owned, case .archive = owned.manifest.sourceProof, archivePresent {
            try validateOwnedControl(control, terminal: owned, account: account, paths: paths)
            guard let archive = entries.first(where: { $0.relativePath == archivePath && !$0.isDirectory }) else { throw Error.unsafeBinding }
            authority = .archive(relativePath: archivePath, sha256: archive.sha256)
        } else if control.mainBytes == nil, control.nextBytes == nil, archivePresent {
            try SyncBootstrapTransaction.validateTerminalRecovery(account: account, accountRoot: paths.accountRoot,
                liveRoot: paths.workingSet, journalURL: snapshot.url, entries: entries)
            authority = nil
        } else {
            try requireAbsent(entries, archivePath: archivePath)
            guard snapshot.url == paths.mutationJournalURL else { throw Error.unsafeBinding }
            // This cheap necessary bound precedes allocation/read of active
            // bootstrap evidence, which itself can approach the file cap.
            for entry in entries where entry.relativePath.hasPrefix(".KnitNote-SyncBootstrap/") && entry.relativePath.hasSuffix("/active.json") {
                guard try base64Count(entry.byteCount) <= maximumBytes else { throw Error.tooLarge }
            }
            let terminal = try owned == nil ? SyncBootstrapTransaction.terminalRecoveryEvidence(account: account,
                accountRoot: paths.accountRoot, liveRoot: paths.workingSet, journalURL: snapshot.url, entries: entries) { path in
                guard let entry = entries.first(where: { $0.relativePath == path && !$0.isDirectory }) else { throw Error.unsafeBinding }
                let value = try SyncRegularFileReader().read(paths.accountRoot.appendingPathComponent(path),
                    maximumBytes: min(maximumBytes, Int(entry.byteCount)),
                    expected: .init(byteCount: entry.byteCount, sha256: entry.sha256))
                guard value.device == entry.device, value.inode == entry.inode else { throw Error.unsafeBinding }
                return value.data
            } : nil
            let source: SyncAccountSourceState
            if case .absentSource(let active) = control.state { source = active }
            else if control.mainBytes == nil, control.nextBytes == nil, let terminal,
                    terminal.phase == .rolledBack, case .missingArchive = terminal.sourceProof {
                var status = stat()
                guard fstat(access.accountDescriptor, &status) == 0 else { throw Error.unsafeBinding }
                source = .init(authorityID: UUID(), generation: UUID(), accountIDHash: account.accountIDHash,
                    accountRoot: paths.accountRoot, accountDevice: UInt64(status.st_dev), accountInode: UInt64(status.st_ino),
                    archiveURL: archiveURL, journalURL: snapshot.url, baselineSHA256: baseline,
                    origin: .bootstrapRollback(transactionID: terminal.transactionID,
                        activeRelativePath: terminal.activeRelativePath, activeEnvelopeSHA256: Data(SHA256.hash(data: terminal.activeEnvelope))))
            } else { throw Error.unsafeBinding }
            authority = .absent(.init(state: source, rollbackEnvelope: owned?.activeEnvelope ?? terminal?.activeEnvelope))
            try validateAuthority(authority, account: account, paths: paths, archiveURL: archiveURL,
                journalURL: snapshot.url, entries: entries, baseline: baseline, bootstrapEvidence: bootstrap)
        }
        let fingerprint = try fingerprint(entries, authority: authority)
        let metadata = Payload(accountIDHash: account.accountIDHash, accountRoot: paths.accountRoot,
            archiveURL: archiveURL, journalURL: snapshot.url, entries: entries, fingerprint: fingerprint,
            packet: nil, deletionLedger: export?.manifest, deletionFiles: placeholders,
            pendingMarkerVersions: export?.pendingMarkerVersions ?? [])
        // The omitted packet property adds a comma plus "packet":. The
        // packet preflights its own metadata and all source Base64 expansion.
        var reservedBytes = try encodePayload(metadata, authority: authority, bootstrapEvidence: bootstrap).count + 10
        for file in placeholders {
            guard file.byteCount >= 0, file.byteCount <= Int64(maximumBytes) else { throw Error.tooLarge }
            let expansion = try base64Count(file.byteCount)
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
            deletionLedger: export?.manifest, deletionFiles: files, pendingMarkerVersions: export?.pendingMarkerVersions ?? [],
            sourceAuthority: authority, bootstrapEvidence: bootstrap)
        let encoded = try result.encoded(maximumBytes: maximumBytes)
        _ = try decodeRecovery(encoded, account: account, paths: paths, journalURL: snapshot.url, maximumBytes: maximumBytes)
        try access.validate()
        guard try access.entries() == entries, try observer.observe(access: access) == control else { throw Error.unsafeBinding }
        return result
    }

    /// Aggregate size includes journal mutations, exact source bytes, selected
    /// ledger envelope/files, markers, account bindings and complete inventory.
    public func encoded(maximumBytes: Int = 100_000_000) throws -> Data {
        guard maximumBytes >= 0, maximumBytes <= 100_000_000 else { throw Error.tooLarge }
        let bytes = try Self.encodePayload(Payload(accountIDHash: account.accountIDHash,
            accountRoot: accountRoot, archiveURL: archiveURL, journalURL: journalURL, entries: entries,
            fingerprint: fingerprint, packet: packet, deletionLedger: deletionLedger,
            deletionFiles: deletionFiles, pendingMarkerVersions: pendingMarkerVersions), authority: sourceAuthority,
            bootstrapEvidence: bootstrapEvidence)
        guard bytes.count <= maximumBytes else { throw Error.tooLarge }
        return bytes
    }

    /// Only the transaction calls this after vault authentication. Decode still
    /// validates every binding and selected dependency; authenticated bytes alone
    /// are not permission to interpret arbitrary names as cleanup targets.
    static func decodeRecovery(_ data: Data, account: SyncAccountIdentity, paths: SyncAccountStorage.Paths,
                               journalURL: URL, maximumBytes: Int) throws -> Self {
        guard maximumBytes >= 0, maximumBytes <= 100_000_000, data.count <= maximumBytes else { throw Error.tooLarge }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Error.unsafeBinding }
        let value: Payload
        let authority: SyncAccountRecoverySourceAuthority?
        let bootstrap: BootstrapEvidence?
        if object.keys.contains("formatVersion") {
            let v2 = try JSONDecoder().decode(PayloadV2.self, from: data)
            guard v2.formatVersion == 2, try normalizedJSON(data) == normalizedJSON(encoder().encode(v2)) else { throw Error.unsafeBinding }
            value = v2.legacy; authority = v2.sourceAuthority; bootstrap = v2.bootstrapEvidence
        } else {
            guard !object.keys.contains("sourceAuthority") else { throw Error.unsafeBinding }
            value = try JSONDecoder().decode(Payload.self, from: data); authority = nil; bootstrap = nil
        }
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
        guard value.fingerprint == (try fingerprint(value.entries, authority: authority)),
              ["working-set", "journal", "engine-state", "staging", "quarantine", ".decrypted-temporary"].allSatisfy({ indexed[$0]?.isDirectory == true }) else { throw Error.unsafeBinding }
        if authority != nil {
            guard value.entries.map(\.relativePath) == value.entries.map(\.relativePath).sorted(by: {
                $0.split(separator: "/").lexicographicallyPrecedes($1.split(separator: "/"))
            }) else { throw Error.unsafeBinding }
            for path in indexed.keys where path.hasPrefix(".decrypted-temporary/") {
                let parts = path.split(separator: "/")
                guard let id = UUID(uuidString: String(parts[1])), String(parts[1]) == id.uuidString.lowercased(),
                      indexed[".decrypted-temporary/" + String(parts[1])]?.isDirectory == true else { throw Error.unsafeBinding }
            }
            let baseline = try SyncAccountSourceBaseline.digest(entries: value.entries, accountRoot: paths.accountRoot,
                journalURL: value.journalURL, mutations: packet.mutations, selectedFiles: packet.files + value.deletionFiles,
                deletionLedger: value.deletionLedger, pendingMarkerVersions: value.pendingMarkerVersions)
            try validateAuthority(authority, account: account, paths: paths, archiveURL: value.archiveURL,
                journalURL: value.journalURL, entries: value.entries, baseline: baseline, bootstrapEvidence: bootstrap)
        } else if indexed[archivePath]?.isDirectory != false { throw Error.unsafeBinding }
        let owned = try validateBootstrapEvidence(bootstrap, account: account, paths: paths,
            journalURL: journalURL, entries: value.entries, maximumBytes: maximumBytes)
        try compatibilityGate(value.entries.filter { !(owned?.abandonedEntries.contains($0) ?? false) })
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
            deletionLedger: value.deletionLedger, deletionFiles: value.deletionFiles, pendingMarkerVersions: value.pendingMarkerVersions,
            sourceAuthority: authority, bootstrapEvidence: bootstrap)
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
    /// Shares the original fields without changing their legacy synthesized wire.
    private struct PayloadV2: Codable {
        let formatVersion: Int
        let legacy: Payload
        let sourceAuthority: SyncAccountRecoverySourceAuthority
        let bootstrapEvidence: BootstrapEvidence?
        private enum Keys: String, CodingKey { case formatVersion, sourceAuthority, bootstrapEvidence }
        init(legacy: Payload, sourceAuthority: SyncAccountRecoverySourceAuthority,
             bootstrapEvidence: BootstrapEvidence? = nil) {
            formatVersion = 2; self.legacy = legacy; self.sourceAuthority = sourceAuthority
            self.bootstrapEvidence = bootstrapEvidence
        }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            formatVersion = try c.decode(Int.self, forKey: .formatVersion)
            sourceAuthority = try c.decode(SyncAccountRecoverySourceAuthority.self, forKey: .sourceAuthority)
            legacy = try Payload(from: decoder)
            bootstrapEvidence = try c.decodeIfPresent(BootstrapEvidence.self, forKey: .bootstrapEvidence)
        }
        func encode(to encoder: any Encoder) throws {
            try legacy.encode(to: encoder)
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(formatVersion, forKey: .formatVersion)
            try c.encode(sourceAuthority, forKey: .sourceAuthority)
            try c.encodeIfPresent(bootstrapEvidence, forKey: .bootstrapEvidence)
        }
    }
    private static func encodePayload(_ payload: Payload, authority: SyncAccountRecoverySourceAuthority?,
                                      bootstrapEvidence: BootstrapEvidence? = nil) throws -> Data {
        if let authority { return try encoder().encode(PayloadV2(legacy: payload, sourceAuthority: authority,
            bootstrapEvidence: bootstrapEvidence)) }
        guard bootstrapEvidence == nil else { throw Error.unsafeBinding }
        return try encoder().encode(payload)
    }
    private static func normalizedJSON(_ bytes: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: bytes), options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func fingerprint(_ entries: [Entry], authority: SyncAccountRecoverySourceAuthority?) throws -> Data {
        struct Projection: Encodable { let entries: [Entry]; let sourceAuthority: SyncAccountRecoverySourceAuthority }
        let bytes = try authority.map { try encoder().encode(Projection(entries: entries, sourceAuthority: $0)) }
            ?? encoder().encode(entries)
        return Data(SHA256.hash(data: bytes))
    }
    private static func base64Count(_ count: Int64) throws -> Int {
        guard count >= 0, count <= 100_000_000 else { throw Error.tooLarge }
        let (padded, overflow) = Int(count).addingReportingOverflow(2)
        let (result, multipliedOverflow) = (padded / 3).multipliedReportingOverflow(by: 4)
        guard !overflow, !multipliedOverflow else { throw Error.tooLarge }
        return result
    }
    static func requireAbsent(_ entries: [Entry], archivePath: String) throws {
        guard !entries.contains(where: {
            $0.relativePath == archivePath || $0.relativePath.hasPrefix(archivePath + "/")
                || ($0.relativePath.hasPrefix("working-set/")
                    && SyncBootstrapTransaction.isReconstructionAuthority(String($0.relativePath.dropFirst("working-set/".count))))
        }) else { throw Error.unsafeBinding }
    }
    private static func validateAuthority(_ authority: SyncAccountRecoverySourceAuthority?,
        account: SyncAccountIdentity, paths: SyncAccountStorage.Paths, archiveURL: URL, journalURL: URL,
        entries: [Entry], baseline: Data, bootstrapEvidence: BootstrapEvidence? = nil) throws {
        guard let authority else { throw Error.unsafeBinding }
        let archivePath = try relative(archiveURL, root: paths.accountRoot)
        switch authority {
        case .archive(let path, let sha256):
            guard path == archivePath, sha256.count == 32,
                  entries.contains(where: { $0.relativePath == path && !$0.isDirectory && $0.sha256 == sha256 }) else { throw Error.unsafeBinding }
        case .absent(let evidence):
            let source = evidence.state
            try SyncAccountRecoveryControlFile.validate(source)
            try requireAbsent(entries, archivePath: archivePath)
            var status = stat()
            guard lstat(paths.accountRoot.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
                  source.accountIDHash == account.accountIDHash, source.accountRoot == paths.accountRoot,
                  source.accountDevice == UInt64(status.st_dev), source.accountInode == UInt64(status.st_ino),
                  source.accountDevice > 0, source.accountInode > 0,
                  source.archiveURL == archiveURL, source.journalURL == journalURL,
                  journalURL == paths.mutationJournalURL, source.baselineSHA256 == baseline else { throw Error.unsafeBinding }
            switch source.origin {
            case .freshAllocation, .restoredSelection:
                guard evidence.rollbackEnvelope == nil,
                      !entries.contains(where: { $0.relativePath == ".KnitNote-SyncBootstrap"
                        || $0.relativePath.hasPrefix(".KnitNote-SyncBootstrap/") }) else { throw Error.unsafeBinding }
            case .bootstrapRollback(let transactionID, let activePath, let digest):
                if let bootstrapEvidence {
                    guard let owned = try validateBootstrapEvidence(bootstrapEvidence, account: account, paths: paths,
                        journalURL: journalURL, entries: entries, maximumBytes: 100_000_000),
                          evidence.rollbackEnvelope == bootstrapEvidence.activeEnvelope,
                          OwnedBootstrapCodec.hash(owned.activeEnvelope) == digest,
                          owned.activeRelativePath == activePath, owned.manifest.id == transactionID,
                          case .missingArchive = owned.manifest.sourceProof else { throw Error.unsafeBinding }
                    break
                }
                guard let bytes = evidence.rollbackEnvelope, Data(SHA256.hash(data: bytes)) == digest,
                      let terminal = try SyncBootstrapTransaction.terminalRecoveryEvidence(account: account,
                        accountRoot: paths.accountRoot, liveRoot: paths.workingSet, journalURL: journalURL,
                        entries: entries, read: { path in
                            guard path == activePath else { throw Error.unsafeBinding }; return bytes
                        }),
                      terminal.phase == .rolledBack, terminal.transactionID == transactionID,
                      terminal.activeRelativePath == activePath, case .missingArchive = terminal.sourceProof else { throw Error.unsafeBinding }
            }
        }
    }
    private static func validateBootstrapEvidence(_ evidence: BootstrapEvidence?, account: SyncAccountIdentity,
        paths: SyncAccountStorage.Paths, journalURL: URL, entries: [Entry], maximumBytes: Int)
        throws -> SyncBootstrapOwnedTerminalEvidence? {
        guard let evidence else { return nil }
        var records: [String: Data] = [:]
        let manifest = try BootstrapManifestV3.decodeEnvelope(evidence.activeEnvelope, maximumBytes: maximumBytes)
        let namespace = OwnedBootstrapCodec.parent(manifest.transactionRelativePath)
        records[namespace + "/active.json"] = evidence.activeEnvelope
        for bytes in evidence.historyRecords {
            let path = SyncBootstrapHistory.recordPath(namespace: namespace, hash: OwnedBootstrapCodec.hash(bytes))
            guard records.updateValue(bytes, forKey: path) == nil else { throw Error.unsafeBinding }
        }
        guard let owned = try SyncBootstrapOwnedTerminalEvidence.read(account: account, accountRoot: paths.accountRoot,
            liveRoot: paths.workingSet, journalURL: journalURL, entries: entries, maximumBytes: maximumBytes,
            read: { path in guard let bytes = records[path] else { throw Error.unsafeBinding }; return bytes }),
              owned.historyRecords == evidence.historyRecords else { throw Error.unsafeBinding }
        return owned
    }

    static func validateOwnedControl(_ control: SyncAccountControlObservation,
        terminal: SyncBootstrapOwnedTerminalEvidence, account: SyncAccountIdentity, paths: SyncAccountStorage.Paths) throws {
        guard control.nextBytes == nil else { throw Error.unsafeBinding }
        switch (terminal.manifest.sourceProof, control.state) {
        case (.archive, nil):
            let witness: Data?
            switch terminal.manifest.body {
            case let .abortedPreparation(value): witness = value.sourceControlSHA256
            default: witness = terminal.manifest.body.preparedBody?.sourceControlSHA256
            }
            guard control.mainBytes == nil, witness == nil else { throw Error.unsafeBinding }
        case (.missingArchive, .sourceSpent(let source, let id, let digest)):
            guard case let .committed(prepared) = terminal.manifest.body,
                  id == terminal.manifest.id, digest == (try terminal.manifest.normalizedPreparedDigest()),
                  let main = control.mainBytes,
                  try SyncAccountRecoveryControlFile.sourceSpentPredecessor(main) == prepared.sourceControlSHA256,
                  try BootstrapManifestV3.formerSourceDigest(control.state) == prepared.formerSourceSHA256,
                  source.accountIDHash == account.accountIDHash, source.accountRoot == paths.accountRoot,
                  source.archiveURL == paths.workingSet.appendingPathComponent("projects-v1.json"),
                  source.journalURL == paths.mutationJournalURL, source.baselineSHA256 == prepared.pendingSnapshotSHA256 else { throw Error.unsafeBinding }
        default: throw Error.unsafeBinding
        }
    }

    func validateOwnedControl(_ control: SyncAccountControlObservation, paths: SyncAccountStorage.Paths) throws {
        guard let terminal = try Self.validateBootstrapEvidence(bootstrapEvidence, account: account,
            paths: paths,
            journalURL: journalURL, entries: entries, maximumBytes: 100_000_000) else { throw Error.unsafeBinding }
        try Self.validateOwnedControl(control, terminal: terminal, account: account, paths: paths)
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }
    static func relative(_ url: URL, root: URL) throws -> String {
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
    struct SourceDependencies {
        let snapshot: (url: URL, mutations: [SyncMutation])
        let export: SyncDeletionLedger.RecoveryExport?
        let placeholders: [SyncPendingRecoveryPacket.File]
        let baseline: Data
    }

    /// Shared read-only dependencies. Callers retain their own source/terminal admission.
    static func captureSourceDependencies(paths: SyncAccountStorage.Paths,
        journal: FileSyncMutationJournal, archiveURL: URL, entries: [Entry], maximumBytes: Int) throws -> SourceDependencies {
        let snapshot = try journal.recoverySnapshot(accountRoot: paths.accountRoot, inventoryEntries: entries, maximumBytes: maximumBytes)
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
        let pendingFiles = try snapshot.mutations.compactMap(\.attachmentSource).map { source in
            let path = try relative(source.fileURL, root: paths.accountRoot)
            guard let observed = entries.first(where: { $0.relativePath == path }), !observed.isDirectory,
                  observed.byteCount == source.byteCount, observed.sha256 == source.contentSHA256 else { throw Error.unsafeBinding }
            return SyncPendingRecoveryPacket.File(relativePath: path, byteCount: source.byteCount, sha256: source.contentSHA256, bytes: Data())
        }
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
        for file in placeholders {
            guard let observed = entries.first(where: { $0.relativePath == file.relativePath }), !observed.isDirectory,
                  observed.byteCount == file.byteCount, observed.sha256 == file.sha256 else { throw Error.unresolvedRecovery }
        }
        let baseline = try SyncAccountSourceBaseline.digest(entries: entries, accountRoot: paths.accountRoot,
            journalURL: snapshot.url, mutations: snapshot.mutations, selectedFiles: pendingFiles + placeholders,
            deletionLedger: export?.manifest, pendingMarkerVersions: export?.pendingMarkerVersions ?? [])
        return .init(snapshot: snapshot, export: export, placeholders: placeholders, baseline: baseline)
    }


    static func compatibilityGate(_ entries: [Entry]) throws {
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
