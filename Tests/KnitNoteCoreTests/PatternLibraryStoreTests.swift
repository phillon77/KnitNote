import Foundation
import Testing
@testable import KnitNoteCore

private struct PatternLibraryInboxWriteFailure: Error {}

private final class PatternLibraryIOThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadValues: [Bool] = []

    func recordCurrentThread() {
        lock.lock()
        mainThreadValues.append(Thread.isMainThread)
        lock.unlock()
    }

    var recordedMainThreadValues: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return mainThreadValues
    }
}

@MainActor @Test func libraryImportPublishesThroughTheDurableInboxWithoutAProjectLink() async throws {
    let harness = try PatternImportHarness()
    let source = try harness.makePDF(named: "Library Pattern.pdf")

    let outcome = try await harness.store.importPatternFromLibrary(source)
    let patternID = try #require(harness.store.patterns.first?.id)

    #expect(outcome == .created(patternID: patternID))
    #expect(harness.store.patternUsages.isEmpty)
    #expect(try harness.inbox.items().isEmpty)
}

@MainActor @Test func libraryThumbnailResolvesTheOwnedAssetByPatternID() async throws {
    let harness = try PatternImportHarness()
    let source = try harness.makePDF(named: "Thumbnail Pattern.pdf")
    _ = try await harness.store.importPatternFromLibrary(source)
    let patternID = try #require(harness.store.patterns.first?.id)

    let thumbnail = await harness.store.patternThumbnailURL(patternID: patternID)

    #expect(thumbnail != nil)
    #expect(thumbnail.map { FileManager.default.fileExists(atPath: $0.path) } == true)
}

@MainActor @Test func libraryImportEnqueuesItsOwnedCopyAwayFromTheMainThread() async throws {
    let recorder = PatternLibraryIOThreadRecorder()
    let harness = try PatternImportHarness(inboxMove: { source, destination in
        recorder.recordCurrentThread()
        try FileManager.default.moveItem(at: source, to: destination)
    })
    let source = try harness.makePDF(named: "Large Pattern.pdf")

    let outcome = try await harness.store.importPatternFromLibrary(source)

    #expect(recorder.recordedMainThreadValues == [false])
    #expect(harness.store.patterns.count == 1)
    #expect(outcome == .created(patternID: harness.store.patterns[0].id))
}

@MainActor @Test func failedLibraryEnqueueLeavesNoInboxOrArchivePublication() async throws {
    let harness = try PatternImportHarness(inboxWrite: { _, _ in
        throw PatternLibraryInboxWriteFailure()
    })
    let source = try harness.makePDF(named: "Fail Before Publication.pdf")

    await #expect(throws: PatternLibraryInboxWriteFailure.self) {
        try await harness.store.importPatternFromLibrary(source)
    }

    #expect(harness.store.patterns.isEmpty)
    #expect(harness.store.patternAssets.isEmpty)
    #expect(harness.archivePatternCount() == 0)
    for directory in [".Candidates", "Items", "Manifests", ".Quarantine"] {
        let url = harness.inbox.root.appendingPathComponent(directory, isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
        #expect(contents.isEmpty)
    }
}

@MainActor @Test
func patternOriginalColorPreferencePersistsAndIsSharedAcrossUsages() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndTwoProjects()
    _ = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    _ = try harness.store.linkPattern(
        patternID: harness.patternID,
        to: try #require(harness.secondProjectID)
    )
    let usagesBefore = harness.store.patternUsages
    let generation = harness.store.dataGeneration

    let next = try harness.store.setPatternPrefersOriginalColorsInDarkMode(
        id: harness.patternID,
        prefersOriginalColors: true,
        expectedDataGeneration: generation
    )

    #expect(next > generation)
    #expect(harness.store.patterns.first { $0.id == harness.patternID }?
        .prefersOriginalColorsInDarkMode == true)
    #expect(harness.store.patternUsages == usagesBefore)
    #expect(usagesBefore.count == 2)
    #expect(try harness.reopenedStore().patterns.first { $0.id == harness.patternID }?
        .prefersOriginalColorsInDarkMode == true)
}

@MainActor @Test
func missingOrStalePatternAppearanceMutationPublishesNothing() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let before = harness.store.patterns
    let generation = harness.store.dataGeneration

    #expect(throws: PatternLibraryMutationError.patternNotFound) {
        _ = try harness.store.setPatternPrefersOriginalColorsInDarkMode(
            id: UUID(),
            prefersOriginalColors: true,
            expectedDataGeneration: generation
        )
    }
    #expect(throws: ProjectStoreError.staleDataGeneration) {
        _ = try harness.store.setPatternPrefersOriginalColorsInDarkMode(
            id: harness.patternID,
            prefersOriginalColors: true,
            expectedDataGeneration: generation &+ 1
        )
    }
    #expect(harness.store.patterns == before)
    #expect(harness.store.dataGeneration == generation)
}

@MainActor @Test
func failedPatternAppearanceWriteLeavesMemoryAndDiskUnchanged() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(
        failingArchiveWrites: true
    )
    let before = harness.store.patterns
    let archiveBefore = try Data(contentsOf: harness.archiveURL)
    harness.archiveWriteGate?.shouldFail = true

    #expect(throws: ProjectStoreError.persistenceFailed) {
        _ = try harness.store.setPatternPrefersOriginalColorsInDarkMode(
            id: harness.patternID,
            prefersOriginalColors: true,
            expectedDataGeneration: harness.store.dataGeneration
        )
    }
    #expect(harness.store.patterns == before)
    #expect(try Data(contentsOf: harness.archiveURL) == archiveBefore)
}

@MainActor @Test
func patternAppearancePreferenceBypassesMutationAuthorization() throws {
    var authorizedMutations: [FeatureMutation] = []
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(
        authorizeMutation: { mutation in
            authorizedMutations.append(mutation)
            return .requiresUnlock
        }
    )

    _ = try harness.store.setPatternPrefersOriginalColorsInDarkMode(
        id: harness.patternID,
        prefersOriginalColors: true,
        expectedDataGeneration: harness.store.dataGeneration
    )

    #expect(harness.store.patterns.first { $0.id == harness.patternID }?
        .prefersOriginalColorsInDarkMode == true)
    #expect(authorizedMutations.isEmpty)
}

@MainActor @Test func writeThenThrowManifestFailureLeavesNothingForFreshRecovery() async throws {
    let harness = try PatternImportHarness(inboxWrite: { data, url in
        try data.write(to: url, options: .atomic)
        throw PatternLibraryInboxWriteFailure()
    })
    let source = try harness.makePDF(named: "Manifest Written Then Failed.pdf")

    await #expect(throws: PatternLibraryInboxWriteFailure.self) {
        try await harness.store.importPatternFromLibrary(source)
    }

    #expect(harness.store.patterns.isEmpty)
    #expect(harness.store.patternAssets.isEmpty)
    #expect(harness.archivePatternCount() == 0)
    for directory in [".Candidates", "Items", "Manifests", ".Quarantine"] {
        let url = harness.inbox.root.appendingPathComponent(directory, isDirectory: true)
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    let freshInbox = PatternInboxFileService(root: harness.inbox.root)
    let report = try freshInbox.recover()

    #expect(report == PatternInboxRecoveryReport())
    #expect(try freshInbox.items().isEmpty)
    for directory in [".Candidates", "Items", "Manifests", ".Quarantine"] {
        let url = freshInbox.root.appendingPathComponent(directory, isDirectory: true)
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }
}

@MainActor @Test func unlinkAndRelinkRestoreTheSameUsage() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()

    let original = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let duplicate = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.updatePatternState(
        usageID: original.id,
        state: PatternReadingState(pageIndex: 3, highlightPosition: 0.7)
    )
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)

    let restored = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)

    #expect(restored.id == original.id)
    #expect(duplicate.id == original.id)
    #expect(harness.store.patternUsages.count == 1)
    #expect(restored.isActive)
    #expect(restored.readingState.pageIndex == 3)
    #expect(restored.readingState.highlightPosition == 0.7)
}

