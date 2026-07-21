import CoreGraphics
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct KnitNoteBackupServiceTests {
    @Test func exportCopiesArchiveAndEveryReferencedMediaKindButNotOrphans() throws {
        let (service, live, root) = try makeServiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try BackupFixture.writeCompleteArchive(to: live)
        try Data("orphan".utf8).write(
            to: live.appendingPathComponent("ProjectPhotos/orphan.jpg")
        )

        let package = try service.createPackage(
            appVersion: "1.0",
            now: .init(timeIntervalSince1970: 10)
        )

        #expect(FileManager.default.fileExists(
            atPath: package.appendingPathComponent("manifest.json").path
        ))
        for relativePath in fixture.referencedRelativePaths {
            #expect(FileManager.default.fileExists(
                atPath: package.appendingPathComponent("Data/\(relativePath)").path
            ))
        }
        #expect(!FileManager.default.fileExists(
            atPath: package.appendingPathComponent("Data/ProjectPhotos/orphan.jpg").path
        ))
        #expect(try service.inspectPackage(at: package).projectCount == 1)
    }

    @Test(arguments: [
        "archive", "project-photos", "yarn-photos", "journal-photos", "patterns", "markup",
    ])
    func exportRejectsSymbolicLinkInEveryLiveSourceAncestor(_ source: String) throws {
        let (service, live, root) = try makeServiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try BackupFixture.writeCompleteArchive(to: live)
        try BackupFixture.replaceLiveSourceWithExternalSymlink(
            source,
            live: live,
            fixture: fixture
        )

        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            _ = try service.createPackage(appVersion: "1.0")
        }
    }

    @Test(arguments: ["../escape.jpg", "/tmp/escape.jpg", "nested/name.jpg"])
    func unsafeReferencedFilenamesAreRejected(_ filename: String) throws {
        let package = try BackupFixture.package(projectPhotoFilename: filename)
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }

        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func missingReferenceIsRejected() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        try FileManager.default.removeItem(at: package.firstReferencedFile)

        #expect(throws: KnitNoteBackupError.missingReferencedFile(package.firstRelativePath)) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func symlinkUnknownEntryAndMalformedMarkupAreRejected() throws {
        let symlink = try BackupFixture.packageContainingSymlink()
        defer { try? FileManager.default.removeItem(at: symlink.cleanupRoot) }
        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            _ = try symlink.service.inspectPackage(at: symlink.url)
        }

        let unknown = try BackupFixture.packageContainingUnknownEntry()
        defer { try? FileManager.default.removeItem(at: unknown.cleanupRoot) }
        #expect(throws: KnitNoteBackupError.unknownPackageEntry) {
            _ = try unknown.service.inspectPackage(at: unknown.url)
        }

        let markup = try BackupFixture.packageContainingMalformedMarkup()
        defer { try? FileManager.default.removeItem(at: markup.cleanupRoot) }
        #expect(throws: KnitNoteBackupError.invalidMarkup) {
            _ = try markup.service.inspectPackage(at: markup.url)
        }
    }

    @Test func structuredMarkupByteCapAcceptsExactAndRejectsLimitPlusOne() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let markupPath = package.url
            .appendingPathComponent("Data/\(package.markupRelativePath)")
            .standardizedFileURL.path
        func service(reporting size: Int64) -> KnitNoteBackupService {
            KnitNoteBackupService(
                liveRoot: package.service.liveRoot,
                workRoot: package.service.workRoot,
                resourceMetadata: { url in
                    try BackupFixture.metadata(
                        for: url,
                        overridingFileSize: url.standardizedFileURL.path == markupPath
                            ? size
                            : nil
                    )
                }
            )
        }

        #expect(try service(
            reporting: KnitNoteBackupLimits.maximumMarkupBytes
        ).inspectPackage(at: package.url).projectCount == 1)
        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            _ = try service(
                reporting: KnitNoteBackupLimits.maximumMarkupBytes + 1
            ).inspectPackage(at: package.url)
        }
    }

    @Test func markupEntryCapAcceptsExactAndRejectsLimitPlusOne() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let directory = package.url
            .appendingPathComponent("Data/\(package.markupRelativePath)")
            .deletingLastPathComponent()
        let documentData = try JSONEncoder().encode(PatternMarkupDocument())
        for page in 1..<KnitNoteBackupLimits.maximumMarkupEntriesPerPattern {
            try documentData.write(to: directory.appendingPathComponent("\(page).json"))
        }

        #expect(try package.service.inspectPackage(at: package.url).projectCount == 1)

        try documentData.write(to: directory.appendingPathComponent(
            "\(KnitNoteBackupLimits.maximumMarkupEntriesPerPattern).json"
        ))
        #expect(throws: KnitNoteBackupError.invalidMarkup) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func markupStrokeCapAcceptsExactAndRejectsLimitPlusOne() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let stroke = PatternMarkupStroke(
            points: [.init(x: 0.25, y: 0.75)],
            color: .red,
            width: 0.006
        )
        try package.rewriteMarkup(PatternMarkupDocument(strokes: Array(
            repeating: stroke,
            count: KnitNoteBackupLimits.maximumMarkupStrokesPerDocument
        )))

        #expect(try package.service.inspectPackage(at: package.url).projectCount == 1)

        try package.rewriteMarkup(PatternMarkupDocument(strokes: Array(
            repeating: stroke,
            count: KnitNoteBackupLimits.maximumMarkupStrokesPerDocument + 1
        )))
        #expect(throws: KnitNoteBackupError.invalidMarkup) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func markupPointCapAcceptsExactAndRejectsLimitPlusOne() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let point = PatternMarkupPoint(x: 0.5, y: 0.5)
        func document(pointCount: Int) -> PatternMarkupDocument {
            PatternMarkupDocument(strokes: [PatternMarkupStroke(
                points: Array(repeating: point, count: pointCount),
                color: .blue,
                width: 0.008
            )])
        }
        try package.rewriteMarkup(document(
            pointCount: KnitNoteBackupLimits.maximumMarkupPointsPerStroke
        ))

        #expect(try package.service.inspectPackage(at: package.url).projectCount == 1)

        try package.rewriteMarkup(document(
            pointCount: KnitNoteBackupLimits.maximumMarkupPointsPerStroke + 1
        ))
        #expect(throws: KnitNoteBackupError.invalidMarkup) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func markupDocumentTotalPointCapAcceptsExactAndRejectsLimitPlusOne() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let point = PatternMarkupPoint(x: 0.5, y: 0.5)
        let fullStroke = PatternMarkupStroke(
            points: Array(
                repeating: point,
                count: KnitNoteBackupLimits.maximumMarkupPointsPerStroke
            ),
            color: .green,
            width: 0.008
        )
        let exactStrokeCount = KnitNoteBackupLimits.maximumMarkupPointsPerDocument
            / KnitNoteBackupLimits.maximumMarkupPointsPerStroke
        let exact = PatternMarkupDocument(strokes: Array(
            repeating: fullStroke,
            count: exactStrokeCount
        ))
        try package.rewriteMarkup(exact)

        #expect(try package.service.inspectPackage(at: package.url).projectCount == 1)

        var overStrokes = exact.strokes
        overStrokes.append(PatternMarkupStroke(
            points: [point],
            color: .green,
            width: 0.008
        ))
        try package.rewriteMarkup(PatternMarkupDocument(strokes: overStrokes))
        #expect(throws: KnitNoteBackupError.invalidMarkup) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func newerFormatIsRejectedDuringInspection() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        try package.rewriteManifest { manifest in
            KnitNoteBackupManifest(
                formatVersion: KnitNoteBackupManifest.currentFormatVersion + 1,
                createdAt: manifest.createdAt,
                appVersion: manifest.appVersion,
                projectCount: manifest.projectCount,
                yarnCount: manifest.yarnCount
            )
        }

        #expect(throws: KnitNoteBackupError.unsupportedNewerVersion(2)) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func projectArchiveDeclaresSharedCurrentAndSupportedLegacyVersions() {
        #expect(ProjectArchive.currentVersion == 9)
        #expect(ProjectArchive.minimumSupportedVersion == 1)
        #expect(ProjectArchive.isSupported(version: 1))
        #expect(ProjectArchive.isSupported(version: 8))
        #expect(ProjectArchive.isSupported(version: ProjectArchive.currentVersion))
        #expect(!ProjectArchive.isSupported(version: 0))
        #expect(!ProjectArchive.isSupported(version: ProjectArchive.currentVersion + 1))
    }

    @Test func supportedLegacyProjectArchiveIsAcceptedDuringInspection() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        try package.rewriteArchive { archive in
            ProjectArchive(version: 8, projects: archive.projects, yarns: archive.yarns)
        }

        #expect(try package.service.inspectPackage(at: package.url).projectCount == 1)
    }

    @Test func futureProjectArchiveIsRejectedDuringExportAndInspection() throws {
        let (service, live, root) = try makeServiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try BackupFixture.writeCompleteArchive(to: live)
        try BackupFixture.rewriteLiveArchive(at: live) { archive in
            ProjectArchive(
                version: ProjectArchive.currentVersion + 1,
                projects: archive.projects,
                yarns: archive.yarns
            )
        }
        #expect(throws: KnitNoteBackupError.unsupportedNewerVersion(10)) {
            _ = try service.createPackage(appVersion: "1.0")
        }

        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        try package.rewriteArchive { archive in
            ProjectArchive(
                version: ProjectArchive.currentVersion + 1,
                projects: archive.projects,
                yarns: archive.yarns
            )
        }
        #expect(throws: KnitNoteBackupError.unsupportedNewerVersion(10)) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func futureProjectArchiveIntroducedAfterInspectionIsRejectedByStage() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let service = KnitNoteBackupService(
            liveRoot: package.service.liveRoot,
            workRoot: package.service.workRoot,
            afterStageCopy: { stagedRoot in
                let archiveURL = stagedRoot.appendingPathComponent("Data/projects-v1.json")
                let archive = try JSONDecoder().decode(
                    ProjectArchive.self,
                    from: Data(contentsOf: archiveURL)
                )
                try JSONEncoder().encode(ProjectArchive(
                    version: ProjectArchive.currentVersion + 1,
                    projects: archive.projects,
                    yarns: archive.yarns
                )).write(to: archiveURL, options: .atomic)
            }
        )

        #expect(throws: KnitNoteBackupError.unsupportedNewerVersion(10)) {
            _ = try service.stagePackage(at: package.url)
        }
    }

    @Test func futureProjectArchiveIntroducedAfterStagingIsRejectedByInstall() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
        let archiveURL = staged.root.appendingPathComponent("Data/projects-v1.json")
        let archive = try JSONDecoder().decode(
            ProjectArchive.self,
            from: Data(contentsOf: archiveURL)
        )
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion + 1,
            projects: archive.projects,
            yarns: archive.yarns
        )).write(to: archiveURL, options: .atomic)

        #expect(throws: KnitNoteBackupError.unsupportedNewerVersion(10)) {
            _ = try fixture.service.install(staged)
        }
        #expect(try fixture.liveArchiveName() == "original")
    }

    @Test func futureProjectArchiveIsRejectedDuringRecovery() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        try BackupFixture.rewriteLiveArchive(at: fixture.liveRoot) { archive in
            ProjectArchive(
                version: ProjectArchive.currentVersion + 1,
                projects: archive.projects,
                yarns: archive.yarns
            )
        }

        #expect(throws: KnitNoteBackupError.rollbackFailed) {
            try fixture.service.recoverInterruptedReplacement()
        }
        #expect(FileManager.default.fileExists(atPath: fixture.liveRoot.path))
    }

    @Test func manifestArchiveCountMismatchIsRejected() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        try package.rewriteManifest { manifest in
            KnitNoteBackupManifest(
                createdAt: manifest.createdAt,
                appVersion: manifest.appVersion,
                projectCount: manifest.projectCount + 1,
                yarnCount: manifest.yarnCount
            )
        }

        #expect(throws: KnitNoteBackupError.countMismatch) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func duplicateProjectIdentifiersAreRejected() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        try package.rewriteArchive { archive in
            ProjectArchive(
                version: archive.version,
                projects: archive.projects + [archive.projects[0]],
                yarns: archive.yarns
            )
        }

        #expect(throws: KnitNoteBackupError.duplicateIdentifier) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func duplicateYarnIdentifiersAreRejected() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        try package.rewriteArchive { archive in
            ProjectArchive(
                version: archive.version,
                projects: archive.projects,
                yarns: archive.yarns + [archive.yarns[0]]
            )
        }

        #expect(throws: KnitNoteBackupError.duplicateIdentifier) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func danglingYarnProjectLinksAreRejected() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        try package.rewriteArchive { archive in
            var yarn = archive.yarns[0]
            yarn.setLinkedProjectIDs([UUID()])
            return ProjectArchive(
                version: archive.version,
                projects: archive.projects,
                yarns: [yarn]
            )
        }

        #expect(throws: KnitNoteBackupError.invalidYarnProjectLinks) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func perFileLimitUsesResourceMetadataWithoutAllocatingHugeFixture() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let oversizedPath = package.firstReferencedFile.standardizedFileURL.path
        let service = KnitNoteBackupService(
            liveRoot: package.service.liveRoot,
            workRoot: package.service.workRoot,
            resourceMetadata: { url in
                try BackupFixture.metadata(
                    for: url,
                    overridingFileSize: url.standardizedFileURL.path == oversizedPath
                        ? KnitNoteBackupLimits.maximumFileBytes + 1
                        : nil
                )
            }
        )

        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            _ = try service.inspectPackage(at: package.url)
        }
    }

    @Test func aggregateLimitUsesResourceMetadataWithoutAllocatingHugeFixture() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let extraDirectory = package.url.appendingPathComponent(
            "Data/ProjectPhotos",
            isDirectory: true
        )
        for index in 1...21 {
            try Data([UInt8(index)]).write(
                to: extraDirectory.appendingPathComponent("aggregate-\(index).bin")
            )
        }
        let extraPrefix = extraDirectory.standardizedFileURL.path + "/aggregate-"
        let service = KnitNoteBackupService(
            liveRoot: package.service.liveRoot,
            workRoot: package.service.workRoot,
            resourceMetadata: { url in
                let actual = try BackupFixture.actualResourceValues(for: url)
                return try BackupFixture.metadata(
                    for: url,
                    overridingFileSize: url.standardizedFileURL.path.hasPrefix(extraPrefix)
                        && actual.isRegularFile == true
                        ? 199_000_000
                        : nil
                )
            }
        )

        #expect(throws: KnitNoteBackupError.packageTooLarge) {
            _ = try service.inspectPackage(at: package.url)
        }
    }

    @Test func stagingCopiesDataIntoIndependentFreshWorkDirectories() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }

        let first = try package.service.stagePackage(at: package.url)
        let second = try package.service.stagePackage(at: package.url)

        #expect(first.root != second.root)
        #expect(
            first.root.deletingLastPathComponent().standardizedFileURL.path
                == package.service.workRoot.standardizedFileURL.path
        )
        #expect(
            second.root.deletingLastPathComponent().standardizedFileURL.path
                == package.service.workRoot.standardizedFileURL.path
        )
        #expect(first.preview.projectCount == 1)
        #expect(FileManager.default.fileExists(
            atPath: first.root.appendingPathComponent("Data/projects-v1.json").path
        ))
        try FileManager.default.removeItem(at: package.url)
        #expect(FileManager.default.fileExists(
            atPath: first.root.appendingPathComponent("Data/\(package.firstRelativePath)").path
        ))
    }

    @Test func stagingCreatesMissingOwnedWorkRoot() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let destinationRoot = package.cleanupRoot.appendingPathComponent(
            "FreshDestination",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: false
        )
        let workRoot = destinationRoot.appendingPathComponent("Work", isDirectory: true)
        let service = KnitNoteBackupService(
            liveRoot: destinationRoot.appendingPathComponent("KnitNote", isDirectory: true),
            workRoot: workRoot
        )

        let staged = try service.stagePackage(at: package.url)

        #expect(staged.root.deletingLastPathComponent() == workRoot)
        #expect(FileManager.default.fileExists(
            atPath: staged.root.appendingPathComponent("Data/projects-v1.json").path
        ))
    }

    @Test func stagingCreatesWritableAppOwnedFilesFromReadOnlySourceMetadata() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let sourceData = package.url.appendingPathComponent("Data", isDirectory: true)
        try BackupFixture.makeTreeReadOnly(sourceData)

        let staged = try package.service.stagePackage(at: package.url)
        let stagedData = staged.root.appendingPathComponent("Data", isDirectory: true)
        let stagedArchive = stagedData.appendingPathComponent("projects-v1.json")
        let directoryMode = try #require(
            FileManager.default.attributesOfItem(atPath: stagedData.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        let fileMode = try #require(
            FileManager.default.attributesOfItem(atPath: stagedArchive.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        #expect(directoryMode & 0o200 != 0)
        #expect(fileMode & 0o200 != 0)
        let probe = stagedData.appendingPathComponent("post-stage-write-probe")
        try Data("writable".utf8).write(to: probe, options: .atomic)
        #expect(FileManager.default.fileExists(atPath: probe.path))
    }

    @Test func stagingStopsBoundedCopyWhenSourceGrowsAndCleansPartialRoot() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let sourceArchive = package.url.appendingPathComponent("Data/projects-v1.json")
        let growth = StageSourceGrowthInjector(
            target: sourceArchive,
            grownSize: UInt64(KnitNoteBackupLimits.maximumArchiveBytes + 1)
        )
        let before = try BackupFixture.childNames(in: package.service.workRoot)
        let service = KnitNoteBackupService(
            liveRoot: package.service.liveRoot,
            workRoot: package.service.workRoot,
            copyChunkHook: { source, copiedBytes in
                try growth.growOnce(source: source, afterCopiedBytes: copiedBytes)
            }
        )

        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            _ = try service.stagePackage(at: package.url)
        }

        #expect(growth.didGrow)
        #expect(try BackupFixture.childNames(in: package.service.workRoot) == before)
    }

    @Test func stagingRejectsRealDirectorySwapBetweenStatAndDescriptorOpen() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let sourceDirectory = package.url.appendingPathComponent(
            "Data/ProjectPhotos",
            isDirectory: true
        )
        let movedDirectory = package.cleanupRoot.appendingPathComponent(
            "MovedProjectPhotos",
            isDirectory: true
        )
        let replacementDirectory = package.cleanupRoot.appendingPathComponent(
            "ReplacementProjectPhotos",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacementDirectory,
            withIntermediateDirectories: false
        )
        for sourceFile in try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) {
            let isRegular = try sourceFile.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile == true
            guard isRegular else { continue }
            try Data("replacement-file".utf8).write(
                to: replacementDirectory.appendingPathComponent(sourceFile.lastPathComponent)
            )
        }
        let swap = StageSourceDirectorySwapInjector(
            sourceDirectory: sourceDirectory,
            movedDirectory: movedDirectory,
            replacementDirectory: replacementDirectory,
            targetRelativePath: "ProjectPhotos"
        )
        let before = try BackupFixture.childNames(in: package.service.workRoot)
        let service = KnitNoteBackupService(
            liveRoot: package.service.liveRoot,
            workRoot: package.service.workRoot,
            beforeSourceEntryOpen: { try swap.swapOnce(relativePath: $0) }
        )

        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            _ = try service.stagePackage(at: package.url)
        }

        #expect(swap.didSwap)
        #expect(try BackupFixture.childNames(in: package.service.workRoot) == before)
    }

    @Test func stagingSourceContractUsesBoundedContentCopyNotRecursiveCopyItem() throws {
        let sourceURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("copyDataContentsBounded("))
        #expect(source.contains("verifyStagedTreeIsWritable("))
        #expect(!source.contains(
            "copyItem(\n                at: packageRoot.appendingPathComponent(\"Data\""
        ))
    }

    @Test func createPackageRejectsDuplicateIdentifiersAndDanglingLinks() throws {
        let (duplicateService, duplicateLive, duplicateRoot) = try makeServiceFixture()
        defer { try? FileManager.default.removeItem(at: duplicateRoot) }
        _ = try BackupFixture.writeCompleteArchive(to: duplicateLive)
        try BackupFixture.rewriteLiveArchive(at: duplicateLive) { archive in
            ProjectArchive(
                version: archive.version,
                projects: archive.projects + [archive.projects[0]],
                yarns: archive.yarns
            )
        }
        #expect(throws: KnitNoteBackupError.duplicateIdentifier) {
            _ = try duplicateService.createPackage(appVersion: "1.0")
        }

        let (linkService, linkLive, linkRoot) = try makeServiceFixture()
        defer { try? FileManager.default.removeItem(at: linkRoot) }
        _ = try BackupFixture.writeCompleteArchive(to: linkLive)
        try BackupFixture.rewriteLiveArchive(at: linkLive) { archive in
            var yarn = archive.yarns[0]
            yarn.setLinkedProjectIDs([UUID()])
            return ProjectArchive(version: archive.version, projects: archive.projects, yarns: [yarn])
        }
        #expect(throws: KnitNoteBackupError.invalidYarnProjectLinks) {
            _ = try linkService.createPackage(appVersion: "1.0")
        }
    }

    @Test func exportRejectsProjectPhotosDirectorySymlinkAncestor() throws {
        let (service, live, root) = try makeServiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try BackupFixture.writeCompleteArchive(to: live)
        let sourceDirectory = live.appendingPathComponent("ProjectPhotos", isDirectory: true)
        let externalDirectory = root.appendingPathComponent("ExternalProjectPhotos", isDirectory: true)
        try FileManager.default.moveItem(at: sourceDirectory, to: externalDirectory)
        try FileManager.default.createSymbolicLink(
            at: sourceDirectory,
            withDestinationURL: externalDirectory
        )

        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            _ = try service.createPackage(appVersion: "1.0")
        }
    }

    @Test func exportRejectsNestedPatternsDirectorySymlinkAncestor() throws {
        let (service, live, root) = try makeServiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let complete = try BackupFixture.writeCompleteArchive(to: live)
        let patternPath = try #require(
            complete.referencedRelativePaths.first {
                $0.hasPrefix("Patterns/") && !$0.contains("/Markup/")
            }
        )
        let projectDirectoryName = try #require(patternPath.split(separator: "/").dropFirst().first)
        let sourceDirectory = live
            .appendingPathComponent("Patterns", isDirectory: true)
            .appendingPathComponent(String(projectDirectoryName), isDirectory: true)
        let externalDirectory = root.appendingPathComponent("ExternalPatternProject", isDirectory: true)
        try FileManager.default.moveItem(at: sourceDirectory, to: externalDirectory)
        try FileManager.default.createSymbolicLink(
            at: sourceDirectory,
            withDestinationURL: externalDirectory
        )

        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            _ = try service.createPackage(appVersion: "1.0")
        }
    }

    @Test func stagedBackupInitializerIsNotPublicAPI() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains(
            "public init(root: URL, preview: KnitNoteBackupPreview)"
        ))
    }

    @Test(arguments: StageCopyMutation.allCases)
    func stagingRejectsAfterCopyMutationAndCleansPartialRoot(
        _ mutation: StageCopyMutation
    ) throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let before = try BackupFixture.childNames(in: package.service.workRoot)
        let referencedPath = package.firstRelativePath
        let service = KnitNoteBackupService(
            liveRoot: package.service.liveRoot,
            workRoot: package.service.workRoot,
            afterStageCopy: { (stagedRoot: URL) in
                let dataRoot = stagedRoot.appendingPathComponent("Data", isDirectory: true)
                switch mutation {
                case .unknownEntry:
                    try Data("unknown".utf8).write(
                        to: dataRoot.appendingPathComponent("unknown.bin")
                    )
                case .symbolicLink:
                    let referencedFile = dataRoot.appendingPathComponent(referencedPath)
                    try FileManager.default.removeItem(at: referencedFile)
                    try FileManager.default.createSymbolicLink(
                        at: referencedFile,
                        withDestinationURL: dataRoot.appendingPathComponent("projects-v1.json")
                    )
                case .corruptArchive:
                    try Data("{".utf8).write(
                        to: dataRoot.appendingPathComponent("projects-v1.json"),
                        options: .atomic
                    )
                }
            }
        )

        #expect(throws: mutation.expectedError) {
            _ = try service.stagePackage(at: package.url)
        }
        #expect(try BackupFixture.childNames(in: package.service.workRoot) == before)
    }

    @Test func installKeepsRollbackUntilExplicitCommit() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }

        let installation = try fixture.service.install(
            try fixture.service.stagePackage(at: fixture.replacementPackage)
        )

        #expect(try fixture.liveArchiveName() == "replacement")
        #expect(FileManager.default.fileExists(atPath: installation.rollbackRoot.path))
        fixture.service.commit(installation)
        #expect(!FileManager.default.fileExists(atPath: installation.rollbackRoot.path))
        #expect(try fixture.liveArchiveName() == "replacement")
    }

    @Test func installRollbackRestoresOriginalArchive() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let installation = try fixture.service.install(
            try fixture.service.stagePackage(at: fixture.replacementPackage)
        )

        try fixture.service.rollback(installation)

        #expect(try fixture.liveArchiveName() == "original")
        #expect(!FileManager.default.fileExists(atPath: installation.rollbackRoot.path))
    }

    @Test(arguments: [
        KnitNoteBackupReplacementStep.beforeLiveMove,
        .afterLiveMove,
        .afterStagedMove,
    ])
    func installStepFailureRestoresOrPreservesOriginal(
        _ failedStep: KnitNoteBackupReplacementStep
    ) throws {
        let fixture = try BackupInstallFixture.make(failingAt: failedStep)
        defer { fixture.cleanup() }
        let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)

        #expect(throws: KnitNoteBackupError.installFailedOriginalPreserved) {
            _ = try fixture.service.install(staged)
        }

        #expect(try fixture.liveArchiveName() == "original")
        #expect(try fixture.rollbackRoots().isEmpty)
    }

    @Test func installCommitHookFailureKeepsInstalledAndDefersRollbackCleanup() throws {
        let fixture = try BackupInstallFixture.make(failingAt: .beforeCommitCleanup)
        defer { fixture.cleanup() }
        let installation = try fixture.service.install(
            try fixture.service.stagePackage(at: fixture.replacementPackage)
        )

        fixture.service.commit(installation)

        #expect(try fixture.liveArchiveName() == "replacement")
        #expect(FileManager.default.fileExists(atPath: installation.rollbackRoot.path))
        #expect(try fixture.archiveName(at: installation.rollbackRoot) == "original")
    }

    @Test func commitRenamesRollbackBeforeBestEffortRecursiveCleanup() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
        let service = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot,
            cleanupItem: { cleanupRoot in
                guard cleanupRoot.lastPathComponent.hasPrefix("Cleanup-") else {
                    try FileManager.default.removeItem(at: cleanupRoot)
                    return
                }
                try FileManager.default.removeItem(
                    at: cleanupRoot.appendingPathComponent("projects-v1.json")
                )
                throw BackupInstallFixture.InjectedFailure()
            }
        )
        let installation = try service.install(staged)

        service.commit(installation)

        #expect(try fixture.liveArchiveName() == "replacement")
        #expect(!FileManager.default.fileExists(atPath: installation.rollbackRoot.path))
        let cleanupRoot = try #require(fixture.cleanupRoots().first)
        #expect(UUID(uuidString: String(
            cleanupRoot.lastPathComponent.dropFirst("Cleanup-".count)
        )) != nil)
        #expect(!FileManager.default.fileExists(
            atPath: cleanupRoot.appendingPathComponent("projects-v1.json").path
        ))
    }

    @Test func installRollbackFailureReportsTypedFailureWithoutDeletingEitherCopy() throws {
        let fixture = try BackupInstallFixture.make(failingAt: .beforeRollback)
        defer { fixture.cleanup() }
        let installation = try fixture.service.install(
            try fixture.service.stagePackage(at: fixture.replacementPackage)
        )

        #expect(throws: KnitNoteBackupError.rollbackFailed) {
            try fixture.service.rollback(installation)
        }

        #expect(try fixture.liveArchiveName() == "replacement")
        #expect(try fixture.archiveName(at: installation.rollbackRoot) == "original")
    }

    @Test func installRepeatedRollbackNeverDeletesTheRestoredOriginal() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let installation = try fixture.service.install(
            try fixture.service.stagePackage(at: fixture.replacementPackage)
        )
        try fixture.service.rollback(installation)

        #expect(throws: KnitNoteBackupError.rollbackFailed) {
            try fixture.service.rollback(installation)
        }

        #expect(try fixture.liveArchiveName() == "original")
    }

    @Test func installRejectsStagedRootSymlinkBeforeTouchingLive() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
        let alternate = try fixture.service.stagePackage(at: fixture.replacementPackage)
        try FileManager.default.removeItem(at: staged.root)
        try FileManager.default.createSymbolicLink(
            at: staged.root,
            withDestinationURL: alternate.root
        )

        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            _ = try fixture.service.install(staged)
        }

        #expect(try fixture.liveArchiveName() == "original")
        #expect(try fixture.rollbackRoots().isEmpty)
    }

    @Test func stagingRejectsSymbolicWorkRootAncestorBeforeTouchingLive() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let realContainer = fixture.root.appendingPathComponent("RealWorkContainer")
        let realWorkRoot = realContainer.appendingPathComponent("Work")
        let symbolicContainer = fixture.root.appendingPathComponent("SymbolicWorkContainer")
        try FileManager.default.createDirectory(
            at: realWorkRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symbolicContainer,
            withDestinationURL: realContainer
        )
        let service = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: symbolicContainer.appendingPathComponent("Work")
        )
        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            _ = try service.stagePackage(at: fixture.replacementPackage)
        }

        #expect(try fixture.liveArchiveName() == "original")
        #expect(try fixture.rollbackRoots().isEmpty)
    }

    @Test func stagingMissingWorkLeafUnderSymlinkDoesNotCreateOutsideDirectory() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let trustedParent = package.cleanupRoot.appendingPathComponent(
            "TrustedDestination",
            isDirectory: true
        )
        let outsideParent = package.cleanupRoot.appendingPathComponent(
            "OutsideDestination",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: trustedParent,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: outsideParent,
            withIntermediateDirectories: false
        )
        let symbolicParent = trustedParent.appendingPathComponent(
            "SymbolicParent",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: symbolicParent,
            withDestinationURL: outsideParent
        )
        let outsideWorkRoot = outsideParent.appendingPathComponent("Work", isDirectory: true)
        let service = KnitNoteBackupService(
            liveRoot: trustedParent.appendingPathComponent("KnitNote", isDirectory: true),
            workRoot: symbolicParent.appendingPathComponent("Work", isDirectory: true)
        )

        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            _ = try service.stagePackage(at: package.url)
        }

        #expect(!FileManager.default.fileExists(atPath: outsideWorkRoot.path))
    }

    @Test func installRejectsPhysicalVolumeMismatchBeforeTouchingLive() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
        let liveParentPath = fixture.liveRoot.deletingLastPathComponent().standardizedFileURL.path
        let service = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot,
            resourceMetadata: { url in
                try BackupFixture.metadata(
                    for: url,
                    overridingFileSize: nil,
                    physicalVolumeIdentifier: url.standardizedFileURL.path == liveParentPath
                        ? "live-volume"
                        : "work-volume"
                )
            }
        )

        #expect(throws: KnitNoteBackupError.crossVolumeReplacement) {
            _ = try service.install(staged)
        }

        #expect(try fixture.liveArchiveName() == "original")
        #expect(try fixture.rollbackRoots().isEmpty)
        #expect(FileManager.default.fileExists(atPath: staged.root.path))
    }

    @Test func installRejectsWhenOnlyExistingLiveRootIsOnAnotherVolumeBeforeHook() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
        let liveRootPath = fixture.liveRoot.standardizedFileURL.path
        let recorder = ReplacementStepRecorder()
        let service = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot,
            resourceMetadata: { url in
                try BackupFixture.metadata(
                    for: url,
                    overridingFileSize: nil,
                    physicalVolumeIdentifier: url.standardizedFileURL.path == liveRootPath
                        ? "live-root-volume"
                        : "replacement-volume"
                )
            },
            replacementStepHook: { recorder.record($0) }
        )

        #expect(throws: KnitNoteBackupError.crossVolumeReplacement) {
            _ = try service.install(staged)
        }

        #expect(!recorder.steps.contains(.beforeLiveMove))
        #expect(try fixture.liveArchiveName() == "original")
        #expect(try fixture.rollbackRoots().isEmpty)
        #expect(FileManager.default.fileExists(atPath: staged.root.path))
    }

    @Test func installAcceptsMatchingInjectedPhysicalVolumeIdentifiers() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let staged = try fixture.service.stagePackage(at: fixture.replacementPackage)
        let service = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot,
            resourceMetadata: { url in
                try BackupFixture.metadata(
                    for: url,
                    overridingFileSize: nil,
                    physicalVolumeIdentifier: "same-volume"
                )
            }
        )

        let installation = try service.install(staged)

        #expect(try fixture.liveArchiveName() == "replacement")
        #expect(FileManager.default.fileExists(atPath: installation.rollbackRoot.path))
    }

    @Test func installRecoversExactlyOneRollbackWhenLiveRootIsMissing() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let installation = try fixture.service.install(
            try fixture.service.stagePackage(at: fixture.replacementPackage)
        )
        try FileManager.default.removeItem(at: installation.liveRoot)

        try fixture.service.recoverInterruptedReplacement()

        #expect(try fixture.liveArchiveName() == "original")
        #expect(!FileManager.default.fileExists(atPath: installation.rollbackRoot.path))
    }

    @Test func installRecoveryPrefersValidLiveRootAndCleansRollback() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let installation = try fixture.service.install(
            try fixture.service.stagePackage(at: fixture.replacementPackage)
        )

        try fixture.service.recoverInterruptedReplacement()

        #expect(try fixture.liveArchiveName() == "replacement")
        #expect(!FileManager.default.fileExists(atPath: installation.rollbackRoot.path))
    }

    @Test func recoveryRetriesExactCleanupTombstoneAfterValidLiveChoice() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let cleanupRoot = fixture.workRoot.appendingPathComponent(
            "Cleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: cleanupRoot, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: cleanupRoot.appendingPathComponent("partial.tmp"))

        try fixture.service.recoverInterruptedReplacement()

        #expect(try fixture.liveArchiveName() == "original")
        #expect(!FileManager.default.fileExists(atPath: cleanupRoot.path))
    }

    @Test func validLiveChoiceSurvivesUndeletableGeneratedHousekeepingArtifacts() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let installation = try fixture.service.install(
            try fixture.service.stagePackage(at: fixture.replacementPackage)
        )
        let cleanupRoot = fixture.workRoot.appendingPathComponent(
            "Cleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        let exportRoot = fixture.workRoot.appendingPathComponent(
            "\(UUID().uuidString).knitnote-backup",
            isDirectory: true
        )
        let stagedRoot = fixture.workRoot.appendingPathComponent(
            "Staged-\(UUID().uuidString)",
            isDirectory: true
        )
        for artifact in [cleanupRoot, exportRoot, stagedRoot] {
            try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
            try Data("retry".utf8).write(to: artifact.appendingPathComponent("retry.tmp"))
        }
        let service = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot,
            cleanupItem: { _ in throw BackupInstallFixture.InjectedFailure() }
        )

        try service.recoverInterruptedReplacement()

        #expect(try fixture.liveArchiveName() == "replacement")
        for artifact in [installation.rollbackRoot, cleanupRoot, exportRoot, stagedRoot] {
            #expect(FileManager.default.fileExists(atPath: artifact.path))
        }
    }
}

