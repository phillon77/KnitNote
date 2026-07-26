import Foundation

public enum ProjectPatternLinkStatus: Equatable, Sendable {
    case link
    case relink
}

public struct ProjectPatternLinkOption: Identifiable, Equatable, Sendable {
    public let pattern: StoredPattern
    public let status: ProjectPatternLinkStatus

    public var id: UUID { pattern.id }

    public init(pattern: StoredPattern, status: ProjectPatternLinkStatus) {
        self.pattern = pattern
        self.status = status
    }
}

public struct ProjectPatternLinkIndex: Sendable {
    public let options: [ProjectPatternLinkOption]

    public init(
        patterns: [StoredPattern],
        usages: [PatternProjectUsage],
        projectID: UUID,
        locale: Locale
    ) {
        let projectUsages = Dictionary(
            uniqueKeysWithValues: usages
                .filter { $0.projectID == projectID }
                .map { ($0.patternID, $0) }
        )
        options = patterns.compactMap { pattern in
            if let usage = projectUsages[pattern.id] {
                return usage.isActive
                    ? nil
                    : ProjectPatternLinkOption(pattern: pattern, status: .relink)
            }
            return ProjectPatternLinkOption(pattern: pattern, status: .link)
        }.sorted { lhs, rhs in
            let order = lhs.pattern.displayName.compare(
                rhs.pattern.displayName,
                options: [.caseInsensitive, .diacriticInsensitive, .numeric, .widthInsensitive],
                range: nil,
                locale: locale
            )
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