@MainActor @Test func relinkedUsageSurvivesFreshStoreReloadWithItsStateNotesAndMarkup() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let markup = PatternMarkupDocument(strokes: [.init(
        points: [.init(x: 0.2, y: 0.3)], color: .blue, width: 0.009
    )])
    try harness.store.updatePatternState(usageID: usage.id, state: PatternReadingState(pageIndex: 4))
    try harness.store.savePatternPageNote(usageID: usage.id, pageIndex: 4, text: "reload note")
    try harness.store.savePatternMarkup(
        markup,
        usageID: usage.id,
        pageIndex: 4,
        expectedDataGeneration: harness.store.dataGeneration
    )
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)
    let relinked = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)

    let reopened = try harness.reopenedStore()

    #expect(reopened.patternUsages == [relinked])
    #expect(try reopened.loadPatternMarkup(usageID: usage.id, pageIndex: 4) == markup)
}

@MainActor @Test func inactiveUsageRejectsEveryReaderWrite() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)

    #expect(throws: PatternLibraryMutationError.usageInactive) {
        try harness.store.updatePatternState(usageID: usage.id, state: PatternReadingState(pageIndex: 1))
    }
    #expect(throws: PatternLibraryMutationError.usageInactive) {
        try harness.store.savePatternPageNote(usageID: usage.id, pageIndex: 1, text: "blocked")
    }
    #expect(throws: PatternLibraryMutationError.usageInactive) {
        try harness.store.savePatternMarkup(
            PatternMarkupDocument(),
            usageID: usage.id,
            pageIndex: 1,
            expectedDataGeneration: harness.store.dataGeneration
        )
    }
}

@MainActor @Test func readerUsageMutationSequenceAdvancesGenerationWithoutSelfStaling() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let counterID = try #require(harness.store.project(id: harness.projectID)?.counters.first?.id)
    var expected = harness.store.dataGeneration

    expected = try harness.store.mutatePatternReaderCounter(
        usageID: usage.id,
        counterID: counterID,
        mutation: .increment,
        expectedDataGeneration: expected
    )
    expected = try harness.store.mutatePatternReaderCounter(
        usageID: usage.id,
        counterID: counterID,
        mutation: .update(name: "Reader counter", value: 4),
        expectedDataGeneration: expected
    )
    expected = try harness.store.mutatePatternReaderCounter(
        usageID: usage.id,
        counterID: counterID,
        mutation: .reset,
        expectedDataGeneration: expected
    )
    expected = try harness.store.updatePatternState(
        usageID: usage.id,
        state: PatternReadingState(pageIndex: 5, zoomScale: 2.2, offsetX: 0.25, offsetY: 0.75),
        expectedDataGeneration: expected
    )
    expected = try harness.store.savePatternPageNote(
        usageID: usage.id,
        pageIndex: 5,
        text: "reader sequence",
        expectedDataGeneration: expected
    )
    let markup = harness.drawing(x: 0.42)
    expected = try harness.store.savePatternMarkup(
        markup,
        usageID: usage.id,
        pageIndex: 5,
        expectedDataGeneration: expected
    )
    _ = try harness.store.savePatternMarkup(
        markup,
        usageID: usage.id,
        pageIndex: 5,
        expectedDataGeneration: expected
    )

    let reopened = try harness.reopenedStore()
    #expect(reopened.project(id: harness.projectID)?.counters.first?.value == 0)
    #expect(reopened.project(id: harness.projectID)?.counters.first?.customName == "Reader counter")
    #expect(reopened.patternUsages.first(where: { $0.id == usage.id })?.readingState.pageIndex == 5)
    #expect(reopened.patternUsages.first(where: { $0.id == usage.id })?.readingState.pageStates[5]?.note == "reader sequence")
    #expect(try reopened.loadPatternMarkup(usageID: usage.id, pageIndex: 5) == markup)
}

@MainActor @Test func readerMutationPublishesGenerationAndReminderTogether() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let counterID = try #require(harness.store.project(id: harness.projectID)?.counters[0].id)
    try harness.store.configureCounterReminder(
        projectID: harness.projectID,
        counterID: counterID,
        draft: .oneTime(target: 2, message: nil)
    )

    let result = try harness.store.mutatePatternReaderCounterWithOutcome(
        usageID: usage.id,
        counterID: counterID,
        mutation: .update(name: nil, value: 3),
        expectedDataGeneration: harness.store.dataGeneration
    )

    #expect(result.generation == harness.store.dataGeneration)
    #expect(result.outcome?.pendingReminder == nil)
    let reminder = try #require(
        harness.store.project(id: harness.projectID)?.knittingReminders.first
    )
    let occurrence = try #require(reminder.progress.pending.first)
    #expect(reminder.counterID == counterID)
    #expect(occurrence.originalTarget == 2)
    let reopened = try harness.reopenedStore()
    #expect(reopened.project(id: harness.projectID)?.knittingReminders == [reminder])
}

@MainActor @Test func staleReaderReminderActionPublishesNothing() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let counterID = try #require(harness.store.project(id: harness.projectID)?.counters[0].id)
    let reminderID = try harness.store.addKnittingReminder(
        projectID: harness.projectID,
        draft: .oneTime(kind: .custom, target: 3, text: nil)
    )
    let managed = try harness.store.mutatePatternReaderCounterWithOutcome(
        usageID: usage.id,
        counterID: counterID,
        mutation: .manage(name: "Body", value: 2, reminder: .unchanged),
        expectedDataGeneration: harness.store.dataGeneration
    )
    let staleRevision = try #require(
        harness.store.project(id: harness.projectID)?
            .knittingReminders.first(where: { $0.id == reminderID })
    ).mutationRevision
    let due = try harness.store.mutatePatternReaderCounterWithOutcome(
        usageID: usage.id,
        counterID: counterID,
        mutation: .increment,
        expectedDataGeneration: managed.generation
    )
    let dueReminder = try #require(
        harness.store.project(id: harness.projectID)?
            .knittingReminders.first(where: { $0.id == reminderID })
    )
    let occurrence = try #require(dueReminder.progress.pending.first)
    let projectsBefore = harness.store.projects
    let archiveBefore = try Data(contentsOf: harness.archiveURL)

    #expect(throws: KnittingReminderMutationError.staleRevision) {
        try harness.store.applyKnittingReminderAction(
            projectID: harness.projectID,
            reminderID: reminderID,
            occurrenceID: occurrence.id,
            observedRevision: staleRevision,
            action: .complete
        )
    }

    #expect(harness.store.projects == projectsBefore)
    #expect(harness.store.dataGeneration == due.generation)
    #expect(try Data(contentsOf: harness.archiveURL) == archiveBefore)
    #expect(try harness.reopenedStore().project(id: harness.projectID)?.knittingReminders == [dueReminder])
}

@MainActor @Test func rejectedReaderReminderActionsPublishNothingOrSelection() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let project = try #require(harness.store.project(id: harness.projectID))
    let mainCounterID = project.counters[0].id
    let initiallySelectedCounterID = project.counters[1].id
    let reminderID = try harness.store.addKnittingReminder(
        projectID: harness.projectID,
        draft: .oneTime(kind: .custom, target: 1, text: nil)
    )
    _ = try harness.store.mutatePatternReaderCounterWithOutcome(
        usageID: usage.id,
        counterID: mainCounterID,
        mutation: .increment,
        expectedDataGeneration: harness.store.dataGeneration
    )
    try harness.store.selectCounter(
        projectID: harness.projectID,
        counterID: initiallySelectedCounterID
    )
    let reminder = try #require(
        harness.store.project(id: harness.projectID)?
            .knittingReminders.first(where: { $0.id == reminderID })
    )
    let occurrence = try #require(reminder.progress.pending.first)
    let projectsBefore = harness.store.projects
    let generationBefore = harness.store.dataGeneration
    let archiveBefore = try Data(contentsOf: harness.archiveURL)

    #expect(throws: KnittingReminderMutationError.occurrenceNotFound) {
        try harness.store.applyKnittingReminderAction(
            projectID: harness.projectID,
            reminderID: UUID(),
            occurrenceID: occurrence.id,
            observedRevision: reminder.mutationRevision,
            action: .complete
        )
    }
    #expect(throws: KnittingReminderMutationError.occurrenceNotFound) {
        try harness.store.applyKnittingReminderAction(
            projectID: harness.projectID,
            reminderID: reminderID,
            occurrenceID: UUID(),
            observedRevision: reminder.mutationRevision,
            action: .complete
        )
    }
    #expect(throws: KnittingReminderMutationError.staleRevision) {
        try harness.store.applyKnittingReminderAction(
            projectID: harness.projectID,
            reminderID: reminderID,
            occurrenceID: occurrence.id,
            observedRevision: reminder.mutationRevision &+ 1,
            action: .complete
        )
    }

    #expect(harness.store.projects == projectsBefore)
    #expect(
        harness.store.project(id: harness.projectID)?.selectedCounterID
            == initiallySelectedCounterID
    )
    #expect(harness.store.dataGeneration == generationBefore)
    #expect(try Data(contentsOf: harness.archiveURL) == archiveBefore)
}

