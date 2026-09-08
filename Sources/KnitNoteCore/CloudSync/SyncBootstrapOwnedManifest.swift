import CryptoKit
import Foundation

/// Pure owned v3 wire data. This does not observe files, verify a freeze/history,
/// certify a commit prefix, or issue a preparation/install/cleanup capability.
struct BootstrapManifestV3: Codable, Equatable {
    struct FileProof: Codable, Equatable { let bytes: Int64; let digest: Data }
    enum Role: String, Codable, CaseIterable {
        case original, staged, attachments, validationOriginal, validationMerged
        var directoryName: String {
            switch self {
            case .original: "Original"
            case .staged: "Staged"
            case .attachments: "Attachments"
            case .validationOriginal: "ValidationOriginal"
            case .validationMerged: "ValidationMerged"
            }
        }
    }
    struct RoleLimit: Codable, Equatable {
        let role: Role
        let maximumEntryCount: Int
        let reservedEncodedProofBytes: Int64
    }
    struct OutputAllocation: Codable, Equatable {
        let transactionID: UUID
        let allowedRoles: [Role]
        let roleLimits: [RoleLimit]
    }
    struct PendingHistoryRecord: Codable, Equatable {
        let record: Data
        let reference: BootstrapHistoryRef
    }
    struct Preparing: Codable, Equatable {
        let sourceControlSHA256: Data?
        let pendingSnapshotSHA256: Data
        let outputAllocation: OutputAllocation
        let predecessor: PendingHistoryRecord?
    }
    struct InstallRootIdentity: Codable, Equatable, Hashable { let device: UInt64; let inode: UInt64 }
    struct PreparedBody: Codable, Equatable {
        let installed: [String: FileProof]
        let mutations: [SyncMutation]
        let preparationSHA256: Data
        let commitProgram: CommitProgram
        let originalLiveRoot: InstallRootIdentity
        let stagedRoot: InstallRootIdentity
    }
    struct RolledBackBody: Codable, Equatable {
        let prepared: PreparedBody
        let frozenTransactionEntries: [SyncAccountRecoveryInventory.Entry]
    }
    struct AbortedPreparation: Codable, Equatable {
        let preparationSHA256: Data
        let sourceControlSHA256: Data?
        let pendingSnapshotSHA256: Data
        let outputAllocation: OutputAllocation
        let frozenOutputEntries: [SyncAccountRecoveryInventory.Entry]
    }
    enum Body: Codable, Equatable {
        case preparing(Preparing), prepared(PreparedBody), installed(PreparedBody), committed(PreparedBody)
        case rollingBack(PreparedBody), rolledBack(RolledBackBody), abortedPreparation(AbortedPreparation)
        private enum Keys: String, CodingKey {
            case phase, preparing, prepared, installed, committed, rollingBack, rolledBack, abortedPreparation
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let phase = try c.decode(String.self, forKey: .phase)
            try OwnedBootstrapCodec.keys(decoder, required: ["phase", phase])
            switch phase {
            case "preparing": self = .preparing(try c.decode(Preparing.self, forKey: .preparing))
            case "prepared": self = .prepared(try c.decode(PreparedBody.self, forKey: .prepared))
            case "installed": self = .installed(try c.decode(PreparedBody.self, forKey: .installed))
            case "committed": self = .committed(try c.decode(PreparedBody.self, forKey: .committed))
            case "rollingBack": self = .rollingBack(try c.decode(PreparedBody.self, forKey: .rollingBack))
            case "rolledBack": self = .rolledBack(try c.decode(RolledBackBody.self, forKey: .rolledBack))
            case "abortedPreparation": self = .abortedPreparation(try c.decode(AbortedPreparation.self, forKey: .abortedPreparation))
            default: throw SyncBootstrapError.corrupt
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case let .preparing(v): try c.encode("preparing", forKey: .phase); try c.encode(v, forKey: .preparing)
            case let .prepared(v): try c.encode("prepared", forKey: .phase); try c.encode(v, forKey: .prepared)
            case let .installed(v): try c.encode("installed", forKey: .phase); try c.encode(v, forKey: .installed)
            case let .committed(v): try c.encode("committed", forKey: .phase); try c.encode(v, forKey: .committed)
            case let .rollingBack(v): try c.encode("rollingBack", forKey: .phase); try c.encode(v, forKey: .rollingBack)
            case let .rolledBack(v): try c.encode("rolledBack", forKey: .phase); try c.encode(v, forKey: .rolledBack)
            case let .abortedPreparation(v): try c.encode("abortedPreparation", forKey: .phase); try c.encode(v, forKey: .abortedPreparation)
            }
        }
        var preparedBody: PreparedBody? {
            switch self {
            case let .prepared(v), let .installed(v), let .committed(v), let .rollingBack(v): v
            case let .rolledBack(v): v.prepared
            case .preparing, .abortedPreparation: nil
            }
        }
    }
    /// Narrow wire wrapper; existing output proofs retain their original API.
    struct OutputProof: Codable, Equatable {
        let byteCount: Int64
        let sha256: Data
        init(_ value: SyncBootstrapOutputProof) { byteCount = value.byteCount; sha256 = value.sha256 }
        var value: SyncBootstrapOutputProof { .init(byteCount: byteCount, sha256: sha256) }
    }
    struct CommitProgram: Codable, Equatable {
        let journalRelativePath: String
        let initialJournalDirectories: [String]
        let initialJournalFiles: [String: OutputProof]
        let operations: [CommitOperation]
    }
    enum CommitOperation: Codable, Equatable {
        case synchronize(path: String), directory(path: String), reuse(path: String, proof: OutputProof)
        case replace(path: String, old: OutputProof?, bytes: Data, temporaryID: UUID)
        case copyAttachment(path: String, sourceVersionID: UUID, proof: OutputProof, temporaryID: UUID)
        case appendSegment(expected: OutputProof?, frames: Data)
        private enum Keys: String, CodingKey { case kind, path, proof, old, bytes, temporaryID, sourceVersionID, expected, frames }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let kind = try c.decode(String.self, forKey: .kind)
            switch kind {
            case "synchronize", "directory":
                try OwnedBootstrapCodec.keys(decoder, required: ["kind", "path"])
                let path = try c.decode(String.self, forKey: .path)
                self = kind == "synchronize" ? .synchronize(path: path) : .directory(path: path)
            case "reuse":
                try OwnedBootstrapCodec.keys(decoder, required: ["kind", "path", "proof"])
                self = .reuse(path: try c.decode(String.self, forKey: .path), proof: try c.decode(OutputProof.self, forKey: .proof))
            case "replace":
                try OwnedBootstrapCodec.keys(decoder, required: ["kind", "path", "bytes", "temporaryID"], optional: ["old"])
                self = .replace(path: try c.decode(String.self, forKey: .path), old: try c.decodeIfPresent(OutputProof.self, forKey: .old),
                    bytes: try c.decode(Data.self, forKey: .bytes), temporaryID: try c.decode(UUID.self, forKey: .temporaryID))
            case "copyAttachment":
                try OwnedBootstrapCodec.keys(decoder, required: ["kind", "path", "sourceVersionID", "proof", "temporaryID"])
                self = .copyAttachment(path: try c.decode(String.self, forKey: .path), sourceVersionID: try c.decode(UUID.self, forKey: .sourceVersionID),
                    proof: try c.decode(OutputProof.self, forKey: .proof), temporaryID: try c.decode(UUID.self, forKey: .temporaryID))
            case "appendSegment":
                try OwnedBootstrapCodec.keys(decoder, required: ["kind", "frames"], optional: ["expected"])
                self = .appendSegment(expected: try c.decodeIfPresent(OutputProof.self, forKey: .expected), frames: try c.decode(Data.self, forKey: .frames))
            default: throw SyncBootstrapError.corrupt
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case let .synchronize(path): try c.encode("synchronize", forKey: .kind); try c.encode(path, forKey: .path)
            case let .directory(path): try c.encode("directory", forKey: .kind); try c.encode(path, forKey: .path)
            case let .reuse(path, proof):
                try c.encode("reuse", forKey: .kind); try c.encode(path, forKey: .path); try c.encode(proof, forKey: .proof)
            case let .replace(path, old, bytes, temporaryID):
                try c.encode("replace", forKey: .kind); try c.encode(path, forKey: .path); try c.encodeIfPresent(old, forKey: .old)
                try c.encode(bytes, forKey: .bytes); try c.encode(temporaryID, forKey: .temporaryID)
            case let .copyAttachment(path, sourceVersionID, proof, temporaryID):
                try c.encode("copyAttachment", forKey: .kind); try c.encode(path, forKey: .path); try c.encode(sourceVersionID, forKey: .sourceVersionID)
                try c.encode(proof, forKey: .proof); try c.encode(temporaryID, forKey: .temporaryID)
            case let .appendSegment(expected, frames):
                try c.encode("appendSegment", forKey: .kind); try c.encodeIfPresent(expected, forKey: .expected); try c.encode(frames, forKey: .frames)
            }
        }
    }
    let version: Int
    let id: UUID
    let context: SyncBootstrapContext
    let livePath: String
    let journalPath: String
    let sourceProof: SyncBootstrapSourceProof
    let original: [String: FileProof]
    let historyHead: BootstrapHistoryRef?
    var body: Body
    init(id: UUID, context: SyncBootstrapContext, livePath: String, journalPath: String,
         sourceProof: SyncBootstrapSourceProof, original: [String: FileProof], historyHead: BootstrapHistoryRef?, body: Body) {
        version = 3; self.id = id; self.context = context; self.livePath = livePath; self.journalPath = journalPath
        self.sourceProof = sourceProof; self.original = original; self.historyHead = historyHead; self.body = body
    }
    private struct Source: Codable {
        let value: SyncBootstrapSourceProof
        init(_ value: SyncBootstrapSourceProof) { self.value = value }
        private enum Keys: String, CodingKey { case kind, sha256, treeSHA256 }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "archive":
                try OwnedBootstrapCodec.keys(decoder, required: ["kind", "sha256"])
                value = .archive(sha256: try c.decode(Data.self, forKey: .sha256))
            case "missingArchive":
                try OwnedBootstrapCodec.keys(decoder, required: ["kind", "treeSHA256"])
                value = .missingArchive(treeSHA256: try c.decode(Data.self, forKey: .treeSHA256))
            default: throw SyncBootstrapError.corrupt
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch value {
            case let .archive(digest): try c.encode("archive", forKey: .kind); try c.encode(digest, forKey: .sha256)
            case let .missingArchive(digest): try c.encode("missingArchive", forKey: .kind); try c.encode(digest, forKey: .treeSHA256)
            }
        }
    }
    private struct Wire: Codable {
        let version: Int; let id: UUID; let context: SyncBootstrapContext
        let livePath: String; let journalPath: String; let sourceProof: Source
        let original: [String: FileProof]; let historyHead: BootstrapHistoryRef?; let body: Body
    }
    private var wire: Wire {
        .init(version: version, id: id, context: context, livePath: livePath, journalPath: journalPath,
              sourceProof: Source(sourceProof), original: original, historyHead: historyHead, body: body)
    }
    init(from decoder: Decoder) throws {
        let v = try OwnedBootstrapCodec.strict(Wire.self, from: decoder)
        version = v.version; id = v.id; context = v.context; livePath = v.livePath; journalPath = v.journalPath
        sourceProof = v.sourceProof.value; original = v.original; historyHead = v.historyHead; body = v.body
        try validate()
    }
    func encode(to encoder: Encoder) throws { try validate(); try wire.encode(to: encoder) }
    /// Encoding shape only, never a manifest or authority. A pending record's
    /// future bytes can be counted without allocating or decoding fake Data.
    func prospectiveEnvelopeByteCount(pendingRecordByteCount: Int? = nil) throws -> Int {
        let payload = try OwnedBootstrapCodec.encode(wire)
        let extra = try pendingRecordByteCount.map(SyncBootstrapRecoveryBudget.escapedBase64Maximum) ?? 0
        return try SyncBootstrapRecoveryBudget.ownedEnvelopeMaximum(payloadByteCount:
            SyncBootstrapRecoveryBudget.add(payload.count, extra))
    }
    func encoded(maximumBytes: Int = 100_000_000) throws -> Data { try SyncBootstrapOwnedManifestCodec.encode(self, maximumBytes: maximumBytes) }
    static func decodeEnvelope(_ bytes: Data, maximumBytes: Int = 100_000_000) throws -> Self {
        try SyncBootstrapOwnedManifestCodec.decode(bytes, maximumBytes: maximumBytes)
    }
    func normalizedPreparedDigest() throws -> Data { try SyncBootstrapOwnedManifestCodec.preparedSHA256(self) }
    var transactionRelativePath: String {
        ".KnitNote-SyncBootstrap/\(context.accountIDHash)/\(OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(livePath.utf8))))/\(id.uuidString)"
    }
    func validate() throws {
        guard version == 3, OwnedBootstrapCodec.isHash(context.accountIDHash),
              livePath.hasPrefix("/"), OwnedBootstrapCodec.relative(String(livePath.dropFirst())),
              OwnedBootstrapCodec.relative(journalPath), journalPath != "projects-v1.json",
              !SyncBootstrapTransaction.isReconstructionAuthority(journalPath) else { throw SyncBootstrapError.corrupt }
        try Self.validateProofs(original); try historyHead?.validate()
        switch sourceProof {
        case let .archive(digest):
            guard digest.count == 32, original["projects-v1.json"]?.digest == digest,
                  (original["projects-v1.json"]?.bytes ?? -1) >= 0 else { throw SyncBootstrapError.corrupt }
        case let .missingArchive(digest):
            guard digest.count == 32, !original.keys.contains(where: {
                $0 == "projects-v1.json" || $0.hasPrefix("projects-v1.json/") || SyncBootstrapTransaction.isReconstructionAuthority($0)
            }), digest == OwnedBootstrapCodec.hash(try OwnedBootstrapCodec.encode(original)) else { throw SyncBootstrapError.corrupt }
        }
        switch body {
        case let .preparing(v):
            try validatePreparation(control: v.sourceControlSHA256, pending: v.pendingSnapshotSHA256, allocation: v.outputAllocation)
            if let pending = v.predecessor {
                try pending.reference.validate(); _ = try OwnedBootstrapCodec.envelopePayload(pending.record)
                guard pending.reference.sha256 == OwnedBootstrapCodec.hash(pending.record), pending.reference.byteCount == pending.record.count else { throw SyncBootstrapError.corrupt }
                let (count, countOverflow) = (historyHead?.recordCount ?? 0).addingReportingOverflow(1)
                let (bytes, bytesOverflow) = (historyHead?.chainByteCount ?? 0).addingReportingOverflow(pending.reference.byteCount)
                guard !countOverflow, !bytesOverflow, pending.reference.recordCount == count, pending.reference.chainByteCount == bytes else { throw SyncBootstrapError.corrupt }
                // Terminal payload/previous link/supplied tree validation lives
                // in SyncBootstrapHistory. This decode is not lineage proof.
            }
        case let .abortedPreparation(v):
            guard v.preparationSHA256.count == 32 else { throw SyncBootstrapError.corrupt }
            try validatePreparation(control: v.sourceControlSHA256, pending: v.pendingSnapshotSHA256, allocation: v.outputAllocation)
            try validateFrozen(v.frozenOutputEntries, allocation: v.outputAllocation, prepared: nil)
        case let .rolledBack(v): try validatePrepared(v.prepared); try validateFrozen(v.frozenTransactionEntries, allocation: nil, prepared: v.prepared)
        case let .prepared(v), let .installed(v), let .committed(v), let .rollingBack(v): try validatePrepared(v)
        }
    }
    private func validatePreparation(control: Data?, pending: Data, allocation: OutputAllocation) throws {
        guard pending.count == 32, control.map({ $0.count == 32 }) ?? true,
              allocation.transactionID == id, !allocation.allowedRoles.isEmpty,
              Set(allocation.allowedRoles).count == allocation.allowedRoles.count,
              Set(allocation.roleLimits.map(\.role)) == Set(allocation.allowedRoles), allocation.roleLimits.count == allocation.allowedRoles.count,
              allocation.roleLimits.allSatisfy({ $0.maximumEntryCount >= 0 && (0...100_000_000).contains($0.reservedEncodedProofBytes) }) else { throw SyncBootstrapError.corrupt }
        if case .missingArchive = sourceProof, control == nil { throw SyncBootstrapError.corrupt }
    }
    // Shared only with the pure legacy-history bridge; ordinary legacy decode is unchanged.
    static func validateProofs(_ proofs: [String: FileProof]) throws {
        var aliases = Set<String>()
        for (name, proof) in proofs {
            let directory = name.hasSuffix("/"), path = name.hasSuffix("/") ? String(name.dropLast()) : name
            guard OwnedBootstrapCodec.relative(path), aliases.insert(OwnedBootstrapCodec.alias(path)).inserted,
                  directory ? (proof.bytes == -1 && proof.digest.isEmpty) : ((0...100_000_000).contains(proof.bytes) && proof.digest.count == 32) else { throw SyncBootstrapError.corrupt }
            for parent in OwnedBootstrapCodec.parents(path) {
                guard let index = proofs.index(forKey: parent + "/"), proofs[index].value.bytes == -1,
                      proofs[index].key.utf8.elementsEqual((parent + "/").utf8) else { throw SyncBootstrapError.corrupt }
            }
        }
    }
    private func validatePrepared(_ v: PreparedBody) throws {
        try Self.validateProofs(v.installed)
        guard v.preparationSHA256.count == 32, v.originalLiveRoot.device > 0, v.originalLiveRoot.inode > 0,
              v.stagedRoot.device > 0, v.stagedRoot.inode > 0, v.stagedRoot != v.originalLiveRoot,
              (v.installed["projects-v1.json"]?.bytes ?? -1) >= 0,
              OwnedBootstrapCodec.samePath(v.commitProgram.journalRelativePath, journalPath),
              Set(v.mutations.map(\.mutationID)).count == v.mutations.count else { throw SyncBootstrapError.corrupt }
        for mutation in v.mutations {
            // Metadata-only journal validation does not read attachment files.
            _ = try mutation.validatedForJournalLoad()
            if let source = mutation.attachmentSource, source.byteCount > 100_000_000 { throw SyncBootstrapError.corrupt }
        }
        try validateCommit(v.commitProgram, installed: v.installed)
    }
    private func validateFrozen(_ entries: [SyncAccountRecoveryInventory.Entry], allocation: OutputAllocation?, prepared: PreparedBody?) throws {
        let root = transactionRelativePath
        if entries.isEmpty { guard prepared == nil else { throw SyncBootstrapError.corrupt }; return }
        guard entries.map(\.relativePath) == entries.map(\.relativePath).sorted(by: OwnedBootstrapCodec.pathOrder),
              entries.first?.relativePath == root, entries.first?.isDirectory == true else { throw SyncBootstrapError.corrupt }
        var indexed: [String: SyncAccountRecoveryInventory.Entry] = [:]
        var aliases = Set<String>(), identities = Set<InstallRootIdentity>()
        let roles = Set(allocation?.allowedRoles.map(\.directoryName) ?? (Role.allCases.map(\.directoryName) + ["Failed"]))
        for entry in entries {
            let path = entry.relativePath
            guard OwnedBootstrapCodec.relative(path), path == root || path.hasPrefix(root + "/"),
                  aliases.insert(OwnedBootstrapCodec.alias(path)).inserted, entry.device > 0, entry.inode > 0,
                  identities.insert(.init(device: entry.device, inode: entry.inode)).inserted,
                  entry.isDirectory ? (entry.byteCount == 0 && entry.sha256.isEmpty) : ((0...100_000_000).contains(entry.byteCount) && entry.sha256.count == 32) else { throw SyncBootstrapError.corrupt }
            if path != root {
                let relative = String(path.dropFirst(root.count + 1))
                let parent = OwnedBootstrapCodec.parent(path)
                guard let role = relative.split(separator: "/").first, roles.contains(String(role)),
                      let index = indexed.index(forKey: parent), indexed[index].value.isDirectory,
                      indexed[index].key.utf8.elementsEqual(parent.utf8) else { throw SyncBootstrapError.corrupt }
                if !relative.contains("/"), !entry.isDirectory { throw SyncBootstrapError.corrupt }
            }
            indexed[path] = entry
        }
        if let allocation {
            for limit in allocation.roleLimits {
                let prefix = root + "/" + limit.role.directoryName
                let selected = entries.filter { $0.relativePath == prefix || $0.relativePath.hasPrefix(prefix + "/") }
                guard selected.count <= limit.maximumEntryCount,
                      try selected.isEmpty || (OwnedBootstrapCodec.encode(selected).count <= limit.reservedEncodedProofBytes) else { throw SyncBootstrapError.corrupt }
            }
        }
        if let prepared {
            guard indexed[root + "/Original"]?.isDirectory == true else { throw SyncBootstrapError.corrupt }
            var actual: [String: FileProof] = [:]
            let prefix = root + "/Original/"
            for entry in entries where entry.relativePath.hasPrefix(prefix) {
                let path = String(entry.relativePath.dropFirst(prefix.count)) + (entry.isDirectory ? "/" : "")
                actual[path] = .init(bytes: entry.isDirectory ? -1 : entry.byteCount, digest: entry.sha256)
            }
            guard actual.count == original.count,
                  actual.allSatisfy({ OwnedBootstrapCodec.exactValue($0.key, in: original) == $0.value }),
                  !(indexed[root + "/Failed"] != nil && indexed[root + "/Staged"] != nil) else { throw SyncBootstrapError.corrupt }
            for role in ["Staged", "Failed"] {
                if let entry = indexed[root + "/" + role] {
                    guard entry.device == prepared.stagedRoot.device, entry.inode == prepared.stagedRoot.inode else { throw SyncBootstrapError.corrupt }
                }
            }
        }
    }
    private func validateCommit(_ program: CommitProgram, installed: [String: FileProof]) throws {
        let journal = program.journalRelativePath, parent = OwnedBootstrapCodec.parent(program.journalRelativePath)
        let attachments = (parent.isEmpty ? "" : parent + "/") + "." + String(journal.split(separator: "/").last!) + ".attachments"
        let receipt = "SyncMetadata/bootstrap-receipt.json"
        let journalDirectories = Set(OwnedBootstrapCodec.parents(journal) + [attachments])
        let directories = journalDirectories.union(["SyncMetadata"])
        func attachmentChild(_ path: String, exact: Bool = true) -> Bool {
            OwnedBootstrapCodec.relative(path) && (exact
                ? OwnedBootstrapCodec.samePath(OwnedBootstrapCodec.parent(path), attachments)
                : OwnedBootstrapCodec.parent(path) == attachments)
        }
        func existingAttachment(_ path: String, exact: Bool = true) -> Bool {
            guard attachmentChild(path, exact: exact) else { return false }
            let initial = exact ? OwnedBootstrapCodec.exactValue(path, in: program.initialJournalFiles) : program.initialJournalFiles[path]
            let installed = exact ? OwnedBootstrapCodec.exactValue(path, in: installed) : installed[path]
            guard let initial, let installed else { return false }
            return installed == FileProof(bytes: initial.byteCount, digest: initial.sha256)
        }
        func attachmentVersion(_ path: String, exact: Bool = true) -> UUID? {
            let prefixMatches = exact ? OwnedBootstrapCodec.hasExactPrefix(path, attachments + "/") : path.hasPrefix(attachments + "/")
            guard prefixMatches, path.hasSuffix(".asset") else { return nil }
            let name = String(path.dropFirst(attachments.count + 1).dropLast(6))
            guard name.count == 73, name[name.index(name.startIndex, offsetBy: 36)] == "-",
                  let mutation = UUID(uuidString: String(name.prefix(36))), let version = UUID(uuidString: String(name.suffix(36))),
                  name == mutation.uuidString + "-" + version.uuidString else { return nil }; return version
        }
        func journalFile(_ path: String, exact: Bool = true) -> Bool {
            let files = [journal, journal + ".checkpoint", journal + ".segment", journal + ".migrated"]
            let fileMatches = exact ? OwnedBootstrapCodec.containsExactPath(files, path) : files.contains(path)
            if fileMatches || attachmentVersion(path, exact: exact) != nil || existingAttachment(path, exact: exact) { return true }
            let prefix = journal + ".proofs."
            guard exact ? OwnedBootstrapCodec.hasExactPrefix(path, prefix) : path.hasPrefix(prefix) else { return false }
            let suffix = String(path.dropFirst(prefix.count))
            // %08d is a minimum width, not an eight-digit maximum.
            guard suffix.utf8.allSatisfy({ (48...57).contains($0) }), let index = Int(suffix), index >= 0 else { return false }
            return suffix == String(repeating: "0", count: max(0, 8 - String(index).count)) + String(index)
        }
        func proof(_ v: OutputProof, path: String) throws {
            let maximum: Int64 = path == receipt || attachmentChild(path) ? 100_000_000 : 64 * 1_024 * 1_024
            guard (0...maximum).contains(v.byteCount), v.sha256.count == 32 else { throw SyncBootstrapError.corrupt }
        }
        guard program.initialJournalDirectories == program.initialJournalDirectories.sorted(by: OwnedBootstrapCodec.pathOrder),
              Set(program.initialJournalDirectories).count == program.initialJournalDirectories.count else { throw SyncBootstrapError.corrupt }
        for directory in program.initialJournalDirectories {
            guard OwnedBootstrapCodec.relative(directory), OwnedBootstrapCodec.containsExactPath(journalDirectories, directory),
                  OwnedBootstrapCodec.exactValue(directory + "/", in: installed)?.bytes == -1 else { throw SyncBootstrapError.corrupt }
        }
        for (path, value) in program.initialJournalFiles {
            try proof(value, path: path)
            guard OwnedBootstrapCodec.relative(path), journalFile(path),
                  OwnedBootstrapCodec.exactValue(path, in: installed) == FileProof(bytes: value.byteCount, digest: value.sha256),
                  OwnedBootstrapCodec.parents(path).allSatisfy({ OwnedBootstrapCodec.containsExactPath(program.initialJournalDirectories, $0) }) else { throw SyncBootstrapError.corrupt }
        }
        for (path, value) in installed {
            if path.hasSuffix("/") {
                let directory = String(path.dropLast())
                // Canonical comparison here only detects aliases to reject. It
                // must never select a different spelling as exact journal proof.
                if journalDirectories.contains(directory) {
                    guard OwnedBootstrapCodec.containsExactPath(journalDirectories, directory),
                          OwnedBootstrapCodec.containsExactPath(program.initialJournalDirectories, directory) else { throw SyncBootstrapError.corrupt }
                }
            } else if journalFile(path, exact: false) || attachmentChild(path, exact: false) {
                guard journalFile(path), OwnedBootstrapCodec.exactValue(path, in: program.initialJournalFiles)
                    == OutputProof(.init(byteCount: value.bytes, sha256: value.digest)) else { throw SyncBootstrapError.corrupt }
            }
        }
        var temporaryPaths = Set<String>()
        func temporary(_ path: String, _ id: UUID) throws {
            let parent = OwnedBootstrapCodec.parent(path), name = String(path.split(separator: "/").last!)
            let temporary = (parent.isEmpty ? "" : parent + "/") + "." + name + "." + id.uuidString + ".tmp"
            guard OwnedBootstrapCodec.relative(temporary), temporaryPaths.insert(temporary).inserted else { throw SyncBootstrapError.corrupt }
        }
        for operation in program.operations {
            switch operation {
            case let .synchronize(path):
                guard OwnedBootstrapCodec.relative(path), OwnedBootstrapCodec.containsExactPath(directories, path) || journalFile(path) || path == receipt else { throw SyncBootstrapError.corrupt }
            case let .directory(path):
                guard OwnedBootstrapCodec.relative(path), OwnedBootstrapCodec.containsExactPath(directories, path) else { throw SyncBootstrapError.corrupt }
            case let .reuse(path, value):
                try proof(value, path: path)
                guard OwnedBootstrapCodec.relative(path), journalFile(path) || path == receipt else { throw SyncBootstrapError.corrupt }
                if attachmentChild(path), attachmentVersion(path) == nil {
                    guard OwnedBootstrapCodec.exactValue(path, in: program.initialJournalFiles) == value else { throw SyncBootstrapError.corrupt }
                }
            case let .replace(path, old, bytes, temporaryID):
                if let old { try proof(old, path: path) }
                guard OwnedBootstrapCodec.relative(path), journalFile(path) || path == receipt, attachmentVersion(path) == nil,
                      !attachmentChild(path), bytes.count <= (path == receipt ? 100_000_000 : 64 * 1_024 * 1_024) else { throw SyncBootstrapError.corrupt }
                try temporary(path, temporaryID)
                if path == receipt {
                    let value = try OwnedBootstrapCodec.strictData(SyncBootstrapReceipt.self, bytes: bytes)
                    guard value.transactionID == id, value.accountIDHash == context.accountIDHash, value.sourceProof == sourceProof else { throw SyncBootstrapError.corrupt }
                }
            case let .copyAttachment(path, sourceVersionID, value, temporaryID):
                try proof(value, path: path)
                guard OwnedBootstrapCodec.relative(path), attachmentVersion(path) == sourceVersionID else { throw SyncBootstrapError.corrupt }
                try temporary(path, temporaryID)
            case let .appendSegment(expected, frames):
                if let expected { try proof(expected, path: journal + ".segment") }
                guard frames.count <= 64 * 1_024 * 1_024, (expected?.byteCount ?? 0) <= Int64(64 * 1_024 * 1_024 - frames.count) else { throw SyncBootstrapError.corrupt }
            }
        }
    }
}

