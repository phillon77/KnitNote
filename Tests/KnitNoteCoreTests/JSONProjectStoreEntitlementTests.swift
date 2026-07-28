import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@MainActor
@Test func liveStoreForwardsTheInjectedMutationAuthorizer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "JSONProjectStoreLiveEntitlementTests-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    var observed: [FeatureMutation] = []
    let store = JSONProjectStore.live(
        baseDirectory: root,
        authorizeMutation: {
            observed.append($0)
            return .requiresUnlock
        }
    )

    #expect(throws: ProjectStoreError.accessRestricted) {
        try store.add(name: "Blocked")
    }

    #expect(observed == [.createProject])
    #expect(store.projects.isEmpty)
    #expect(
        !FileManager.default.fileExists(
            atPath: root
                .appendingPathComponent("KnitNote", isDirectory: true)
                .appendingPathComponent("projects-v1.json")
                .path
        )
    )
}

@MainActor
@Test func restrictedCreateProjectFailsBeforeWritingTheArchive() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestrictedStore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("projects-v1.json")
    let store = JSONProjectStore(
        url: archive,
        authorizeMutation: { _ in .requiresUnlock }
    )

    #expect(throws: ProjectStoreError.accessRestricted) {
        try store.add(name: "Blocked")
    }
    #expect(store.projects.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: archive.path))
}

@MainActor
@Test func failedProjectCreationNeverCommitsTrialStart() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FailedCreateCommit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let committer = MutationCommitterProbe()
    let store = JSONProjectStore(
        url: root.appendingPathComponent("projects-v1.json"),
        authorizeMutation: { _ in .allow },
        commitSuccessfulMutation: { committer.commit($0) }
    )

    #expect(throws: Error.self) {
        try store.add(name: "   ")
    }

    #expect(committer.mutations.isEmpty)
    #expect(store.projects.isEmpty)
}

@MainActor
@Test func archiveWriteFailureNeverCommitsTrialStart() throws {
    enum WriteFailure: Error { case expected }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FailedArchiveCommit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let committer = MutationCommitterProbe()
    let store = JSONProjectStore(
        url: root.appendingPathComponent("projects-v1.json"),
        backupService: KnitNoteBackupService(
            liveRoot: root,
            workRoot: root.appendingPathComponent("Work", isDirectory: true)
        ),
        archiveWrite: { _, _ in throw WriteFailure.expected },
        authorizeMutation: { _ in .allow },
        commitSuccessfulMutation: { committer.commit($0) }
    )

    #expect(throws: ProjectStoreError.persistenceFailed) {
        try store.add(name: "Write fails")
    }

    #expect(committer.mutations.isEmpty)
    #expect(store.projects.isEmpty)
}

@MainActor
@Test func failedPatternImportsNeverCommitTrialStart() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FailedImportCommit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let archive = root.appendingPathComponent("projects-v1.json")
    let badPDF = root.appendingPathComponent("bad.pdf")
    try Data("not a pdf".utf8).write(to: badPDF)
    let committer = MutationCommitterProbe()
    let store = JSONProjectStore(
        url: archive,
        authorizeMutation: { _ in .allow },
        commitSuccessfulMutation: { committer.commit($0) }
    )

    await #expect(throws: ProjectStoreError.patternNotFound) {
        _ = try await store.importPattern(from: badPDF, projectID: UUID())
    }
    await #expect(throws: PatternFileError.invalidContent) {
        _ = try await store.importPatternFromLibrary(badPDF)
    }

    #expect(committer.mutations.isEmpty)
}

@MainActor
@Test func successfulProjectCreationAndImportUseOnlyTheEntryAuthorizationBoundary() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SuccessfulMutationCommit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("pattern.pdf")
    try makeTestPatternPDF(at: source)
    let committer = MutationCommitterProbe()
    let store = JSONProjectStore(
        url: root.appendingPathComponent("projects-v1.json"),
        authorizeMutation: { _ in .allow },
        commitSuccessfulMutation: { committer.commit($0) }
    )

    try store.add(name: "First")
    let projectID = try #require(store.projects.first?.id)
    _ = try await store.importPattern(from: source, projectID: projectID)

    #expect(committer.mutations.isEmpty)
}

@MainActor
@Test func importAdmittedBeforeExactExpiryCompletesAcrossTheBoundary() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImportExpiryBoundary-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("pattern.pdf")
    try makeTestPatternPDF(at: source)
    let startedAt = Date(timeIntervalSince1970: 10_000)
    let trial = TrialRecord(startedAt: startedAt)
    let clock = MutationBoundaryClock(
        now: trial.expiresAt.addingTimeInterval(-0.001)
    )
    let project = try StoredProject(name: "First")
    let archive = root.appendingPathComponent("projects-v1.json")
    try JSONEncoder().encode(ProjectArchive(
        version: ProjectArchive.currentVersion,
        projects: [project]
    )).write(to: archive, options: .atomic)
    let patternRoot = root.appendingPathComponent("Patterns", isDirectory: true)
    var authorizations: [FeatureMutation] = []
    var laterCommitChecks: [FeatureMutation] = []
    let store = JSONProjectStore(
        url: archive,
        patternFileService: PatternFileService(
            root: patternRoot,
            copyFile: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
                clock.setNow(trial.expiresAt)
            }
        ),
        authorizeMutation: { mutation in
            authorizations.append(mutation)
            return FeatureAccessPolicy.decision(
                for: mutation,
                snapshot: .trial(startedAt: startedAt, expiresAt: trial.expiresAt),
                now: clock.now
            )
        },
        commitSuccessfulMutation: { mutation in
            laterCommitChecks.append(mutation)
            return FeatureAccessPolicy.decision(
                for: mutation,
                snapshot: .trial(startedAt: startedAt, expiresAt: trial.expiresAt),
                now: clock.now
            )
        }
    )

    let imported = try await store.importPattern(from: source, projectID: project.id)

    #expect(clock.now == trial.expiresAt)
    #expect(authorizations == [.importPattern])
    #expect(laterCommitChecks.isEmpty)
    #expect(store.project(id: project.id)?.patterns == [imported])
    #expect(FileManager.default.fileExists(
        atPath: store.patternURL(projectID: project.id, pattern: imported).path
    ))
}

