import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct PatternFolderPresentationTests {
    @Test func sidebarPlacesSystemRowsFirstAndSortsUserFoldersBySelectedLocale() {
        let alphaID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let betaID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let beta = PatternFolder(
            id: betaID,
            displayName: "Beta 10",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let alpha = PatternFolder(
            id: alphaID,
            displayName: "Beta 2",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let rows = PatternFolderPresentation.rows(
            folders: [beta, alpha],
            patterns: [pattern(folderID: alpha.id), pattern(folderID: nil)],
            locale: Locale(identifier: "en")
        )

        #expect(rows.map(\.scope) == [.all, .uncategorized, .folder(alpha.id), .folder(beta.id)])
        #expect(rows.map(\.count) == [2, 1, 1, 0])
        #expect(rows.map(\.title) == [
            .localizedKey("patterns.folder.all"),
            .localizedKey("patterns.folder.uncategorized"),
            .userContent("Beta 2"),
            .userContent("Beta 10"),
        ])
    }

    @Test func equalFolderNamesUseCreationDateThenIdentifierForStableOrdering() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let first = PatternFolder(
            id: firstID,
            displayName: "Lace",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = PatternFolder(
            id: secondID,
            displayName: "lace",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let rows = PatternFolderPresentation.rows(
            folders: [first, second],
            patterns: [],
            locale: Locale(identifier: "en")
        )

        #expect(rows.dropFirst(2).map(\.scope) == [.folder(secondID), .folder(firstID)])
    }

    @Test func deletingOnlyTheSelectedFolderChangesSelection() {
        let deletedID = UUID()
        let otherID = UUID()

        #expect(PatternFolderPresentation.selectionAfterDeleting(
            .folder(deletedID), deletedFolderID: deletedID
        ) == .uncategorized)
        #expect(PatternFolderPresentation.selectionAfterDeleting(
            .folder(otherID), deletedFolderID: deletedID
        ) == .folder(otherID))
        #expect(PatternFolderPresentation.selectionAfterDeleting(
            .all, deletedFolderID: deletedID
        ) == .all)
    }

    @Test func nameContextResolvesEveryShippingSystemNameWithoutHardcodedProductionCopy() {
        let translations: [String: [String: String]] = [
            "en": ["patterns.folder.all": "All", "patterns.folder.uncategorized": "Uncategorized"],
            "zh-Hant": ["patterns.folder.all": "全部", "patterns.folder.uncategorized": "未分類"],
            "zh-Hans": ["patterns.folder.all": "全部", "patterns.folder.uncategorized": "未分类"],
            "de": ["patterns.folder.all": "Alle", "patterns.folder.uncategorized": "Nicht kategorisiert"],
            "fr": ["patterns.folder.all": "Tous", "patterns.folder.uncategorized": "Non classés"],
            "ja": ["patterns.folder.all": "すべて", "patterns.folder.uncategorized": "未分類"],
            "nb": ["patterns.folder.all": "Alle", "patterns.folder.uncategorized": "Ukategorisert"],
            "sv": ["patterns.folder.all": "Alla", "patterns.folder.uncategorized": "Okategoriserade"],
            "fi": ["patterns.folder.all": "Kaikki", "patterns.folder.uncategorized": "Luokittelemattomat"],
            "da": ["patterns.folder.all": "Alle", "patterns.folder.uncategorized": "Ikke kategoriseret"],
            "ko": ["patterns.folder.all": "전체", "patterns.folder.uncategorized": "미분류"],
            "el": ["patterns.folder.all": "Όλα", "patterns.folder.uncategorized": "Χωρίς κατηγορία"],
            "nl": ["patterns.folder.all": "Alles", "patterns.folder.uncategorized": "Niet gecategoriseerd"],
        ]
        let context = PatternFolderPresentation.nameContext(
            locale: Locale(identifier: "zh-Hant"),
            supportedLocaleIdentifiers: SupportedLocalization.v150Identifiers
        ) { key, locale in
            translations[locale.identifier]?[key] ?? key
        }

        #expect(context.reservedNames == Set(translations.values.flatMap(\.values)))
        #expect(context.reservedNames.contains("All"))
        #expect(context.reservedNames.contains("全部"))
        #expect(context.reservedNames.contains("すべて"))
        #expect(context.reservedNames.contains("Uncategorized"))
        #expect(context.reservedNames.contains("未分類"))
        #expect(context.reservedNames.contains("미분류"))
    }

    @Test func failuresMapToSemanticLocalizationKeys() {
        #expect(PatternFolderFailurePresentation.key(
            for: PatternFolderValidationError.emptyName
        ) == "patterns.folder.error.empty")
        #expect(PatternFolderFailurePresentation.key(
            for: PatternFolderValidationError.duplicateName
        ) == "patterns.folder.error.duplicate")
        #expect(PatternFolderFailurePresentation.key(
            for: PatternFolderValidationError.reservedName
        ) == "patterns.folder.error.reserved")
        #expect(PatternFolderFailurePresentation.key(
            for: PatternFolderStoreError.folderNotFound
        ) == "patterns.folder.error.missing")
        #expect(PatternFolderFailurePresentation.key(for: CocoaError(.fileWriteUnknown))
            == "patterns.folder.error.saveFailed")
    }

    private func pattern(folderID: UUID?) -> StoredPattern {
        StoredPattern(assetID: UUID(), displayName: UUID().uuidString, folderID: folderID)
    }
}