private struct BackupInstallFixture {
    struct InjectedFailure: Error {}

    let root: URL
    let liveRoot: URL
    let workRoot: URL
    let replacementPackage: URL
    let service: KnitNoteBackupService

    static func make(
        failingAt failedStep: KnitNoteBackupReplacementStep? = nil
    ) throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let liveRoot = root.appendingPathComponent("KnitNote", isDirectory: true)
        let workRoot = root.appendingPathComponent("Work", isDirectory: true)
        try writeArchive(named: "original", to: liveRoot)
        let packageBuilder = KnitNoteBackupService(liveRoot: liveRoot, workRoot: workRoot)
        try writeArchive(named: "replacement", to: liveRoot)
        let replacementPackage = try packageBuilder.createPackage(appVersion: "1.0")
        try FileManager.default.removeItem(at: liveRoot)
        try writeArchive(named: "original", to: liveRoot)
        let service = KnitNoteBackupService(
            liveRoot: liveRoot,
            workRoot: workRoot,
            replacementStepHook: { step in
                if step == failedStep { throw InjectedFailure() }
            }
        )
        return Self(
            root: root,
            liveRoot: liveRoot,
            workRoot: workRoot,
            replacementPackage: replacementPackage,
            service: service
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func liveArchiveName() throws -> String {
        try archiveName(at: liveRoot)
    }

    func archiveName(at root: URL) throws -> String {
        let archive = try JSONDecoder().decode(
            ProjectArchive.self,
            from: Data(contentsOf: root.appendingPathComponent("projects-v1.json"))
        )
        return try #require(archive.projects.first?.name)
    }

    func rollbackRoots() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: workRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: workRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("Rollback-") }
    }

    func cleanupRoots() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: workRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: workRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("Cleanup-") }
    }

    private static func writeArchive(named name: String, to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = ProjectArchive(
            version: 9,
            projects: [try StoredProject(name: name)],
            yarns: []
        )
        try JSONEncoder().encode(archive).write(
            to: root.appendingPathComponent("projects-v1.json"),
            options: .atomic
        )
    }
}