@MainActor
@Test func journalPhotoAdmittedBeforeExactExpiryCompletesAcrossTheBoundary() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("JournalExpiryBoundary-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let startedAt = Date(timeIntervalSince1970: 20_000)
    let trial = TrialRecord(startedAt: startedAt)
    let clock = MutationBoundaryClock(
        now: trial.expiresAt.addingTimeInterval(-0.001)
    )
    let project = try StoredProject(name: "Journal")
    let archive = root.appendingPathComponent("projects-v1.json")
    try JSONEncoder().encode(ProjectArchive(
        version: ProjectArchive.currentVersion,
        projects: [project]
    )).write(to: archive, options: .atomic)
    var authorizations: [FeatureMutation] = []
    var laterCommitChecks: [FeatureMutation] = []
    let journalDirectory = root.appendingPathComponent("JournalPhotos", isDirectory: true)
    let store = JSONProjectStore(
        url: archive,
        journalPhotoService: ProjectJournalPhotoFileService(
            directory: journalDirectory,
            writeData: { data, destination in
                clock.setNow(trial.expiresAt)
                try data.write(to: destination, options: .atomic)
            }
        ),
        authorizeMutation: { mutation in
            authorizations.append(mutation)
            return FeatureAccessPolicy.decision(
                for: mutation,
                snapshot: .trial(startedAt: startedAt, expiresAt: trial.expiresAt),
                now: clock.now
            )
        },
        commitSuccessfulMutation: { mutation in
            laterCommitChecks.append(mutation)
            return FeatureAccessPolicy.decision(
                for: mutation,
                snapshot: .trial(startedAt: startedAt, expiresAt: trial.expiresAt),
                now: clock.now
            )
        }
    )

    try await store.addJournalEntry(
        projectID: project.id,
        photoData: try journalBoundaryJPEG(),
        caption: "Crossed",
        createdAt: trial.expiresAt
    )

    let entry = try #require(store.project(id: project.id)?.journalEntries.first)
    #expect(clock.now == trial.expiresAt)
    #expect(authorizations == [.editJournal])
    #expect(laterCommitChecks.isEmpty)
    #expect(store.journalPhotoURL(for: entry).map {
        FileManager.default.fileExists(atPath: $0.path)
    } == true)
}

@MainActor
@Test func restrictedYarnMutationFailsWithoutChangingMemoryOrDisk() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestrictedYarn-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("projects-v1.json")
    let store = JSONProjectStore(
        url: archive,
        authorizeMutation: { _ in .requiresUnlock }
    )

    #expect(throws: ProjectStoreError.accessRestricted) {
        try store.addYarn(StoredYarn(name: "Blocked"))
    }
    #expect(store.yarns.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: archive.path))
}

