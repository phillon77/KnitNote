import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite(.serialized) @MainActor struct ProjectJournalStoreTests {
    @Test func journalRoundTripsAndCompletionLocksEveryMutation() async throws {
        let fixture = try StoreFixture()
        try fixture.store.add(name: "Sweater")
        let projectID = try #require(fixture.store.projects.first?.id)

        try await fixture.store.addJournalEntry(
            projectID: projectID,
            photoData: try journalFixtureJPEG(),
            caption: "  body  ",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let entry = try #require(fixture.store.project(id: projectID)?.journalEntries.first)
        #expect(entry.caption == "body")
        #expect(fixture.store.journalPhotoURL(for: entry) == fixture.journalService.url(filename: entry.photoFilename))
        #expect(fixture.store.journalThumbnailURL(for: entry) == fixture.journalService.url(filename: entry.thumbnailFilename))

        try fixture.store.markCompleted(projectID: projectID)
        await #expect(throws: ProjectJournalMutationError.projectCompleted) {
            try await fixture.store.addJournalEntry(
                projectID: projectID,
                photoData: try journalFixtureJPEG(),
                caption: nil,
                createdAt: .now
            )
        }
        #expect(throws: ProjectJournalMutationError.projectCompleted) {
            try fixture.store.updateJournalCaption(projectID: projectID, entryID: entry.id, caption: "Done")
        }
        #expect(throws: ProjectJournalMutationError.projectCompleted) {
            try fixture.store.deleteJournalEntry(projectID: projectID, entryID: entry.id)
        }

        try fixture.store.resumeProject(projectID: projectID)
        try fixture.store.updateJournalCaption(projectID: projectID, entryID: entry.id, caption: "  Done  ")
        #expect(fixture.store.project(id: projectID)?.journalEntries.first?.caption == "Done")

        let reloaded = JSONProjectStore(
            url: fixture.archiveURL,
            journalPhotoService: fixture.journalService
        )
        #expect(reloaded.project(id: projectID)?.journalEntries.first?.caption == "Done")
        let reloadedEntry = try #require(reloaded.project(id: projectID)?.journalEntries.first)
        try reloaded.deleteJournalEntry(projectID: projectID, entryID: reloadedEntry.id)
        #expect(reloaded.project(id: projectID)?.journalEntries.isEmpty == true)
        #expect(!fixture.fileExists(reloadedEntry.photoFilename))
        #expect(!fixture.fileExists(reloadedEntry.thumbnailFilename))
        #expect(JSONProjectStore(url: fixture.archiveURL).project(id: projectID)?.journalEntries.isEmpty == true)
    }

    @Test func missingProjectsRejectEveryMutationBeforeCreatingFiles() async throws {
        let fixture = try StoreFixture()
        let missingProjectID = UUID()

        await #expect(throws: ProjectJournalMutationError.entryNotFound) {
            try await fixture.store.addJournalEntry(
                projectID: missingProjectID,
                photoData: try journalFixtureJPEG(),
                caption: nil
            )
        }
        #expect(throws: ProjectJournalMutationError.entryNotFound) {
            try fixture.store.updateJournalCaption(projectID: missingProjectID, entryID: UUID(), caption: nil)
        }
        #expect(throws: ProjectJournalMutationError.entryNotFound) {
            try fixture.store.deleteJournalEntry(projectID: missingProjectID, entryID: UUID())
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.journalDirectory.path))
    }

    @Test func addRollsBackCandidateFilesWhenArchivePersistenceFails() async throws {
        let fixture = try StoreFixture()
        try fixture.store.add(name: "Sweater")
        let projectID = try #require(fixture.store.projects.first?.id)
        try FileManager.default.removeItem(at: fixture.archiveURL)
        try FileManager.default.createDirectory(at: fixture.archiveURL, withIntermediateDirectories: false)

        await #expect(throws: ProjectStoreError.persistenceFailed) {
            try await fixture.store.addJournalEntry(
                projectID: projectID,
                photoData: try journalFixtureJPEG(),
                caption: "candidate"
            )
        }

        #expect(fixture.store.project(id: projectID)?.journalEntries.isEmpty == true)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.journalDirectory.path))?.isEmpty != false)
    }

    @Test func addRechecksCompletionAfterDetachedImageProcessingAndRollsBack() async throws {
        let blocker = BlockingFullImageWrites()
        let fixture = try StoreFixture(writeData: blocker.write)
        try fixture.store.add(name: "Sweater")
        let projectID = try #require(fixture.store.projects.first?.id)

        let addition = Task { @MainActor in
            try await fixture.store.addJournalEntry(
                projectID: projectID,
                photoData: try journalFixtureJPEG(),
                caption: nil
            )
        }
        let reachedWriter = await Task.detached { blocker.waitUntilBlocked() }.value
        #expect(reachedWriter)
        try fixture.store.markCompleted(projectID: projectID)
        blocker.resume()

        await #expect(throws: ProjectJournalMutationError.projectCompleted) {
            try await addition.value
        }
        #expect(fixture.store.project(id: projectID)?.journalEntries.isEmpty == true)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.journalDirectory.path))?.isEmpty != false)
    }

    @Test func addRechecksProjectExistenceAfterDetachedImageProcessingAndRollsBack() async throws {
        let blocker = BlockingFullImageWrites()
        let fixture = try StoreFixture(writeData: blocker.write)
        try fixture.store.add(name: "Sweater")
        let projectID = try #require(fixture.store.projects.first?.id)

        let addition = Task { @MainActor in
            try await fixture.store.addJournalEntry(
                projectID: projectID,
                photoData: try journalFixtureJPEG(),
                caption: nil
            )
        }
        let reachedWriter = await Task.detached { blocker.waitUntilBlocked() }.value
        #expect(reachedWriter)
        try fixture.store.delete(id: projectID)
        blocker.resume()

        await #expect(throws: ProjectJournalMutationError.entryNotFound) {
            try await addition.value
        }
        #expect(fixture.store.project(id: projectID) == nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.journalDirectory.path))?.isEmpty != false)
    }

    @Test func persistDuringPostWriteImageProcessingDoesNotDeleteTheCandidate() async throws {
        let blocker = BlockingFullImageWrites()
        let fixture = try StoreFixture(writeData: blocker.write)
        try fixture.store.add(name: "Sweater")
        let projectID = try #require(fixture.store.projects.first?.id)

        let addition = Task { @MainActor in
            try await fixture.store.addJournalEntry(
                projectID: projectID,
                photoData: try journalFixtureJPEG(),
                caption: "progress"
            )
        }
        let reachedWriter = await Task.detached { blocker.waitUntilBlocked() }.value
        let candidateFilename = try FileManager.default.contentsOfDirectory(atPath: fixture.journalDirectory.path)
            .first(where: ProjectJournalPhotoFilename.isFullImage)

        try fixture.store.rename(id: projectID, to: "Renamed while saving")
        let candidateSurvivedPersist = candidateFilename.map(fixture.fileExists) ?? false
        blocker.resume()
        try await addition.value

        #expect(reachedWriter)
        #expect(candidateFilename != nil)
        #expect(candidateSurvivedPersist)
        let entry = try #require(fixture.store.project(id: projectID)?.journalEntries.first)
        #expect(fixture.fileExists(entry.photoFilename))
        #expect(fixture.fileExists(entry.thumbnailFilename))
    }

    @Test func twoConcurrentAddsProtectEveryCandidateUntilBothTransactionsFinish() async throws {
        let blocker = BlockingFullImageWrites()
        let fixture = try StoreFixture(writeData: blocker.write)
        try fixture.store.add(name: "Sweater")
        let projectID = try #require(fixture.store.projects.first?.id)

        let first = Task { @MainActor in
            try await fixture.store.addJournalEntry(
                projectID: projectID,
                photoData: try journalFixtureJPEG(red: 0.2),
                caption: "first"
            )
        }
        let second = Task { @MainActor in
            try await fixture.store.addJournalEntry(
                projectID: projectID,
                photoData: try journalFixtureJPEG(red: 0.8),
                caption: "second"
            )
        }
        let bothReachedWriter = await Task.detached { blocker.waitUntilBlocked(count: 2) }.value
        let fullCandidates = try FileManager.default.contentsOfDirectory(atPath: fixture.journalDirectory.path)
            .filter(ProjectJournalPhotoFilename.isFullImage)

        try fixture.store.rename(id: projectID, to: "Renamed during two saves")
        let candidatesSurvivedPersist = fullCandidates.allSatisfy(fixture.fileExists)
        blocker.resume(count: 2)
        try await first.value
        try await second.value

        #expect(bothReachedWriter)
        #expect(fullCandidates.count == 2)
        #expect(candidatesSurvivedPersist)
        let entries = try #require(fixture.store.project(id: projectID)?.journalEntries)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy {
            fixture.fileExists($0.photoFilename) && fixture.fileExists($0.thumbnailFilename)
        })
    }

    @Test func parentCancellationStopsTheDetachedPipelineAndImmediatelyReconcilesAtTransactionZero() async throws {
        let blocker = BlockingFullImageWrites()
        let fixture = try StoreFixture(writeData: blocker.write)
        try fixture.store.add(name: "Sweater")
        let projectID = try #require(fixture.store.projects.first?.id)

        let cancelledAddition = Task { @MainActor in
            try await fixture.store.addJournalEntry(
                projectID: projectID,
                photoData: try journalFixtureJPEG(),
                caption: nil
            )
        }
        let reachedWriter = await Task.detached { blocker.waitUntilBlocked() }.value
        let orphan = try fixture.writeOrphanFiles()
        cancelledAddition.cancel()
        blocker.resume()
        await #expect(throws: CancellationError.self) {
            try await cancelledAddition.value
        }
        #expect(reachedWriter)
        #expect(blocker.writeCount == 1)
        #expect(fixture.store.project(id: projectID)?.journalEntries.isEmpty == true)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.journalDirectory.path))?.isEmpty != false)
        #expect(!fixture.fileExists(orphan.photoFilename))
        #expect(!fixture.fileExists(orphan.thumbnailFilename))
    }

    @Test func failedAddDoesNotLeaveReconciliationSuppressed() async throws {
        let fixture = try StoreFixture()
        try fixture.store.add(name: "Sweater")
        let projectID = try #require(fixture.store.projects.first?.id)

        await #expect(throws: ProjectJournalPhotoFileError.invalidImage) {
            try await fixture.store.addJournalEntry(
                projectID: projectID,
                photoData: Data("not an image".utf8),
                caption: nil
            )
        }

        let orphan = try fixture.writeOrphanFiles()
        try fixture.store.rename(id: projectID, to: "Reconcile after failure")

        #expect(!fixture.fileExists(orphan.photoFilename))
        #expect(!fixture.fileExists(orphan.thumbnailFilename))
    }

    @Test func deletePublishesAndPersistsMetadataBeforeBestEffortFileCleanup() async throws {
        let fixture = try StoreFixture()
        try fixture.store.add(name: "Sweater")
        let projectID = try #require(fixture.store.projects.first?.id)
        try await fixture.store.addJournalEntry(
            projectID: projectID,
            photoData: try journalFixtureJPEG(),
            caption: nil
        )
        let entry = try #require(fixture.store.project(id: projectID)?.journalEntries.first)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.journalDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.journalDirectory.path
            )
        }

        try fixture.store.deleteJournalEntry(projectID: projectID, entryID: entry.id)

        #expect(fixture.store.project(id: projectID)?.journalEntries.isEmpty == true)
        #expect(fixture.fileExists(entry.photoFilename))
        #expect(fixture.fileExists(entry.thumbnailFilename))
        let reloaded = JSONProjectStore(
            url: fixture.archiveURL,
            journalPhotoService: fixture.journalService
        )
        #expect(reloaded.project(id: projectID)?.journalEntries.isEmpty == true)
    }

    @Test func failedDeletePersistencePreservesMetadataAndFiles() async throws {
        let fixture = try StoreFixture()
        try fixture.store.add(name: "Sweater")
        let projectID = try #require(fixture.store.projects.first?.id)
        try await fixture.store.addJournalEntry(
            projectID: projectID,
            photoData: try journalFixtureJPEG(),
            caption: nil
        )
        let entry = try #require(fixture.store.project(id: projectID)?.journalEntries.first)
        try FileManager.default.removeItem(at: fixture.archiveURL)
        try FileManager.default.createDirectory(at: fixture.archiveURL, withIntermediateDirectories: false)

        #expect(throws: ProjectStoreError.persistenceFailed) {
            try fixture.store.deleteJournalEntry(projectID: projectID, entryID: entry.id)
        }

        #expect(fixture.store.project(id: projectID)?.journalEntries.map(\.id) == [entry.id])
        #expect(fixture.fileExists(entry.photoFilename))
        #expect(fixture.fileExists(entry.thumbnailFilename))
    }

    @Test func deletingAProjectCleansOnlyItsJournalFilesAfterPersistence() async throws {
        let fixture = try StoreFixture()
        try fixture.store.add(name: "Sweater")
        try fixture.store.add(name: "Hat")
        let deletedID = try #require(fixture.store.projects.first(where: { $0.name == "Sweater" })?.id)
        let retainedID = try #require(fixture.store.projects.first(where: { $0.name == "Hat" })?.id)
        try await fixture.store.addJournalEntry(
            projectID: deletedID,
            photoData: try journalFixtureJPEG(red: 0.2),
            caption: nil
        )
        try await fixture.store.addJournalEntry(
            projectID: retainedID,
            photoData: try journalFixtureJPEG(red: 0.8),
            caption: nil
        )
        let deletedEntry = try #require(fixture.store.project(id: deletedID)?.journalEntries.first)
        let retainedEntry = try #require(fixture.store.project(id: retainedID)?.journalEntries.first)

        try fixture.store.delete(id: deletedID)

        #expect(fixture.store.project(id: deletedID) == nil)
        #expect(!fixture.fileExists(deletedEntry.photoFilename))
        #expect(!fixture.fileExists(deletedEntry.thumbnailFilename))
        #expect(fixture.fileExists(retainedEntry.photoFilename))
        #expect(fixture.fileExists(retainedEntry.thumbnailFilename))
    }

    @Test func failedProjectDeletionPreservesJournalMetadataAndFiles() async throws {
        let fixture = try StoreFixture()
        try fixture.store.add(name: "Sweater")
        let projectID = try #require(fixture.store.projects.first?.id)
        try await fixture.store.addJournalEntry(
            projectID: projectID,
            photoData: try journalFixtureJPEG(),
            caption: nil
        )
        let entry = try #require(fixture.store.project(id: projectID)?.journalEntries.first)
        try FileManager.default.removeItem(at: fixture.archiveURL)
        try FileManager.default.createDirectory(at: fixture.archiveURL, withIntermediateDirectories: false)

        #expect(throws: ProjectStoreError.persistenceFailed) {
            try fixture.store.delete(id: projectID)
        }

        #expect(fixture.store.project(id: projectID)?.journalEntries.map(\.id) == [entry.id])
        #expect(fixture.fileExists(entry.photoFilename))
        #expect(fixture.fileExists(entry.thumbnailFilename))
    }

    @Test func trustedLoadReconcilesOrphansWhilePreservingReferencedAndUnrelatedFiles() async throws {
        let fixture = try StoreFixture()
        try fixture.store.add(name: "Sweater")
        let projectID = try #require(fixture.store.projects.first?.id)
        try await fixture.store.addJournalEntry(
            projectID: projectID,
            photoData: try journalFixtureJPEG(),
            caption: nil
        )
        let referenced = try #require(fixture.store.project(id: projectID)?.journalEntries.first)
        let orphan = try fixture.journalService.save(
            data: try journalFixtureJPEG(red: 0.1),
            projectID: UUID(),
            entryID: UUID()
        )
        let unrelated = fixture.journalDirectory.appendingPathComponent("keep-me.txt")
        try Data("other owner".utf8).write(to: unrelated)

        _ = JSONProjectStore(
            url: fixture.archiveURL,
            journalPhotoService: fixture.journalService
        )

        #expect(fixture.fileExists(referenced.photoFilename))
        #expect(fixture.fileExists(referenced.thumbnailFilename))
        #expect(!fixture.fileExists(orphan.photoFilename))
        #expect(!fixture.fileExists(orphan.thumbnailFilename))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func malformedArchiveRejectsCrossProjectFilenameAliasesWithoutReconcilingFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let archiveURL = base.appendingPathComponent("projects.json")
        let journalService = ProjectJournalPhotoFileService(
            directory: base.appendingPathComponent("journal", isDirectory: true)
        )
        let filenameOwnerID = UUID()
        let metadataOwner = try StoredProject(id: UUID(), name: "Aliased metadata")
        let entryID = UUID()
        let files = try journalService.save(
            data: try journalFixtureJPEG(),
            projectID: filenameOwnerID,
            entryID: entryID
        )
        var malformedProject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(metadataOwner)) as? [String: Any]
        )
        malformedProject["journalEntries"] = [[
            "id": entryID.uuidString,
            "photoFilename": files.photoFilename,
            "thumbnailFilename": files.thumbnailFilename,
            "createdAt": Date.now.timeIntervalSinceReferenceDate,
        ]]
        let malformedArchive = try JSONSerialization.data(withJSONObject: [
            "version": 9,
            "projects": [malformedProject],
            "yarns": [],
        ])
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try malformedArchive.write(to: archiveURL, options: .atomic)

        let store = JSONProjectStore(url: archiveURL, journalPhotoService: journalService)

        #expect(store.loadError == .unreadableArchive)
        #expect(store.projects.isEmpty)
        #expect(FileManager.default.fileExists(atPath: try #require(journalService.url(filename: files.photoFilename)).path))
        #expect(FileManager.default.fileExists(atPath: try #require(journalService.url(filename: files.thumbnailFilename)).path))
    }

    @Test func deletionPolicyNeverDeletesFilesStillReferencedByAnyRemainingProject() throws {
        let projectID = UUID()
        let entryID = UUID()
        let retainedStem = "\(projectID.uuidString)-\(entryID.uuidString)-\(UUID().uuidString)"
        let retainedFiles = ProjectJournalPhotoFiles(
            photoFilename: "\(retainedStem)-full.jpg",
            thumbnailFilename: "\(retainedStem)-thumb.jpg"
        )
        let retainedEntry = try ProjectJournalEntry(
            id: entryID,
            photoFilename: retainedFiles.photoFilename,
            thumbnailFilename: retainedFiles.thumbnailFilename,
            caption: nil
        )
        let retainedProject = try StoredProject(
            id: projectID,
            name: "Remaining project",
            journalEntries: [retainedEntry]
        )
        let orphanStem = "\(UUID().uuidString)-\(UUID().uuidString)-\(UUID().uuidString)"
        let orphanFiles = ProjectJournalPhotoFiles(
            photoFilename: "\(orphanStem)-full.jpg",
            thumbnailFilename: "\(orphanStem)-thumb.jpg"
        )

        let deletable = ProjectJournalPhotoReferencePolicy.unreferencedFilenames(
            requestedFilenames: [
                retainedFiles.photoFilename,
                retainedFiles.thumbnailFilename,
                orphanFiles.photoFilename,
                orphanFiles.thumbnailFilename,
            ],
            remainingProjects: [retainedProject]
        )

        #expect(deletable == [orphanFiles.photoFilename, orphanFiles.thumbnailFilename])
    }

    @Test func missingAndUnreadableArchivesDoNotReconcileUntilATrustedPersist() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = base.appendingPathComponent("projects.json")
        let journalService = ProjectJournalPhotoFileService(directory: base.appendingPathComponent("journal", isDirectory: true))
        let orphan = try journalService.save(
            data: try journalFixtureJPEG(),
            projectID: UUID(),
            entryID: UUID()
        )

        let emptyStore = JSONProjectStore(url: archiveURL, journalPhotoService: journalService)
        #expect(FileManager.default.fileExists(atPath: try #require(journalService.url(filename: orphan.photoFilename)).path))
        try emptyStore.add(name: "First trusted write")
        #expect(!FileManager.default.fileExists(atPath: try #require(journalService.url(filename: orphan.photoFilename)).path))

        let unreadableCandidate = try journalService.save(
            data: try journalFixtureJPEG(),
            projectID: UUID(),
            entryID: UUID()
        )
        try Data("not JSON".utf8).write(to: archiveURL, options: .atomic)
        let unreadableStore = JSONProjectStore(url: archiveURL, journalPhotoService: journalService)

        #expect(unreadableStore.loadError == .unreadableArchive)
        #expect(FileManager.default.fileExists(atPath: try #require(journalService.url(filename: unreadableCandidate.photoFilename)).path))
        #expect(throws: ProjectStoreError.archiveUnavailable) {
            try unreadableStore.add(name: "Must not reconcile")
        }
        #expect(FileManager.default.fileExists(atPath: try #require(journalService.url(filename: unreadableCandidate.photoFilename)).path))
    }

    @Test func version8ArchiveMigratesToVersion9WithoutLosingExistingProjectOrYarnData() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = base.appendingPathComponent("projects.json")
        let start = Date(timeIntervalSince1970: 100)
        var legacyProject = try StoredProject(name: "Legacy", now: start)
        let selectedCounterID = legacyProject.counters[2].id
        legacyProject.selectCounter(id: selectedCounterID, now: Date(timeIntervalSince1970: 110))
        legacyProject.updateCounter(
            id: selectedCounterID,
            name: "Sleeve",
            value: 42,
            now: Date(timeIntervalSince1970: 120)
        )
        try legacyProject.saveNote(
            counterID: selectedCounterID,
            row: 42,
            text: "Decrease",
            now: Date(timeIntervalSince1970: 130)
        )
        let pattern = PatternDocument(
            displayName: "Cable chart",
            kind: .pdf,
            storedFilename: "cable-chart.pdf",
            createdAt: start
        )
        legacyProject.addPattern(pattern)
        legacyProject.setPhotoFilename("legacy-cover.jpg", now: Date(timeIntervalSince1970: 140))
        legacyProject.updateToolDetails(
            type: .knittingNeedles,
            size: "4 mm",
            notes: "Bamboo",
            now: Date(timeIntervalSince1970: 150)
        )
        let completedAt = Date(timeIntervalSince1970: 160)
        legacyProject.markCompleted(at: completedAt)
        var legacyYarn = try StoredYarn(name: "Merino", now: start)
        legacyYarn.setLinkedProjectIDs([legacyProject.id], now: Date(timeIntervalSince1970: 170))
        var projectObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyProject)) as? [String: Any]
        )
        projectObject.removeValue(forKey: "journalEntries")
        let yarnObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyYarn))
        let legacy = try JSONSerialization.data(withJSONObject: [
            "version": 8,
            "projects": [projectObject],
            "yarns": [yarnObject],
        ])
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try legacy.write(to: archiveURL, options: .atomic)

        let store = JSONProjectStore(url: archiveURL)

        #expect(store.loadError == nil)
        let loaded = try #require(store.projects.first)
        #expect(loaded.journalEntries.isEmpty)
        #expect(loaded.counters == legacyProject.counters)
        #expect(loaded.selectedCounterID == selectedCounterID)
        #expect(loaded.note(counterID: selectedCounterID, row: 42)?.text == "Decrease")
        #expect(loaded.patterns == [pattern])
        #expect(loaded.photoFilename == "legacy-cover.jpg")
        #expect(loaded.completedAt == completedAt)
        #expect(loaded.toolType == .knittingNeedles)
        #expect(loaded.toolSize == "4 mm")
        #expect(loaded.toolNotes == "Bamboo")
        #expect(store.yarn(id: legacyYarn.id)?.linkedProjectIDs == [legacyProject.id])

        try store.rename(id: legacyProject.id, to: "Migrated")
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
        #expect(archive.version == 9)
        let migrated = try #require(JSONProjectStore(url: archiveURL).project(id: legacyProject.id))
        #expect(migrated.counters == legacyProject.counters)
        #expect(migrated.selectedCounterID == selectedCounterID)
        #expect(migrated.patterns == [pattern])
        #expect(migrated.photoFilename == "legacy-cover.jpg")
        #expect(migrated.completedAt == completedAt)
        #expect(migrated.toolType == .knittingNeedles)
        #expect(migrated.toolSize == "4 mm")
        #expect(migrated.toolNotes == "Bamboo")
        #expect(JSONProjectStore(url: archiveURL).yarn(id: legacyYarn.id)?.linkedProjectIDs == [legacyProject.id])
    }
}