/// These pure codecs are the planned downstream seam, never a terminal reader.
enum SyncBootstrapOwnedManifestCodec {
    static func encode(_ manifest: BootstrapManifestV3, maximumBytes: Int = 100_000_000) throws -> Data {
        try OwnedBootstrapCodec.checkLimit(maximumBytes)
        let payload = try OwnedBootstrapCodec.encode(manifest)
        guard payload.count <= maximumBytes else { throw SyncBootstrapError.corrupt }
        let bytes = try OwnedBootstrapCodec.encode(OwnedBootstrapCodec.Envelope(payload: payload, digest: OwnedBootstrapCodec.hash(payload)))
        guard bytes.count <= maximumBytes else { throw SyncBootstrapError.corrupt }; return bytes
    }
    static func decode(_ bytes: Data, maximumBytes: Int = 100_000_000) throws -> BootstrapManifestV3 {
        try JSONDecoder().decode(BootstrapManifestV3.self, from: OwnedBootstrapCodec.envelopePayload(bytes, maximumBytes: maximumBytes))
    }
    static func preparedSHA256(_ manifest: BootstrapManifestV3) throws -> Data {
        try manifest.validate()
        guard let prepared = manifest.body.preparedBody else { throw SyncBootstrapError.invalidPhase }
        var normalized = manifest; normalized.body = .prepared(prepared)
        return OwnedBootstrapCodec.hash(try OwnedBootstrapCodec.encode(normalized))
    }
}

