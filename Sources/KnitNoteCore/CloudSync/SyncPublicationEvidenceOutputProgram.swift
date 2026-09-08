import CryptoKit
import Foundation

/// Complete caller-supplied Staged projection. This is accounting data, not ownership evidence.
struct SyncPublicationEvidenceFrozenTree {
    struct File {
        let path: String
        let proof: SyncBootstrapOutputProof
        let bytes: Data?
    }
    let directories: [String]
    let files: [File]
}

enum SyncPublicationEvidenceOutputError: Error, Equatable {
    case invalidTree, invalidProof, missingSelectedBytes, collision
}

/// A save suffix and its exact initial-tree precondition. A future owner must establish that
/// precondition with its complete prefix and plan prefix + all helper suffixes once.
/// No step performs I/O, validates physical ownership, or certifies durability.
struct SyncPublicationEvidenceOutputProgram {
    struct Output {
        let action: SyncBootstrapOutputAction
        let bytes: Data?
    }
    enum Step {
        case output(Output)
        /// The named entry's parent must be synchronized; this reserves no extra entry.
        case synchronizeParentDirectory(path: String)
    }
    let expectedInitialTree: SyncPublicationEvidenceFrozenTree
    /// The single lock begins at its action and lasts through the final head write's durability.
    let steps: [Step]
    let compactHeadBytes: Data
    let finalDirectories: [String]
    let finalFiles: [SyncPublicationEvidenceFrozenTree.File]
    var actions: [SyncBootstrapOutputAction] {
        steps.compactMap { if case let .output(output) = $0 { return output.action }; return nil }
    }
}

/// Pure staged-tree assembly; semantic selection and private wire codecs live with the ordinary save.
struct SyncPublicationEvidenceOutputBuilder {
    typealias Tree = SyncPublicationEvidenceFrozenTree
    typealias Program = SyncPublicationEvidenceOutputProgram
    typealias Error = SyncPublicationEvidenceOutputError
    private enum Node { case directory, file(Int) }
    private enum Draft {
        case output(SyncBootstrapOutputAction)
        case sync(String)
        case write(String, SyncBootstrapOutputWriteMode, Data)
    }
    private let initial: Tree
    private var nodes: [String: Node] = [:]
    private var aliases: [String: String] = [:]
    private var drafts: [Draft] = []
    private var directories: [String]
    private var files: [Tree.File]

