import Foundation

/// Bounded wire reference only; it grants no I/O authority.
struct BootstrapHistoryRef: Codable, Equatable {
    let sha256: Data
    let byteCount: Int64
    let recordCount: Int
    let chainByteCount: Int64
    init(sha256: Data, byteCount: Int64, recordCount: Int, chainByteCount: Int64) {
        self.sha256 = sha256; self.byteCount = byteCount; self.recordCount = recordCount; self.chainByteCount = chainByteCount
    }
    private enum Keys: String, CodingKey { case sha256, byteCount, recordCount, chainByteCount }
    init(from decoder: Decoder) throws {
        try OwnedBootstrapCodec.keys(decoder, required: ["sha256", "byteCount", "recordCount", "chainByteCount"])
        let c = try decoder.container(keyedBy: Keys.self)
        sha256 = try c.decode(Data.self, forKey: .sha256); byteCount = try c.decode(Int64.self, forKey: .byteCount)
        recordCount = try c.decode(Int.self, forKey: .recordCount); chainByteCount = try c.decode(Int64.self, forKey: .chainByteCount)
        try validate()
    }
    func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: Keys.self)
        try c.encode(sha256, forKey: .sha256); try c.encode(byteCount, forKey: .byteCount)
        try c.encode(recordCount, forKey: .recordCount); try c.encode(chainByteCount, forKey: .chainByteCount)
    }
    func validate() throws {
        guard sha256.count == 32, (0...100_000_000).contains(byteCount), recordCount > 0,
              (byteCount...100_000_000).contains(chainByteCount), recordCount != 1 || chainByteCount == byteCount else { throw SyncBootstrapError.corrupt }
    }
}

/// Plain immutable wire observations; construction issues no I/O authority.
struct BootstrapHistoryRecordV1: Codable {
    let version: Int
    let accountIDHash: String
    let livePath: String
    let journalPath: String
    let transactionID: UUID
    let terminalEnvelope: Data
    let treeEntries: [SyncAccountRecoveryInventory.Entry]
    let previous: BootstrapHistoryRef?