@MainActor private struct StoreFixture {
    let base: URL
    let archiveURL: URL
    let journalDirectory: URL
    let journalService: ProjectJournalPhotoFileService
    let store: JSONProjectStore

    init(writeData: (@Sendable (Data, URL) throws -> Void)? = nil) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        archiveURL = base.appendingPathComponent("projects.json")
        journalDirectory = base.appendingPathComponent("journal", isDirectory: true)
        if let writeData {
            journalService = ProjectJournalPhotoFileService(directory: journalDirectory, writeData: writeData)
        } else {
            journalService = ProjectJournalPhotoFileService(directory: journalDirectory)
        }
        store = JSONProjectStore(url: archiveURL, journalPhotoService: journalService)
    }

    func fileExists(_ filename: String) -> Bool {
        guard let url = journalService.url(filename: filename) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func writeOrphanFiles() throws -> ProjectJournalPhotoFiles {
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        let stem = "\(UUID().uuidString)-\(UUID().uuidString)-\(UUID().uuidString)"
        let files = ProjectJournalPhotoFiles(
            photoFilename: "\(stem)-full.jpg",
            thumbnailFilename: "\(stem)-thumb.jpg"
        )
        try Data("orphan full".utf8).write(
            to: try #require(journalService.url(filename: files.photoFilename))
        )
        try Data("orphan thumbnail".utf8).write(
            to: try #require(journalService.url(filename: files.thumbnailFilename))
        )
        return files
    }
}

private final class BlockingFullImageWrites: @unchecked Sendable {
    private let blocked = DispatchSemaphore(value: 0)
    private let continuation = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var writes = 0

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func write(_ data: Data, _ url: URL) throws {
        lock.lock()
        writes += 1
        lock.unlock()
        try data.write(to: url, options: .atomic)
        guard ProjectJournalPhotoFilename.isFullImage(url.lastPathComponent) else { return }
        blocked.signal()
        continuation.wait()
    }

    func waitUntilBlocked(count: Int = 1) -> Bool {
        let deadline = DispatchTime.now() + 10
        return (0..<count).allSatisfy { _ in
            blocked.wait(timeout: deadline) == .success
        }
    }

    func resume(count: Int = 1) {
        for _ in 0..<count {
            continuation.signal()
        }
    }
}

private func journalFixtureJPEG(red: CGFloat = 0.4) throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: 32,
        height: 24,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
