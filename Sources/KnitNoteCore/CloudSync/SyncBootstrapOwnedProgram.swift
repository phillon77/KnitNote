import CryptoKit
import Foundation

struct SyncBootstrapOwnedInput {
    let local: SyncExportPackage?
    let sourceArchive: ProjectArchive
    let remote: SyncBootstrapRemoteSnapshot
    let pending: SyncBootstrapPendingSnapshot?
    let counterReminderContext: SyncCounterReminderMergeContext
}

/// Read-only request and accounting description. No value grants output authority.
struct SyncBootstrapOwnedProgram {
    enum Source {
        case live(path: String, proof: SyncBootstrapOutputProof)
        case attachment(versionID: UUID, proof: SyncBootstrapOutputProof)
        case output(index: Int, proof: SyncBootstrapOutputProof)
        case helperOutput(programIndex: Int, actionIndex: Int, proof: SyncBootstrapOutputProof)
    }
    enum Content {
        case bytes(Data)
        case copy(Source)
    }
    struct Output {
        let action: SyncBootstrapOutputAction
        let content: Content?
    }
    enum Step {
        case output(Output)
        case backup(index: Int, initial: KnitNoteBackupFrozenTree, establishedRoleRoot: Bool)
        case validateLocal(ProjectArchiveSyncUnvalidatedProjection, expected: ProjectArchive)
        case validateMaterialization(ProjectArchiveSyncUnvalidatedProjection)
        case deletion
        case publication
    }
    let transactionID: UUID
    let actions: [SyncBootstrapOutputAction]
    let backupPackages: [KnitNoteBackupPackagePlan]
    let deletion: SyncDeletionCaptureProgram
    let deletionRequests: [SyncDeletionCaptureRequest]
    let deletionAllocations: [SyncDeletionCaptureAllocation]
    let publication: SyncPublicationEvidenceOutputProgram
    let reservation: SyncBootstrapOutputPlan
    let preparingEnvelope: Data
    let maximumRecoveryEnvelopeBytes: Int
    let lifetimeScenarios: [SyncBootstrapRecoveryBudget.Scenario]
    let steps: [Step]
    let attachmentSources: [UUID: SyncAttachmentSource]
    let attachmentIdentities: [UUID: SyncRegularFileIdentity]
    let projection: ProjectArchiveSyncUnvalidatedProjection
    let mutations: [SyncMutation]
    let commitProgram: BootstrapManifestV3.CommitProgram
    let finalJournalFiles: [String: BootstrapManifestV3.OutputProof]
    let initialInventory: SyncAccountRecoveryInventory
    let initialControl: SyncAccountControlObservation
}

/// Mutable semantic projection only. Actual content stays in immutable ordered
/// output steps; replacing a destination cannot overwrite earlier copy bytes.
struct SyncBootstrapOwnedProgramBuilder {
    struct File {
        let proof: SyncBootstrapOutputProof
        let origin: SyncBootstrapOwnedProgram.Source
    }
    struct Tree {
        var directories: Set<String> = [""]
        var files: [String: File] = [:]
    }
    var steps: [SyncBootstrapOwnedProgram.Step] = []
    var actions: [SyncBootstrapOutputAction] = []
    var trees: [SyncBootstrapOutputRole: Tree] = [:]
    var backupPackages: [KnitNoteBackupPackagePlan] = []
    var temporaryID: () -> UUID = UUID.init