@MainActor @Test func completedProjectRejectsReaderReminderActionsWithoutPublishing() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let counterID = try #require(harness.store.project(id: harness.projectID)?.counters[0].id)
    let reminderID = try harness.store.addKnittingReminder(
        projectID: harness.projectID,
        draft: .oneTime(kind: .custom, target: 1, text: nil)
    )
    _ = try harness.store.mutatePatternReaderCounterWithOutcome(
        usageID: usage.id,
        counterID: counterID,
        mutation: .increment,
        expectedDataGeneration: harness.store.dataGeneration
    )
    let reminder = try #require(
        harness.store.project(id: harness.projectID)?
            .knittingReminders.first(where: { $0.id == reminderID })
    )
    let occurrence = try #require(reminder.progress.pending.first)
    try harness.store.markCompleted(projectID: harness.projectID)
    let projectsBefore = harness.store.projects
    let generationBefore = harness.store.dataGeneration
    let archiveBefore = try Data(contentsOf: harness.archiveURL)

    #expect(throws: PatternLibraryMutationError.projectCompleted) {
        try harness.store.applyKnittingReminderAction(
            projectID: harness.projectID,
            reminderID: reminderID,
            occurrenceID: occurrence.id,
            observedRevision: reminder.mutationRevision,
            action: .complete
        )
    }
    #expect(throws: PatternLibraryMutationError.projectCompleted) {
        try harness.store.applyKnittingReminderAction(
            projectID: harness.projectID,
            reminderID: reminderID,
            occurrenceID: nil,
            observedRevision: reminder.mutationRevision,
            action: .stop
        )
    }
    #expect(harness.store.projects == projectsBefore)
    #expect(harness.store.dataGeneration == generationBefore)
    #expect(try Data(contentsOf: harness.archiveURL) == archiveBefore)
}

@MainActor @Test func failedReminderPersistencePublishesNothing() throws {
    let direct = try PatternLibraryStoreHarness.onePatternAndProject(failingArchiveWrites: true)
    let directProjectsBefore = direct.store.projects
    let directGenerationBefore = direct.store.dataGeneration
    let directArchiveBefore = try Data(contentsOf: direct.archiveURL)
    direct.archiveWriteGate?.shouldFail = true

    #expect(throws: ProjectStoreError.persistenceFailed) {
        try direct.store.addKnittingReminder(
            projectID: direct.projectID,
            draft: .oneTime(kind: .custom, target: 1, text: nil)
        )
    }
    #expect(direct.store.projects == directProjectsBefore)
    #expect(direct.store.dataGeneration == directGenerationBefore)
    #expect(try Data(contentsOf: direct.archiveURL) == directArchiveBefore)

    let reader = try PatternLibraryStoreHarness.onePatternAndProject(failingArchiveWrites: true)
    let usage = try reader.store.linkPattern(patternID: reader.patternID, to: reader.projectID)
    let project = try #require(reader.store.project(id: reader.projectID))
    let reminderCounterID = project.counters[0].id
    let initiallySelectedCounterID = project.counters[1].id
    let reminderID = try reader.store.addKnittingReminder(
        projectID: reader.projectID,
        draft: .oneTime(kind: .custom, target: 1, text: nil)
    )
    _ = try reader.store.mutatePatternReaderCounterWithOutcome(
        usageID: usage.id,
        counterID: reminderCounterID,
        mutation: .increment,
        expectedDataGeneration: reader.store.dataGeneration
    )
    try reader.store.selectCounter(
        projectID: reader.projectID,
        counterID: initiallySelectedCounterID
    )
    let reminder = try #require(
        reader.store.project(id: reader.projectID)?
            .knittingReminders.first(where: { $0.id == reminderID })
    )
    let occurrence = try #require(reminder.progress.pending.first)
    let readerProjectsBefore = reader.store.projects
    let readerGenerationBefore = reader.store.dataGeneration
    let readerArchiveBefore = try Data(contentsOf: reader.archiveURL)
    reader.archiveWriteGate?.shouldFail = true

    #expect(throws: ProjectStoreError.persistenceFailed) {
        try reader.store.applyKnittingReminderAction(
            projectID: reader.projectID,
            reminderID: reminderID,
            occurrenceID: occurrence.id,
            observedRevision: reminder.mutationRevision,
            action: .complete
        )
    }
    #expect(reader.store.projects == readerProjectsBefore)
    #expect(
        reader.store.project(id: reader.projectID)?.selectedCounterID
            == initiallySelectedCounterID
    )
    #expect(reader.store.dataGeneration == readerGenerationBefore)
    #expect(try Data(contentsOf: reader.archiveURL) == readerArchiveBefore)
}

@MainActor @Test func readerCompleteAndStopPublishSelectionAndReopenState() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let project = try #require(harness.store.project(id: harness.projectID))
    let reminderCounterID = project.counters[0].id
    let selectedCounterID = project.counters[1].id
    let reminderID = try harness.store.addKnittingReminder(
        projectID: harness.projectID,
        draft: .repeating(
            kind: .custom,
            firstTarget: 2,
            interval: 2,
            limit: nil,
            text: nil
        )
    )
    _ = try harness.store.mutatePatternReaderCounterWithOutcome(
        usageID: usage.id,
        counterID: reminderCounterID,
        mutation: .update(name: nil, value: 2),
        expectedDataGeneration: harness.store.dataGeneration
    )
    try harness.store.selectCounter(
        projectID: harness.projectID,
        counterID: selectedCounterID
    )
    let pendingReminder = try #require(
        harness.store.project(id: harness.projectID)?
            .knittingReminders.first(where: { $0.id == reminderID })
    )
    let occurrence = try #require(pendingReminder.progress.pending.first)
    let generationBeforeComplete = harness.store.dataGeneration

    try harness.store.applyKnittingReminderAction(
        projectID: harness.projectID,
        reminderID: reminderID,
        occurrenceID: occurrence.id,
        observedRevision: pendingReminder.mutationRevision,
        action: .complete
    )
    #expect(harness.store.dataGeneration > generationBeforeComplete)
    let reopenedAfterComplete = try harness.reopenedStore()
    #expect(reopenedAfterComplete.project(id: harness.projectID)?.selectedCounterID == selectedCounterID)
    let completedReminder = try #require(
        reopenedAfterComplete.project(id: harness.projectID)?
            .knittingReminders.first(where: { $0.id == reminderID })
    )
    #expect(completedReminder.progress.completedCount == 1)
    #expect(completedReminder.progress.pending.isEmpty)
    #expect(completedReminder.state == .active)
    #expect(completedReminder.progress.nextTarget == 4)
    let currentReminder = try #require(
        harness.store.project(id: harness.projectID)?
            .knittingReminders.first(where: { $0.id == reminderID })
    )
    let generationBeforeStop = harness.store.dataGeneration

    try harness.store.applyKnittingReminderAction(
        projectID: harness.projectID,
        reminderID: reminderID,
        occurrenceID: nil,
        observedRevision: currentReminder.mutationRevision,
        action: .stop
    )
    #expect(harness.store.dataGeneration > generationBeforeStop)
    let reopenedAfterStop = try harness.reopenedStore()
    #expect(reopenedAfterStop.project(id: harness.projectID)?.selectedCounterID == selectedCounterID)
    let stoppedReminder = try #require(
        reopenedAfterStop.project(id: harness.projectID)?
            .knittingReminders.first(where: { $0.id == reminderID })
    )
    #expect(stoppedReminder.state == .stopped)
    #expect(stoppedReminder.progress.nextTarget == nil)
    #expect(stoppedReminder.progress.pending.isEmpty)
}

