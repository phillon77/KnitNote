import Foundation
import Testing
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
@Test func successfulProjectCreationAndImportCommitTrialStart() async throws {
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

    #expect(committer.mutations == [.createProject, .importPattern])
}

@MainActor
@Test func failedTrialCommitDoesNotRollBackAnAlreadyPublishedImport() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PublishedImportCommitFailure-\(UUID().uuidString)", isDirectory: true)
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
    committer.decision = .requiresUnlock

    await #expect(throws: ProjectStoreError.accessRestricted) {
        _ = try await store.importPattern(from: source, projectID: projectID)
    }

    let pattern = try #require(store.project(id: projectID)?.patterns.first)
    #expect(FileManager.default.fileExists(
        atPath: store.patternURL(projectID: projectID, pattern: pattern).path
    ))
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
@Test func restrictedPatternDetailMutationsLeaveLibraryAndArchiveUnchanged() throws {
    let fixture = try RestrictedMutationFixture()
    defer { fixture.removeFiles() }
    let operations: [(JSONProjectStore) throws -> Void] = [
        {
            try $0.deletePattern(projectID: fixture.projectID, id: UUID())
        },
        {
            try $0.deletePatternPermanently(id: fixture.patternID)
        },
        {
            try $0.renamePattern(id: fixture.patternID, to: "Blocked")
        },
        {
            try $0.setPatternNote(id: fixture.patternID, note: "Blocked")
        },
        {
            try $0.markPatternOpened(id: fixture.patternID)
        },
    ]

    for operation in operations {
        fixture.authorizer.reset()
        let patternsBefore = fixture.store.patterns
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let filesBefore = try fixture.fileSnapshot()

        #expect(throws: ProjectStoreError.accessRestricted) {
            try operation(fixture.store)
        }
        #expect(fixture.authorizer.mutations == [.editPattern])
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