    private struct Wire: Codable {
        let version: Int; let accountIDHash: String; let livePath: String; let journalPath: String
        let transactionID: UUID; let terminalEnvelope: Data
        let treeEntries: [SyncAccountRecoveryInventory.Entry]; let previous: BootstrapHistoryRef?
    }
    init(version: Int, accountIDHash: String, livePath: String, journalPath: String, transactionID: UUID,
         terminalEnvelope: Data, treeEntries: [SyncAccountRecoveryInventory.Entry], previous: BootstrapHistoryRef?) {
        self.version = version; self.accountIDHash = accountIDHash; self.livePath = livePath; self.journalPath = journalPath
        self.transactionID = transactionID; self.terminalEnvelope = terminalEnvelope; self.treeEntries = treeEntries; self.previous = previous
    }
    init(from decoder: Decoder) throws {
        let wire = try OwnedBootstrapCodec.strict(Wire.self, from: decoder)
        self.init(version: wire.version, accountIDHash: wire.accountIDHash, livePath: wire.livePath, journalPath: wire.journalPath,
            transactionID: wire.transactionID, terminalEnvelope: wire.terminalEnvelope, treeEntries: wire.treeEntries, previous: wire.previous)
        try validate()
    }
    func encode(to encoder: Encoder) throws {
        try validate()
        try Wire(version: version, accountIDHash: accountIDHash, livePath: livePath, journalPath: journalPath,
            transactionID: transactionID, terminalEnvelope: terminalEnvelope, treeEntries: treeEntries, previous: previous).encode(to: encoder)
    }
    var namespaceRelativePath: String {
        ".KnitNote-SyncBootstrap/\(accountIDHash)/\(OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(livePath.utf8))))"
    }
    var transactionRelativePath: String { namespaceRelativePath + "/" + transactionID.uuidString }
    func encoded(maximumBytes: Int = 100_000_000) throws -> Data {
        try OwnedBootstrapCodec.checkLimit(maximumBytes)
        guard terminalEnvelope.count <= maximumBytes else { throw SyncBootstrapError.corrupt }
        let payload = try OwnedBootstrapCodec.encode(self)
        guard payload.count <= maximumBytes else { throw SyncBootstrapError.corrupt }
        let bytes = try OwnedBootstrapCodec.encode(OwnedBootstrapCodec.Envelope(payload: payload, digest: OwnedBootstrapCodec.hash(payload)))
        guard bytes.count <= maximumBytes else { throw SyncBootstrapError.corrupt }
        return bytes
    }
    static func decodeEnvelope(_ bytes: Data, maximumBytes: Int = 100_000_000) throws -> Self {
        try JSONDecoder().decode(Self.self, from: OwnedBootstrapCodec.envelopePayload(bytes, maximumBytes: maximumBytes))
    }
    /// Shares the actual history wire; terminal bytes are an unknown future
    /// Data field. This returns only a conservative size, never record bytes.
    func prospectiveEnvelopeByteCount(terminalByteCount: Int) throws -> Int {
        let value = Wire(version: version, accountIDHash: accountIDHash, livePath: livePath,
            journalPath: journalPath, transactionID: transactionID, terminalEnvelope: Data(),
            treeEntries: treeEntries, previous: previous)
        let payload = try OwnedBootstrapCodec.encode(value)
        return try SyncBootstrapRecoveryBudget.ownedEnvelopeMaximum(payloadByteCount:
            SyncBootstrapRecoveryBudget.add(payload.count,
                SyncBootstrapRecoveryBudget.escapedBase64Maximum(terminalByteCount)))
    }
    private func validate() throws {
        guard version == 1, OwnedBootstrapCodec.isHash(accountIDHash), livePath.hasPrefix("/"),
              OwnedBootstrapCodec.relative(String(livePath.dropFirst())), OwnedBootstrapCodec.relative(journalPath),
              journalPath != "projects-v1.json", !SyncBootstrapTransaction.isReconstructionAuthority(journalPath) else { throw SyncBootstrapError.corrupt }
        try previous?.validate()
        struct Version: Decodable { let version: Int }
        let payload = try OwnedBootstrapCodec.envelopePayload(terminalEnvelope)
        let terminalVersion = try JSONDecoder().decode(Version.self, from: payload).version
        let original: [String: BootstrapManifestV3.FileProof]?
        if terminalVersion == 3 {
            let terminal = try BootstrapManifestV3.decodeEnvelope(terminalEnvelope)
            guard terminal.id == transactionID, terminal.context.accountIDHash == accountIDHash,
                  OwnedBootstrapCodec.samePath(terminal.livePath, livePath), OwnedBootstrapCodec.samePath(terminal.journalPath, journalPath),
                  terminal.historyHead == previous else { throw SyncBootstrapError.corrupt }
            switch terminal.body {
            case let .abortedPreparation(body):
                guard SyncBootstrapHistory.exactEntries(body.frozenOutputEntries, treeEntries) else { throw SyncBootstrapError.corrupt }
                original = nil
            case let .rolledBack(body):
                guard SyncBootstrapHistory.exactEntries(body.frozenTransactionEntries, treeEntries) else { throw SyncBootstrapError.corrupt }
                original = terminal.original
            default: throw SyncBootstrapError.invalidPhase
            }
        } else {
            let terminal = try SyncBootstrapTransaction.legacyHistorySource(terminalEnvelope)
            guard previous == nil, terminal.id == transactionID, terminal.context.accountIDHash == accountIDHash,
                  OwnedBootstrapCodec.samePath(terminal.livePath, livePath), OwnedBootstrapCodec.samePath(terminal.journalPath, journalPath) else { throw SyncBootstrapError.corrupt }
            original = terminal.original
        }
        try SyncBootstrapHistory.validateTree(treeEntries, root: transactionRelativePath,
            roles: Set(BootstrapManifestV3.Role.allCases.map(\.directoryName) + ["Failed"]), original: original)
    }
}