@MainActor
@Test func passivePatternBrowsingPreservesExplicitFieldsAndExplicitEditStartsTrial() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PassivePatternBrowsing-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let assetID = UUID()
    let patternsRoot = root.appendingPathComponent("Patterns", isDirectory: true)
    let assetURL = patternsRoot
        .appendingPathComponent("Assets", isDirectory: true)
        .appendingPathComponent("\(assetID.uuidString).pdf")
    try FileManager.default.createDirectory(
        at: assetURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try makeTestPatternPDF(at: assetURL)
    let metadata = try PatternFileService(root: patternsRoot).inspect(assetURL)
    let asset = PatternAsset(
        id: assetID,
        sha256: metadata.sha256,
        kind: metadata.kind,
        storedFilename: assetURL.lastPathComponent,
        byteCount: metadata.byteCount,
        pageCount: metadata.pageCount
    )
    let pattern = StoredPattern(assetID: asset.id, displayName: "Browse")
    let project = try StoredProject(name: "Linked")
    let storedPageStates = [
        0: PatternPageState(
            horizontalPosition: 0.21,
            verticalPosition: 0.79,
            note: "Stored page zero"
        ),
        2: PatternPageState(
            horizontalPosition: 0.42,
            verticalPosition: 0.64,
            note: "Stored page two"
        ),
    ]
    let usage = PatternProjectUsage(
        patternID: pattern.id,
        projectID: project.id,
        sortOrder: 0,
        readingState: PatternReadingState(
            highlightEnabled: true,
            highlightPosition: 0.21,
            highlightMode: .cross,
            verticalHighlightPosition: 0.79,
            pageNote: "Stored page zero",
            pageStates: storedPageStates
        )
    )
    let archive = root.appendingPathComponent("projects-v1.json")
    try JSONEncoder().encode(ProjectArchive(
        version: ProjectArchive.currentVersion,
        projects: [project],
        patternAssets: [asset],
        patterns: [pattern],
        patternUsages: [usage]
    )).write(to: archive, options: .atomic)
    let committer = MutationCommitterProbe()
    let store = JSONProjectStore(
        url: archive,
        authorizeMutation: {
            FeatureAccessPolicy.decision(
                for: $0,
                snapshot: .trialNotStarted,
                now: Date(timeIntervalSince1970: 30_000)
            )
        },
        commitSuccessfulMutation: { committer.commit($0) }
    )

    try store.markPatternOpened(
        id: pattern.id,
        at: Date(timeIntervalSince1970: 30_001)
    )

    #expect(committer.mutations.isEmpty)
    #expect(store.patterns.first?.lastOpenedAt == Date(timeIntervalSince1970: 30_001))

    let stateBeforeBrowsing = try #require(store.patternUsages.first?.readingState)
    let lastOpenedBeforeBrowsing = try #require(store.patterns.first?.lastOpenedAt)
    _ = try store.updatePatternBrowsingState(
        usageID: usage.id,
        state: PatternReadingState(
            pageIndex: 2,
            zoomScale: 2.25,
            offsetX: 0.3,
            offsetY: 0.7,
            highlightEnabled: false,
            highlightPosition: 0.91,
            highlightMode: .vertical,
            verticalHighlightPosition: 0.09,
            pageNote: "Injected housekeeping note",
            pageStates: [
                2: PatternPageState(
                    horizontalPosition: 0.91,
                    verticalPosition: 0.09,
                    note: "Injected housekeeping note"
                ),
            ]
        ).browsingState,
        expectedDataGeneration: store.dataGeneration
    )

    #expect(committer.mutations.isEmpty)
    let browsed = try #require(store.patternUsages.first?.readingState)
    #expect(browsed.pageIndex == 2)
    #expect(browsed.zoomScale == 2.25)
    #expect(browsed.offsetX == 0.3)
    #expect(browsed.offsetY == 0.7)
    var expectedBrowsingState = stateBeforeBrowsing
    expectedBrowsingState.pageIndex = 2
    expectedBrowsingState.zoomScale = 2.25
    expectedBrowsingState.offsetX = 0.3
    expectedBrowsingState.offsetY = 0.7
    #expect(browsed == expectedBrowsingState)
    #expect(browsed.highlightEnabled)
    #expect(browsed.highlightMode == .cross)
    #expect(browsed.highlightPosition == 0.21)
    #expect(browsed.verticalHighlightPosition == 0.79)
    #expect(browsed.pageNote == "Stored page zero")
    #expect(browsed.pageStates == storedPageStates)
    #expect(store.patterns.first?.lastOpenedAt == lastOpenedBeforeBrowsing)

    let explicitState = PatternReadingState(
        pageIndex: 3,
        zoomScale: 1.4,
        offsetX: 0.2,
        offsetY: 0.6,
        highlightEnabled: false,
        highlightPosition: 0.83,
        highlightMode: .vertical,
        verticalHighlightPosition: 0.17,
        pageNote: "Explicit edit",
        pageStates: [
            3: PatternPageState(
                horizontalPosition: 0.83,
                verticalPosition: 0.17,
                note: "Explicit edit"
            ),
        ]
    )
    _ = try store.updatePatternState(
        usageID: usage.id,
        state: explicitState,
        expectedDataGeneration: store.dataGeneration
    )

    #expect(committer.mutations == [.editPatternReadingState])
    #expect(store.patternUsages.first?.readingState == explicitState)
}