enum StageCopyMutation: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case unknownEntry
    case symbolicLink
    case corruptArchive

    var testDescription: String { rawValue }

    var expectedError: KnitNoteBackupError {
        switch self {
        case .unknownEntry:
            .unknownPackageEntry
        case .symbolicLink:
            .unsafePackageEntry
        case .corruptArchive:
            .invalidArchive
        }
    }
}

private func makeServiceFixture() throws -> (KnitNoteBackupService, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let live = root.appendingPathComponent("KnitNote")
    let work = root.appendingPathComponent("Work")
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    return (KnitNoteBackupService(liveRoot: live, workRoot: work), live, root)
}

private enum BackupFixture {
    struct CompleteArchive {
        let referencedRelativePaths: [String]
    }

    struct Package {
        let service: KnitNoteBackupService
        let url: URL
        let cleanupRoot: URL
        let firstRelativePath: String
        let markupRelativePath: String

        var firstReferencedFile: URL {
            url.appendingPathComponent("Data/\(firstRelativePath)")
        }

        func rewriteManifest(
            _ transform: (KnitNoteBackupManifest) throws -> KnitNoteBackupManifest
        ) throws {
            let manifestURL = url.appendingPathComponent("manifest.json")
            let manifest = try JSONDecoder().decode(
                KnitNoteBackupManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            try JSONEncoder().encode(try transform(manifest)).write(
                to: manifestURL,
                options: .atomic
            )
        }

        func rewriteArchive(
            _ transform: (ProjectArchive) throws -> ProjectArchive
        ) throws {
            let archiveURL = url.appendingPathComponent("Data/projects-v1.json")
            let archive = try JSONDecoder().decode(
                ProjectArchive.self,
                from: Data(contentsOf: archiveURL)
            )
            try JSONEncoder().encode(try transform(archive)).write(
                to: archiveURL,
                options: .atomic
            )
        }

        func rewriteMarkup(_ document: PatternMarkupDocument) throws {
            try JSONEncoder().encode(document).write(
                to: url.appendingPathComponent("Data/\(markupRelativePath)"),
                options: .atomic
            )
        }
    }

