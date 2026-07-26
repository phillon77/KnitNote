import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct ProjectPatternImportPresentationTests {
    @Test func newerOperationInvalidatesThePreviousResult() {
        var coordinator = ProjectPatternImportOperationCoordinator()
        let first = UUID()
        let second = UUID()

        #expect(coordinator.begin(id: first) == first)
        #expect(coordinator.isRunning)
        #expect(coordinator.begin(id: second) == second)

        let acceptedStaleResult = coordinator.finishIfCurrent(first)
        #expect(!acceptedStaleResult)
        #expect(coordinator.isCurrent(second))
        #expect(coordinator.isRunning)
        let acceptedCurrentResult = coordinator.finishIfCurrent(second)
        #expect(acceptedCurrentResult)
        #expect(!coordinator.isRunning)
    }

    @Test func cancellationInvalidatesTheCurrentResult() {
        var coordinator = ProjectPatternImportOperationCoordinator()
        let operationID = coordinator.begin()

        coordinator.cancel()

        #expect(!coordinator.isRunning)
        #expect(!coordinator.isCurrent(operationID))
        let acceptedCancelledResult = coordinator.finishIfCurrent(operationID)
        #expect(!acceptedCancelledResult)
    }

    @Test func importFailuresMapToStableUserFacingMessages() {
        let cases: [(any Error, ProjectPatternImportFailureContext, ProjectPatternImportErrorMessage)] = [
            (PatternFileError.empty, .operation, .emptyFile),
            (PatternFileError.tooLarge, .operation, .fileTooLarge),
            (PatternFileError.unsupported, .operation, .invalidFile),
            (PatternFileError.invalidContent, .operation, .invalidFile),
            (PatternFileError.unsafeStoredFilename, .operation, .storageUnavailable),
            (PatternInboxError.appGroupUnavailable, .operation, .storageUnavailable),
            (PatternInboxError.itemNotFound, .operation, .storageUnavailable),
            (PatternInboxError.invalidItem, .operation, .storageUnavailable),
            (PatternInboxError.invalidSelection, .operation, .storageUnavailable),
            (PatternLibraryMutationError.projectNotFound, .operation, .projectUnavailable),
            (PatternLibraryMutationError.patternNotFound, .operation, .storageUnavailable),
            (PatternLibraryMutationError.usageNotFound, .operation, .storageUnavailable),
            (PatternLibraryMutationError.usageInactive, .operation, .storageUnavailable),
            (PatternLibraryMutationError.projectCompleted, .operation, .storageUnavailable),
            (PatternLibraryMutationError.activeLinksExist([]), .operation, .storageUnavailable),
            (ProjectStoreError.unreadableArchive, .operation, .storageUnavailable),
            (ProjectStoreError.archiveUnavailable, .operation, .storageUnavailable),
            (ProjectStoreError.invalidYarnProjectLinks, .operation, .storageUnavailable),
            (ProjectStoreError.patternNotFound, .operation, .storageUnavailable),
            (ProjectStoreError.staleDataGeneration, .operation, .storageUnavailable),
            (ProjectStoreError.persistenceFailed, .operation, .storageUnavailable),
            (CancellationError(), .operation, .cancelled),
            (CocoaError(.fileReadUnknown), .filePicker, .fileSelectionFailed),
            (CocoaError(.fileReadUnknown), .operation, .unexpected),
        ]

        for (error, context, expected) in cases {
            #expect(
                ProjectPatternImportErrorMapper.message(
                    for: error,
                    context: context
                ) == expected
            )
        }
    }
}
