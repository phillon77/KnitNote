import Foundation

public enum PatternLibrarySort: String, CaseIterable, Sendable {
    case recentlyAdded
    case name
}

public struct PatternLibraryRowModel: Identifiable, Equatable, Sendable {
    public let patternID: UUID
    public let name: String
    public let note: String?
    public let activeProjectNames: [String]
    public let createdAt: Date

    public var id: UUID { patternID }
    public var activeLinkCount: Int { activeProjectNames.count }

    public init(
        patternID: UUID,
        name: String,
        note: String?,
        activeProjectNames: [String],
        createdAt: Date
    ) {
        self.patternID = patternID
        self.name = name
        self.note = note
        self.activeProjectNames = activeProjectNames
        self.createdAt = createdAt
    }
}

public struct PatternLibraryIndex: Sendable {
    private let sourceRows: [PatternLibraryRowModel]
    private let locale: Locale

    public init(rows: [PatternLibraryRowModel], locale: Locale) {
        sourceRows = rows
        self.locale = locale
    }

    public func rows(sortedBy sort: PatternLibrarySort) -> [PatternLibraryRowModel] {
        sourceRows.sorted { lhs, rhs in
            switch sort {
            case .recentlyAdded:
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
            case .name:
                break
            }
            let order = localizedStandardCompare(lhs.name, rhs.name)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhs.patternID.uuidString < rhs.patternID.uuidString
        }
    }

    public func search(
        _ query: String,
        sortedBy sort: PatternLibrarySort = .recentlyAdded
    ) -> [PatternLibraryRowModel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows(sortedBy: sort).filter { row in
            guard !trimmed.isEmpty else { return true }
            return matches(row.name, query: trimmed)
                || row.note.map { matches($0, query: trimmed) } == true
                || row.activeProjectNames.contains { matches($0, query: trimmed) }
        }
    }

    private func matches(_ value: String, query: String) -> Bool {
        value.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: locale
        ) != nil
    }

    private func localizedStandardCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if locale.identifier == Locale.current.identifier {
            return lhs.localizedStandardCompare(rhs)
        }
        return lhs.compare(
            rhs,
            options: [.caseInsensitive, .diacriticInsensitive, .numeric, .widthInsensitive],
            range: nil,
            locale: locale
        )
    }
}
