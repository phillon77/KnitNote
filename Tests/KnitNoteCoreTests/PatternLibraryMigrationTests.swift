import CryptoKit
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

@Test func stagedMigrationJournalsHaveDistinctIDsAndStagedPhase() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let first = try PatternLibraryMigrator().migrate(archive: fixture.archive, liveRoot: fixture.liveRoot)
    let second = try PatternLibraryMigrator().migrate(archive: fixture.archive, liveRoot: fixture.liveRoot)
    let decoder = JSONDecoder()
    let firstJournal = try decoder.decode(
        PatternMigrationTransaction.self,
        from: Data(contentsOf: first.stagedRoot.appendingPathComponent("transaction.json"))
    )
    let secondJournal = try decoder.decode(
        PatternMigrationTransaction.self,
        from: Data(contentsOf: second.stagedRoot.appendingPathComponent("transaction.json"))
    )

    #expect(firstJournal.phase == .staged)
    #expect(secondJournal.phase == .staged)
    #expect(firstJournal.id != secondJournal.id)
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

@MainActor @Test func sameProjectDuplicateLegacyDocumentsUseSeparatePatternsAndUsages() throws {
    let fixture = try LegacyPatternFixture.oneProject(
        names: ["Ida Tee", "ida tee"],
        identicalBytes: true
    )

    let store = JSONProjectStore(url: fixture.archiveURL)

    #expect(store.loadError == nil)
    #expect(store.patternAssets.count == 1)
    #expect(store.patterns.count == 2)
    #expect(store.patternUsages.map(\.id) == fixture.legacyPatternIDs)
    #expect(Set(store.patternUsages.map(\.patternID)).count == 2)
    #expect(store.patternUsages.map(\.readingState) == fixture.legacyReadingStates)
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

@Test func migrationPreservesCompleteReadingStateAndMarkupBytes() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let result = try PatternLibraryMigrator().migrate(
        archive: fixture.archive,
        liveRoot: fixture.liveRoot
    )

    #expect(result.usages.map(\.readingState) == fixture.legacyReadingStates)
    #expect(result.patterns.map(\.createdAt) == fixture.legacyCreatedAt)
    #expect(result.patterns.map(\.lastOpenedAt) == fixture.legacyLastOpenedAt)
    let markupURL = result.stagedRoot.appendingPathComponent(
        "Patterns/UsageMarkup/\(fixture.legacyPatternIDs[0].uuidString)/0.json"
    )
    #expect(try Data(contentsOf: markupURL) == fixture.legacyMarkupData)
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

@Test func failedAfterInstallRestoresArchiveAndPatternTreeByteForByte() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let originalArchive = try Data(contentsOf: fixture.archiveURL)
    let originalPattern = try Data(contentsOf: fixture.legacyPatternURL)
    let originalMarkup = try Data(contentsOf: fixture.legacyMarkupURL)
    enum PatternMigrationTestError: Error { case injected }
    let migrator = PatternLibraryMigrator(stepHook: { step in
        if step == .afterInstall { throw PatternMigrationTestError.injected }
    })

    #expect(throws: PatternMigrationTestError.injected) {
        try migrator.migrateOnDisk(archiveURL: fixture.archiveURL)
    }

    #expect(try Data(contentsOf: fixture.archiveURL) == originalArchive)
    #expect(try Data(contentsOf: fixture.legacyPatternURL) == originalPattern)
    #expect(try Data(contentsOf: fixture.legacyMarkupURL) == originalMarkup)
}

@Test func interruptedArchiveInstallRecoversOriginalArchiveAndPatternTree() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let originalArchive = try Data(contentsOf: fixture.archiveURL)
    let originalPattern = try Data(contentsOf: fixture.legacyPatternURL)
    let result = try PatternLibraryMigrator().migrate(
        archive: fixture.archive,
        liveRoot: fixture.liveRoot
    )
    let rollback = result.stagedRoot.appendingPathComponent("Rollback", isDirectory: true)
    let originalPatterns = fixture.liveRoot.appendingPathComponent("Patterns", isDirectory: true)

    try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
    try FileManager.default.moveItem(
        at: fixture.archiveURL,
        to: rollback.appendingPathComponent("archive.json")
    )
    try FileManager.default.moveItem(
        at: originalPatterns,
        to: rollback.appendingPathComponent("Patterns", isDirectory: true)
    )
    try FileManager.default.moveItem(
        at: result.stagedRoot.appendingPathComponent("archive.json"),
        to: fixture.archiveURL
    )
    try writeTransactionPhase(.archiveInstalled, at: result.stagedRoot)

    try PatternLibraryMigrator().recoverInterruptedMigration(archiveURL: fixture.archiveURL)

    #expect(try Data(contentsOf: fixture.archiveURL) == originalArchive)
    #expect(try Data(contentsOf: fixture.legacyPatternURL) == originalPattern)
}