@MainActor @Test func readerUsageMutationKeepsExternalOptimisticConcurrencyRejection() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let staleGeneration = harness.store.dataGeneration
    let counterID = try #require(harness.store.project(id: harness.projectID)?.counters.first?.id)
    _ = try harness.store.mutatePatternReaderCounter(
        usageID: usage.id,
        counterID: counterID,
        mutation: .increment,
        expectedDataGeneration: staleGeneration
    )
    let confirmedGeneration = harness.store.dataGeneration

    #expect(throws: ProjectStoreError.staleDataGeneration) {
        try harness.store.updatePatternState(
            usageID: usage.id,
            state: PatternReadingState(pageIndex: 2),
            expectedDataGeneration: staleGeneration
        )
    }
    #expect(harness.store.dataGeneration == confirmedGeneration)
}

@MainActor @Test func inactiveUsageRejectsReaderCounterMutationAndRelinkRestoresReaderWrites() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let counterID = try #require(harness.store.project(id: harness.projectID)?.counters.first?.id)
    let state = PatternReadingState(pageIndex: 3)
    let markup = harness.drawing(x: 0.61)
    var expected = try harness.store.updatePatternState(
        usageID: usage.id,
        state: state,
        expectedDataGeneration: harness.store.dataGeneration
    )
    expected = try harness.store.savePatternMarkup(markup, usageID: usage.id, pageIndex: 3, expectedDataGeneration: expected)
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)

    #expect(throws: PatternLibraryMutationError.usageInactive) {
        try harness.store.mutatePatternReaderCounter(
            usageID: usage.id,
            counterID: counterID,
            mutation: .increment,
            expectedDataGeneration: harness.store.dataGeneration
        )
    }
    #expect(harness.store.patternUsages.first(where: { $0.id == usage.id })?.readingState == state)
    #expect(try harness.store.loadPatternMarkup(usageID: usage.id, pageIndex: 3) == markup)

    let relinked = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    expected = try harness.store.mutatePatternReaderCounter(
        usageID: relinked.id,
        counterID: counterID,
        mutation: .increment,
        expectedDataGeneration: harness.store.dataGeneration
    )
    #expect(expected == harness.store.dataGeneration)
    #expect(relinked.id == usage.id)
    #expect(harness.store.patternUsages.first(where: { $0.id == usage.id })?.readingState == state)
    #expect(try harness.store.loadPatternMarkup(usageID: usage.id, pageIndex: 3) == markup)
}

@MainActor @Test func markupSavePublishesGenerationAndRejectsASecondStaleWriter() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let expected = harness.store.dataGeneration
    let first = harness.drawing(x: 0.2)
    let second = harness.drawing(x: 0.8)

    let committed = try harness.store.savePatternMarkup(
        first,
        usageID: usage.id,
        pageIndex: 0,
        expectedDataGeneration: expected
    )
    #expect(committed > expected)
    #expect(throws: ProjectStoreError.staleDataGeneration) {
        try harness.store.savePatternMarkup(
            second,
            usageID: usage.id,
            pageIndex: 0,
            expectedDataGeneration: expected
        )
    }
    #expect(try harness.reopenedStore().loadPatternMarkup(usageID: usage.id, pageIndex: 0) == first)
}

@MainActor @Test func failedArchiveCommitRollsMarkupBackWithoutAdvancingGeneration() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(failingArchiveWrites: true)
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let original = harness.drawing(x: 0.1)
    _ = try harness.store.savePatternMarkup(
        original,
        usageID: usage.id,
        pageIndex: 0,
        expectedDataGeneration: harness.store.dataGeneration
    )
    let before = harness.store.dataGeneration
    harness.archiveWriteGate?.shouldFail = true

    #expect(throws: ProjectStoreError.persistenceFailed) {
        try harness.store.savePatternMarkup(
            harness.drawing(x: 0.9),
            usageID: usage.id,
            pageIndex: 0,
            expectedDataGeneration: before
        )
    }
    #expect(harness.store.dataGeneration == before)
    #expect(try harness.reopenedStore().loadPatternMarkup(usageID: usage.id, pageIndex: 0) == original)
}

@MainActor @Test func externalRevisionWithDirtyMarkupBlocksPageLoadAndRetainsLocalStrokesUntilReload() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let original = harness.drawing(x: 0.2)
    let expected = try harness.store.savePatternMarkup(
        original,
        usageID: usage.id,
        pageIndex: 0,
        expectedDataGeneration: harness.store.dataGeneration
    )
    let counterID = try #require(harness.store.project(id: harness.projectID)?.counters.first?.id)
    let external = try harness.store.mutatePatternReaderCounter(
        usageID: usage.id,
        counterID: counterID,
        mutation: .increment,
        expectedDataGeneration: expected
    )
    let localDirty = harness.drawing(x: 0.9)
    var coordinator = PatternReaderRevisionCoordinator(expectedDataGeneration: expected)
    coordinator.setMarkupDirty(true)

    #expect(coordinator.observeStoreGeneration(external, canWrite: true) == .conflict)
    #expect(!coordinator.canChangePage)
    #expect(localDirty != original)
    #expect(try harness.store.loadPatternMarkup(usageID: usage.id, pageIndex: 0) == original)

    coordinator.reset(expectedDataGeneration: external)
    #expect(coordinator.canChangePage)
    #expect(try harness.reopenedStore().loadPatternMarkup(usageID: usage.id, pageIndex: 0) == original)
}

@MainActor @Test func usageBoundReaderServiceRejectsUnknownUsageInsteadOfProvidingStandaloneWrites() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()

    #expect(throws: PatternLibraryMutationError.usageNotFound) {
        try harness.store.savePatternMarkup(
            PatternMarkupDocument(),
            usageID: UUID(),
            pageIndex: 0,
            expectedDataGeneration: harness.store.dataGeneration
        )
    }
}

@MainActor @Test func linkedProjectsKeepReadingNotesAndMarkupIndependent() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndTwoProjects()
    let first = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let second = try harness.store.linkPattern(patternID: harness.patternID, to: harness.secondProjectID!)
    let firstMarkup = PatternMarkupDocument(strokes: [.init(
        points: [.init(x: 0.1, y: 0.2)], color: .red, width: 0.006
    )])

    try harness.store.updatePatternState(usageID: first.id, state: PatternReadingState(pageIndex: 2))
    try harness.store.savePatternPageNote(usageID: first.id, pageIndex: 2, text: "first project")
    try harness.store.savePatternMarkup(
        firstMarkup,
        usageID: first.id,
        pageIndex: 2,
        expectedDataGeneration: harness.store.dataGeneration
    )

    #expect(harness.store.patternUsages.first(where: { $0.id == first.id })?.readingState.pageIndex == 2)
    #expect(harness.store.patternUsages.first(where: { $0.id == second.id })?.readingState.pageIndex == 0)
    #expect(harness.store.patternUsages.first(where: { $0.id == first.id })?.readingState.pageStates[2]?.note == "first project")
    #expect(harness.store.patternUsages.first(where: { $0.id == second.id })?.readingState.pageStates[2]?.note == nil)
    #expect(try harness.store.loadPatternMarkup(usageID: first.id, pageIndex: 2) == firstMarkup)
    #expect(try harness.store.loadPatternMarkup(usageID: second.id, pageIndex: 2).strokes.isEmpty)
}

@MainActor @Test func emptyDeletionTransactionDoesNotLeaveADeletionJournal() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()

    let transaction = try PatternLibraryDeletionTransaction.begin(
        root: harness.patternsRoot,
        markupService: PatternMarkupFileService(root: harness.patternsRoot),
        usageIDs: [],
        asset: nil,
        fileService: PatternFileService(root: harness.patternsRoot)
    )
    try transaction.stage()

    let reopened = try harness.reopenedStore()
    #expect(reopened.loadError == nil)
    #expect(harness.deletionTransactionEntries().isEmpty)
}