/// Strict shape comparison reaches reused legacy values without changing their
/// decoders. Only keys/nulls are compared: UInt64 identities are never rounded.
enum OwnedBootstrapCodec {
    struct Envelope: Codable { let payload: Data; let digest: Data }
    static func hash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
    static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value) // Preserve legacy slash escaping.
    }
    static func checkLimit(_ limit: Int) throws { guard (0...100_000_000).contains(limit) else { throw SyncBootstrapError.corrupt } }
    static func envelopePayload(_ bytes: Data, maximumBytes: Int = 100_000_000) throws -> Data {
        try checkLimit(maximumBytes)
        guard bytes.count <= maximumBytes else { throw SyncBootstrapError.corrupt }
        let envelope = try strictData(Envelope.self, bytes: bytes)
        guard envelope.payload.count <= maximumBytes, envelope.digest.count == 32, hash(envelope.payload) == envelope.digest else { throw SyncBootstrapError.corrupt }
        return envelope.payload
    }
    static func strictData<T: Codable>(_ type: T.Type, bytes: Data) throws -> T {
        let value = try JSONDecoder().decode(type, from: bytes)
        guard try JSONDecoder().decode(Shape.self, from: bytes) == JSONDecoder().decode(Shape.self, from: encode(value)) else { throw SyncBootstrapError.corrupt }
        return value
    }
    static func strict<T: Codable>(_ type: T.Type, from decoder: Decoder) throws -> T {
        let value = try T(from: decoder)
        guard try Shape(from: decoder) == JSONDecoder().decode(Shape.self, from: encode(value)) else { throw SyncBootstrapError.corrupt }; return value
    }
    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func keys(_ decoder: Decoder, required: Set<String>, optional: Set<String> = []) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let actual = Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else { throw SyncBootstrapError.corrupt }
        for key in c.allKeys where try c.decodeNil(forKey: key) { throw SyncBootstrapError.corrupt }
    }
    private enum Shape: Decodable, Equatable {
        case object([String: Shape]), array([Shape]), scalar, null
        init(from decoder: Decoder) throws {
            if let c = try? decoder.container(keyedBy: Key.self) {
                var fields: [String: Shape] = [:]
                for key in c.allKeys { fields[key.stringValue] = try c.decode(Shape.self, forKey: key) }; self = .object(fields)
            } else if var c = try? decoder.unkeyedContainer() {
                var values: [Shape] = []
                while !c.isAtEnd { values.append(try c.decode(Shape.self)) }; self = .array(values)
            } else { self = try decoder.singleValueContainer().decodeNil() ? .null : .scalar }
        }
    }
    static func isHash(_ string: String) -> Bool { string.utf8.count == 64 && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func relative(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= 1_024 && parts.count <= 128 && !path.contains("\\") && !path.utf8.contains(0)
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }
    }
    static func alias(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    // String/Dictionary equality intentionally treats canonical Unicode forms as
    // equivalent. Cross-field filesystem proofs instead bind their exact bytes.
    static func samePath(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    static func hasExactPrefix(_ path: String, _ prefix: String) -> Bool { path.utf8.starts(with: prefix.utf8) }
    static func containsExactPath<S: Sequence>(_ paths: S, _ path: String) -> Bool where S.Element == String {
        paths.contains { samePath($0, path) }
    }
    static func exactValue<Value>(_ path: String, in values: [String: Value]) -> Value? {
        guard let index = values.index(forKey: path), samePath(values[index].key, path) else { return nil }
        return values[index].value
    }
    static func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
    static func parents(_ path: String) -> [String] {
        let parts = path.split(separator: "/"); guard parts.count > 1 else { return [] }
        return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
    }
    static func pathOrder(_ lhs: String, _ rhs: String) -> Bool { lhs.split(separator: "/").lexicographicallyPrecedes(rhs.split(separator: "/")) }
}
