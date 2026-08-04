import Foundation

public enum ProjectPatternAddAction: CaseIterable, Identifiable, Sendable {
    case linkExisting
    case importFile
    case addYouTube

    public var id: Self { self }

    public var localizationKey: String {
        switch self {
        case .linkExisting: "patterns.linkExisting"
        case .importFile: "patterns.importNew"
        case .addYouTube: "patterns.youtube.add"
        }
    }

    public var systemImageName: String {
        switch self {
        case .linkExisting: "link.badge.plus"
        case .importFile: "square.and.arrow.down"
        case .addYouTube: "play.rectangle"
        }
    }
}

public enum ProjectPatternOpenRoute: Equatable, Sendable {
    case reader
    case externalYouTube
}

public func projectPatternOpenRoute(for asset: PatternAsset) -> ProjectPatternOpenRoute {
    switch asset.kind {
    case .youtube: .externalYouTube
    case .pdf, .image: .reader
    }
}

public enum ProjectPatternLinkStatus: Equatable, Sendable {
    case link
    case relink
}

public struct ProjectPatternLinkChoice: Identifiable, Equatable, Sendable {
    public let option: ProjectPatternLinkOption
    public let asset: PatternAsset

    public var id: UUID { option.id }

    public init(option: ProjectPatternLinkOption, asset: PatternAsset) {
        self.option = option
        self.asset = asset
    }
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

public struct ProjectPatternLinkChoiceIndex: Sendable {
    public let options: [ProjectPatternLinkChoice]

    public init(
        patterns: [StoredPattern],
        assets: [PatternAsset],
        usages: [PatternProjectUsage],
        projectID: UUID,
        locale: Locale
    ) {
        options = ProjectPatternLinkIndex(
            patterns: patterns,
            usages: usages,
            projectID: projectID,
            locale: locale
        ).options.compactMap { option in
            guard let asset = assets.first(where: { $0.id == option.pattern.assetID }) else {
                return nil
            }
            return ProjectPatternLinkChoice(option: option, asset: asset)
        }
    }
}

public func projectPatternLinkChoiceAccessibilityLabel(
    name: String,
    assetTypeDescription: String,
    status: ProjectPatternLinkStatus,
    relinkDescription: String
) -> String {
    var parts = [name, assetTypeDescription]
    if status == .relink {
        parts.append(relinkDescription)
    }
    return parts.joined(separator: ", ")
}
