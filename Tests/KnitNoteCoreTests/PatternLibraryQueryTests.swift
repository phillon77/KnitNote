import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct PatternLibraryQueryTests {
    @Test func queryMatchesNameNoteAndActiveProjectName() {
        let index = PatternLibraryIndex(
            rows: [
                .init(
                    patternID: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
                    name: "Ida Tee",
                    note: "Bought from designer",
                    activeProjectNames: ["Blue summer top"],
                    createdAt: Date(timeIntervalSince1970: 10)
                ),
                .init(
                    patternID: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!,
                    name: "Winter Socks",
                    note: nil,
                    activeProjectNames: [],
                    createdAt: Date(timeIntervalSince1970: 20)
                ),
            ],
            locale: Locale(identifier: "en")
        )

        #expect(index.search("ida").map(\.name) == ["Ida Tee"])
        #expect(index.search("designer").map(\.name) == ["Ida Tee"])
        #expect(index.search("summer").map(\.name) == ["Ida Tee"])
        #expect(index.search("missing").isEmpty)
    }

    @Test func recentSortUsesCreationDateDescendingWithStableNameTieBreak() {
        let index = PatternLibraryIndex(
            rows: [
                .init(
                    patternID: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
                    name: "Zulu",
                    note: nil,
                    activeProjectNames: [],
                    createdAt: Date(timeIntervalSince1970: 10)
                ),
                .init(
                    patternID: UUID(uuidString: "20000000-0000-4000-8000-000000000002")!,
                    name: "Beta",
                    note: nil,
                    activeProjectNames: [],
                    createdAt: Date(timeIntervalSince1970: 20)
                ),
                .init(
                    patternID: UUID(uuidString: "20000000-0000-4000-8000-000000000003")!,
                    name: "Alpha",
                    note: nil,
                    activeProjectNames: [],
                    createdAt: Date(timeIntervalSince1970: 20)
                ),
            ],
            locale: Locale(identifier: "en")
        )

        #expect(index.rows(sortedBy: .recentlyAdded).map(\.name) == ["Alpha", "Beta", "Zulu"])
    }

    @Test func nameSortUsesLocalizedStandardOrdering() {
        let index = PatternLibraryIndex(
            rows: [
                .init(
                    patternID: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!,
                    name: "Pattern 10",
                    note: nil,
                    activeProjectNames: [],
                    createdAt: .distantPast
                ),
                .init(
                    patternID: UUID(uuidString: "30000000-0000-4000-8000-000000000002")!,
                    name: "Pattern 2",
                    note: nil,
                    activeProjectNames: [],
                    createdAt: .distantFuture
                ),
            ],
            locale: Locale(identifier: "en")
        )

        #expect(index.rows(sortedBy: .name).map(\.name) == ["Pattern 2", "Pattern 10"])
    }

    @Test func blankQueryReturnsTheSelectedSortOrder() {
        let index = PatternLibraryIndex(
            rows: [
                .init(
                    patternID: UUID(uuidString: "40000000-0000-4000-8000-000000000001")!,
                    name: "Older",
                    note: nil,
                    activeProjectNames: [],
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                .init(
                    patternID: UUID(uuidString: "40000000-0000-4000-8000-000000000002")!,
                    name: "Newer",
                    note: nil,
                    activeProjectNames: [],
                    createdAt: Date(timeIntervalSince1970: 2)
                ),
            ],
            locale: Locale(identifier: "en")
        )

        #expect(index.search(" \n", sortedBy: .recentlyAdded).map(\.name) == ["Newer", "Older"])
    }
}
