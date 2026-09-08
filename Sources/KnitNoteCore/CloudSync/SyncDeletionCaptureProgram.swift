import CryptoKit
import Foundation

/// Frozen projections and obligations only; none of these values certify physical ownership.
enum SyncDeletionFrozenLedger {
    case absent
    case present(manifestBytes: Data, directories: Set<String>, files: [String: SyncBootstrapOutputProof])
}

struct SyncDeletionCaptureRequest {
    let domain: SyncDeletedDomain
    let exactRemovalVersions: [SyncRecordVersion]
    let deletedAt: Date
    let currentRecords: [SyncRecord]
    let currentArchive: ProjectArchive
    let attachments: [UUID: SyncBootstrapOutputProof]
    let restoreRelativePaths: [UUID: String]
    let supportingAttachments: [UUID: SyncBootstrapOutputProof]
    let counterReminderContext: SyncCounterReminderMergeContext
}

struct SyncDeletionCaptureAllocation {
    let stagedEntryID: UUID
    let liveValidationID: UUID
    let restoredValidationID: UUID
    let restoredAttachmentIDs: [UUID: UUID]
}

struct SyncDeletionCaptureProgram {
    enum Source {
        case incoming(requestIndex: Int, attachmentID: UUID)
        case initialRetained(path: String)
        case earlierOutput(stepIndex: Int)
    }
    enum Content {
        case bytes(Data)
        case copy(source: Source, proof: SyncBootstrapOutputProof)
    }
    struct Output {
        let action: SyncBootstrapOutputAction
        let content: Content?
    }
    struct Validation {
        enum Comparison {
            case liveArchive(ProjectArchive)
            case restorationPaths([SyncAttachmentSlot: String])
        }
        let records: [SyncRecord]
        let baseArchive: ProjectArchive
        let sources: [UUID: Int]
        let counterReminderContext: SyncCounterReminderMergeContext?
        let comparison: Comparison
    }
    enum Step {
        case output(Output)
        case validate(Validation)
    }
    struct Capture {
        let stagedManifestBytes: Data
        let finalManifestBytes: Data
        let retainedEntry: SyncDeletionEntry
    }
    let expectedInitialLedger: SyncDeletionFrozenLedger
    let initialManifestBytes: Data?
    let steps: [Step]
    let captures: [Capture]
    let finalManifestBytes: Data?
    let finalDirectories: Set<String>
    let finalFiles: [String: SyncBootstrapOutputProof]
}

/// Local semantic builder. It retains ordered content before allocating any temporary identities.
struct SyncDeletionCaptureProgramBuilder {
    typealias Program = SyncDeletionCaptureProgram
    private enum Draft {
        case output(SyncBootstrapOutputAction)
        case write(SyncBootstrapOutputRole, String, SyncBootstrapOutputWriteMode, Program.Content)
        case validate(Program.Validation)
    }
    private enum Node: Equatable { case directory, file(SyncBootstrapOutputProof) }
    private var nodes: [String: Node] = [:]
    private var aliases: [String: String] = [:]
    private var drafts: [Draft] = []
    private var immutableWrites: [Int: SyncBootstrapOutputProof] = [:]
    private(set) var directories: Set<String> = []
    private(set) var files: [String: SyncBootstrapOutputProof] = [:]
    private(set) var origins: [String: Program.Source] = [:]

