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

    /// Select only actual removals. Embedded values remain aggregate members;
    /// shared relationships contribute supporting identities, never payloads.
    static func capture(before: [SyncRecord], after: [SyncRecord],
                        beforeArchive: ProjectArchive, afterArchive: ProjectArchive) throws -> Self? {
        let afterByID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        let removed = before.filter {
            $0.deletedAt.value == nil && (afterByID[$0.id] == nil || afterByID[$0.id]?.deletedAt.value != nil)
        }
        let removedIDs = Set(removed.map(\.id))
        let removedSlots = Set(removed.compactMap { $0.payload.attachment?.slot })
        let owned = before.filter { removedIDs.contains($0.id) || $0.payload.attachment.map { removedSlots.contains($0.slot) } == true }
        let ownedIDs = Set(owned.map(\.id))
        var reminders: [UUID: [KnittingReminder]] = [:]
        var legacy: [UUID: [PatternDocument]] = [:]
        for project in beforeArchive.projects {
            guard let current = afterArchive.projects.first(where: { $0.id == project.id }) else { continue }
            let currentReminders = Set(current.knittingReminders.map(\.id))
            for reminder in project.knittingReminders where !currentReminders.contains(reminder.id)
                && !ownedIDs.contains(.init(kind: .projectCounter, uuid: reminder.counterID)) {
                reminders[reminder.counterID, default: []].append(reminder)
            }
            let currentPatterns = Set(current.patterns.map(\.id))
            let selected = project.patterns.filter { !currentPatterns.contains($0.id) }
            if !selected.isEmpty { legacy[project.id] = selected }
        }
        guard !owned.isEmpty || !reminders.isEmpty || !legacy.isEmpty else { return nil }
        let legacyIDs = Set(legacy.values.flatMap { $0 }.map { SyncEntityID(kind: .pattern, uuid: $0.id) })
            .union(beforeArchive.projects.filter { ownedIDs.contains(.init(kind: .project, uuid: $0.id)) }
                .flatMap(\.patterns).map { .init(kind: .pattern, uuid: $0.id) })
        let supporting = Set(owned.flatMap(\.relationships).map(\.target))
            .subtracting(ownedIDs).subtracting(legacyIDs)
            .union(reminders.keys.map { .init(kind: .projectCounter, uuid: $0) })
            .union(legacy.keys.map { .init(kind: .project, uuid: $0) })
        var roots = Set(removed.filter { record in
            !record.relationships.contains { ownedIDs.contains($0.target) || legacyIDs.contains($0.target) }
        }.map(\.id))
        roots.formUnion(reminders.keys.map { .init(kind: .projectCounter, uuid: $0) })
        roots.formUnion(legacy.values.flatMap { $0 }.map { .init(kind: .pattern, uuid: $0.id) })
        return .init(rootIDs: roots, ownedRecords: owned, supportingParentIDs: supporting,
                     removedReminders: reminders, removedLegacyPatterns: legacy)
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
