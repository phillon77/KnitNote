import Foundation

struct SyncDeletedDomain: Codable, Sendable {
    let rootIDs: Set<SyncEntityID>
    let ownedRecords: [SyncRecord]
    let supportingParentIDs: Set<SyncEntityID>
    let removedReminders: [UUID: [KnittingReminder]]
    let removedLegacyPatterns: [UUID: [PatternDocument]]

    init(rootIDs: Set<SyncEntityID>, ownedRecords: [SyncRecord],
         supportingParentIDs: Set<SyncEntityID>, removedReminders: [UUID: [KnittingReminder]],
         removedLegacyPatterns: [UUID: [PatternDocument]] = [:]) {
        self.rootIDs = rootIDs
        self.ownedRecords = ownedRecords
        self.supportingParentIDs = supportingParentIDs
        self.removedReminders = removedReminders
        self.removedLegacyPatterns = removedLegacyPatterns
    }
}

struct SyncDeletionFileProof: Codable, Equatable, Sendable {
    let attachmentVersionID: UUID
    let restoreRelativePath: String
    let retainedRelativePath: String
    let byteCount: Int64
    let sha256: Data
}

struct SyncDeletionEntry: Codable, Sendable {
    let id: UUID
    let deletedAt: Date
    let domain: SyncDeletedDomain
    let exactRemovalVersions: [SyncRecordVersion]
    let files: [SyncDeletionFileProof]
}