@MainActor @Test func projectDeletionRejectsASymlinkedUsageMarkupRoot() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.savePatternMarkup(
        harness.drawing(x: 0.3),
        usageID: usage.id,
        pageIndex: 0,
        expectedDataGeneration: harness.store.dataGeneration
    )
    let usageMarkupRoot = harness.patternsRoot.appendingPathComponent("UsageMarkup", isDirectory: true)
    let outside = harness.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: usageMarkupRoot)
    try FileManager.default.createSymbolicLink(at: usageMarkupRoot, withDestinationURL: outside)

    #expect(throws: PatternMarkupFileError.unsafePath) {
        try harness.store.delete(id: harness.projectID)
    }
    #expect(harness.store.projects.map(\.id) == [harness.projectID])
}

@MainActor @Test func unlinkingAnUnknownPairDoesNotDeletePatternOrAsset() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()

    try harness.store.unlinkPattern(patternID: harness.patternID, from: UUID())

    #expect(harness.store.patterns.map(\.id) == [harness.patternID])
    #expect(harness.store.patternAssets.map(\.id) == [harness.assetID])
    #expect(FileManager.default.fileExists(atPath: harness.assetURL.path))
}

@MainActor @Test func completedProjectRejectsReaderWrites() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(completed: true)
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)

    #expect(throws: PatternLibraryMutationError.projectCompleted) {
        try harness.store.updatePatternState(usageID: usage.id, state: PatternReadingState(pageIndex: 3))
    }
    #expect(throws: PatternLibraryMutationError.projectCompleted) {
        try harness.store.savePatternPageNote(usageID: usage.id, pageIndex: 3, text: "blocked")
    }
    #expect(throws: PatternLibraryMutationError.projectCompleted) {
        try harness.store.savePatternMarkup(
            PatternMarkupDocument(),
            usageID: usage.id,
            pageIndex: 3,
            expectedDataGeneration: harness.store.dataGeneration
        )
    }
}

@MainActor @Test func completedProjectCanLinkUnlinkAndRelinkWithoutDeletingThePattern() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(completed: true)

    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)

    #expect(harness.store.patternUsages.count == 1)
    #expect(harness.store.patternUsages[0].id == usage.id)
    #expect(!harness.store.patternUsages[0].isActive)
    #expect(harness.store.patterns.map(\.id) == [harness.patternID])
    #expect(harness.store.patternAssets.map(\.id) == [harness.assetID])
    #expect(FileManager.default.fileExists(atPath: harness.assetURL.path))

    let relinked = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)

    #expect(relinked.id == usage.id)
    #expect(relinked.isActive)
}

@MainActor @Test func deletingProjectDeletesAllItsUsageMarkupWithoutDeletingPatternOrAsset() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndTwoProjects()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let survivingUsage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.secondProjectID!)
    try harness.store.savePatternMarkup(
        PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.4, y: 0.5)], color: .black, width: 0.01)]),
        usageID: usage.id,
        pageIndex: 0,
        expectedDataGeneration: harness.store.dataGeneration
    )
    let markupURL = harness.markupURL(usageID: usage.id, pageIndex: 0)
    let survivingMarkup = PatternMarkupDocument(strokes: [.init(
        points: [.init(x: 0.7, y: 0.6)], color: .red, width: 0.01
    )])
    try harness.store.updatePatternState(
        usageID: survivingUsage.id,
        state: PatternReadingState(pageIndex: 5)
    )
    try harness.store.savePatternMarkup(
        survivingMarkup,
        usageID: survivingUsage.id,
        pageIndex: 5,
        expectedDataGeneration: harness.store.dataGeneration
    )
    let updatedSurvivingUsage = try #require(
        harness.store.patternUsages.first(where: { $0.id == survivingUsage.id })
    )

    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)
    try harness.store.delete(id: harness.projectID)

    #expect(harness.store.patternUsages == [updatedSurvivingUsage])
    #expect(harness.store.patterns.map(\.id) == [harness.patternID])
    #expect(harness.store.patternAssets.map(\.id) == [harness.assetID])
    #expect(!FileManager.default.fileExists(atPath: markupURL.path))
    #expect(FileManager.default.fileExists(atPath: harness.assetURL.path))
    #expect(try harness.store.loadPatternMarkup(usageID: survivingUsage.id, pageIndex: 5) == survivingMarkup)

    let reopened = try harness.reopenedStore()
    #expect(reopened.patternUsages == [updatedSurvivingUsage])
    #expect(try reopened.loadPatternMarkup(usageID: survivingUsage.id, pageIndex: 5) == survivingMarkup)
}

@MainActor @Test func failedProjectDeleteRestoresUsagesMarkupAndArchiveAfterFreshReload() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(failingArchiveWrites: true)
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let markup = PatternMarkupDocument(strokes: [.init(
        points: [.init(x: 0.2, y: 0.2)], color: .green, width: 0.01
    )])
    try harness.store.savePatternMarkup(
        markup,
        usageID: usage.id,
        pageIndex: 0,
        expectedDataGeneration: harness.store.dataGeneration
    )
    harness.archiveWriteGate?.shouldFail = true

    #expect(throws: ProjectStoreError.persistenceFailed) {
        try harness.store.delete(id: harness.projectID)
    }

    let reopened = try harness.reopenedStore()
    #expect(reopened.loadError == nil)
    #expect(reopened.projects.map(\.id) == [harness.projectID])
    #expect(reopened.patternUsages.map(\.id) == [usage.id])
    #expect(try reopened.loadPatternMarkup(usageID: usage.id, pageIndex: 0) == markup)
}

@MainActor @Test func permanentDeleteBlocksActiveLinksThenRemovesInactiveUsageMarkupAndLastAsset() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.savePatternMarkup(
        PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.2, y: 0.8)], color: .blue, width: 0.01)]),
        usageID: usage.id,
        pageIndex: 1,
        expectedDataGeneration: harness.store.dataGeneration
    )
    let markupURL = harness.markupURL(usageID: usage.id, pageIndex: 1)

    #expect(throws: PatternLibraryMutationError.activeLinksExist([harness.projectID])) {
        try harness.store.deletePatternPermanently(id: harness.patternID)
    }
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)
    try harness.store.deletePatternPermanently(id: harness.patternID)

    #expect(harness.store.patterns.isEmpty)
    #expect(harness.store.patternUsages.isEmpty)
    #expect(harness.store.patternAssets.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: markupURL.path))
    #expect(!FileManager.default.fileExists(atPath: harness.assetURL.path))

    let reopened = try harness.reopenedStore()
    #expect(reopened.loadError == nil)
    #expect(reopened.patterns.isEmpty)
    #expect(reopened.patternUsages.isEmpty)
    #expect(reopened.patternAssets.isEmpty)
}

@MainActor @Test func permanentDeleteKeepsAnAssetReferencedByAnotherPattern() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(sharedAsset: true)
    _ = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)

    try harness.store.deletePatternPermanently(id: harness.patternID)

    #expect(harness.store.patterns.map(\.id) == [harness.sharedPatternID!])
    #expect(harness.store.patternAssets.map(\.id) == [harness.assetID])
    #expect(FileManager.default.fileExists(atPath: harness.assetURL.path))
}

@MainActor @Test func failedPermanentDeleteRestoresArchiveAndOwnedFiles() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(failingArchiveWrites: true)
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.savePatternMarkup(
        PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.4, y: 0.4)], color: .green, width: 0.01)]),
        usageID: usage.id,
        pageIndex: 0,
        expectedDataGeneration: harness.store.dataGeneration
    )
    let markupURL = harness.markupURL(usageID: usage.id, pageIndex: 0)
    try harness.store.unlinkPattern(patternID: harness.patternID, from: harness.projectID)
    harness.archiveWriteGate?.shouldFail = true

    #expect(throws: ProjectStoreError.persistenceFailed) {
        try harness.store.deletePatternPermanently(id: harness.patternID)
    }

    #expect(harness.store.patterns.map(\.id) == [harness.patternID])
    #expect(harness.store.patternUsages.map(\.id) == [usage.id])
    #expect(harness.store.patternAssets.map(\.id) == [harness.assetID])
    #expect(FileManager.default.fileExists(atPath: harness.assetURL.path))
    #expect(FileManager.default.fileExists(atPath: markupURL.path))
}

