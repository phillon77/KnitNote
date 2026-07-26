import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct ProjectPatternLinkIndexTests {
    @Test func optionsExcludeActiveLinksAndDistinguishRelinkingFromNewLinks() {
        let projectID = UUID()
        let otherProjectID = UUID()
        let active = StoredPattern(id: UUID(), assetID: UUID(), displayName: "Alpha")
        let inactive = StoredPattern(id: UUID(), assetID: UUID(), displayName: "Beta")
        let available = StoredPattern(id: UUID(), assetID: UUID(), displayName: "Gamma")
        let usages = [
            PatternProjectUsage(
                patternID: active.id,
                projectID: projectID,
                sortOrder: 0
            ),
            PatternProjectUsage(
                patternID: inactive.id,
                projectID: projectID,
                isActive: false,
                unlinkedAt: Date(timeIntervalSince1970: 10),
                sortOrder: 1
            ),
            PatternProjectUsage(
                patternID: available.id,
                projectID: otherProjectID,
                sortOrder: 0
            ),
        ]

        let options = ProjectPatternLinkIndex(
            patterns: [available, active, inactive],
            usages: usages,
            projectID: projectID,
            locale: Locale(identifier: "en")
        ).options

        #expect(options == [
            ProjectPatternLinkOption(pattern: inactive, status: .relink),
            ProjectPatternLinkOption(pattern: available, status: .link),
        ])
    }
}