    static func completePackage() throws -> Package {
        let (service, live, root) = try makeServiceFixture()
        let complete = try writeCompleteArchive(to: live)
        let packageURL = try service.createPackage(appVersion: "1.0", now: .init(timeIntervalSince1970: 10))
        let firstRelativePath = try #require(
            complete.referencedRelativePaths.first(where: { $0.hasPrefix("ProjectPhotos/") })
        )
        let markupRelativePath = try #require(
            complete.referencedRelativePaths.first(where: { $0.contains("/Markup/") })
        )
        return Package(
            service: service,
            url: packageURL,
            cleanupRoot: root,
            firstRelativePath: firstRelativePath,
            markupRelativePath: markupRelativePath
        )
    }

    static func package(projectPhotoFilename filename: String) throws -> Package {
        let package = try completePackage()
        try FileManager.default.removeItem(at: package.firstReferencedFile)
        try package.rewriteArchive { archive in
            var project = archive.projects[0]
            project.setPhotoFilename(filename)
            return ProjectArchive(
                version: archive.version,
                projects: [project],
                yarns: archive.yarns
            )
        }
        return package
    }

    static func packageContainingSymlink() throws -> Package {
        let package = try completePackage()
        let target = package.cleanupRoot.appendingPathComponent("symlink-target.jpg")
        try Data("target".utf8).write(to: target)
        try FileManager.default.removeItem(at: package.firstReferencedFile)
        try FileManager.default.createSymbolicLink(
            at: package.firstReferencedFile,
            withDestinationURL: target
        )
        return package
    }

    static func packageContainingUnknownEntry() throws -> Package {
        let package = try completePackage()
        try Data("unknown".utf8).write(
            to: package.url.appendingPathComponent("Data/unknown.bin")
        )
        return package
    }

    static func packageContainingMalformedMarkup() throws -> Package {
        let package = try completePackage()
        try Data("{".utf8).write(
            to: package.url.appendingPathComponent("Data/\(package.markupRelativePath)"),
            options: .atomic
        )
        return package
    }

    static func writeCompleteArchive(to live: URL) throws -> CompleteArchive {
        let projectID = UUID()
        let yarnID = UUID()
        let patternID = UUID()
        let entryID = UUID()
        let token = UUID()
        let projectPhoto = "\(projectID.uuidString)-\(UUID().uuidString).jpg"
        let yarnPhoto = "\(yarnID.uuidString)-\(UUID().uuidString).jpg"
        let journalStem = "\(projectID.uuidString)-\(entryID.uuidString)-\(token.uuidString)"
        let journalFull = "\(journalStem)-full.jpg"
        let journalThumbnail = "\(journalStem)-thumb.jpg"
        let patternFilename = "\(patternID.uuidString).pdf"

        let entry = try ProjectJournalEntry(
            id: entryID,
            photoFilename: journalFull,
            thumbnailFilename: journalThumbnail,
            caption: "Swatch"
        )
        var project = try StoredProject(
            id: projectID,
            name: "Cardigan",
            journalEntries: [entry]
        )
        project.setPhotoFilename(projectPhoto)
        project.addPattern(PatternDocument(
            id: patternID,
            displayName: "Chart",
            kind: .pdf,
            storedFilename: patternFilename
        ))

        var yarn = try StoredYarn(id: yarnID, name: "Merino")
        yarn.setPhotoFilename(yarnPhoto)
        yarn.setLinkedProjectIDs([projectID])

        let archive = ProjectArchive(version: 9, projects: [project], yarns: [yarn])
        let archivePath = "projects-v1.json"
        let projectPhotoPath = "ProjectPhotos/\(projectPhoto)"
        let yarnPhotoPath = "YarnPhotos/\(yarnPhoto)"
        let journalFullPath = "ProjectJournalPhotos/\(journalFull)"
        let journalThumbnailPath = "ProjectJournalPhotos/\(journalThumbnail)"
        let patternPath = "Patterns/\(projectID.uuidString)/\(patternFilename)"
        let markupPath = "Patterns/\(projectID.uuidString)/Markup/\(patternID.uuidString)/0.json"

        let files: [(String, Data)] = [
            (archivePath, try JSONEncoder().encode(archive)),
            (projectPhotoPath, Data("project-photo".utf8)),
            (yarnPhotoPath, Data("yarn-photo".utf8)),
            (journalFullPath, Data("journal-full".utf8)),
            (journalThumbnailPath, Data("journal-thumbnail".utf8)),
            (markupPath, try JSONEncoder().encode(PatternMarkupDocument())),
        ]
        for (relativePath, data) in files {
            let destination = live.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination)
        }
        let patternURL = live.appendingPathComponent(patternPath)
        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
        let consumer = try #require(CGDataConsumer(url: patternURL as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return CompleteArchive(referencedRelativePaths: files.map(\.0) + [patternPath])
    }

    static func replaceLiveSourceWithExternalSymlink(
        _ source: String,
        live: URL,
        fixture: CompleteArchive
    ) throws {
        let markupPath = try #require(
            fixture.referencedRelativePaths.first(where: { $0.contains("/Markup/") })
        )
        let markupComponents = markupPath.split(separator: "/").map(String.init)
        let relativePath: String
        switch source {
        case "archive":
            relativePath = "projects-v1.json"
        case "project-photos":
            relativePath = "ProjectPhotos"
        case "yarn-photos":
            relativePath = "YarnPhotos"
        case "journal-photos":
            relativePath = "ProjectJournalPhotos"
        case "patterns":
            relativePath = "Patterns"
        case "markup":
            relativePath = markupComponents.prefix(3).joined(separator: "/")
        default:
            Issue.record("Unknown live source fixture: \(source)")
            return
        }

        let original = live.appendingPathComponent(relativePath)
        let externalRoot = live.deletingLastPathComponent()
            .appendingPathComponent("External-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: original, to: externalRoot)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: externalRoot)
    }

    static func rewriteLiveArchive(
        at live: URL,
        _ transform: (ProjectArchive) throws -> ProjectArchive
    ) throws {
        let archiveURL = live.appendingPathComponent("projects-v1.json")
        let archive = try JSONDecoder().decode(
            ProjectArchive.self,
            from: Data(contentsOf: archiveURL)
        )
        try JSONEncoder().encode(try transform(archive)).write(
            to: archiveURL,
            options: .atomic
        )
    }

    static func actualResourceValues(for url: URL) throws -> URLResourceValues {
        try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
    }

    static func childNames(in directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    static func metadata(
        for url: URL,
        overridingFileSize: Int64?,
        physicalVolumeIdentifier: String? = "test-volume"
    ) throws -> (
        isRegularFile: Bool?,
        isDirectory: Bool?,
        isSymbolicLink: Bool?,
        fileSize: Int64?,
        physicalVolumeIdentifier: String?
    ) {
        let values = try actualResourceValues(for: url)
        return (
            isRegularFile: values.isRegularFile,
            isDirectory: values.isDirectory,
            isSymbolicLink: values.isSymbolicLink,
            fileSize: overridingFileSize ?? values.fileSize.map(Int64.init),
            physicalVolumeIdentifier: physicalVolumeIdentifier
        )
    }

    static func makeTreeReadOnly(_ root: URL) throws {
        let enumerator = try #require(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ))
        var entries: [URL] = []
        for case let entry as URL in enumerator { entries.append(entry) }
        for entry in entries.reversed() {
            let isDirectory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            try FileManager.default.setAttributes(
                [.posixPermissions: isDirectory ? 0o500 : 0o400],
                ofItemAtPath: entry.path
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: root.path
        )
    }
}

private final class StageSourceGrowthInjector: @unchecked Sendable {
    private let target: URL
    private let grownSize: UInt64
    private let lock = NSLock()
    private var hasGrown = false

    init(target: URL, grownSize: UInt64) {
        self.target = target.standardizedFileURL
        self.grownSize = grownSize
    }

    var didGrow: Bool {
        lock.withLock { hasGrown }
    }

    func growOnce(source: URL, afterCopiedBytes: Int64) throws {
        guard source.standardizedFileURL == target, afterCopiedBytes > 0 else { return }
        let shouldGrow = lock.withLock {
            guard !hasGrown else { return false }
            hasGrown = true
            return true
        }
        guard shouldGrow else { return }
        let handle = try FileHandle(forWritingTo: target)
        try handle.truncate(atOffset: grownSize)
        try handle.close()
    }
}

private final class ReplacementStepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSteps: [KnitNoteBackupReplacementStep] = []

    var steps: [KnitNoteBackupReplacementStep] {
        lock.withLock { recordedSteps }
    }

    func record(_ step: KnitNoteBackupReplacementStep) {
        lock.withLock { recordedSteps.append(step) }
    }
}

private final class StageSourceDirectorySwapInjector: @unchecked Sendable {
    private let sourceDirectory: URL
    private let movedDirectory: URL
    private let replacementDirectory: URL
    private let targetRelativePath: String
    private let lock = NSLock()
    private var hasSwapped = false

    init(
        sourceDirectory: URL,
        movedDirectory: URL,
        replacementDirectory: URL,
        targetRelativePath: String
    ) {
        self.sourceDirectory = sourceDirectory
        self.movedDirectory = movedDirectory
        self.replacementDirectory = replacementDirectory
        self.targetRelativePath = targetRelativePath
    }

    var didSwap: Bool {
        lock.withLock { hasSwapped }
    }

    func swapOnce(relativePath: String) throws {
        guard relativePath == targetRelativePath else { return }
        let shouldSwap = lock.withLock {
            guard !hasSwapped else { return false }
            hasSwapped = true
            return true
        }
        guard shouldSwap else { return }
        try FileManager.default.moveItem(at: sourceDirectory, to: movedDirectory)
        try FileManager.default.moveItem(at: replacementDirectory, to: sourceDirectory)
    }
}