@MainActor @Test func freshStartupRollsBackStagedProjectDeletionBeforeArchivePublication() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndTwoProjects()
    let first = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let second = try harness.store.linkPattern(patternID: harness.patternID, to: harness.secondProjectID!)
    let firstMarkup = harness.drawing(x: 0.1)
    let secondMarkup = harness.drawing(x: 0.9)
    try harness.store.savePatternMarkup(firstMarkup, usageID: first.id, pageIndex: 0, expectedDataGeneration: harness.store.dataGeneration)
    try harness.store.savePatternMarkup(secondMarkup, usageID: second.id, pageIndex: 0, expectedDataGeneration: harness.store.dataGeneration)
    let transaction = try PatternLibraryDeletionTransaction.begin(
        root: harness.patternsRoot,
        markupService: PatternMarkupFileService(root: harness.patternsRoot),
        usageIDs: [first.id],
        asset: nil,
        fileService: PatternFileService(root: harness.patternsRoot)
    )
    try transaction.stage()

    let reopened = try harness.reopenedStore()
    #expect(reopened.loadError == nil)
    let restoredUsageIDs = reopened.patternUsages.map(\.id).sorted { $0.uuidString < $1.uuidString }
    let expectedUsageIDs = [first.id, second.id].sorted { $0.uuidString < $1.uuidString }

    #expect(restoredUsageIDs == expectedUsageIDs)
    #expect(try reopened.loadPatternMarkup(usageID: first.id, pageIndex: 0) == firstMarkup)
    #expect(try reopened.loadPatternMarkup(usageID: second.id, pageIndex: 0) == secondMarkup)
    #expect(harness.deletionTransactionEntries().isEmpty)
}

@MainActor @Test func freshStartupFinalizesPublishedProjectDeletionWithoutTouchingAnotherUsage() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndTwoProjects()
    let first = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let second = try harness.store.linkPattern(patternID: harness.patternID, to: harness.secondProjectID!)
    let firstMarkup = harness.drawing(x: 0.1)
    let secondMarkup = harness.drawing(x: 0.9)
    try harness.store.savePatternMarkup(firstMarkup, usageID: first.id, pageIndex: 0, expectedDataGeneration: harness.store.dataGeneration)
    try harness.store.savePatternMarkup(secondMarkup, usageID: second.id, pageIndex: 0, expectedDataGeneration: harness.store.dataGeneration)
    let transaction = try PatternLibraryDeletionTransaction.begin(
        root: harness.patternsRoot,
        markupService: PatternMarkupFileService(root: harness.patternsRoot),
        usageIDs: [first.id],
        asset: nil,
        fileService: PatternFileService(root: harness.patternsRoot)
    )
    try transaction.stage()
    try harness.removeProjectFromArchive(projectID: harness.projectID)
    try transaction.publish()

    let reopened = try harness.reopenedStore()
    #expect(reopened.loadError == nil)

    #expect(reopened.projects.map(\.id) == [harness.secondProjectID!])
    #expect(reopened.patternUsages.map(\.id) == [second.id])
    #expect(try reopened.loadPatternMarkup(usageID: second.id, pageIndex: 0) == secondMarkup)
    #expect(harness.deletionTransactionEntries().isEmpty)
}

@MainActor @Test func freshStartupRollsBackStagedPatternDeletionBeforeArchivePublication() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let markup = harness.drawing(x: 0.3)
    try harness.store.savePatternMarkup(markup, usageID: usage.id, pageIndex: 0, expectedDataGeneration: harness.store.dataGeneration)
    let transaction = try PatternLibraryDeletionTransaction.begin(
        root: harness.patternsRoot,
        markupService: PatternMarkupFileService(root: harness.patternsRoot),
        usageIDs: [usage.id],
        asset: harness.asset,
        fileService: PatternFileService(root: harness.patternsRoot)
    )
    try transaction.stage()

    let reopened = try harness.reopenedStore()
    #expect(reopened.loadError == nil)

    #expect(reopened.patterns.map(\.id) == [harness.patternID])
    #expect(reopened.patternAssets.map(\.id) == [harness.assetID])
    #expect(try reopened.loadPatternMarkup(usageID: usage.id, pageIndex: 0) == markup)
    #expect(FileManager.default.fileExists(atPath: harness.assetURL.path))
    #expect(harness.deletionTransactionEntries().isEmpty)
}

@MainActor @Test func freshStartupFinalizesPublishedPatternDeletionAndClearsTransactionArtifacts() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    try harness.store.savePatternMarkup(harness.drawing(x: 0.3), usageID: usage.id, pageIndex: 0, expectedDataGeneration: harness.store.dataGeneration)
    let transaction = try PatternLibraryDeletionTransaction.begin(
        root: harness.patternsRoot,
        markupService: PatternMarkupFileService(root: harness.patternsRoot),
        usageIDs: [usage.id],
        asset: harness.asset,
        fileService: PatternFileService(root: harness.patternsRoot)
    )
    try transaction.stage()
    try harness.removePatternFromArchive(patternID: harness.patternID)
    try transaction.publish()

    let reopened = try harness.reopenedStore()

    #expect(reopened.patterns.isEmpty)
    #expect(reopened.patternUsages.isEmpty)
    #expect(reopened.patternAssets.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: harness.assetURL.path))
    #expect(harness.deletionTransactionEntries().isEmpty)
}

@MainActor @Test func malformedDeletionJournalBlocksLoadAndFurtherMutations() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    try harness.writeMalformedDeletionJournal()

    let reopened = try harness.reopenedStore()

    #expect(reopened.loadError == .unreadableArchive)
    #expect(throws: ProjectStoreError.archiveUnavailable) {
        try reopened.linkPattern(patternID: harness.patternID, to: harness.projectID)
    }
}

@MainActor @Test func tamperedDeletionJournalIntegrityBlocksLoadAndFurtherMutations() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let transaction = try PatternLibraryDeletionTransaction.begin(
        root: harness.patternsRoot,
        markupService: PatternMarkupFileService(root: harness.patternsRoot),
        usageIDs: [usage.id],
        asset: nil,
        fileService: PatternFileService(root: harness.patternsRoot)
    )
    try transaction.stage()
    try harness.tamperDeletionJournalIntegrity()

    let reopened = try harness.reopenedStore()

    #expect(reopened.loadError == .unreadableArchive)
    #expect(throws: ProjectStoreError.archiveUnavailable) {
        try reopened.linkPattern(patternID: harness.patternID, to: harness.projectID)
    }
}

private struct PatternFolderStoreState {
    let projects: [StoredProject]
    let yarns: [StoredYarn]
    let folders: [PatternFolder]
    let assets: [PatternAsset]
    let patterns: [StoredPattern]
    let usages: [PatternProjectUsage]
    let generation: UInt64
    let archiveData: Data
}

@MainActor
private func patternFolderStoreState(_ harness: PatternLibraryStoreHarness) throws -> PatternFolderStoreState {
    PatternFolderStoreState(
        projects: harness.store.projects,
        yarns: harness.store.yarns,
        folders: harness.store.patternFolders,
        assets: harness.store.patternAssets,
        patterns: harness.store.patterns,
        usages: harness.store.patternUsages,
        generation: harness.store.dataGeneration,
        archiveData: try Data(contentsOf: harness.archiveURL)
    )
}

@MainActor
private func expectPatternFolderStoreState(
    _ expected: PatternFolderStoreState,
    in harness: PatternLibraryStoreHarness
) throws {
    #expect(harness.store.projects == expected.projects)
    #expect(harness.store.yarns == expected.yarns)
    #expect(harness.store.patternFolders == expected.folders)
    #expect(harness.store.patternAssets == expected.assets)
    #expect(harness.store.patterns == expected.patterns)
    #expect(harness.store.patternUsages == expected.usages)
    #expect(harness.store.dataGeneration == expected.generation)
    #expect(try Data(contentsOf: harness.archiveURL) == expected.archiveData)
}