/// Validates only supplied observations. The owner must provide its frozen
/// inventory and exact bytes, authenticate/reobserve them and validate current
/// source/install state separately. No filesystem reads or capabilities here.
enum SyncBootstrapHistory {
    struct SuppliedRecord {
        let relativePath: String
        let bytes: Data
    }
    static func validate(current: BootstrapManifestV3, records: [SuppliedRecord],
                         accountEntries: [SyncAccountRecoveryInventory.Entry], maximumBytes: Int = 100_000_000) throws -> [BootstrapHistoryRecordV1] {
        try OwnedBootstrapCodec.checkLimit(maximumBytes)
        let pending: BootstrapManifestV3.PendingHistoryRecord?
        if case let .preparing(body) = current.body { pending = body.predecessor } else { pending = nil }
        let head = pending?.reference ?? current.historyHead
        let namespace = OwnedBootstrapCodec.parent(current.transactionRelativePath)
        // Preflight all advertised count/byte feasibility and supplied byte totals
        // before constructing indexes or decoding/traversing a chain.
        if let head { try feasible(head, maximumBytes: maximumBytes) }
        let pendingPath = pending.map { recordPath(namespace: namespace, hash: $0.reference.sha256) }
        let pendingSupplied = pendingPath.map { path in records.contains { OwnedBootstrapCodec.samePath($0.relativePath, path) } } ?? false
        let extraCount = pending != nil && !pendingSupplied ? 1 : 0
        let (count, overflow) = records.count.addingReportingOverflow(extraCount)
        guard !overflow, count == (head?.recordCount ?? 0) else { throw SyncBootstrapError.corrupt }
        var total = 0
        for record in records {
            guard !record.bytes.isEmpty, record.bytes.count <= maximumBytes - total else { throw SyncBootstrapError.corrupt }
            total += record.bytes.count
        }
        if let pending, !pendingSupplied {
            guard !pending.record.isEmpty, pending.record.count <= maximumBytes - total else { throw SyncBootstrapError.corrupt }
            total += pending.record.count
        }
        guard Int64(total) == (head?.chainByteCount ?? 0) else { throw SyncBootstrapError.corrupt }
        try current.validate()
        let scoped = accountEntries.filter { OwnedBootstrapCodec.samePath($0.relativePath, namespace) || OwnedBootstrapCodec.hasExactPrefix($0.relativePath, namespace + "/") }
        let observed = try indexTree(scoped, root: namespace)
        // Group once, so each retained record does not scan the entire account
        // namespace again. Paths inside each group preserve frozen entry order.
        var subtrees: [String: [SyncAccountRecoveryInventory.Entry]] = [:]
        for entry in scoped.dropFirst() {
            let relative = entry.relativePath.dropFirst(namespace.count + 1)
            guard let child = relative.split(separator: "/").first else { throw SyncBootstrapError.corrupt }
            subtrees[String(child), default: []].append(entry)
        }
        var supplied: [String: Data] = [:]
        for record in records {
            let expected = recordPath(namespace: namespace, hash: OwnedBootstrapCodec.hash(record.bytes))
            guard OwnedBootstrapCodec.samePath(record.relativePath, expected), supplied.updateValue(record.bytes, forKey: expected) == nil,
                  let entry = OwnedBootstrapCodec.exactValue(expected, in: observed), !entry.isDirectory,
                  entry.byteCount == record.bytes.count, entry.sha256 == OwnedBootstrapCodec.hash(record.bytes) else { throw SyncBootstrapError.corrupt }
        }
        if let pending, let pendingPath {
            if let bytes = supplied[pendingPath] { guard bytes == pending.record else { throw SyncBootstrapError.corrupt } }
            else {
                // An absent pending file is only embedded evidence. A partial
                // physical file must first be completed/resynchronized by Task2.
                guard observed[pendingPath] == nil else { throw SyncBootstrapError.corrupt }
                supplied[pendingPath] = pending.record
            }
        }
        var result: [BootstrapHistoryRecordV1] = []
        var hashes = Set<Data>(), ids: Set<UUID> = [current.id]
        var next = head, remainingCount = count, remainingBytes = Int64(total)
        var allowedPaths: Set<String> = [namespace, namespace + "/active.json", namespace + "/active-next.json"]
        if head != nil { allowedPaths.insert(namespace + "/History") }
        while let reference = next {
            try feasible(reference, maximumBytes: maximumBytes)
            guard hashes.insert(reference.sha256).inserted, reference.recordCount == remainingCount,
                  reference.chainByteCount == remainingBytes else { throw SyncBootstrapError.corrupt }
            let path = recordPath(namespace: namespace, hash: reference.sha256)
            guard let bytes = supplied.removeValue(forKey: path), bytes.count == reference.byteCount,
                  OwnedBootstrapCodec.hash(bytes) == reference.sha256 else { throw SyncBootstrapError.corrupt }
            let record = try BootstrapHistoryRecordV1.decodeEnvelope(bytes, maximumBytes: maximumBytes)
            if pending != nil, result.isEmpty {
                guard record.previous == current.historyHead else { throw SyncBootstrapError.corrupt }
            }
            guard ids.insert(record.transactionID).inserted, record.accountIDHash == current.context.accountIDHash,
                  OwnedBootstrapCodec.samePath(record.livePath, current.livePath), OwnedBootstrapCodec.samePath(record.journalPath, current.journalPath) else { throw SyncBootstrapError.corrupt }
            remainingCount -= 1; remainingBytes -= reference.byteCount
            guard (record.previous?.recordCount ?? 0) == remainingCount,
                  (record.previous?.chainByteCount ?? 0) == remainingBytes else { throw SyncBootstrapError.corrupt }
            let actual = subtrees[record.transactionID.uuidString] ?? []
            guard exactEntries(actual, record.treeEntries) else { throw SyncBootstrapError.corrupt }
            allowedPaths.insert(path)
            allowedPaths.formUnion(record.treeEntries.map(\.relativePath))
            result.append(record); next = record.previous
        }
        guard supplied.isEmpty, remainingCount == 0, remainingBytes == 0 else { throw SyncBootstrapError.corrupt }
        let currentEntries = subtrees[current.id.uuidString] ?? []
        let currentRoles: Set<String>
        switch current.body {
        case let .preparing(body): currentRoles = Set(body.outputAllocation.allowedRoles.map(\.directoryName))
        case let .abortedPreparation(body):
            guard exactEntries(currentEntries, body.frozenOutputEntries) else { throw SyncBootstrapError.corrupt }
            currentRoles = Set(body.outputAllocation.allowedRoles.map(\.directoryName))
        case let .rolledBack(body):
            guard exactEntries(currentEntries, body.frozenTransactionEntries) else { throw SyncBootstrapError.corrupt }
            currentRoles = Set(BootstrapManifestV3.Role.allCases.map(\.directoryName) + ["Failed"])
        default: currentRoles = Set(BootstrapManifestV3.Role.allCases.map(\.directoryName) + ["Failed", "Displaced"])
        }
        try validateTree(currentEntries, root: current.transactionRelativePath, roles: currentRoles, original: nil)
        allowedPaths.formUnion(currentEntries.map(\.relativePath))
        guard scoped.allSatisfy({ entry in
            guard allowedPaths.contains(entry.relativePath) else { return false }
            if entry.relativePath == namespace + "/active.json" || entry.relativePath == namespace + "/active-next.json" { return !entry.isDirectory }
            if entry.relativePath == namespace + "/History" { return entry.isDirectory }
            return true
        }) else { throw SyncBootstrapError.corrupt }
        return result
    }

