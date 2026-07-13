import Foundation

public enum ProjectValidationError: Error, Equatable { case emptyName }

public struct StoredProject: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public private(set) var currentRow: Int
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var rowNotes: [RowNote]
    public private(set) var patterns: [PatternDocument]

    public init(id: UUID = UUID(), name: String, currentRow: Int = 0, now: Date = .now) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ProjectValidationError.emptyName }
        self.id = id; self.name = clean; self.currentRow = max(0, currentRow)
        createdAt = now; updatedAt = now
        rowNotes = []
        patterns = []
    }
    public mutating func rename(to value: String, now: Date = .now) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ProjectValidationError.emptyName }
        name = clean; updatedAt = now
    }
    public mutating func completeRow(now: Date = .now) { currentRow += 1; updatedAt = now }
    public mutating func undoRow(now: Date = .now) { currentRow = max(0, currentRow - 1); updatedAt = now }
    public var sortedNotes: [RowNote] { rowNotes.sorted { $0.row > $1.row } }
    public func note(row: Int) -> RowNote? { rowNotes.first { $0.row == row } }
    public mutating func saveNote(row: Int, text: String, now: Date = .now) throws {
        guard row >= 0 else { throw ProjectValidationError.emptyName }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { deleteNote(row: row, now: now); return }
        if let i = rowNotes.firstIndex(where: { $0.row == row }) { rowNotes[i].text = clean; rowNotes[i].updatedAt = now }
        else { rowNotes.append(RowNote(row: row, text: clean, createdAt: now, updatedAt: now)) }
        updatedAt = now
    }
    public mutating func deleteNote(row: Int, now: Date = .now) {
        let old = rowNotes.count; rowNotes.removeAll { $0.row == row }; if rowNotes.count != old { updatedAt = now }
    }

    public mutating func addPattern(_ pattern: PatternDocument) { patterns.append(pattern); updatedAt = .now }
    public mutating func deletePattern(id: UUID) { patterns.removeAll { $0.id == id }; updatedAt = .now }
    public mutating func renamePattern(id: UUID, name: String) { if let i = patterns.firstIndex(where: {$0.id == id}) { patterns[i].displayName = name; updatedAt = .now } }
    public mutating func updatePatternState(id: UUID, state: PatternReadingState, now: Date = .now) { if let i = patterns.firstIndex(where: {$0.id == id}) { patterns[i].pageIndex=state.pageIndex; patterns[i].zoomScale=state.zoomScale; patterns[i].contentOffsetX=state.offsetX; patterns[i].contentOffsetY=state.offsetY; patterns[i].highlightEnabled=state.highlightEnabled; patterns[i].highlightPosition=state.highlightPosition; patterns[i].highlightMode=state.highlightMode; patterns[i].verticalHighlightPosition=state.verticalHighlightPosition; patterns[i].highlightPageIndex=state.highlightPageIndex; patterns[i].lastOpenedAt = now; updatedAt = now } }
    public mutating func updatePatternState(id: UUID, pageIndex: Int, highlightPosition: Double) { updatePatternState(id: id, state: .init(pageIndex: pageIndex, highlightPosition: highlightPosition)) }

    enum CodingKeys: String, CodingKey { case id, name, currentRow, createdAt, updatedAt, rowNotes, patterns }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        currentRow = try c.decode(Int.self, forKey: .currentRow); createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt); rowNotes = try c.decodeIfPresent([RowNote].self, forKey: .rowNotes) ?? []; patterns = try c.decodeIfPresent([PatternDocument].self, forKey: .patterns) ?? []
    }
}