@MainActor @Test
func createRenameMoveAndDeleteFolderAreAtomic() async throws {
    let harness = try PatternImportHarness()
    let source = try harness.makePDF(named: "Cardigan.pdf")
    let outcome = try await harness.store.importPatternFromLibrary(source)
    guard case let .created(patternID) = outcome else {
        Issue.record("Expected a newly created pattern")
        return
    }
    let context = PatternFolderNameContext(
        locale: Locale(identifier: "en"),
        reservedNames: ["All", "Uncategorized"]
    )
    let initialGeneration = harness.store.dataGeneration

    let folder = try harness.store.createPatternFolder(
        name: " Sweaters ", nameContext: context, now: Date(timeIntervalSince1970: 10)
    )
    #expect(folder.displayName == "Sweaters")
    #expect(harness.store.patternFolders == [folder])
    #expect(harness.store.dataGeneration == initialGeneration + 1)
    var archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: harness.archiveURL))
    #expect(archive.patternFolders == [folder])

    try harness.store.renamePatternFolder(id: folder.id, to: "Pullovers", nameContext: context)
    #expect(harness.store.patternFolders.first?.displayName == "Pullovers")
    #expect(harness.store.dataGeneration == initialGeneration + 2)
    archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: harness.archiveURL))
    #expect(archive.patternFolders.first?.displayName == "Pullovers")

    try harness.store.movePattern(id: patternID, toFolderID: folder.id)
    #expect(harness.store.patterns.first(where: { $0.id == patternID })?.folderID == folder.id)
    #expect(harness.store.dataGeneration == initialGeneration + 3)
    archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: harness.archiveURL))
    #expect(archive.patterns.first(where: { $0.id == patternID })?.folderID == folder.id)
    let reloaded = try harness.reopenedStore()
    #expect(reloaded.patternFolders == harness.store.patternFolders)
    #expect(reloaded.patterns.first(where: { $0.id == patternID })?.folderID == folder.id)

    let movedCount = try harness.store.deletePatternFolder(id: folder.id)
    #expect(movedCount == 1)
    #expect(harness.store.patternFolders.isEmpty)
    #expect(harness.store.patterns.first(where: { $0.id == patternID })?.folderID == nil)
    #expect(harness.store.dataGeneration == initialGeneration + 4)
    archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: harness.archiveURL))
    #expect(archive.patternFolders.isEmpty)
    #expect(archive.patterns.first(where: { $0.id == patternID })?.folderID == nil)
}

@MainActor @Test
func deletingFolderMovesEveryMatchingPatternAndLeavesUnrelatedPattern() async throws {
    let harness = try PatternImportHarness()
    var patternIDs: [UUID] = []
    for pageCount in 1...3 {
        let source = harness.sourceRoot.appendingPathComponent("Pattern-\(pageCount).pdf")
        try makeTestPatternPDF(at: source, pageCount: pageCount)
        guard case let .created(patternID) = try await harness.store.importPatternFromLibrary(source)
        else {
            Issue.record("Expected distinct imported pattern")
            return
        }
        patternIDs.append(patternID)
    }
    let context = try shippingPatternFolderNameContext()
    let deleted = try harness.store.createPatternFolder(name: "Delete me", nameContext: context)
    let retained = try harness.store.createPatternFolder(name: "Keep me", nameContext: context)
    try harness.store.movePattern(id: patternIDs[0], toFolderID: deleted.id)
    try harness.store.movePattern(id: patternIDs[1], toFolderID: deleted.id)
    try harness.store.movePattern(id: patternIDs[2], toFolderID: retained.id)

    let movedCount = try harness.store.deletePatternFolder(id: deleted.id)

    #expect(movedCount == 2)
    #expect(harness.store.patterns.first { $0.id == patternIDs[0] }?.folderID == nil)
    #expect(harness.store.patterns.first { $0.id == patternIDs[1] }?.folderID == nil)
    #expect(harness.store.patterns.first { $0.id == patternIDs[2] }?.folderID == retained.id)
    #expect(harness.store.patternFolders == [retained])
}

@MainActor @Test
func staleFolderAndPatternIdentitiesPublishNothing() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let context = PatternFolderNameContext(locale: Locale(identifier: "en"), reservedNames: [])
    let folder = try harness.store.createPatternFolder(name: "Socks", nameContext: context)
    let before = try patternFolderStoreState(harness)

    #expect(throws: PatternFolderStoreError.folderNotFound) {
        try harness.store.renamePatternFolder(id: UUID(), to: "Renamed", nameContext: context)
    }
    try expectPatternFolderStoreState(before, in: harness)

    #expect(throws: PatternFolderStoreError.folderNotFound) {
        _ = try harness.store.deletePatternFolder(id: UUID())
    }
    try expectPatternFolderStoreState(before, in: harness)

    #expect(throws: PatternFolderStoreError.folderNotFound) {
        try harness.store.movePattern(id: harness.patternID, toFolderID: UUID())
    }
    try expectPatternFolderStoreState(before, in: harness)

    #expect(throws: PatternFolderStoreError.patternNotFound) {
        try harness.store.movePattern(id: UUID(), toFolderID: folder.id)
    }
    try expectPatternFolderStoreState(before, in: harness)
}

@MainActor @Test
func rejectedFolderNamesPublishNothing() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let context = PatternFolderNameContext(
        locale: Locale(identifier: "en"), reservedNames: ["All", "Uncategorized"]
    )
    let folder = try harness.store.createPatternFolder(name: "Socks", nameContext: context)
    let before = try patternFolderStoreState(harness)

    #expect(throws: PatternFolderValidationError.duplicateName) {
        _ = try harness.store.createPatternFolder(name: " socks ", nameContext: context)
    }
    try expectPatternFolderStoreState(before, in: harness)

    #expect(throws: PatternFolderValidationError.reservedName) {
        try harness.store.renamePatternFolder(id: folder.id, to: "all", nameContext: context)
    }
    try expectPatternFolderStoreState(before, in: harness)

    #expect(throws: PatternFolderValidationError.emptyName) {
        _ = try harness.store.createPatternFolder(name: " \n ", nameContext: context)
    }
    try expectPatternFolderStoreState(before, in: harness)

    #expect(throws: PatternFolderValidationError.emptyName) {
        try harness.store.renamePatternFolder(id: folder.id, to: "\t ", nameContext: context)
    }
    try expectPatternFolderStoreState(before, in: harness)
}

@MainActor @Test
func movingToTheCurrentFolderDoesNotRewriteOrAdvanceGeneration() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(failingArchiveWrites: true)
    let context = PatternFolderNameContext(locale: Locale(identifier: "en"), reservedNames: [])
    let folder = try harness.store.createPatternFolder(name: "Socks", nameContext: context)
    try harness.store.movePattern(id: harness.patternID, toFolderID: folder.id)
    let before = try patternFolderStoreState(harness)
    let writesBefore = harness.archiveWriteGate?.writeCount

    try harness.store.movePattern(id: harness.patternID, toFolderID: folder.id)

    try expectPatternFolderStoreState(before, in: harness)
    #expect(harness.archiveWriteGate?.writeCount == writesBefore)
}

