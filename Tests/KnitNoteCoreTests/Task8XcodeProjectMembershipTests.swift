import Foundation
import Testing

@Suite struct Task8XcodeProjectMembershipTests {
    @Test func task8SourcesBelongToTheAppTargetAndNeverTheWatchTarget() throws {
        let project = try PBXProjectMembership(
            contents: readRepositoryFile("KnitNote.xcodeproj/project.pbxproj")
        )
        let required = Set([
            "ChooseLibraryPatternView.swift",
            "ChoosePatternReadingContextView.swift",
            "PatternAsset.swift",
            "PatternDetailView.swift",
            "PatternImportCoordinator.swift",
            "PatternImportResultView.swift",
            "PatternInboxFileService.swift",
            "PatternInboxProcessing.swift",
            "PatternInboxItem.swift",
            "PatternInboxProcessor.swift",
            "PatternLibraryImportPresentation.swift",
            "PatternLibraryIndex.swift",
            "PatternLibraryMigrator.swift",
            "PatternLibraryRow.swift",
            "PatternLibrarySort.swift",
            "PatternProjectUsage.swift",
            "PatternReaderContext.swift",
            "PatternShareImportPresentation.swift",
            "PatternShareInboxEnqueuer.swift",
            "PatternStorageLocations.swift",
            "ProjectPatternLinkIndex.swift",
            "ProjectPatternImportPresentation.swift",
            "PendingPatternSelectionView.swift",
            "StoredPattern.swift",
        ])

        let appSourceList = try project.sourceFilenames(targetName: "KnitNote")
        let watchSourceList = try project.sourceFilenames(targetName: "KnitNoteWatch")
        let appSources = Set(appSourceList)
        let watchSources = Set(watchSourceList)
        let watchSharedCore = Set([
            "PatternAsset.swift",
            "PatternImportCoordinator.swift",
            "PatternInboxFileService.swift",
            "PatternInboxItem.swift",
            "PatternLibraryMigrator.swift",
            "PatternProjectUsage.swift",
            "PatternStorageLocations.swift",
            "StoredPattern.swift",
        ])
        let appOnly = required.subtracting(watchSharedCore)

        #expect(required.isSubset(of: appSources))
        #expect(watchSharedCore.isSubset(of: watchSources))
        #expect(appOnly.isDisjoint(with: watchSources))
        #expect(appSourceList.count == appSources.count)
        #expect(watchSourceList.count == watchSources.count)
    }
}

private struct PBXProjectMembership {
    let contents: String

    func sourceFilenames(targetName: String) throws -> [String] {
        let target = try targetBody(named: targetName)
        let phaseIDs = captures(
            pattern: #"([A-F0-9]{24}) /\* [^*]+ \*/"#,
            in: try capture(pattern: #"buildPhases = \((.*?)\);"#, in: target)
        )
        let sourcesPhaseID = try #require(phaseIDs.first {
            (try? objectBody(id: $0).contains("isa = PBXSourcesBuildPhase;")) == true
        })
        let sourcesPhase = try objectBody(id: sourcesPhaseID)
        let buildFileIDs = captures(
            pattern: #"([A-F0-9]{24}) /\* [^*]+ in Sources \*/"#,
            in: try capture(pattern: #"files = \((.*?)\);"#, in: sourcesPhase)
        )

        return try buildFileIDs.map { buildFileID in
            let buildFile = try objectBody(id: buildFileID)
            let fileRefID = try capture(
                pattern: #"fileRef = ([A-F0-9]{24}) /\* [^*]+ \*/;"#,
                in: buildFile
            )
            let fileRef = try objectBody(id: fileRefID)
            return try capture(pattern: #"path = "?([^";]+)"?;"#, in: fileRef)
        }
    }

    private func targetBody(named name: String) throws -> String {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let bodies = captures(
            pattern: #"[A-F0-9]{24} /\* \#(escaped) \*/ = \{(.*?)^\s*\};"#,
            in: contents,
            options: [.anchorsMatchLines, .dotMatchesLineSeparators]
        )
        return try #require(bodies.first { $0.contains("isa = PBXNativeTarget;") })
    }

    private func objectBody(id: String) throws -> String {
        try capture(
            pattern: #"\#(id) /\* [^*]+ \*/ = \{(.*?)^\s*\};"#,
            in: contents,
            options: [.anchorsMatchLines, .dotMatchesLineSeparators]
        )
    }

    private func captures(
        pattern: String,
        in value: String,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: options
        ) else {
            return []
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap {
            Range($0.range(at: 1), in: value).map { String(value[$0]) }
        }
    }

    private func capture(
        pattern: String,
        in value: String,
        options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
    ) throws -> String {
        let expression = try NSRegularExpression(pattern: pattern, options: options)
        let match = try #require(expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ))
        let range = try #require(Range(match.range(at: 1), in: value))
        return String(value[range])
    }
}