@MainActor @Test func storeRecoversInterruptedArchiveInstallBeforePublishingData() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let result = try PatternLibraryMigrator().migrate(
        archive: fixture.archive,
        liveRoot: fixture.liveRoot
    )
    let rollback = result.stagedRoot.appendingPathComponent("Rollback", isDirectory: true)
    let originalPatterns = fixture.liveRoot.appendingPathComponent("Patterns", isDirectory: true)

    try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
    try FileManager.default.moveItem(
        at: fixture.archiveURL,
        to: rollback.appendingPathComponent("archive.json")
    )
    try FileManager.default.moveItem(
        at: originalPatterns,
        to: rollback.appendingPathComponent("Patterns", isDirectory: true)
    )
    try FileManager.default.moveItem(
        at: result.stagedRoot.appendingPathComponent("archive.json"),
        to: fixture.archiveURL
    )
    try writeTransactionPhase(.archiveInstalled, at: result.stagedRoot)

    let store = JSONProjectStore(url: fixture.archiveURL)

    #expect(store.loadError == nil)
    #expect(store.patternAssets.count == 1)
    #expect(store.patternUsages.map(\.id) == fixture.legacyPatternIDs)
}

@MainActor @Test func storeRecoversPendingRollbackWhenLiveArchiveIsMissing() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let result = try stageInterruptedInstall(fixture)

    try FileManager.default.removeItem(at: fixture.archiveURL)
    try writeTransactionPhase(.patternsBackedUp, at: result.stagedRoot)

    let store = JSONProjectStore(url: fixture.archiveURL)

    #expect(store.loadError == nil)
    #expect(store.patternAssets.count == 1)
    #expect(store.patternUsages.map(\.id) == fixture.legacyPatternIDs)
    #expect(!store.projects.isEmpty)
}

@Test func committedJournalNeverRollsBackInvalidCurrentLibrary() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let originalArchive = try Data(contentsOf: fixture.archiveURL)
    let result = try stageInterruptedInstall(fixture)
    let asset = try #require(result.archive.patternAssets.first)
    let assetURL = fixture.liveRoot
        .appendingPathComponent("Patterns/Assets")
        .appendingPathComponent(asset.storedFilename)

    try FileManager.default.removeItem(at: assetURL)
    try writeTransactionPhase(.committed, at: result.stagedRoot)
    try PatternLibraryMigrator().recoverInterruptedMigration(archiveURL: fixture.archiveURL)

    let current = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: fixture.archiveURL))
    #expect(current.version == ProjectArchive.currentVersion)
    #expect(try Data(contentsOf: fixture.archiveURL) != originalArchive)
    #expect(!FileManager.default.fileExists(atPath: result.stagedRoot.path))
}

@Test func interruptedInstalledTruncatedAssetRollsBackLegacyData() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let originalArchive = try Data(contentsOf: fixture.archiveURL)
    let originalPattern = try Data(contentsOf: fixture.legacyPatternURL)
    let result = try stageInterruptedInstall(fixture)
    let asset = try #require(result.archive.patternAssets.first)
    let assetURL = fixture.liveRoot
        .appendingPathComponent("Patterns/Assets")
        .appendingPathComponent(asset.storedFilename)

    try Data([0x25, 0x50, 0x44, 0x46]).write(to: assetURL)
    try writeTransactionPhase(.installed, at: result.stagedRoot)
    try PatternLibraryMigrator().recoverInterruptedMigration(archiveURL: fixture.archiveURL)

    #expect(try Data(contentsOf: fixture.archiveURL) == originalArchive)
    #expect(try Data(contentsOf: fixture.legacyPatternURL) == originalPattern)
}