@MainActor @Test
func failedFolderTransactionsLeaveEveryPublishedValueAndArchiveUnchanged() throws {
    let context = PatternFolderNameContext(locale: Locale(identifier: "en"), reservedNames: [])

    let createHarness = try PatternLibraryStoreHarness.onePatternAndProject(failingArchiveWrites: true)
    let createBefore = try patternFolderStoreState(createHarness)
    createHarness.archiveWriteGate?.shouldFail = true
    #expect(throws: ProjectStoreError.persistenceFailed) {
        _ = try createHarness.store.createPatternFolder(name: "Socks", nameContext: context)
    }
    try expectPatternFolderStoreState(createBefore, in: createHarness)

    let renameHarness = try PatternLibraryStoreHarness.onePatternAndProject(failingArchiveWrites: true)
    let renameFolder = try renameHarness.store.createPatternFolder(name: "Socks", nameContext: context)
    let renameBefore = try patternFolderStoreState(renameHarness)
    renameHarness.archiveWriteGate?.shouldFail = true
    #expect(throws: ProjectStoreError.persistenceFailed) {
        try renameHarness.store.renamePatternFolder(id: renameFolder.id, to: "Mittens", nameContext: context)
    }
    try expectPatternFolderStoreState(renameBefore, in: renameHarness)

    let moveHarness = try PatternLibraryStoreHarness.onePatternAndProject(failingArchiveWrites: true)
    let moveFolder = try moveHarness.store.createPatternFolder(name: "Socks", nameContext: context)
    let moveBefore = try patternFolderStoreState(moveHarness)
    moveHarness.archiveWriteGate?.shouldFail = true
    #expect(throws: ProjectStoreError.persistenceFailed) {
        try moveHarness.store.movePattern(id: moveHarness.patternID, toFolderID: moveFolder.id)
    }
    try expectPatternFolderStoreState(moveBefore, in: moveHarness)

    let deleteHarness = try PatternLibraryStoreHarness.onePatternAndProject(failingArchiveWrites: true)
    let deleteFolder = try deleteHarness.store.createPatternFolder(name: "Socks", nameContext: context)
    try deleteHarness.store.movePattern(id: deleteHarness.patternID, toFolderID: deleteFolder.id)
    let deleteBefore = try patternFolderStoreState(deleteHarness)
    deleteHarness.archiveWriteGate?.shouldFail = true
    #expect(throws: ProjectStoreError.persistenceFailed) {
        _ = try deleteHarness.store.deletePatternFolder(id: deleteFolder.id)
    }
    try expectPatternFolderStoreState(deleteBefore, in: deleteHarness)
}

@MainActor
final class PatternLibraryStoreHarness {
    let root: URL
    let patternID: UUID
    let assetID: UUID
    let projectID: UUID
    let secondProjectID: UUID?
    let sharedPatternID: UUID?
    let asset: PatternAsset
    let patternsRoot: URL
    let archiveURL: URL
    let assetURL: URL
    let store: JSONProjectStore
    let archiveWriteGate: ArchiveWriteGate?

    private init(
        completed: Bool,
        secondProject: Bool,
        sharedAsset: Bool,
        failingArchiveWrites: Bool,
        authorizeMutation: @escaping MutationAuthorizer = { _ in .allow }
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatternLibraryStoreHarness-\(UUID().uuidString)", isDirectory: true)
        patternsRoot = root.appendingPathComponent("Patterns", isDirectory: true)
        archiveURL = root.appendingPathComponent("projects-v1.json")
        assetID = UUID()
        patternID = UUID()
        projectID = UUID()
        secondProjectID = secondProject ? UUID() : nil
        let sharedID = sharedAsset ? UUID() : nil
        sharedPatternID = sharedID
        assetURL = patternsRoot.appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent("\(assetID.uuidString).pdf")
        try FileManager.default.createDirectory(at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeTestPatternPDF(at: assetURL)
        let metadata = try PatternFileService(root: patternsRoot).inspect(assetURL)
        asset = PatternAsset(
            id: assetID,
            sha256: metadata.sha256,
            kind: metadata.kind,
            storedFilename: assetURL.lastPathComponent,
            byteCount: metadata.byteCount,
            pageCount: metadata.pageCount
        )
        let firstProject = try StoredProject(
            id: projectID,
            name: "First",
            completedAt: completed ? Date(timeIntervalSince1970: 1) : nil
        )
        var projects = [firstProject]
        if let secondProjectID {
            projects.append(try StoredProject(id: secondProjectID, name: "Second"))
        }
        var archivePatterns = [StoredPattern(id: patternID, assetID: assetID, displayName: "Fixture")]
        if let sharedID {
            archivePatterns.append(StoredPattern(id: sharedID, assetID: assetID, displayName: "Shared"))
        }
        let archive = ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: projects,
            patternAssets: [asset],
            patterns: archivePatterns
        )
        try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)
        let gate = failingArchiveWrites ? ArchiveWriteGate() : nil
        archiveWriteGate = gate
        let nameContext = try shippingPatternFolderNameContext()
        store = JSONProjectStore(
            url: archiveURL,
            patternFileService: PatternFileService(root: patternsRoot),
            patternInboxFileService: PatternInboxFileService(
                root: root.appendingPathComponent("PatternInbox", isDirectory: true)
            ),
            patternFolderNameContext: nameContext,
            backupService: KnitNoteBackupService(
                liveRoot: root,
                workRoot: root.appendingPathComponent(".BackupWork", isDirectory: true),
                patternFolderNameContext: nameContext
            ),
            archiveWrite: { data, destination in
                gate?.writeCount += 1
                if gate?.shouldFail == true { throw ProjectStoreError.persistenceFailed }
                try data.write(to: destination, options: .atomic)
            },
            authorizeMutation: authorizeMutation
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    static func onePatternAndProject(
        completed: Bool = false,
        sharedAsset: Bool = false,
        failingArchiveWrites: Bool = false,
        authorizeMutation: @escaping MutationAuthorizer = { _ in .allow }
    ) throws -> PatternLibraryStoreHarness {
        try .init(
            completed: completed,
            secondProject: false,
            sharedAsset: sharedAsset,
            failingArchiveWrites: failingArchiveWrites,
            authorizeMutation: authorizeMutation
        )
    }

    static func onePatternAndTwoProjects() throws -> PatternLibraryStoreHarness {
        try .init(
            completed: false,
            secondProject: true,
            sharedAsset: false,
            failingArchiveWrites: false
        )
    }

    func markupURL(usageID: UUID, pageIndex: Int) -> URL {
        root.appendingPathComponent("Patterns/UsageMarkup/\(usageID.uuidString)/\(pageIndex).json")
    }

    func drawing(x: Double) -> PatternMarkupDocument {
        PatternMarkupDocument(strokes: [.init(
            points: [.init(x: x, y: 0.5)], color: .black, width: 0.01
        )])
    }

    func reopenedStore() throws -> JSONProjectStore {
        let nameContext = try shippingPatternFolderNameContext()
        return JSONProjectStore(
            url: archiveURL,
            patternFileService: PatternFileService(root: patternsRoot),
            patternInboxFileService: PatternInboxFileService(
                root: root.appendingPathComponent("PatternInbox", isDirectory: true)
            ),
            patternFolderNameContext: nameContext,
            backupService: KnitNoteBackupService(
                liveRoot: root,
                workRoot: root.appendingPathComponent(".BackupWork", isDirectory: true),
                patternFolderNameContext: nameContext
            )
        )
    }

    func removeProjectFromArchive(projectID: UUID) throws {
        var archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
        archive.projects.removeAll { $0.id == projectID }
        archive.patternUsages.removeAll { $0.projectID == projectID }
        try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)
    }

    func removePatternFromArchive(patternID: UUID) throws {
        var archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
        guard let pattern = archive.patterns.first(where: { $0.id == patternID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        archive.patterns.removeAll { $0.id == patternID }
        archive.patternUsages.removeAll { $0.patternID == patternID }
        if !archive.patterns.contains(where: { $0.assetID == pattern.assetID }) {
            archive.patternAssets.removeAll { $0.id == pattern.assetID }
        }
        try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)
    }

    func deletionTransactionEntries() -> [URL] {
        let root = patternsRoot.appendingPathComponent(".DeletionTransactions", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }

    func writeMalformedDeletionJournal() throws {
        let root = patternsRoot.appendingPathComponent(".DeletionTransactions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a journal".utf8).write(
            to: root.appendingPathComponent("\(UUID().uuidString).json"),
            options: .atomic
        )
    }

    func tamperDeletionJournalIntegrity() throws {
        guard let journalURL = deletionTransactionEntries().first(where: { $0.pathExtension == "json" }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
        object?["integrity"] = "tampered"
        try JSONSerialization.data(withJSONObject: object ?? [:]).write(to: journalURL, options: .atomic)
    }
}

final class ArchiveWriteGate: @unchecked Sendable {
    var shouldFail = false
    var writeCount = 0
}