    static func proof(_ bytes: Data) -> SyncBootstrapOutputProof {
        .init(byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)))
    }
    mutating func establish(_ role: SyncBootstrapOutputRole) {
        guard trees[role] == nil else { return }
        trees[role] = Tree()
        output(.directory(role: role, path: ""), content: nil)
    }
    private mutating func output(_ action: SyncBootstrapOutputAction,
                                 content: SyncBootstrapOwnedProgram.Content?) {
        actions.append(action); steps.append(.output(.init(action: action, content: content)))
    }
    mutating func directory(_ role: SyncBootstrapOutputRole, _ path: String) throws {
        establish(role)
        for parent in OwnedBootstrapCodec.parents(path) + [path] where !parent.isEmpty {
            guard trees[role]!.files[parent] == nil else { throw SyncBootstrapError.unsafePath }
            if trees[role]!.directories.insert(parent).inserted {
                output(.directory(role: role, path: parent), content: nil)
            }
        }
    }
    mutating func write(_ role: SyncBootstrapOutputRole, _ path: String,
        proof: SyncBootstrapOutputProof, content: SyncBootstrapOwnedProgram.Content) throws {
        try directory(role, OwnedBootstrapCodec.parent(path))
        guard !trees[role]!.directories.contains(path) else { throw SyncBootstrapError.unsafePath }
        let old = trees[role]!.files[path]?.proof
        let mode: SyncBootstrapOutputWriteMode = old.map { .replace(expected: $0, new: proof) } ?? .create(proof)
        let index = steps.count
        output(.write(role: role, path: path, mode: mode, temporaryID: temporaryID()), content: content)
        trees[role]!.files[path] = .init(proof: proof, origin: .output(index: index, proof: proof))
    }
    mutating func write(_ role: SyncBootstrapOutputRole, _ path: String, bytes: Data) throws {
        try write(role, path, proof: Self.proof(bytes), content: .bytes(bytes))
    }
    mutating func copy(_ tree: Tree, to role: SyncBootstrapOutputRole) throws {
        establish(role)
        // The ordinary copy walks the source proof keys, whose directory
        // spelling has a trailing slash. Preserve its interleaved order.
        let paths = tree.directories.filter { !$0.isEmpty }.map { $0 + "/" } + Array(tree.files.keys)
        for path in paths.sorted() {
            if path.hasSuffix("/") { try directory(role, String(path.dropLast())) }
            else {
                let source = tree.files[path]!
                try write(role, path, proof: source.proof, content: .copy(source.origin))
            }
        }
    }
    /// Apply helper actions only to the projection. Their original program and
    /// local source/validation indices remain intact in the execution step.
    mutating func appendHelper(_ supplied: [SyncBootstrapOutputAction], step: SyncBootstrapOwnedProgram.Step,
                              mayConsumeRoot: SyncBootstrapOutputRole? = nil) throws {
        var consumed = false
        let index = steps.count
        for (actionIndex, action) in supplied.enumerated() {
            switch action {
            case let .directory(role, path):
                if path.isEmpty, trees[role] != nil {
                    guard mayConsumeRoot == role, !consumed else { throw SyncBootstrapError.unsafePath }
                    consumed = true; continue
                }
                if path.isEmpty { trees[role] = Tree() }
                else {
                    guard trees[role] != nil, !trees[role]!.directories.contains(path),
                          trees[role]!.files[path] == nil,
                          trees[role]!.directories.contains(OwnedBootstrapCodec.parent(path)) else {
                        throw SyncBootstrapError.unsafePath
                    }
                    trees[role]!.directories.insert(path)
                }
            case let .write(role, path, mode, _):
                let proof: SyncBootstrapOutputProof
                switch mode {
                case let .create(value):
                    guard trees[role]?.files[path] == nil else { throw SyncBootstrapError.sourceChanged }; proof = value
                case let .replace(expected, value):
                    guard trees[role]?.files[path]?.proof == expected else { throw SyncBootstrapError.sourceChanged }; proof = value
                }
                guard trees[role]?.directories.contains(OwnedBootstrapCodec.parent(path)) == true else {
                    throw SyncBootstrapError.unsafePath
                }
                trees[role]!.files[path] = .init(proof: proof,
                    origin: .helperOutput(programIndex: index, actionIndex: actionIndex, proof: proof))
            case let .reuseExact(role, path, proof):
                guard trees[role]?.files[path]?.proof == proof else { throw SyncBootstrapError.sourceChanged }
            case let .lock(role, path, old):
                guard trees[role]?.files[path]?.proof == old else { throw SyncBootstrapError.sourceChanged }
                let proof = Self.proof(Data())
                trees[role]!.files[path] = .init(proof: proof,
                    origin: .helperOutput(programIndex: index, actionIndex: actionIndex, proof: proof))
            }
            actions.append(action)
        }
        steps.append(step)
    }
}
