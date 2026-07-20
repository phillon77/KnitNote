import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct ProjectJournalEntryTests {
    @Test func captionIsTrimmedAndBlankBecomesNil() throws {
        #expect(try journalEntry(caption: "  sleeve done  ").caption == "sleeve done")
        #expect(try journalEntry(caption: " \n ").caption == nil)
    }

    @Test func activeProjectMutatesButCompletedProjectRejectsChanges() throws {
        var project = try StoredProject(name: "Sweater")
        let entry = try journalEntry(projectID: project.id)
        try project.addJournalEntry(entry)
        project.markCompleted()
        #expect(throws: ProjectJournalMutationError.projectCompleted) {
            try project.updateJournalCaption(id: entry.id, caption: "Done")
        }
        #expect(throws: ProjectJournalMutationError.projectCompleted) {
            try project.deleteJournalEntry(id: entry.id)
        }
        project.resume()
        try project.updateJournalCaption(id: entry.id, caption: "Done")
        #expect(project.journalEntries.first?.caption == "Done")
    }

    @Test func legacyProjectDecodesWithEmptyJournal() throws {
        let project = try StoredProject(name: "Legacy")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        object.removeValue(forKey: "journalEntries")
        let decoded = try JSONDecoder().decode(StoredProject.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.journalEntries.isEmpty)
    }

    @Test func blankFilenamesAreRejectedDuringCreationAndDecoding() throws {
        let files = journalPhotoFilenames()
        #expect(throws: ProjectJournalEntryError.invalidFilename) {
            _ = try ProjectJournalEntry(photoFilename: " \n", thumbnailFilename: files.thumbnail, caption: nil)
        }

        let invalid = journalEntryObject(photoFilename: "  ", thumbnailFilename: files.thumbnail)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ProjectJournalEntry.self, from: JSONSerialization.data(withJSONObject: invalid))
        }
    }

    @Test func blankThumbnailFilenameIsRejectedDuringDecoding() throws {
        let invalid = journalEntryObject(photoFilename: journalPhotoFilenames().full, thumbnailFilename: " \n ")

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ProjectJournalEntry.self, from: JSONSerialization.data(withJSONObject: invalid))
        }
    }

    @Test func traversalAbsoluteAndNonJournalFilenamesAreRejectedDuringCreationAndDecoding() throws {
        let files = journalPhotoFilenames()
        for unsafeFilename in ["../outside.jpg", "../\(files.full)", "/tmp/outside.jpg", "full.jpg"] {
            #expect(throws: ProjectJournalEntryError.invalidFilename) {
                _ = try ProjectJournalEntry(
                    photoFilename: unsafeFilename,
                    thumbnailFilename: files.thumbnail,
                    caption: nil
                )
            }
            #expect(throws: ProjectJournalEntryError.invalidFilename) {
                _ = try ProjectJournalEntry(
                    photoFilename: files.full,
                    thumbnailFilename: unsafeFilename,
                    caption: nil
                )
            }
        }

        #expect(throws: ProjectJournalEntryError.invalidFilename) {
            _ = try ProjectJournalEntry(
                photoFilename: files.thumbnail,
                thumbnailFilename: files.full,
                caption: nil
            )
        }

        let invalid = journalEntryObject(photoFilename: "../\(files.full)", thumbnailFilename: files.thumbnail)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ProjectJournalEntry.self, from: JSONSerialization.data(withJSONObject: invalid))
        }
    }

    @Test func journalImagesMustBeAMatchingPairForTheirEntryIdentifier() throws {
        let projectID = UUID()
        let entryID = UUID()
        let matching = journalPhotoFilenames(projectID: projectID, entryID: entryID)
        let otherToken = journalPhotoFilenames(projectID: projectID, entryID: entryID)

        #expect(throws: ProjectJournalEntryError.invalidFilename) {
            _ = try ProjectJournalEntry(
                id: entryID,
                photoFilename: matching.full,
                thumbnailFilename: otherToken.thumbnail,
                caption: nil
            )
        }
        let mismatchedPair = journalEntryObject(
            id: entryID,
            photoFilename: matching.full,
            thumbnailFilename: otherToken.thumbnail
        )
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ProjectJournalEntry.self, from: JSONSerialization.data(withJSONObject: mismatchedPair))
        }

        let differentEntryID = UUID()
        let mismatchedEntry = journalPhotoFilenames(projectID: projectID, entryID: differentEntryID)
        #expect(throws: ProjectJournalEntryError.invalidFilename) {
            _ = try ProjectJournalEntry(
                id: entryID,
                photoFilename: mismatchedEntry.full,
                thumbnailFilename: mismatchedEntry.thumbnail,
                caption: nil
            )
        }
        let decodedMismatchedEntry = journalEntryObject(
            id: entryID,
            photoFilename: mismatchedEntry.full,
            thumbnailFilename: mismatchedEntry.thumbnail
        )
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ProjectJournalEntry.self, from: JSONSerialization.data(withJSONObject: decodedMismatchedEntry))
        }
    }

    @Test func projectRejectsJournalFilenamesOwnedByAnotherProjectAtEveryBoundary() throws {
        let owningProjectID = UUID()
        let otherProjectID = UUID()
        let entryID = UUID()
        let otherProjectFiles = journalPhotoFilenames(
            projectID: otherProjectID,
            entryID: entryID
        )
        let aliasedEntry = try ProjectJournalEntry(
            id: entryID,
            photoFilename: otherProjectFiles.full,
            thumbnailFilename: otherProjectFiles.thumbnail,
            caption: nil
        )

        #expect(throws: ProjectJournalEntryError.invalidFilename) {
            _ = try StoredProject(
                id: owningProjectID,
                name: "Initializer boundary",
                journalEntries: [aliasedEntry]
            )
        }

        var project = try StoredProject(id: owningProjectID, name: "Mutation boundary")
        #expect(throws: ProjectJournalEntryError.invalidFilename) {
            try project.addJournalEntry(aliasedEntry)
        }

        var archivedProject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
        )
        archivedProject["journalEntries"] = [
            journalEntryObject(
                id: entryID,
                photoFilename: otherProjectFiles.full,
                thumbnailFilename: otherProjectFiles.thumbnail
            )
        ]
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                StoredProject.self,
                from: JSONSerialization.data(withJSONObject: archivedProject)
            )
        }
    }

    @Test func projectInitializerRejectsDuplicateJournalEntryIdentifiers() throws {
        let projectID = UUID()
        let entryID = UUID()
        let first = try journalEntry(
            id: entryID,
            projectID: projectID,
            caption: "First"
        )
        let secondFiles = journalPhotoFilenames(projectID: projectID, entryID: entryID)
        let second = try ProjectJournalEntry(
            id: entryID,
            photoFilename: secondFiles.full,
            thumbnailFilename: secondFiles.thumbnail,
            caption: "Second"
        )

        #expect(throws: (any Error).self) {
            _ = try StoredProject(
                id: projectID,
                name: "Duplicate initializer",
                journalEntries: [first, second]
            )
        }
    }

    @Test func projectInitializerAcceptsAndOrdersMultipleValidJournalEntries() throws {
        let projectID = UUID()
        let olderID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let newerID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let older = try journalEntry(
            id: olderID,
            projectID: projectID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let newer = try journalEntry(
            id: newerID,
            projectID: projectID,
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        let project = try StoredProject(
            id: projectID,
            name: "Valid initializer",
            journalEntries: [older, newer]
        )

        #expect(project.journalEntries.map(\.id) == [newerID, olderID])
        #expect(try JSONDecoder().decode(StoredProject.self, from: JSONEncoder().encode(project)) == project)
    }

    @Test func decodedProjectRejectsDuplicateJournalEntryIdentifiers() throws {
        let project = try StoredProject(name: "Duplicate")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        let id = UUID()
        let first = journalPhotoFilenames(projectID: project.id, entryID: id)
        let second = journalPhotoFilenames(projectID: project.id, entryID: id)
        object["journalEntries"] = [
            journalEntryObject(id: id, photoFilename: first.full, thumbnailFilename: first.thumbnail),
            journalEntryObject(id: id, photoFilename: second.full, thumbnailFilename: second.thumbnail)
        ]

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(StoredProject.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func entriesAreOrderedNewestFirstWithStableIdentifierTieBreak() throws {
        let date = Date(timeIntervalSinceReferenceDate: 123)
        var project = try StoredProject(name: "Sorted")
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let lowerEntryID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let higherEntryID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let earlierFiles = journalPhotoFilenames(projectID: project.id, entryID: earlierID)
        let lowerFiles = journalPhotoFilenames(projectID: project.id, entryID: lowerEntryID)
        let higherFiles = journalPhotoFilenames(projectID: project.id, entryID: higherEntryID)
        let earlier = try ProjectJournalEntry(id: earlierID, photoFilename: earlierFiles.full, thumbnailFilename: earlierFiles.thumbnail, caption: nil, createdAt: date.addingTimeInterval(-1))
        let lowerID = try ProjectJournalEntry(id: lowerEntryID, photoFilename: lowerFiles.full, thumbnailFilename: lowerFiles.thumbnail, caption: nil, createdAt: date)
        let higherID = try ProjectJournalEntry(id: higherEntryID, photoFilename: higherFiles.full, thumbnailFilename: higherFiles.thumbnail, caption: nil, createdAt: date)
        try project.addJournalEntry(lowerID)
        try project.addJournalEntry(earlier)
        try project.addJournalEntry(higherID)

        #expect(project.journalEntries.map(\.id) == [higherID.id, lowerID.id, earlier.id])
    }

    @Test func decodedJournalEntriesAreOrderedDeterministically() throws {
        let project = try StoredProject(name: "Decoded sort")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        let date = Date(timeIntervalSinceReferenceDate: 123)
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let earlierFiles = journalPhotoFilenames(projectID: project.id, entryID: earlierID)
        let lowerFiles = journalPhotoFilenames(projectID: project.id, entryID: lowerID)
        let higherFiles = journalPhotoFilenames(projectID: project.id, entryID: higherID)
        object["journalEntries"] = [
            journalEntryObject(id: earlierID, photoFilename: earlierFiles.full, thumbnailFilename: earlierFiles.thumbnail, createdAt: date.addingTimeInterval(-1)),
            journalEntryObject(id: lowerID, photoFilename: lowerFiles.full, thumbnailFilename: lowerFiles.thumbnail, createdAt: date),
            journalEntryObject(id: higherID, photoFilename: higherFiles.full, thumbnailFilename: higherFiles.thumbnail, createdAt: date)
        ]

        let decoded = try JSONDecoder().decode(StoredProject.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.journalEntries.map(\.id) == [higherID, lowerID, earlierID])
    }

    @Test func updatingJournalCaptionToTheSameValuePreservesTimestamp() throws {
        let initialDate = Date(timeIntervalSinceReferenceDate: 100)
        let addDate = Date(timeIntervalSinceReferenceDate: 200)
        let attemptedUpdateDate = Date(timeIntervalSinceReferenceDate: 300)
        var project = try StoredProject(name: "No-op", now: initialDate)
        let entry = try journalEntry(projectID: project.id, caption: "Done")
        try project.addJournalEntry(entry, now: addDate)

        try project.updateJournalCaption(id: entry.id, caption: "Done", now: attemptedUpdateDate)

        #expect(project.updatedAt == addDate)
    }

    @Test func updatingJournalCaptionWithOnlyWhitespaceDifferencePreservesTimestamp() throws {
        let initialDate = Date(timeIntervalSinceReferenceDate: 100)
        let addDate = Date(timeIntervalSinceReferenceDate: 200)
        let attemptedUpdateDate = Date(timeIntervalSinceReferenceDate: 300)
        var project = try StoredProject(name: "Normalized no-op", now: initialDate)
        let entry = try journalEntry(projectID: project.id, caption: "Done")
        try project.addJournalEntry(entry, now: addDate)

        try project.updateJournalCaption(id: entry.id, caption: "  Done \n", now: attemptedUpdateDate)

        #expect(project.updatedAt == addDate)
    }

    @Test func journalRoundTripPreservesEntriesAndMutationsUpdateTimestamp() throws {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let addDate = Date(timeIntervalSinceReferenceDate: 200)
        let updateDate = Date(timeIntervalSinceReferenceDate: 300)
        let deleteDate = Date(timeIntervalSinceReferenceDate: 400)
        var project = try StoredProject(name: "Round trip", now: start)
        let entry = try journalEntry(projectID: project.id, caption: "Caption", createdAt: start)

        try project.addJournalEntry(entry, now: addDate)
        #expect(project.updatedAt == addDate)
        try project.updateJournalCaption(id: entry.id, caption: " Updated ", now: updateDate)
        #expect(project.updatedAt == updateDate)
        #expect(try JSONDecoder().decode(StoredProject.self, from: JSONEncoder().encode(project)).journalEntries == project.journalEntries)
        _ = try project.deleteJournalEntry(id: entry.id, now: deleteDate)
        #expect(project.updatedAt == deleteDate)
    }
}

private func journalEntryObject(
    id: UUID = UUID(),
    photoFilename: String,
    thumbnailFilename: String,
    caption: String? = nil,
    createdAt: Date = .now
) -> [String: Any] {
    [
        "id": id.uuidString,
        "photoFilename": photoFilename,
        "thumbnailFilename": thumbnailFilename,
        "caption": caption as Any,
        "createdAt": createdAt.timeIntervalSinceReferenceDate
    ]
}

private func journalPhotoFilenames(
    projectID: UUID = UUID(),
    entryID: UUID = UUID(),
    token: UUID = UUID()
) -> (full: String, thumbnail: String) {
    let stem = "\(projectID.uuidString)-\(entryID.uuidString)-\(token.uuidString)"
    return ("\(stem)-full.jpg", "\(stem)-thumb.jpg")
}

private func journalEntry(
    id: UUID = UUID(),
    projectID: UUID = UUID(),
    caption: String? = nil,
    createdAt: Date = .now
) throws -> ProjectJournalEntry {
    let files = journalPhotoFilenames(projectID: projectID, entryID: id)
    return try ProjectJournalEntry(
        id: id,
        photoFilename: files.full,
        thumbnailFilename: files.thumbnail,
        caption: caption,
        createdAt: createdAt
    )
}
