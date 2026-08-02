import Testing
@testable import KnitNoteCore

@Suite struct PatternReaderRevisionCoordinatorTests {
    @Test func externalRevisionReloadsOnlyWhenMarkupIsClean() {
        var coordinator = PatternReaderRevisionCoordinator(expectedDataGeneration: 4)

        #expect(coordinator.observeStoreGeneration(5, canWrite: true) == .reload)
        #expect(coordinator.phase == .needsReload)
    }

    @Test func externalRevisionWithDirtyMarkupBlocksPageChangesAndRetainsTheDocument() {
        var coordinator = PatternReaderRevisionCoordinator(expectedDataGeneration: 4)
        coordinator.setMarkupDirty(true)

        #expect(coordinator.observeStoreGeneration(5, canWrite: true) == .conflict)
        #expect(!coordinator.canChangePage)
        #expect(coordinator.phase == .conflict)
    }

    @Test func successfulSelfMutationAdvancesExpectedRevisionWithoutReloading() {
        var coordinator = PatternReaderRevisionCoordinator(expectedDataGeneration: 4)
        coordinator.confirmMutation(generation: 5)

        #expect(coordinator.observeStoreGeneration(5, canWrite: true) == .none)
        #expect(coordinator.phase == .ready)
    }

    @Test func confirmedReadOnlySelfMutationDoesNotReloadButExternalRevisionStillDoes() {
        var selfMutation = PatternReaderRevisionCoordinator(expectedDataGeneration: 4)
        selfMutation.confirmMutation(generation: 5)

        #expect(selfMutation.observeStoreGeneration(5, canWrite: false) == .none)
        #expect(selfMutation.phase == .ready)

        var externalMutation = PatternReaderRevisionCoordinator(expectedDataGeneration: 4)
        #expect(externalMutation.observeStoreGeneration(5, canWrite: false) == .reloadReadOnly)
        #expect(externalMutation.phase == .needsReload)
    }

    @Test func unlinkOrCompletionForcesImmediateReadOnlyReloadEvenWithDirtyMarkup() {
        var coordinator = PatternReaderRevisionCoordinator(expectedDataGeneration: 4)
        coordinator.setMarkupDirty(true)

        #expect(coordinator.observeStoreGeneration(5, canWrite: false) == .reloadReadOnly)
        #expect(coordinator.phase == .needsReload)
    }

    @Test func discardingAConflictResetsTheCoordinatorForTheReloadedRevision() {
        var coordinator = PatternReaderRevisionCoordinator(expectedDataGeneration: 4)
        coordinator.setMarkupDirty(true)
        #expect(coordinator.observeStoreGeneration(5, canWrite: true) == .conflict)

        #expect(coordinator.requiresConflictResolution)
        #expect(!coordinator.canDismissConflictPresentation)
        let didPrepareReload = coordinator.discardConflictAndPrepareReload(expectedDataGeneration: 5)
        #expect(didPrepareReload)

        #expect(coordinator.phase == .ready)
        #expect(coordinator.canChangePage)
        #expect(!coordinator.requiresConflictResolution)
        #expect(coordinator.canDismissConflictPresentation)
        #expect(coordinator.observeStoreGeneration(5, canWrite: true) == .none)
    }
}