@MainActor
@Test func legacyBrowsingChangesOnlyPassiveScalarsWithoutTouchingTimestamps() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LegacyPassiveBrowsing-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let initialLastOpenedAt = Date(timeIntervalSince1970: 41_000)
    let storedPageStates = [
        0: PatternPageState(
            horizontalPosition: 0.24,
            verticalPosition: 0.76,
            note: "Legacy page zero"
        ),
        2: PatternPageState(
            horizontalPosition: 0.43,
            verticalPosition: 0.67,
            note: "Legacy page two"
        ),
    ]
    var pattern = PatternDocument(
        displayName: "Legacy",
        kind: .pdf,
        storedFilename: "legacy.pdf"
    )
    pattern.lastOpenedAt = initialLastOpenedAt
    pattern.highlightEnabled = true
    pattern.highlightPosition = 0.24
    pattern.highlightMode = .cross
    pattern.verticalHighlightPosition = 0.76
    pattern.pageStates = storedPageStates
    var project = try StoredProject(
        name: "Legacy project",
        now: Date(timeIntervalSince1970: 40_000)
    )
    project.addPattern(pattern)

    let archive = root.appendingPathComponent("projects-v1.json")
    try JSONEncoder().encode(ProjectArchive(
        version: ProjectArchive.currentVersion,
        projects: [project]
    )).write(to: archive, options: .atomic)
    let committer = MutationCommitterProbe()
    let store = JSONProjectStore(
        url: archive,
        authorizeMutation: {
            FeatureAccessPolicy.decision(
                for: $0,
                snapshot: .trialNotStarted,
                now: Date(timeIntervalSince1970: 42_000)
            )
        },
        commitSuccessfulMutation: { committer.commit($0) }
    )

    let projectBeforeBrowsing = try #require(store.project(id: project.id))
    let patternBeforeBrowsing = try #require(
        projectBeforeBrowsing.patterns.first(where: { $0.id == pattern.id })
    )
    _ = try store.updatePatternBrowsingState(
        projectID: project.id,
        id: pattern.id,
        state: PatternBrowsingState(
            pageIndex: 2,
            zoomScale: 2.4,
            offsetX: 0.35,
            offsetY: 0.65
        ),
        expectedDataGeneration: store.dataGeneration
    )

    let projectAfterBrowsing = try #require(store.project(id: project.id))
    let patternAfterBrowsing = try #require(
        projectAfterBrowsing.patterns.first(where: { $0.id == pattern.id })
    )
    var expectedPattern = patternBeforeBrowsing
    expectedPattern.pageIndex = 2
    expectedPattern.zoomScale = 2.4
    expectedPattern.contentOffsetX = 0.35
    expectedPattern.contentOffsetY = 0.65

    #expect(committer.mutations.isEmpty)
    #expect(patternAfterBrowsing == expectedPattern)
    #expect(patternAfterBrowsing.lastOpenedAt == initialLastOpenedAt)
    #expect(projectAfterBrowsing.updatedAt == projectBeforeBrowsing.updatedAt)

    let explicitState = PatternReadingState(
        pageIndex: 3,
        zoomScale: 1.6,
        offsetX: 0.15,
        offsetY: 0.85,
        highlightEnabled: false,
        highlightPosition: 0.82,
        highlightMode: .vertical,
        verticalHighlightPosition: 0.18,
        pageNote: "Explicit legacy edit",
        pageStates: [
            3: PatternPageState(
                horizontalPosition: 0.82,
                verticalPosition: 0.18,
                note: "Explicit legacy edit"
            ),
        ]
    )
    _ = try store.updatePatternState(
        projectID: project.id,
        id: pattern.id,
        state: explicitState,
        expectedDataGeneration: store.dataGeneration
    )

    #expect(committer.mutations == [.editPatternReadingState])
    #expect(store.project(id: project.id)?.patterns.first?.readingState == explicitState)
}

@MainActor
@Test func restrictedCounterMutationsAreRejectedAtTheStoreBoundary() throws {
    let fixture = try RestrictedMutationFixture()
    defer { fixture.removeFiles() }
    let operations: [(JSONProjectStore) throws -> Void] = [
        {
            try $0.selectCounter(projectID: fixture.projectID, counterID: fixture.counterID)
        },
        {
            try $0.incrementCounter(projectID: fixture.projectID, counterID: fixture.counterID)
        },
        {
            try $0.decrementCounter(projectID: fixture.projectID, counterID: fixture.counterID)
        },
        {
            try $0.resetCounter(projectID: fixture.projectID, counterID: fixture.counterID)
        },
        {
            try $0.updateCounter(
                projectID: fixture.projectID,
                counterID: fixture.counterID,
                name: "Blocked",
                value: 9
            )
        },
        {
            try $0.renameCounter(
                projectID: fixture.projectID,
                counterID: fixture.counterID,
                name: "Blocked"
            )
        },
        {
            _ = try $0.mutatePatternReaderCounter(
                usageID: fixture.usageID,
                counterID: fixture.counterID,
                mutation: .increment,
                expectedDataGeneration: $0.dataGeneration
            )
        },
    ]

    for operation in operations {
        fixture.authorizer.reset()
        let projectsBefore = fixture.store.projects
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)

        #expect(throws: ProjectStoreError.accessRestricted) {
            try operation(fixture.store)
        }
        #expect(fixture.authorizer.mutations == [.changeCounter])
        #expect(fixture.store.projects == projectsBefore)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
    }
}

@MainActor
@Test func restrictedWatchCounterCommandDoesNotMutateTheLedgerOrProject() throws {
    let fixture = try RestrictedMutationFixture()
    defer { fixture.removeFiles() }
    var ledger = ProcessedWatchCommandLedger()
    let ledgerBefore = ledger
    let projectsBefore = fixture.store.projects
    let archiveBefore = try Data(contentsOf: fixture.archiveURL)
    let command = WatchCounterCommand(
        projectID: fixture.projectID,
        counterID: fixture.counterID,
        operation: .increment
    )

    #expect(throws: ProjectStoreError.accessRestricted) {
        _ = try fixture.store.applyWatchCommand(command, ledger: &ledger)
    }

    #expect(fixture.authorizer.mutations == [.changeCounter])
    #expect(ledger == ledgerBefore)
    #expect(fixture.store.projects == projectsBefore)
    #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
}