@MainActor @Test func storeRejectsCurrentArchiveWhenAssetBytesAreCorrupted() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let migrated = JSONProjectStore(url: fixture.archiveURL)
    let asset = try #require(migrated.patternAssets.first)
    let assetURL = fixture.liveRoot
        .appendingPathComponent("Patterns/Assets")
        .appendingPathComponent(asset.storedFilename)
    var bytes = try Data(contentsOf: assetURL)
    bytes[bytes.startIndex] ^= 0x01
    try bytes.write(to: assetURL)

    let reloaded = JSONProjectStore(url: fixture.archiveURL)

    #expect(reloaded.loadError == .unreadableArchive)
    #expect(reloaded.patternAssets.isEmpty)
}

@MainActor @Test func storeRejectsCurrentArchiveWhenPDFAssetContentIsInvalid() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let migrated = JSONProjectStore(url: fixture.archiveURL)
    let asset = try #require(migrated.patternAssets.first)
    let assetURL = fixture.liveRoot
        .appendingPathComponent("Patterns/Assets")
        .appendingPathComponent(asset.storedFilename)
    let invalidPDF = Data("this is not a PDF".utf8)
    try invalidPDF.write(to: assetURL)
    let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: fixture.archiveURL))
    let replacement = PatternAsset(
        id: asset.id,
        sha256: SHA256.hash(data: invalidPDF).map { String(format: "%02x", $0) }.joined(),
        kind: .pdf,
        storedFilename: asset.storedFilename,
        byteCount: Int64(invalidPDF.count),
        pageCount: asset.pageCount
    )
    let corruptArchive = ProjectArchive(
        version: archive.version,
        projects: archive.projects,
        yarns: archive.yarns,
        patternAssets: archive.patternAssets.map { $0.id == asset.id ? replacement : $0 },
        patterns: archive.patterns,
        patternUsages: archive.patternUsages
    )
    try JSONEncoder().encode(corruptArchive).write(to: fixture.archiveURL, options: .atomic)

    let reloaded = JSONProjectStore(url: fixture.archiveURL)

    #expect(reloaded.loadError == .unreadableArchive)
    #expect(reloaded.patternAssets.isEmpty)
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

@MainActor @Test func storeMigrationIsIdempotentAcrossTwoReopens() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let first = JSONProjectStore(url: fixture.archiveURL)
    let onceMigrated = try Data(contentsOf: fixture.archiveURL)

    let second = JSONProjectStore(url: fixture.archiveURL)
    let third = JSONProjectStore(url: fixture.archiveURL)

    #expect(first.patternAssets == second.patternAssets)
    #expect(second.patterns == third.patterns)
    #expect(second.patternUsages == third.patternUsages)
    #expect(try Data(contentsOf: fixture.archiveURL) == onceMigrated)
}

@MainActor @Test func storeRejectsCurrentArchiveWhenReferencedAssetIsMissing() throws {
    let fixture = try LegacyPatternFixture.onePattern()
    let migrated = JSONProjectStore(url: fixture.archiveURL)
    let asset = try #require(migrated.patternAssets.first)
    let assetURL = fixture.liveRoot
        .appendingPathComponent("Patterns/Assets")
        .appendingPathComponent(asset.storedFilename)
    try FileManager.default.removeItem(at: assetURL)

    let reloaded = JSONProjectStore(url: fixture.archiveURL)

    #expect(reloaded.loadError == .unreadableArchive)
    #expect(reloaded.projects.isEmpty)
    #expect(reloaded.patternAssets.isEmpty)
}

@MainActor @Test(arguments: Array(1...9))
func everySupportedLegacySchemaMigratesThroughTheStore(version: Int) throws {
    let fixture = try LegacyPatternFixture.onePattern(version: version)

    let store = JSONProjectStore(url: fixture.archiveURL)
    let installed = try JSONDecoder().decode(
        ProjectArchive.self,
        from: Data(contentsOf: fixture.archiveURL)
    )

    #expect(store.loadError == nil)
    #expect(installed.version == ProjectArchive.currentVersion)
    #expect(store.patternUsages.map(\.id) == fixture.legacyPatternIDs)
}

private struct LegacyPatternFixture {
    let liveRoot: URL
    let archiveURL: URL
    let archive: ProjectArchive
    let legacyPatternIDs: [UUID]
    let legacyReadingStates: [PatternReadingState]
    let legacyCreatedAt: [Date]
    let legacyLastOpenedAt: [Date?]
    let legacyPatternURL: URL
    let legacyMarkupURL: URL
    let legacyMarkupData: Data

