import Foundation
import Testing
@testable import KnitNoteCore

@Test func migrationSharesBytesButPreservesDifferentNames() throws {
    let fixture = try LegacyPatternFixture.twoProjects(
        firstName: "Ida Tee",
        secondName: "Ida Tee English",
        identicalBytes: true
    )
    let result = try PatternLibraryMigrator().migrate(
        archive: fixture.archive,
        liveRoot: fixture.liveRoot
    )

    #expect(result.assets.count == 1)
    #expect(result.patterns.map(\.displayName).sorted() == ["Ida Tee", "Ida Tee English"])
    #expect(
        result.usages.map(\.id.uuidString).sorted()
            == fixture.legacyPatternIDs.map(\.uuidString).sorted()
    )
    #expect(result.usages.map(\.sortOrder).sorted() == [0, 0])
}

@Test func migrationMergesNormalizedNamesAcrossProjects() throws {
    let fixture = try LegacyPatternFixture.twoProjects(
        firstName: "  Ida Tee  ",
        secondName: "ida tee",
        identicalBytes: true
    )
    let result = try PatternLibraryMigrator().migrate(
        archive: fixture.archive,
        liveRoot: fixture.liveRoot
    )

    #expect(result.assets.count == 1)
    #expect(result.patterns.map(\.displayName) == ["Ida Tee"])
    #expect(result.usages.map(\.sortOrder) == [0, 0])
    #expect(result.usages.map(\.id) == fixture.legacyPatternIDs)
}

@Test func migrationKeepsLegacyOrderWithinOneProject() throws {
    let fixture = try LegacyPatternFixture.oneProject(
        names: ["Ida Tee", "Sleeve chart", "Body chart"],
        identicalBytes: true
    )
    let result = try PatternLibraryMigrator().migrate(
        archive: fixture.archive,
        liveRoot: fixture.liveRoot
    )

    #expect(result.assets.count == 1)
    #expect(result.patterns.map(\.displayName) == ["Ida Tee", "Sleeve chart", "Body chart"])
    #expect(result.usages.map(\.sortOrder) == [0, 1, 2])
    #expect(result.usages.map(\.id) == fixture.legacyPatternIDs)
}

@Test func migrationPreservesUsageReadingStateAndMovesMarkup() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let result = try PatternLibraryMigrator().migrate(
        archive: fixture.archive,
        liveRoot: fixture.liveRoot
    )
    let usage = try #require(result.usages.first)

    #expect(usage.id == fixture.legacyPatternIDs[0])
    #expect(usage.readingState.pageIndex == 2)
    #expect(usage.readingState.pageNote == "Sleeve repeat")
    #expect(
        FileManager.default.fileExists(
            atPath: result.stagedRoot
                .appendingPathComponent("Patterns/UsageMarkup/\(usage.id.uuidString)/0.json")
                .path
        )
    )
    #expect(result.archive.projects.allSatisfy { $0.patterns.isEmpty })
}

@Test func failedMigrationLeavesLegacyArchiveAndFilesUntouched() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let originalArchive = try Data(contentsOf: fixture.archiveURL)
    enum PatternMigrationTestError: Error { case injected }
    let migrator = PatternLibraryMigrator(stepHook: { step in
        if step == .beforeInstall { throw PatternMigrationTestError.injected }
    })

    #expect(throws: PatternMigrationTestError.injected) {
        try migrator.migrateOnDisk(archiveURL: fixture.archiveURL)
    }

    #expect(try Data(contentsOf: fixture.archiveURL) == originalArchive)
    #expect(FileManager.default.fileExists(atPath: fixture.legacyPatternURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.legacyMarkupURL.path))
}

@MainActor @Test func storeUpgradesLegacyArchiveAndPublishesMigratedLibrary() throws {
    let fixture = try LegacyPatternFixture.onePattern()

    let store = JSONProjectStore(url: fixture.archiveURL)
    let installed = try JSONDecoder().decode(
        ProjectArchive.self,
        from: Data(contentsOf: fixture.archiveURL)
    )

    #expect(store.loadError == nil)
    #expect(store.patternAssets.count == 1)
    #expect(store.patterns.count == 1)
    #expect(store.patternUsages.map(\.id) == fixture.legacyPatternIDs)
    #expect(installed.version == 10)
    #expect(installed.projects.allSatisfy { $0.patterns.isEmpty })
}