@MainActor
@Test func restoredDataStartsTrialBeforeItsFirstExistingDataMutation() throws {
    let fixture = try RestrictedMutationFixture(
        authorizerDecision: .startTrial,
        committerDecision: .requiresUnlock
    )
    defer { fixture.removeFiles() }
    let existingYarn = try #require(fixture.store.yarn(id: fixture.yarnID))
    let operations: [(FeatureMutation, (JSONProjectStore) throws -> Void)] = [
        (.editProject, {
            try $0.rename(id: fixture.projectID, to: "Must not persist")
        }),
        (.changeCounter, {
            try $0.incrementCounter(
                projectID: fixture.projectID,
                counterID: fixture.counterID
            )
        }),
        (.editNote, {
            try $0.saveNote(
                projectID: fixture.projectID,
                counterID: fixture.counterID,
                row: 4,
                text: "Must not persist"
            )
        }),
        (.editJournal, {
            try $0.updateJournalCaption(
                projectID: fixture.projectID,
                entryID: fixture.journalEntryID,
                caption: "Must not persist"
            )
        }),
        (.editYarn, {
            try $0.updateYarn(existingYarn)
        }),
        (.linkPattern, {
            try $0.unlinkPattern(
                patternID: fixture.patternID,
                from: fixture.projectID
            )
        }),
        (.editPatternReadingState, {
            _ = try $0.savePatternMarkup(
                PatternMarkupDocument(),
                usageID: fixture.usageID,
                pageIndex: 0,
                expectedDataGeneration: $0.dataGeneration
            )
        }),
    ]

    for (mutation, operation) in operations {
        fixture.authorizer.reset()
        fixture.committer.reset()
        let projectsBefore = fixture.store.projects
        let yarnsBefore = fixture.store.yarns
        let usagesBefore = fixture.store.patternUsages
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let filesBefore = try fixture.fileSnapshot()

        #expect(throws: ProjectStoreError.accessRestricted) {
            try operation(fixture.store)
        }
        #expect(fixture.authorizer.mutations == [mutation])
        #expect(fixture.committer.mutations == [mutation])
        #expect(fixture.store.projects == projectsBefore)
        #expect(fixture.store.yarns == yarnsBefore)
        #expect(fixture.store.patternUsages == usagesBefore)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        #expect(try fixture.fileSnapshot() == filesBefore)
    }
}

@MainActor
@Test func restrictedRowNoteMutationsLeaveMemoryAndArchiveUnchanged() throws {
    let fixture = try RestrictedMutationFixture()
    defer { fixture.removeFiles() }
    let operations: [(JSONProjectStore) throws -> Void] = [
        {
            try $0.saveNote(
                projectID: fixture.projectID,
                counterID: fixture.counterID,
                row: 4,
                text: "Blocked"
            )
        },
        {
            try $0.deleteNote(
                projectID: fixture.projectID,
                counterID: fixture.counterID,
                row: 4
            )
        },
    ]

    for operation in operations {
        fixture.authorizer.reset()
        let projectsBefore = fixture.store.projects
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)

        #expect(throws: ProjectStoreError.accessRestricted) {
            try operation(fixture.store)
        }
        #expect(fixture.authorizer.mutations == [.editNote])
        #expect(fixture.store.projects == projectsBefore)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
    }
}

@MainActor
@Test func restrictedJournalMutationsAreRejectedBeforePhotoOrArchiveWrites() async throws {
    let fixture = try RestrictedMutationFixture()
    defer { fixture.removeFiles() }
    let projectsBefore = fixture.store.projects
    let archiveBefore = try Data(contentsOf: fixture.archiveURL)

    await #expect(throws: ProjectStoreError.accessRestricted) {
        try await fixture.store.addJournalEntry(
            projectID: fixture.projectID,
            photoData: Data("not decoded because access is checked first".utf8),
            caption: "Blocked"
        )
    }
    #expect(fixture.authorizer.mutations == [.editJournal])
    #expect(!FileManager.default.fileExists(atPath: fixture.journalDirectory.path))
    #expect(fixture.store.projects == projectsBefore)
    #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)

    fixture.authorizer.reset()
    #expect(throws: ProjectStoreError.accessRestricted) {
        try fixture.store.updateJournalCaption(
            projectID: fixture.projectID,
            entryID: fixture.journalEntryID,
            caption: "Blocked"
        )
    }
    #expect(fixture.authorizer.mutations == [.editJournal])
    #expect(fixture.store.projects == projectsBefore)
    #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)

    fixture.authorizer.reset()
    #expect(throws: ProjectStoreError.accessRestricted) {
        try fixture.store.deleteJournalEntry(
            projectID: fixture.projectID,
            entryID: fixture.journalEntryID
        )
    }
    #expect(fixture.authorizer.mutations == [.editJournal])
    #expect(fixture.store.projects == projectsBefore)
    #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
}

@MainActor
@Test func restrictedPatternImportEntryPointsDoNotWriteFiles() async throws {
    let fixture = try RestrictedMutationFixture()
    defer { fixture.removeFiles() }
    let source = fixture.archiveURL
    let operations: [(JSONProjectStore) async throws -> Void] = [
        {
            try $0.addPattern(
                projectID: fixture.projectID,
                pattern: PatternDocument(
                    displayName: "Blocked",
                    kind: .pdf,
                    storedFilename: "blocked.pdf"
                )
            )
        },
        {
            _ = try await $0.importPattern(from: source, projectID: fixture.projectID)
        },
        {
            _ = try await $0.processPatternInboxItem(id: UUID(), selectingPatternID: nil)
        },
        {
            _ = try await $0.processPatternInboxItem(
                id: UUID(),
                duplicateResolution: .automatic
            )
        },
        {
            try await $0.discardPatternInboxItem(id: UUID())
        },
        {
            _ = try await $0.importPatternFromLibrary(source)
        },
        {
            _ = try await $0.importPatternFromProject(
                source,
                projectID: fixture.projectID
            )
        },
    ]

    for operation in operations {
        fixture.authorizer.reset()
        let projectsBefore = fixture.store.projects
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let filesBefore = try fixture.fileSnapshot()

        await #expect(throws: ProjectStoreError.accessRestricted) {
            try await operation(fixture.store)
        }
        #expect(fixture.authorizer.mutations == [.importPattern])
        #expect(fixture.store.projects == projectsBefore)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        #expect(try fixture.fileSnapshot() == filesBefore)
    }
}

