import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct PatternFolderModelTests {
    private let context = PatternFolderNameContext(
        locale: Locale(identifier: "zh-Hant"),
        reservedNames: ["全部", "未分類", "All", "Uncategorized"]
    )

    @Test func folderRoundTripsWithoutChangingUserCopy() throws {
        let folder = PatternFolder(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            displayName: "  毛衣 / Sweaters  ",
            createdAt: Date(timeIntervalSince1970: 123)
        )
        let decoded = try JSONDecoder().decode(
            PatternFolder.self,
            from: JSONEncoder().encode(folder)
        )
        #expect(decoded == folder)
        #expect(decoded.displayName == "  毛衣 / Sweaters  ")
    }

    @Test func policyTrimsAndRejectsEmptyDuplicateAndReservedNames() throws {
        let existing = PatternFolder(displayName: "Café", createdAt: .distantPast)
        #expect(try PatternFolderNamePolicy.validatedName(
            "  Socks  ", folders: [existing], excluding: nil, nameContext: context
        ) == "Socks")
        #expect(throws: PatternFolderValidationError.emptyName) {
            try PatternFolderNamePolicy.validatedName(
                " \n ", folders: [existing], excluding: nil, nameContext: context
            )
        }
        #expect(throws: PatternFolderValidationError.duplicateName) {
            try PatternFolderNamePolicy.validatedName(
                "CAFE", folders: [existing], excluding: nil, nameContext: context
            )
        }
        #expect(throws: PatternFolderValidationError.reservedName) {
            try PatternFolderNamePolicy.validatedName(
                "All", folders: [existing], excluding: nil, nameContext: context
            )
        }
        #expect(try PatternFolderNamePolicy.validatedName(
            "Café", folders: [existing], excluding: existing.id, nameContext: context
        ) == "Café")
    }
}
