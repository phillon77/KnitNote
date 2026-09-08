import Foundation

/// Frozen content declarations only; no physical ownership or semantic-content certification.
struct KnitNoteBackupFrozenTree: Equatable, Sendable {
    let archiveData: Data
    let directories: Set<String> // source-relative, no root entry, complete projected tree
    let files: [String: SyncBootstrapOutputProof]
}

struct KnitNoteBackupPackagePlan: Sendable {
    let role: SyncBootstrapOutputRole
    let packageID: UUID
    let archiveData: Data
    let manifestData: Data
    let sourceFiles: [String: SyncBootstrapOutputProof] // selected dependencies, including archive
    let temporaryIDs: [String: UUID] // keys are exact role-relative final file paths
    let actions: [SyncBootstrapOutputAction]
    let output: SyncBootstrapOutputPlan
}