@MainActor
@Test func patternInboxConvenienceOverloadUsesOneEntryAuthorizationBoundary() async throws {
    let fixture = try RestrictedMutationFixture(authorizerDecision: .allow)
    defer { fixture.removeFiles() }

    await #expect(throws: Error.self) {
        _ = try await fixture.store.processPatternInboxItem(
            id: UUID(),
            selectingPatternID: nil
        )
    }

    #expect(fixture.authorizer.mutations == [.importPattern])
    #expect(fixture.committer.mutations.isEmpty)
}

@MainActor
@Test func restrictedPatternDetailMutationsLeaveLibraryAndArchiveUnchanged() throws {
    let fixture = try RestrictedMutationFixture()
    defer { fixture.removeFiles() }
    let operations: [(FeatureMutation, (JSONProjectStore) throws -> Void)] = [
        (.editPattern, {
            try $0.deletePattern(projectID: fixture.projectID, id: UUID())
        }),
        (.editPattern, {
            try $0.deletePatternPermanently(id: fixture.patternID)
        }),
        (.editPattern, {
            try $0.renamePattern(id: fixture.patternID, to: "Blocked")
        }),
        (.editPattern, {
            try $0.setPatternNote(id: fixture.patternID, note: "Blocked")
        }),
        (.recordPatternBrowsing, {
            try $0.markPatternOpened(id: fixture.patternID)
        }),
    ]

    for (mutation, operation) in operations {
        fixture.authorizer.reset()
        let patternsBefore = fixture.store.patterns
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let filesBefore = try fixture.fileSnapshot()

        #expect(throws: ProjectStoreError.accessRestricted) {
            try operation(fixture.store)
        }
        #expect(fixture.authorizer.mutations == [mutation])
        #expect(fixture.store.patterns == patternsBefore)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        #expect(try fixture.fileSnapshot() == filesBefore)
    }
}

@MainActor
@Test func restrictedPatternLinkMutationsLeaveUsagesUnchanged() throws {
    let fixture = try RestrictedMutationFixture()
    defer { fixture.removeFiles() }
    let operations: [(JSONProjectStore) throws -> Void] = [
        {
            _ = try $0.linkPattern(patternID: fixture.patternID, to: fixture.projectID)
        },
        {
            try $0.unlinkPattern(patternID: fixture.patternID, from: fixture.projectID)
        },
    ]

    for operation in operations {
        fixture.authorizer.reset()
        let usagesBefore = fixture.store.patternUsages
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)

        #expect(throws: ProjectStoreError.accessRestricted) {
            try operation(fixture.store)
        }
        #expect(fixture.authorizer.mutations == [.linkPattern])
        #expect(fixture.store.patternUsages == usagesBefore)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
    }
}

@MainActor
@Test func restrictedPatternReaderMutationsDoNotChangeStateOrMarkupFiles() throws {
    let fixture = try RestrictedMutationFixture()
    defer { fixture.removeFiles() }
    let operations: [(JSONProjectStore) throws -> Void] = [
        {
            _ = try $0.updatePatternState(
                usageID: fixture.usageID,
                state: PatternReadingState(pageIndex: 2),
                expectedDataGeneration: $0.dataGeneration
            )
        },
        {
            _ = try $0.savePatternPageNote(
                usageID: fixture.usageID,
                pageIndex: 2,
                text: "Blocked",
                expectedDataGeneration: $0.dataGeneration
            )
        },
        {
            _ = try $0.savePatternMarkup(
                PatternMarkupDocument(),
                usageID: fixture.usageID,
                pageIndex: 2,
                expectedDataGeneration: $0.dataGeneration
            )
        },
        {
            _ = try $0.savePatternPageNote(
                projectID: fixture.projectID,
                patternID: UUID(),
                pageIndex: 2,
                text: "Blocked",
                expectedDataGeneration: $0.dataGeneration
            )
        },
        {
            try $0.updatePatternState(
                projectID: fixture.projectID,
                id: UUID(),
                pageIndex: 2,
                highlightPosition: 0.7
            )
        },
        {
            _ = try $0.updatePatternState(
                projectID: fixture.projectID,
                id: UUID(),
                state: PatternReadingState(pageIndex: 2),
                expectedDataGeneration: $0.dataGeneration
            )
        },
        {
            _ = try $0.savePatternMarkup(
                PatternMarkupDocument(),
                projectID: fixture.projectID,
                patternID: UUID(),
                pageIndex: 2,
                expectedDataGeneration: $0.dataGeneration
            )
        },
    ]

    for operation in operations {
        fixture.authorizer.reset()
        let projectsBefore = fixture.store.projects
        let usagesBefore = fixture.store.patternUsages
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let filesBefore = try fixture.fileSnapshot()

        #expect(throws: ProjectStoreError.accessRestricted) {
            try operation(fixture.store)
        }
        #expect(fixture.authorizer.mutations == [.editPatternReadingState])
        #expect(fixture.store.projects == projectsBefore)
        #expect(fixture.store.patternUsages == usagesBefore)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        #expect(try fixture.fileSnapshot() == filesBefore)
    }
}