    static func onePattern(version: Int = 9) throws -> LegacyPatternFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatternLibraryMigration-\(UUID().uuidString)", isDirectory: true)
        let project = try StoredProject(name: "Cardigan")
        return try make(
            root: root,
            projects: [project],
            names: ["Ida Tee"],
            identicalBytes: true,
            version: version
        )
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
        sharedProject: Bool = false,
        version: Int = 9
    ) throws -> LegacyPatternFixture {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.pdf")
        try makeTestPatternPDF(at: source, pageCount: 3)
        let sharedBytes = try Data(contentsOf: source)

        var legacyProjects = sharedProject ? [projects[0]] : projects
        var patternIDs: [UUID] = []
        var readingStates: [PatternReadingState] = []
        var createdAt: [Date] = []
        var lastOpenedAt: [Date?] = []
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
                offsetY: 0.8,
                highlightEnabled: true,
                highlightPosition: 0.31,
                highlightMode: .cross,
                verticalHighlightPosition: 0.72
            )
            readingState.setPageNote("Sleeve repeat")
            readingState.pageStates[0] = PatternPageState(
                horizontalPosition: 0.15,
                verticalPosition: 0.25,
                note: "Cast on"
            )
            readingState.pageStates[1] = PatternPageState(
                horizontalPosition: 0.65,
                verticalPosition: 0.45,
                note: "Increase"
            )
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
            let markup = PatternMarkupDocument(strokes: [
                .init(
                    points: [.init(x: 0.1, y: 0.2), .init(x: 0.3, y: 0.4)],
                    color: .red,
                    width: 0.006
                )
            ])
            try JSONEncoder().encode(markup).write(to: markupURL)
            patternIDs.append(pattern.id)
            readingStates.append(legacyProjects[projectIndex].patterns.last!.readingState)
            createdAt.append(legacyProjects[projectIndex].patterns.last!.createdAt)
            lastOpenedAt.append(legacyProjects[projectIndex].patterns.last!.lastOpenedAt)
            firstPatternURL = firstPatternURL ?? patternURL
            firstMarkupURL = firstMarkupURL ?? markupURL
        }

        let archive = ProjectArchive(version: version, projects: legacyProjects)
        let archiveURL = root.appendingPathComponent("projects-v1.json")
        try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)
        return LegacyPatternFixture(
            liveRoot: root,
            archiveURL: archiveURL,
            archive: archive,
            legacyPatternIDs: patternIDs,
            legacyReadingStates: readingStates,
            legacyCreatedAt: createdAt,
            legacyLastOpenedAt: lastOpenedAt,
            legacyPatternURL: try #require(firstPatternURL),
            legacyMarkupURL: try #require(firstMarkupURL),
            legacyMarkupData: try Data(contentsOf: try #require(firstMarkupURL))
        )
    }
}

private func stageInterruptedInstall(_ fixture: LegacyPatternFixture) throws -> MigratedPatternLibrary {
    let result = try PatternLibraryMigrator().migrate(
        archive: fixture.archive,
        liveRoot: fixture.liveRoot
    )
    let rollback = result.stagedRoot.appendingPathComponent("Rollback", isDirectory: true)
    let originalPatterns = fixture.liveRoot.appendingPathComponent("Patterns", isDirectory: true)
    try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
    try FileManager.default.moveItem(
        at: fixture.archiveURL,
        to: rollback.appendingPathComponent("archive.json")
    )
    try FileManager.default.moveItem(
        at: originalPatterns,
        to: rollback.appendingPathComponent("Patterns", isDirectory: true)
    )
    try FileManager.default.moveItem(
        at: result.stagedRoot.appendingPathComponent("archive.json"),
        to: fixture.archiveURL
    )
    try FileManager.default.moveItem(
        at: result.stagedRoot.appendingPathComponent("Patterns", isDirectory: true),
        to: originalPatterns
    )
    return result
}

private func writeTransactionPhase(
    _ phase: PatternMigrationTransaction.Phase,
    at root: URL
) throws {
    let transactionURL = root.appendingPathComponent("transaction.json")
    var transaction = try JSONDecoder().decode(PatternMigrationTransaction.self, from: Data(contentsOf: transactionURL))
    transaction.phase = phase
    try JSONEncoder().encode(transaction).write(to: transactionURL, options: .atomic)
}
