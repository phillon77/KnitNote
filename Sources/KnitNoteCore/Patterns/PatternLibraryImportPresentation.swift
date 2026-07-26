import Foundation

public enum PatternLibraryImportPresentation: Equatable, Sendable {
    case none
    case alreadySaved(patternID: UUID)
    case chooseDuplicate(itemID: UUID, candidatePatternIDs: [UUID])

    public init(outcome: PatternImportOutcome) {
        switch outcome {
        case .created:
            self = .none
        case let .existing(patternID):
            self = .alreadySaved(patternID: patternID)
        case let .needsSelection(itemID, candidatePatternIDs):
            self = .chooseDuplicate(
                itemID: itemID,
                candidatePatternIDs: candidatePatternIDs
            )
        }
    }
}