@MainActor
@Test func restrictedEntitlementStillAllowsPatternReads() async throws {
    let fixture = try RestrictedMutationFixture()
    defer { fixture.removeFiles() }

    #expect(fixture.store.project(id: fixture.projectID)?.id == fixture.projectID)
    #expect(try fixture.store.patternAssetURL(patternID: fixture.patternID).lastPathComponent == "\(fixture.assetID.uuidString).pdf")
    #expect(try fixture.store.loadPatternMarkup(usageID: fixture.usageID, pageIndex: 0) == PatternMarkupDocument())
    #expect(try await fixture.store.pendingPatternInboxItems().isEmpty)
    #expect(await fixture.store.patternThumbnailURL(patternID: fixture.patternID) != nil)
    #expect(fixture.authorizer.mutations.isEmpty)
}

@MainActor
@Test func restrictedProjectMutationsLeaveProjectAndFilesUnchanged() throws {
    let fixture = try RestrictedMutationFixture()
    defer { fixture.removeFiles() }
    let operations: [(FeatureMutation, (JSONProjectStore) throws -> Void)] = [
        (.editProject, {
            try $0.rename(id: fixture.projectID, to: "Blocked")
        }),
        (.editProject, {
            try $0.updateProject(
                id: fixture.projectID,
                name: "Blocked",
                toolType: .knittingNeedles,
                toolSize: "4 mm",
                toolNotes: nil,
                photoChange: .replace(Data("not decoded because access is checked first".utf8))
            )
        }),
        (.deleteProject, {
            try $0.delete(id: fixture.projectID)
        }),
        (.completeProject, {
            try $0.markCompleted(projectID: fixture.projectID)
        }),
        (.resumeProject, {
            try $0.resumeProject(projectID: fixture.projectID)
        }),
    ]

    for (mutation, operation) in operations {
        fixture.authorizer.reset()
        let projectsBefore = fixture.store.projects
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let filesBefore = try fixture.fileSnapshot()

        #expect(throws: ProjectStoreError.accessRestricted) {
            try operation(fixture.store)
        }
        #expect(fixture.authorizer.mutations == [mutation])
        #expect(fixture.store.projects == projectsBefore)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        #expect(try fixture.fileSnapshot() == filesBefore)
    }
}

@MainActor
@Test func restrictedYarnEntryPointsLeaveYarnsAndPhotosUnchanged() throws {
    let fixture = try RestrictedMutationFixture()
    defer { fixture.removeFiles() }
    let existingYarn = try #require(fixture.store.yarn(id: fixture.yarnID))
    let operations: [(FeatureMutation, (JSONProjectStore) throws -> Void)] = [
        (.createYarn, {
            try $0.addYarn(
                StoredYarn(name: "Blocked create"),
                photoData: Data("not decoded because access is checked first".utf8)
            )
        }),
        (.editYarn, {
            try $0.updateYarn(existingYarn)
        }),
        (.editYarn, {
            try $0.updateYarn(
                existingYarn,
                photoChange: .replace(Data("not decoded because access is checked first".utf8))
            )
        }),
        (.deleteYarn, {
            try $0.deleteYarn(id: fixture.yarnID)
        }),
        (.linkYarn, {
            try $0.setYarnProjects(
                yarnID: fixture.yarnID,
                projectIDs: [fixture.projectID]
            )
        }),
    ]

    for (mutation, operation) in operations {
        fixture.authorizer.reset()
        let yarnsBefore = fixture.store.yarns
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let filesBefore = try fixture.fileSnapshot()

        #expect(throws: ProjectStoreError.accessRestricted) {
            try operation(fixture.store)
        }
        #expect(fixture.authorizer.mutations == [mutation])
        #expect(fixture.store.yarns == yarnsBefore)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        #expect(try fixture.fileSnapshot() == filesBefore)
    }
}

@MainActor
@Test func restrictedBackupRestoreIsRejectedBeforeStartingTheDataOperation() async throws {
    let fixture = try RestrictedMutationFixture()
    defer { fixture.removeFiles() }
    let stagedRoot = fixture.root.appendingPathComponent("BlockedRestore", isDirectory: true)
    let backup = StagedKnitNoteBackup(
        root: stagedRoot,
        preview: KnitNoteBackupPreview(
            createdAt: .now,
            projectCount: 0,
            yarnCount: 0
        )
    )
    let projectsBefore = fixture.store.projects
    let yarnsBefore = fixture.store.yarns
    let archiveBefore = try Data(contentsOf: fixture.archiveURL)
    let filesBefore = try fixture.fileSnapshot()

    await #expect(throws: ProjectStoreError.accessRestricted) {
        try await fixture.store.restoreBackup(backup)
    }

    #expect(fixture.authorizer.mutations == [.restoreBackup])
    #expect(!fixture.store.isDataOperationInProgress)
    #expect(fixture.store.projects == projectsBefore)
    #expect(fixture.store.yarns == yarnsBefore)
    #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
    #expect(try fixture.fileSnapshot() == filesBefore)
}