    static func proof(_ bytes: Data) -> SyncBootstrapOutputProof {
        .init(byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)))
    }
    static func validate(_ proof: SyncBootstrapOutputProof) throws {
        guard (0...100_000_000).contains(proof.byteCount), proof.sha256.count == 32 else {
            throw SyncDeletionLedgerError.corrupt
        }
    }
    private func key(_ role: SyncBootstrapOutputRole, _ path: String) -> String { role.rawValue + "/" + path }
    private mutating func register(_ path: String, node: Node) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 124, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }),
              !path.contains("\\"), !path.utf8.contains(0) else { throw SyncDeletionLedgerError.unsafePath }
        if node == .directory, components.count == 124 { throw SyncDeletionLedgerError.unsafePath }
        let alias = path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if let old = aliases[alias], !old.utf8.elementsEqual(path.utf8) { throw SyncDeletionLedgerError.unsafePath }
        aliases[alias] = path
        if let old = nodes[path] {
            guard old == node else { throw SyncDeletionLedgerError.unsafePath }
        }
        if components.count > 1 {
            let parent = components.dropLast().joined(separator: "/")
            guard let index = nodes.index(forKey: parent), nodes[index].value == .directory,
                  nodes[index].key.utf8.elementsEqual(parent.utf8) else { throw SyncDeletionLedgerError.unsafePath }
        }
        nodes[path] = node
    }
    init(initial: SyncDeletionFrozenLedger) throws {
        nodes["Staged"] = .directory
        nodes["ValidationMerged"] = .directory
        if case let .present(bytes, dirs, supplied) = initial {
            guard dirs.contains(""), supplied["ledger.json"] == Self.proof(bytes) else { throw SyncDeletionLedgerError.corrupt }
            for path in dirs.sorted(by: { $0.utf8.count < $1.utf8.count }) {
                try register(key(.staged, path.isEmpty ? ".sync-deletions" : ".sync-deletions/" + path), node: .directory)
            }
            for (path, proof) in supplied {
                try Self.validate(proof)
                guard !path.isEmpty else { throw SyncDeletionLedgerError.unsafePath }
                try register(key(.staged, ".sync-deletions/" + path), node: .file(proof))
                origins[path] = .initialRetained(path: path)
            }
            directories = dirs; files = supplied
        }
    }
    mutating func directory(_ role: SyncBootstrapOutputRole, _ path: String, reuse: Bool = false) throws {
        let full = key(role, path)
        if reuse, nodes[full] == .directory {
            try register(full, node: .directory)
            return
        }
        guard nodes[full] == nil else { throw SyncDeletionLedgerError.unsafePath }
        try register(full, node: .directory)
        drafts.append(.output(.directory(role: role, path: path)))
        if role == .staged {
            directories.insert(path == ".sync-deletions" ? "" : String(path.dropFirst(".sync-deletions/".count)))
        }
    }
    mutating func lock() throws {
        let path = ".sync-deletions/.ledger.json.lock", empty = Self.proof(Data())
        let old = files[".ledger.json.lock"]
        guard old == nil || old == empty else { throw SyncDeletionLedgerError.corrupt }
        try register(key(.staged, path), node: .file(empty))
        files[".ledger.json.lock"] = empty
        drafts.append(.output(.lock(role: .staged, path: path, expectedExisting: old)))
    }
    @discardableResult mutating func write(_ role: SyncBootstrapOutputRole, _ path: String,
        proof: SyncBootstrapOutputProof, content: Program.Content, replace: Bool = false) throws -> Int {
        try Self.validate(proof)
        guard let filename = path.split(separator: "/").last, filename.utf8.count + 42 <= 255 else {
            throw SyncDeletionLedgerError.unsafePath
        }
        switch content {
        case let .bytes(data): guard Self.proof(data) == proof else { throw SyncDeletionLedgerError.corrupt }
        case let .copy(source, copied):
            guard proof == copied else { throw SyncDeletionLedgerError.corrupt }
            if case let .earlierOutput(index) = source {
                guard immutableWrites[index] == proof, index < drafts.count else { throw SyncDeletionLedgerError.corrupt }
            }
        }
        let full = key(role, path)
        let mode: SyncBootstrapOutputWriteMode
        if replace, case let .file(old)? = nodes[full] { mode = .replace(expected: old, new: proof); nodes.removeValue(forKey: full) }
        else { guard nodes[full] == nil else { throw SyncDeletionLedgerError.unsafePath }; mode = .create(proof) }
        try register(full, node: .file(proof))
        let index = drafts.count
        drafts.append(.write(role, path, mode, content))
        if path != ".sync-deletions/ledger.json" { immutableWrites[index] = proof }
        if role == .staged {
            let relative = String(path.dropFirst(".sync-deletions/".count))
            files[relative] = proof; origins[relative] = .earlierOutput(stepIndex: index)
        }
        return index
    }
    mutating func reuse(_ path: String, proof: SyncBootstrapOutputProof) throws {
        guard files[path] == proof else { throw SyncDeletionLedgerError.witnessMismatch }
        try register(key(.staged, ".sync-deletions/" + path), node: .file(proof))
        drafts.append(.output(.reuseExact(role: .staged, path: ".sync-deletions/" + path, proof: proof)))
    }
    mutating func validation(_ job: Program.Validation) {
        drafts.append(.validate(job))
    }
    mutating func scratch(id: UUID, sources: [UUID: (Program.Source, SyncBootstrapOutputProof)]) throws -> [UUID: Int] {
        guard !sources.isEmpty else { return [:] }
        try directory(.validationMerged, "DeletionValidation", reuse: true)
        let path = "DeletionValidation/" + id.uuidString
        try directory(.validationMerged, path)
        var result: [UUID: Int] = [:]
        for id in sources.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let (source, proof) = sources[id]!
            result[id] = try write(.validationMerged, path + "/" + id.uuidString, proof: proof, content: .copy(source: source, proof: proof))
        }
        return result
    }
    mutating func finish(temporaryID: () -> UUID) throws -> [Program.Step] {
        var result: [Program.Step] = []
        for draft in drafts {
            switch draft {
            case let .output(action): result.append(.output(.init(action: action, content: nil)))
            case let .validate(job): result.append(.validate(job))
            case let .write(role, path, mode, content):
                let id = temporaryID()
                let components = path.split(separator: "/").map(String.init)
                let temporary = (components.dropLast() + ["." + components.last! + "." + id.uuidString + ".tmp"]).joined(separator: "/")
                let full = key(role, temporary)
                guard nodes[full] == nil else { throw SyncDeletionLedgerError.unsafePath }
                let proof: SyncBootstrapOutputProof
                switch mode { case let .create(p): proof = p; case let .replace(_, p): proof = p }
                try register(full, node: .file(proof))
                result.append(.output(.init(action: .write(role: role, path: path, mode: mode, temporaryID: id), content: content)))
            }
        }
        return result
    }
}