    private static func feasible(_ reference: BootstrapHistoryRef, maximumBytes: Int) throws {
        try reference.validate()
        guard reference.byteCount > 0, reference.chainByteCount <= maximumBytes,
              reference.recordCount <= reference.chainByteCount else { throw SyncBootstrapError.corrupt }
    }
    static func recordPath(namespace: String, hash: Data) -> String {
        namespace + "/History/" + OwnedBootstrapCodec.hex(hash) + ".json"
    }
    static func exactEntries(_ lhs: [SyncAccountRecoveryInventory.Entry], _ rhs: [SyncAccountRecoveryInventory.Entry]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            OwnedBootstrapCodec.samePath(a.relativePath, b.relativePath) && a == b
        }
    }
    private static func indexTree(_ entries: [SyncAccountRecoveryInventory.Entry], root: String) throws -> [String: SyncAccountRecoveryInventory.Entry] {
        if entries.isEmpty { return [:] }
        guard entries.first?.isDirectory == true, OwnedBootstrapCodec.samePath(entries[0].relativePath, root) else { throw SyncBootstrapError.corrupt }
        var result: [String: SyncAccountRecoveryInventory.Entry] = [:]
        var aliases = Set<String>(), identities = Set<BootstrapManifestV3.InstallRootIdentity>()
        var prior: String?
        for entry in entries {
            let path = entry.relativePath
            guard OwnedBootstrapCodec.relative(path), prior.map({ OwnedBootstrapCodec.pathOrder($0, path) }) ?? true,
                  OwnedBootstrapCodec.samePath(path, root) || OwnedBootstrapCodec.hasExactPrefix(path, root + "/"),
                  aliases.insert(OwnedBootstrapCodec.alias(path)).inserted, entry.device > 0, entry.inode > 0,
                  identities.insert(.init(device: entry.device, inode: entry.inode)).inserted,
                  entry.isDirectory ? (entry.byteCount == 0 && entry.sha256.isEmpty) : ((0...100_000_000).contains(entry.byteCount) && entry.sha256.count == 32) else { throw SyncBootstrapError.corrupt }
            if !OwnedBootstrapCodec.samePath(path, root) {
                guard OwnedBootstrapCodec.exactValue(OwnedBootstrapCodec.parent(path), in: result)?.isDirectory == true else { throw SyncBootstrapError.corrupt }
            }
            result[path] = entry; prior = path
        }
        return result
    }
    static func validateTree(_ entries: [SyncAccountRecoveryInventory.Entry], root: String, roles: Set<String>,
                             original: [String: BootstrapManifestV3.FileProof]?) throws {
        let indexed = try indexTree(entries, root: root)
        for entry in entries.dropFirst() {
            let relative = String(entry.relativePath.dropFirst(root.count + 1))
            guard let role = relative.split(separator: "/").first, roles.contains(String(role)),
                  relative.contains("/") || entry.isDirectory else { throw SyncBootstrapError.corrupt }
        }
        if let original {
            guard indexed[root + "/Original"]?.isDirectory == true else { throw SyncBootstrapError.corrupt }
            let prefix = root + "/Original/"
            var actual: [String: BootstrapManifestV3.FileProof] = [:]
            for entry in entries where OwnedBootstrapCodec.hasExactPrefix(entry.relativePath, prefix) {
                let path = String(entry.relativePath.dropFirst(prefix.count)) + (entry.isDirectory ? "/" : "")
                actual[path] = .init(bytes: entry.isDirectory ? -1 : entry.byteCount, digest: entry.sha256)
            }
            guard actual.count == original.count,
                  actual.allSatisfy({ OwnedBootstrapCodec.exactValue($0.key, in: original) == $0.value }),
                  !(indexed[root + "/Failed"] != nil && indexed[root + "/Staged"] != nil) else { throw SyncBootstrapError.corrupt }
        }
    }
}