@MainActor
@Test func restrictedEntitlementStillAllowsReadsAndBackupExport() async throws {
    let fixture = try RestrictedMutationFixture()
    defer { fixture.removeFiles() }

    #expect(fixture.store.project(id: fixture.projectID)?.name == "Restricted")
    #expect(fixture.store.yarn(id: fixture.yarnID)?.name == "Restricted yarn")
    let exportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestrictedExport-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: exportRoot) }
    try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
    let exportArchive = exportRoot.appendingPathComponent("projects-v1.json")
    try JSONEncoder().encode(
        ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
    ).write(to: exportArchive, options: .atomic)
    let exportStore = JSONProjectStore(
        url: exportArchive,
        authorizeMutation: { _ in .requiresUnlock }
    )
    let backupURL = try await exportStore.exportBackup(appVersion: "Tests")
    defer { exportStore.cleanupBackupArtifact(at: backupURL) }

    #expect(FileManager.default.fileExists(atPath: backupURL.path))
    #expect(fixture.authorizer.mutations.isEmpty)
}

@MainActor
private final class MutationAuthorizerProbe {
    var decision: FeatureAccessDecision = .requiresUnlock
    private(set) var mutations: [FeatureMutation] = []

    func authorize(_ mutation: FeatureMutation) -> FeatureAccessDecision {
        mutations.append(mutation)
        return decision
    }

    func reset() {
        mutations.removeAll()
    }
}

@MainActor
private final class MutationCommitterProbe {
    var decision: FeatureAccessDecision = .allow
    private(set) var mutations: [FeatureMutation] = []

    func commit(_ mutation: FeatureMutation) -> FeatureAccessDecision {
        mutations.append(mutation)
        return decision
    }

    func reset() {
        mutations.removeAll()
    }
}

private final class MutationBoundaryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) {
        value = now
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func setNow(_ date: Date) {
        lock.lock()
        value = date
        lock.unlock()
    }
}

private func journalBoundaryJPEG() throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: 32,
        height: 24,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )
    )
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@MainActor
private final class RestrictedMutationFixture {
    let root: URL
    let archiveURL: URL
    let journalDirectory: URL
    let projectID: UUID
    let counterID: UUID
    let usageID: UUID
    let assetID: UUID
    let patternID: UUID
    let yarnID: UUID
    let journalEntryID: UUID
    let authorizer: MutationAuthorizerProbe
    let committer: MutationCommitterProbe
    let store: JSONProjectStore

    init(
        authorizerDecision: FeatureAccessDecision = .requiresUnlock,
        committerDecision: FeatureAccessDecision = .allow
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestrictedMutation-\(UUID().uuidString)", isDirectory: true)
        archiveURL = root.appendingPathComponent("projects-v1.json")
        journalDirectory = root.appendingPathComponent("JournalPhotos", isDirectory: true)
        projectID = UUID()
        journalEntryID = UUID()
        let journalToken = UUID()
        let journalEntry = try ProjectJournalEntry(
            id: journalEntryID,
            photoFilename: "\(projectID.uuidString)-\(journalEntryID.uuidString)-\(journalToken.uuidString)-full.jpg",
            thumbnailFilename: "\(projectID.uuidString)-\(journalEntryID.uuidString)-\(journalToken.uuidString)-thumb.jpg",
            caption: "Existing"
        )
        let project = try StoredProject(
            id: projectID,
            name: "Restricted",
            journalEntries: [journalEntry]
        )
        counterID = project.selectedCounterID
        assetID = UUID()
        let patternsRoot = root.appendingPathComponent("Patterns", isDirectory: true)
        let assetURL = patternsRoot
            .appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent("\(assetID.uuidString).pdf")
        try FileManager.default.createDirectory(
            at: assetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeTestPatternPDF(at: assetURL)
        let metadata = try PatternFileService(root: patternsRoot).inspect(assetURL)
        let asset = PatternAsset(
            id: assetID,
            sha256: metadata.sha256,
            kind: metadata.kind,
            storedFilename: assetURL.lastPathComponent,
            byteCount: metadata.byteCount,
            pageCount: metadata.pageCount
        )
        let pattern = StoredPattern(assetID: asset.id, displayName: "Restricted")
        patternID = pattern.id
        let usage = PatternProjectUsage(
            patternID: pattern.id,
            projectID: projectID,
            sortOrder: 0
        )
        usageID = usage.id
        let yarn = try StoredYarn(name: "Restricted yarn")
        yarnID = yarn.id
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(
            ProjectArchive(
                version: ProjectArchive.currentVersion,
                projects: [project],
                yarns: [yarn],
                patternAssets: [asset],
                patterns: [pattern],
                patternUsages: [usage]
            )
        ).write(to: archiveURL, options: .atomic)
        let authorizer = MutationAuthorizerProbe()
        authorizer.decision = authorizerDecision
        self.authorizer = authorizer
        let committer = MutationCommitterProbe()
        committer.decision = committerDecision
        self.committer = committer
        store = JSONProjectStore(
            url: archiveURL,
            journalPhotoService: ProjectJournalPhotoFileService(directory: journalDirectory),
            authorizeMutation: { authorizer.authorize($0) },
            commitSuccessfulMutation: { committer.commit($0) }
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }

    func fileSnapshot() throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return [:]
        }
        var result: [String: Data] = [:]
        for case let fileURL as URL in enumerator {
            guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let relativePath = fileURL.path.replacingOccurrences(
                of: root.path + "/",
                with: ""
            )
            result[relativePath] = try Data(contentsOf: fileURL)
        }
        return result
    }
}
