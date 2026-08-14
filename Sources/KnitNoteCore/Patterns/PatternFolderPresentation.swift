import Foundation

public enum PatternFolderSidebarTitle: Equatable, Sendable {
    case localizedKey(String)
    case userContent(String)
}

public struct PatternFolderSidebarRow: Identifiable, Equatable, Sendable {
    public let scope: PatternLibraryScope
    public let title: PatternFolderSidebarTitle
    public let count: Int

    public var id: PatternLibraryScope { scope }

    public init(scope: PatternLibraryScope, title: PatternFolderSidebarTitle, count: Int) {
        self.scope = scope
        self.title = title
        self.count = count
    }
}

public enum PatternFolderPresentation {
    public static func rows(
        folders: [PatternFolder],
        patterns: [StoredPattern],
        locale: Locale
    ) -> [PatternFolderSidebarRow] {
        let systemRows = [
            PatternFolderSidebarRow(
                scope: .all,
                title: .localizedKey("patterns.folder.all"),
                count: patterns.count
            ),
            PatternFolderSidebarRow(
                scope: .uncategorized,
                title: .localizedKey("patterns.folder.uncategorized"),
                count: patterns.count(where: { $0.folderID == nil })
            ),
        ]
        let options: String.CompareOptions = [
            .caseInsensitive,
            .diacriticInsensitive,
            .numeric,
            .widthInsensitive,
        ]
        let userRows = folders.sorted { lhs, rhs in
            let order = lhs.displayName.compare(
                rhs.displayName,
                options: options,
                range: nil,
                locale: locale
            )
            if order != .orderedSame {
                return order == .orderedAscending
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }.map { folder in
            PatternFolderSidebarRow(
                scope: .folder(folder.id),
                title: .userContent(folder.displayName),
                count: patterns.count(where: { $0.folderID == folder.id })
            )
        }
        return systemRows + userRows
    }

    public static func selectionAfterDeleting(
        _ selection: PatternLibraryScope,
        deletedFolderID: UUID
    ) -> PatternLibraryScope {
        guard case .folder(deletedFolderID) = selection else { return selection }
        return .uncategorized
    }

    public static func nameContext(
        locale: Locale,
        supportedLocaleIdentifiers: [String],
        resolve: (_ key: String, _ locale: Locale) -> String
    ) -> PatternFolderNameContext {
        let reservedNames = Set(supportedLocaleIdentifiers.flatMap { identifier in
            let candidateLocale = Locale(identifier: identifier)
            return [
                resolve("patterns.folder.all", candidateLocale),
                resolve("patterns.folder.uncategorized", candidateLocale),
            ]
        })
        return PatternFolderNameContext(locale: locale, reservedNames: reservedNames)
    }
}

public enum PatternFolderFailurePresentation {
    public static func key(for error: Error) -> String {
        switch error {
        case PatternFolderValidationError.emptyName:
            "patterns.folder.error.empty"
        case PatternFolderValidationError.duplicateName:
            "patterns.folder.error.duplicate"
        case PatternFolderValidationError.reservedName:
            "patterns.folder.error.reserved"
        case PatternFolderStoreError.folderNotFound:
            "patterns.folder.error.missing"
        default:
            "patterns.folder.error.saveFailed"
        }
    }
}
