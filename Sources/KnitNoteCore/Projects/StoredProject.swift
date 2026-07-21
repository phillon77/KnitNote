import Foundation
import CryptoKit

public enum ProjectValidationError: Error, Equatable { case emptyName }

public enum ProjectToolType: String, Codable, CaseIterable, Sendable {
    case crochetHook
    case knittingNeedles
    case other
}

public struct PatternProjectGroup: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let projectName: String
    public let patterns: [PatternDocument]
    public init(id: UUID, projectName: String, patterns: [PatternDocument]) {
        self.id = id; self.projectName = projectName; self.patterns = patterns
    }
}

public func patternGroups(from projects: [StoredProject]) -> [PatternProjectGroup] {
    projects.compactMap { project in
        guard !project.patterns.isEmpty else { return nil }
        return PatternProjectGroup(id: project.id, projectName: project.name, patterns: project.patterns)
    }
}

public struct StoredProject: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var counters: [ProjectCounter]
    public private(set) var selectedCounterID: UUID
    public private(set) var patterns: [PatternDocument]
    public private(set) var photoFilename: String?
    public private(set) var completedAt: Date?
    public private(set) var toolType: ProjectToolType?
    public private(set) var toolSize: String?
    public private(set) var toolNotes: String?
    public private(set) var journalEntries: [ProjectJournalEntry]

    public init(
        id: UUID = UUID(),
        name: String,
        counters: [ProjectCounter]? = nil,
        selectedCounterID: UUID? = nil,
        completedAt: Date? = nil,
        journalEntries: [ProjectJournalEntry] = [],
        now: Date = .now
    ) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ProjectValidationError.emptyName }
        self.id = id
        self.name = clean
        self.counters = Self.normalizedCounters(counters ?? [], projectID: id)
        self.selectedCounterID = Self.selectedID(selectedCounterID, in: self.counters)
        self.createdAt = now
        self.updatedAt = now
        self.patterns = []
        self.photoFilename = nil
        self.completedAt = completedAt
        self.toolType = nil
        self.toolSize = nil
        self.toolNotes = nil
        guard Set(journalEntries.map(\.id)).count == journalEntries.count else {
            throw ProjectJournalEntryError.duplicateIdentifier
        }
        guard Self.hasValidJournalOwnership(journalEntries, projectID: id) else {
            throw ProjectJournalEntryError.invalidFilename
        }
        self.journalEntries = journalEntries.sorted(by: Self.isJournalEntryOrderedBefore)
    }
    public mutating func rename(to value: String, now: Date = .now) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ProjectValidationError.emptyName }
        guard name != clean else { return }
        name = clean; updatedAt = now
    }
    public mutating func updateToolDetails(
        type: ProjectToolType?,
        size: String?,
        notes: String?,
        now: Date = .now
    ) {
        let cleanSize = Self.normalizedOptionalText(size)
        let cleanNotes = Self.normalizedOptionalText(notes)
        guard toolType != type || toolSize != cleanSize || toolNotes != cleanNotes else { return }
        toolType = type
        toolSize = cleanSize
        toolNotes = cleanNotes
        updatedAt = now
    }
    public var selectedCounter: ProjectCounter { counters.first { $0.id == selectedCounterID } ?? counters[0] }
    public var isCompleted: Bool { completedAt != nil }

    public mutating func markCompleted(at date: Date = .now) {
        guard completedAt == nil else { return }
        completedAt = date
        updatedAt = date
    }
    public mutating func resume(at date: Date = .now) {
        guard completedAt != nil else { return }
        completedAt = nil
        updatedAt = date
    }

    public mutating func selectCounter(id: UUID, now: Date = .now) {
        guard counters.contains(where: { $0.id == id }), selectedCounterID != id else { return }
        selectedCounterID = id
        updatedAt = now
    }
    public mutating func incrementCounter(id: UUID, now: Date = .now) {
        guard !isCompleted else { return }
        mutateCounter(id: id, now: now) { $0.increment() }
    }
    public mutating func decrementCounter(id: UUID, now: Date = .now) {
        guard !isCompleted else { return }
        mutateCounter(id: id, now: now) { $0.decrement() }
    }
    public mutating func resetCounter(id: UUID, now: Date = .now) {
        guard !isCompleted else { return }
        mutateCounter(id: id, now: now) { $0.reset() }
    }
    public mutating func updateCounter(id: UUID, name: String?, value: Int, now: Date = .now) {
        guard !isCompleted else { return }
        mutateCounter(id: id, now: now) { $0.update(name: name, value: value) }
    }
    public mutating func renameCounter(id: UUID, to name: String?, now: Date = .now) {
        guard !isCompleted else { return }
        mutateCounter(id: id, now: now) { $0.rename(to: name) }
    }
    public mutating func setPhotoFilename(_ filename: String?, now: Date = .now) { photoFilename = filename; updatedAt = now }
    public func note(counterID: UUID, row: Int) -> RowNote? { counters.first { $0.id == counterID }?.note(row: row) }
    public mutating func saveNote(counterID: UUID, row: Int, text: String, now: Date = .now) throws {
        guard let index = counters.firstIndex(where: { $0.id == counterID }) else { return }
        if try counters[index].saveNote(row: row, text: text, now: now) { updatedAt = now }
    }
    public mutating func deleteNote(counterID: UUID, row: Int, now: Date = .now) {
        mutateCounter(id: counterID, now: now) { $0.deleteNote(row: row) }
    }

    public mutating func addPattern(_ pattern: PatternDocument) { patterns.append(pattern); updatedAt = .now }
    public mutating func deletePattern(id: UUID) { patterns.removeAll { $0.id == id }; updatedAt = .now }
    public mutating func renamePattern(id: UUID, name: String) { if let i = patterns.firstIndex(where: {$0.id == id}) { patterns[i].displayName = name; updatedAt = .now } }
    public mutating func savePatternPageNote(patternID: UUID, pageIndex: Int, text: String, now: Date = .now) { if let i = patterns.firstIndex(where: {$0.id == patternID}) { patterns[i].setPageNote(text, pageIndex: pageIndex); updatedAt = now } }
    public mutating func updatePatternState(id: UUID, state: PatternReadingState, now: Date = .now) { if let i = patterns.firstIndex(where: {$0.id == id}) { patterns[i].pageIndex=state.pageIndex; patterns[i].zoomScale=state.zoomScale; patterns[i].contentOffsetX=state.offsetX; patterns[i].contentOffsetY=state.offsetY; patterns[i].highlightEnabled=state.highlightEnabled; patterns[i].highlightPosition=state.highlightPosition; patterns[i].highlightMode=state.highlightMode; patterns[i].verticalHighlightPosition=state.verticalHighlightPosition; patterns[i].pageStates=state.pageStates; patterns[i].lastOpenedAt = now; updatedAt = now } }
    public mutating func updatePatternState(id: UUID, pageIndex: Int, highlightPosition: Double) { updatePatternState(id: id, state: .init(pageIndex: pageIndex, highlightPosition: highlightPosition)) }

    public mutating func addJournalEntry(_ entry: ProjectJournalEntry, now: Date = .now) throws {
        guard !isCompleted else { throw ProjectJournalMutationError.projectCompleted }
        guard Self.hasValidJournalOwnership([entry], projectID: id) else {
            throw ProjectJournalEntryError.invalidFilename
        }
        guard !journalEntries.contains(where: { $0.id == entry.id }) else { return }
        journalEntries.append(entry)
        journalEntries.sort(by: Self.isJournalEntryOrderedBefore)
        updatedAt = now
    }

    public mutating func updateJournalCaption(id: UUID, caption: String?, now: Date = .now) throws {
        guard !isCompleted else { throw ProjectJournalMutationError.projectCompleted }
        guard let index = journalEntries.firstIndex(where: { $0.id == id }) else {
            throw ProjectJournalMutationError.entryNotFound
        }
        guard journalEntries[index].updateCaption(caption) else { return }
        updatedAt = now
    }

    @discardableResult
    public mutating func deleteJournalEntry(id: UUID, now: Date = .now) throws -> ProjectJournalEntry {
        guard !isCompleted else { throw ProjectJournalMutationError.projectCompleted }
        guard let index = journalEntries.firstIndex(where: { $0.id == id }) else {
            throw ProjectJournalMutationError.entryNotFound
        }
        updatedAt = now
        return journalEntries.remove(at: index)
    }

    enum CodingKeys: String, CodingKey { case id, name, counters, selectedCounterID, currentRow, createdAt, updatedAt, rowNotes, patterns, photoFilename, completedAt, toolType, toolSize, toolNotes, journalEntries }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        patterns = try c.decodeIfPresent([PatternDocument].self, forKey: .patterns) ?? []
        photoFilename = try c.decodeIfPresent(String.self, forKey: .photoFilename)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        toolType = try c.decodeIfPresent(ProjectToolType.self, forKey: .toolType)
        toolSize = try c.decodeIfPresent(String.self, forKey: .toolSize)
        toolNotes = try c.decodeIfPresent(String.self, forKey: .toolNotes)
        let decodedJournalEntries = try c.decodeIfPresent([ProjectJournalEntry].self, forKey: .journalEntries) ?? []
        guard Set(decodedJournalEntries.map(\.id)).count == decodedJournalEntries.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .journalEntries,
                in: c,
                debugDescription: "Journal entry identifiers must be unique."
            )
        }
        guard Self.hasValidJournalOwnership(decodedJournalEntries, projectID: id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .journalEntries,
                in: c,
                debugDescription: "Journal photo filenames must belong to their owning project."
            )
        }
        journalEntries = decodedJournalEntries.sorted(by: Self.isJournalEntryOrderedBefore)

        if let decodedCounters = try c.decodeIfPresent([ProjectCounter].self, forKey: .counters) {
            counters = Self.normalizedCounters(decodedCounters, projectID: id)
            selectedCounterID = Self.selectedID(try c.decodeIfPresent(UUID.self, forKey: .selectedCounterID), in: counters)
        } else {
            let legacyRow = try c.decodeIfPresent(Int.self, forKey: .currentRow) ?? 0
            let legacyNotes = try c.decodeIfPresent([RowNote].self, forKey: .rowNotes) ?? []
            counters = Self.normalizedCounters(
                [
                    ProjectCounter(
                        id: Self.generatedCounterID(projectID: id, ordinal: 1),
                        defaultOrdinal: 1,
                        value: legacyRow,
                        rowNotes: legacyNotes
                    )
                ],
                projectID: id
            )
            selectedCounterID = counters[0].id
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(counters, forKey: .counters)
        try c.encode(selectedCounterID, forKey: .selectedCounterID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(patterns, forKey: .patterns)
        try c.encodeIfPresent(photoFilename, forKey: .photoFilename)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(toolType, forKey: .toolType)
        try c.encodeIfPresent(toolSize, forKey: .toolSize)
        try c.encodeIfPresent(toolNotes, forKey: .toolNotes)
        try c.encode(journalEntries, forKey: .journalEntries)
    }

    private mutating func mutateCounter(id: UUID, now: Date, _ mutation: (inout ProjectCounter) -> Bool) {
        guard let index = counters.firstIndex(where: { $0.id == id }), mutation(&counters[index]) else { return }
        updatedAt = now
    }

    private static func selectedID(_ requestedID: UUID?, in counters: [ProjectCounter]) -> UUID {
        guard let requestedID, counters.contains(where: { $0.id == requestedID }) else { return counters[0].id }
        return requestedID
    }

    private static func normalizedOptionalText(_ value: String?) -> String? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else {
            return nil
        }
        return clean
    }

    private static func isJournalEntryOrderedBefore(
        _ lhs: ProjectJournalEntry,
        _ rhs: ProjectJournalEntry
    ) -> Bool {
        lhs.createdAt == rhs.createdAt
            ? lhs.id.uuidString > rhs.id.uuidString
            : lhs.createdAt > rhs.createdAt
    }

    private static func hasValidJournalOwnership(
        _ entries: [ProjectJournalEntry],
        projectID: UUID
    ) -> Bool {
        entries.allSatisfy {
            ProjectJournalPhotoFilename.isOwnedPair(
                full: $0.photoFilename,
                thumbnail: $0.thumbnailFilename,
                projectID: projectID,
                entryID: $0.id
            )
        }
    }

    private static func normalizedCounters(
        _ candidates: [ProjectCounter],
        projectID: UUID
    ) -> [ProjectCounter] {
        let reservedCandidateIDs = Set(candidates.map(\.id))
        var usedIDs = Set<UUID>()
        return (1...6).map { ordinal in
            let candidate = candidates.last { $0.defaultOrdinal == ordinal }
            let id: UUID
            if let candidate, usedIDs.insert(candidate.id).inserted {
                id = candidate.id
            } else {
                id = nextGeneratedCounterID(
                    projectID: projectID,
                    ordinal: ordinal,
                    excluding: reservedCandidateIDs.union(usedIDs)
                )
                usedIDs.insert(id)
            }
            return ProjectCounter(
                id: id,
                defaultOrdinal: ordinal,
                customName: candidate?.customName,
                value: candidate?.value ?? 0,
                mutationRevision: candidate?.mutationRevision ?? 0,
                rowNotes: candidate?.rowNotes ?? []
            )
        }
    }

    private static func nextGeneratedCounterID(
        projectID: UUID,
        ordinal: Int,
        excluding excludedIDs: Set<UUID>
    ) -> UUID {
        var attempt = 0
        while true {
            let candidate = generatedCounterID(
                projectID: projectID,
                ordinal: ordinal,
                attempt: attempt
            )
            if !excludedIDs.contains(candidate) { return candidate }
            attempt += 1
        }
    }

    private static func generatedCounterID(
        projectID: UUID,
        ordinal: Int,
        attempt: Int = 0
    ) -> UUID {
        let namespace = UUID(uuidString: "B11BBE8E-4873-5E4C-AF15-773BA9DD5B33")!
        var input = Data()
        withUnsafeBytes(of: namespace.uuid) { input.append(contentsOf: $0) }
        withUnsafeBytes(of: projectID.uuid) { input.append(contentsOf: $0) }
        var ordinalBytes = UInt32(ordinal).bigEndian
        var attemptBytes = UInt32(attempt).bigEndian
        withUnsafeBytes(of: &ordinalBytes) { input.append(contentsOf: $0) }
        withUnsafeBytes(of: &attemptBytes) { input.append(contentsOf: $0) }

        var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