private struct LegacyPatternFixture {
    let liveRoot: URL
    let archiveURL: URL
    let archive: ProjectArchive
    let legacyPatternIDs: [UUID]
    let legacyPatternURL: URL
    let legacyMarkupURL: URL

    static func onePattern() throws -> LegacyPatternFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatternLibraryMigration-\(UUID().uuidString)", isDirectory: true)
        let project = try StoredProject(name: "Cardigan")
        return try make(root: root, projects: [project], names: ["Ida Tee"], identicalBytes: true)
    }

    static func twoProjects(
        firstName: String,
        secondName: String,
        identicalBytes: Bool
    ) throws -> LegacyPatternFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatternLibraryMigration-\(UUID().uuidString)", isDirectory: true)
        return try make(
            root: root,
            projects: [try StoredProject(name: "First"), try StoredProject(name: "Second")],
            names: [firstName, secondName],
            identicalBytes: identicalBytes
        )
    }

    static func oneProject(names: [String], identicalBytes: Bool) throws -> LegacyPatternFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatternLibraryMigration-\(UUID().uuidString)", isDirectory: true)
        return try make(
            root: root,
            projects: [try StoredProject(name: "Cardigan")],
            names: names,
            identicalBytes: identicalBytes,
            sharedProject: true
        )
    }

    private static func make(
        root: URL,
        projects: [StoredProject],
        names: [String],
        identicalBytes: Bool,
        sharedProject: Bool = false
    ) throws -> LegacyPatternFixture {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.pdf")
        try makeTestPatternPDF(at: source, pageCount: 3)
        let sharedBytes = try Data(contentsOf: source)

        var legacyProjects = sharedProject ? [projects[0]] : projects
        var patternIDs: [UUID] = []
        var firstPatternURL: URL?
        var firstMarkupURL: URL?
        for index in names.indices {
            let projectIndex = sharedProject ? 0 : index
            let pattern = PatternDocument(
                displayName: names[index],
                kind: .pdf,
                storedFilename: "legacy-\(index).pdf",
                createdAt: Date(timeIntervalSince1970: 1_000 + Double(index))
            )
            legacyProjects[projectIndex].addPattern(pattern)
            var readingState = PatternReadingState(
                pageIndex: 2,
                zoomScale: 1.4,
                offsetX: 0.2,
                offsetY: 0.8
            )
            readingState.setPageNote("Sleeve repeat")
            legacyProjects[projectIndex].updatePatternState(
                id: pattern.id,
                state: readingState,
                now: Date(timeIntervalSince1970: 2_000 + Double(index))
            )
            let patternURL = root
                .appendingPathComponent("Patterns/\(legacyProjects[projectIndex].id.uuidString)")
                .appendingPathComponent(pattern.storedFilename)
            try FileManager.default.createDirectory(
                at: patternURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let bytes = identicalBytes || index == 0 ? sharedBytes : Data(sharedBytes.reversed())
            try bytes.write(to: patternURL)

            let markupURL = root
                .appendingPathComponent(
                    "Patterns/\(legacyProjects[projectIndex].id.uuidString)/Markup/\(pattern.id.uuidString)/0.json"
                )
            try FileManager.default.createDirectory(
                at: markupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(PatternMarkupDocument()).write(to: markupURL)
            patternIDs.append(pattern.id)
            firstPatternURL = firstPatternURL ?? patternURL
            firstMarkupURL = firstMarkupURL ?? markupURL
        }

        let archive = ProjectArchive(version: 9, projects: legacyProjects)
        let archiveURL = root.appendingPathComponent("projects-v1.json")
        try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)
        return LegacyPatternFixture(
            liveRoot: root,
            archiveURL: archiveURL,
            archive: archive,
            legacyPatternIDs: patternIDs,
            legacyPatternURL: try #require(firstPatternURL),
            legacyMarkupURL: try #require(firstMarkupURL)
        )
    }
}
