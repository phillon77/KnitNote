import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct PatternLibraryImportPresentationTests {
    @Test func existingImportSurfacesTheSavedPatternForFeedbackAndNavigation() {
        let patternID = UUID()

        let presentation = PatternLibraryImportPresentation(
            outcome: .existing(patternID: patternID)
        )

        #expect(presentation == .alreadySaved(patternID: patternID))
    }

    @Test func createdAndAmbiguousImportsKeepTheirDistinctPresentationPaths() {
        let patternID = UUID()
        let itemID = UUID()
        let candidates = [UUID(), UUID()]

        #expect(
            PatternLibraryImportPresentation(
                outcome: .created(patternID: patternID)
            ) == .none
        )
        #expect(
            PatternLibraryImportPresentation(
                outcome: .needsSelection(
                    itemID: itemID,
                    candidatePatternIDs: candidates
                )
            ) == .chooseDuplicate(
                itemID: itemID,
                candidatePatternIDs: candidates
            )
        )
    }
}