    static func proof(_ bytes: Data) -> SyncBootstrapOutputProof {
        .init(byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)))
    }
    private static func validate(_ proof: SyncBootstrapOutputProof) throws {
        guard (0...100_000_000).contains(proof.byteCount), proof.sha256.count == 32 else { throw Error.invalidProof }
    }
    private static func alias(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func validatePath(_ path: String, directory: Bool) throws {
        if path.isEmpty { guard directory else { throw Error.invalidTree }; return }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // The finite namespace contributes four components plus the Staged role.
        guard parts.count <= (directory ? 122 : 123),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }),
              !path.contains("\\"), !path.utf8.contains(0) else { throw Error.invalidTree }
    }
    private func checkSpelling(_ path: String) throws {
        if let old = aliases[Self.alias(path)], !old.utf8.elementsEqual(path.utf8) { throw Error.collision }
    }
    private func requireParent(_ path: String) throws {
        guard !path.isEmpty else { return }
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        guard let index = nodes.index(forKey: parent), case .directory = nodes[index].value else { throw Error.invalidTree }
        guard nodes[index].key.utf8.elementsEqual(parent.utf8) else { throw Error.collision }
    }
    init(initial: Tree) throws {
        self.initial = initial; directories = initial.directories; files = initial.files
        // Check arrays before building node dictionaries: Swift String equality merges NFC/NFD.
        let raw = initial.directories.map { ($0, true) } + initial.files.map { ($0.path, false) }
        var seen = Set<String>()
        for (path, directory) in raw {
            try Self.validatePath(path, directory: directory)
            guard seen.insert(Self.alias(path)).inserted else { throw Error.collision }
        }
        guard initial.directories.contains("") else { throw Error.invalidTree }
        for path in initial.directories { nodes[path] = .directory; aliases[Self.alias(path)] = path }
        for (index, file) in initial.files.enumerated() {
            try Self.validate(file.proof)
            if let bytes = file.bytes, Self.proof(bytes) != file.proof { throw Error.invalidProof }
            nodes[file.path] = .file(index); aliases[Self.alias(file.path)] = file.path
        }
        for (path, _) in raw { try requireParent(path) }
        for path in ["SyncMetadata", "SyncMetadata/attachment-versions.attachment-records",
                     "SyncMetadata/attachment-versions.attachment-tombstones", "SyncMetadata/attachment-versions.watch-proofs"] {
            try checkSpelling(path)
            if case .file? = nodes[path] { throw Error.invalidTree }
        }
        _ = try existingFile("SyncMetadata/attachment-versions.json")
        if let lock = try existingFile("SyncMetadata/.attachment-versions.json.lock"), lock.proof != Self.proof(Data()) {
            throw Error.invalidProof
        }
    }
    func existingFile(_ path: String) throws -> Tree.File? {
        try checkSpelling(path)
        switch nodes[path] {
        case let .file(index): return files[index]
        case .directory: throw Error.invalidTree
        case nil: return nil
        }
    }
    func selectedBytes(_ path: String) throws -> Data? {
        guard let file = try existingFile(path) else { return nil }
        guard let bytes = file.bytes else { throw Error.missingSelectedBytes }
        return bytes
    }
    mutating func directory(_ path: String) throws {
        try Self.validatePath(path, directory: true); try checkSpelling(path)
        if case .directory? = nodes[path] { return }
        guard nodes[path] == nil else { throw Error.invalidTree }
        try requireParent(path)
        nodes[path] = .directory; aliases[Self.alias(path)] = path; directories.append(path)
        drafts.append(.output(.directory(role: .staged, path: path))); drafts.append(.sync(path))
    }
    mutating func beginSave() throws {
        try directory("SyncMetadata")
        let path = "SyncMetadata/.attachment-versions.json.lock", empty = Self.proof(Data())
        let old = try existingFile(path)
        try requireParent(path)
        if old == nil {
            nodes[path] = .file(files.count); aliases[Self.alias(path)] = path
            files.append(.init(path: path, proof: empty, bytes: Data()))
        }
        drafts.append(.output(.lock(role: .staged, path: path, expectedExisting: old?.proof)))
    }
    mutating func immutable(_ path: String, bytes: Data) throws {
        if let existing = try existingFile(path) {
            // The caller has already checked selected semantic bytes. Retain their original proof.
            drafts.append(.output(.reuseExact(role: .staged, path: path, proof: existing.proof)))
            drafts.append(.sync(path))
            return
        }
        let components = path.split(separator: "/")
        try directory(components.dropLast(2).joined(separator: "/"))
        try directory(components.dropLast().joined(separator: "/"))
        try write(path, bytes: bytes)
    }
    mutating func write(_ path: String, bytes: Data) throws {
        try Self.validatePath(path, directory: false); try checkSpelling(path); try requireParent(path)
        guard let name = path.split(separator: "/").last, name.utf8.count + 42 <= 255 else { throw Error.invalidTree }
        let new = Self.proof(bytes)
        try Self.validate(new)
        let old = try existingFile(path)
        let mode: SyncBootstrapOutputWriteMode = old.map { .replace(expected: $0.proof, new: new) } ?? .create(new)
        let entry = Tree.File(path: path, proof: new, bytes: bytes)
        if case let .file(index)? = nodes[path] { files[index] = entry }
        else { nodes[path] = .file(files.count); files.append(entry) }
        aliases[Self.alias(path)] = path
        drafts.append(.write(path, mode, bytes))
    }
    mutating func finish(headBytes: Data, temporaryID: () -> UUID) throws -> Program {
        var steps: [Program.Step] = []
        // All non-temporary semantics and shape checks completed while making drafts.
        // Reserve against the entire projected tree and all earlier temporary paths.
        for draft in drafts {
            switch draft {
            case let .output(action): steps.append(.output(.init(action: action, bytes: nil)))
            case let .sync(path): steps.append(.synchronizeParentDirectory(path: path))
            case let .write(path, mode, bytes):
                let id = temporaryID(), parts = path.split(separator: "/").map(String.init)
                let temporary = (parts.dropLast() + ["." + parts.last! + "." + id.uuidString + ".tmp"]).joined(separator: "/")
                try Self.validatePath(temporary, directory: false); try checkSpelling(temporary)
                guard nodes[temporary] == nil, aliases[Self.alias(temporary)] == nil else { throw Error.collision }
                aliases[Self.alias(temporary)] = temporary
                steps.append(.output(.init(action: .write(role: .staged, path: path, mode: mode, temporaryID: id), bytes: bytes)))
            }
        }
        return .init(expectedInitialTree: initial, steps: steps, compactHeadBytes: headBytes,
            finalDirectories: directories, finalFiles: files)
    }
}
