import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite struct KnitNoteBackupServiceTests {
    @Test func versionElevenBackupRoundTripsYarnLabelFieldsAndTwoPhotos() throws {
        let (service, live, root) = try makeServiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try StoredProject(name: "Label backup")
        var yarn = try StoredYarn(name: "Belle")
        yarn.setLinkedProjectIDs([project.id])
        try yarn.updateLabelDetails(
            ballWeightGrams: 50,
            lengthMeters: 120,
            fiberContent: "53% Cotton, 33% Viscose, 14% Linen",
            recommendedNeedleMM: try YarnMetricRange(lower: 4, upper: 4.5),
            recommendedHookMM: try YarnMetricRange(lower: 3.5, upper: 4)
        )
        let firstFilename = "\(yarn.id.uuidString)-label-1-\(UUID().uuidString).jpg"
        let secondFilename = "\(yarn.id.uuidString)-label-2-\(UUID().uuidString).jpg"
        try yarn.setLabelPhotoFilenames([firstFilename, secondFilename])
        let archive = ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [project],
            yarns: [yarn]
        )
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(
            to: live.appendingPathComponent("projects-v1.json"),
            options: .atomic
        )
        let labelDirectory = live.appendingPathComponent("YarnLabelPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: labelDirectory, withIntermediateDirectories: true)
        let firstData = try BackupFixture.jpegData(red: 0.2)
        let secondData = try BackupFixture.jpegData(red: 0.8)
        try firstData.write(to: labelDirectory.appendingPathComponent(firstFilename))
        try secondData.write(to: labelDirectory.appendingPathComponent(secondFilename))

        let package = try service.createPackage(appVersion: "1.3.0")
        let preview = try service.inspectPackage(at: package)
        let packagedLabelRoot = package.appendingPathComponent("Data/YarnLabelPhotos")
        #expect(preview.yarnCount == 1)
        #expect(try Data(contentsOf: packagedLabelRoot.appendingPathComponent(firstFilename)) == firstData)
        #expect(try Data(contentsOf: packagedLabelRoot.appendingPathComponent(secondFilename)) == secondData)

        let restoredLive = root.appendingPathComponent("RestoredKnitNote", isDirectory: true)
        let restoreService = KnitNoteBackupService(
            liveRoot: restoredLive,
            workRoot: root.appendingPathComponent("RestoreWork", isDirectory: true)
        )
        let staged = try restoreService.stagePackage(at: package)
        let installation = try restoreService.install(staged)
        restoreService.commit(installation)
        let restoredArchive = try JSONDecoder().decode(
            ProjectArchive.self,
            from: Data(contentsOf: restoredLive.appendingPathComponent("projects-v1.json"))
        )
        let restoredYarn = try #require(restoredArchive.yarns.first)

        #expect(restoredYarn.ballWeightGrams == 50)
        #expect(restoredYarn.lengthMeters == 120)
        #expect(restoredYarn.fiberContent == "53% Cotton, 33% Viscose, 14% Linen")
        #expect(restoredYarn.labelPhotoFilenames == [firstFilename, secondFilename])
        #expect(try Data(
            contentsOf: restoredLive.appendingPathComponent("YarnLabelPhotos/\(firstFilename)")
        ) == firstData)
        #expect(try Data(
            contentsOf: restoredLive.appendingPathComponent("YarnLabelPhotos/\(secondFilename)")
        ) == secondData)
    }

    @Test func versionElevenBackupRejectsInvalidReferencedYarnLabelImage() throws {
        let (service, live, root) = try makeServiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var yarn = try StoredYarn(name: "Invalid label")
        let filename = "\(yarn.id.uuidString)-label-1-\(UUID().uuidString).jpg"
        try yarn.setLabelPhotoFilenames([filename])
        let archive = ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [],
            yarns: [yarn]
        )
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(
            to: live.appendingPathComponent("projects-v1.json"),
            options: .atomic
        )
        let labelDirectory = live.appendingPathComponent("YarnLabelPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: labelDirectory, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: labelDirectory.appendingPathComponent(filename))

        #expect(throws: KnitNoteBackupError.invalidArchive) {
            try service.createPackage(appVersion: "1.3.0")
        }
    }

    @MainActor @Test func formatTwoSchemaTenPatternLibraryRestoresAndMigratesWithoutDataLoss() throws {
        let package = try BackupFixture.schemaTenPatternLibraryPackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let packagedArchive = try JSONDecoder().decode(
            ProjectArchive.self,
            from: Data(contentsOf: package.url.appendingPathComponent("Data/projects-v1.json"))
        )
        let packagedUsage = try #require(packagedArchive.patternUsages.first)
        let packagedAsset = try #require(packagedArchive.patternAssets.first)
        let packagedAssetData = try Data(
            contentsOf: package.url.appendingPathComponent(
                "Data/Patterns/Assets/\(packagedAsset.storedFilename)"
            )
        )
        let packagedMarkup = try Data(
            contentsOf: package.url.appendingPathComponent("Data/\(package.markupRelativePath)")
        )

        let preview = try package.service.inspectPackage(at: package.url)
        #expect(preview.patternCount == 1)

        let restoredLive = package.cleanupRoot.appendingPathComponent("RestoredKnitNote")
        let restoreService = KnitNoteBackupService(
            liveRoot: restoredLive,
            workRoot: package.cleanupRoot.appendingPathComponent("RestoreWork")
        )
        let staged = try restoreService.stagePackage(at: package.url)
        let stagedArchive = try JSONDecoder().decode(
            ProjectArchive.self,
            from: Data(contentsOf: staged.root.appendingPathComponent("Data/projects-v1.json"))
        )
        #expect(stagedArchive.version == 10)

        let installation = try restoreService.install(staged)
        restoreService.commit(installation)
        let installedArchiveURL = restoredLive.appendingPathComponent("projects-v1.json")
        #expect(try JSONDecoder().decode(
            ProjectArchive.self,
            from: Data(contentsOf: installedArchiveURL)
        ).version == 10)

        let restoredStore = JSONProjectStore(url: installedArchiveURL)
        let migratedArchive = try JSONDecoder().decode(
            ProjectArchive.self,
            from: Data(contentsOf: installedArchiveURL)
        )
        let restoredUsage = try #require(restoredStore.patternUsages.first)

        #expect(restoredStore.loadError == nil)
        #expect(migratedArchive.version == ProjectArchive.currentVersion)
        #expect(restoredStore.projects == packagedArchive.projects)
        #expect(restoredStore.yarns == packagedArchive.yarns)
        #expect(restoredStore.patternAssets == packagedArchive.patternAssets)
        #expect(restoredStore.patterns == packagedArchive.patterns)
        #expect(restoredStore.patternUsages == packagedArchive.patternUsages)
        #expect(restoredUsage.readingState.pdfWidthScaleRatio == 1.0)
        #expect(restoredUsage.readingState.pageStates[2]?.note == "Cable repeat")
        #expect(try Data(
            contentsOf: restoredLive.appendingPathComponent(
                "Patterns/Assets/\(packagedAsset.storedFilename)"
            )
        ) == packagedAssetData)
        #expect(try Data(
            contentsOf: restoredLive.appendingPathComponent(package.markupRelativePath)
        ) == packagedMarkup)
        #expect(restoredUsage.id == packagedUsage.id)
    }

    @Test func schemaNineBackupStillRejectsPatternLibraryCollections() throws {
        let package = try BackupFixture.patternLibraryPackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        try package.rewriteArchive { archive in
            ProjectArchive(
                version: 9,
                projects: archive.projects,
                yarns: archive.yarns,
                patternAssets: archive.patternAssets,
                patterns: archive.patterns,
                patternUsages: archive.patternUsages
            )
        }

        #expect(throws: KnitNoteBackupError.invalidArchive) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func formatTwoExportListsExactSchemaTenPatternFilesAndIntegrity() throws {
        let (service, live, root) = try makeServiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try BackupFixture.writePatternLibraryArchive(to: live)
        try BackupFixture.writeExcludedPatternArtifacts(to: live)

        let package = try service.createPackage(
            appVersion: "1.2.0",
            now: .init(timeIntervalSince1970: 20)
        )
        let manifest = try JSONDecoder().decode(
            KnitNoteBackupManifest.self,
            from: Data(contentsOf: package.appendingPathComponent("manifest.json"))
        )

        #expect(manifest.formatVersion == 2)
        #expect(manifest.patternCount == 1)
        #expect(Set(manifest.files.map(\.relativePath)) == Set(fixture.referencedRelativePaths))
        #expect(manifest.criticalFeatures == [KnitNoteBackupManifest.fileIntegrityFeature])
        for entry in manifest.files {
            let data = try Data(
                contentsOf: package.appendingPathComponent("Data/\(entry.relativePath)")
            )
            #expect(entry.byteCount == Int64(data.count))
            #expect(entry.sha256 == BackupFixture.sha256(data))
        }
        let packagedPaths = Set(try BackupFixture.relativeFilePaths(
            below: package.appendingPathComponent("Data", isDirectory: true)
        ))
        #expect(packagedPaths == Set(fixture.referencedRelativePaths))
        #expect(!packagedPaths.contains { path in
            path.contains("Thumbnail")
                || path.contains("Inbox")
                || path.contains("PublicationReceipts")
                || path.contains("Quarantine")
                || path.contains("Candidates")
                || path.contains("Transactions")
        })
    }

    @Test func versionTwelveYouTubeBackupRoundTripsTwoUsagesWithoutCachedMedia() throws {
        let fixture = try BackupFixture.youtubePackage()
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        let manifest = try fixture.manifest
        let packagedPaths = Set(try BackupFixture.relativeFilePaths(
            below: fixture.url.appendingPathComponent("Data", isDirectory: true)
        ))
        let sidecarPath = "Patterns/Assets/\(fixture.asset.storedFilename)"

        #expect(manifest.formatVersion == 2)
        #expect(manifest.files.contains { $0.relativePath == sidecarPath })
        #expect(packagedPaths.contains(sidecarPath))
        #expect(!packagedPaths.contains { path in
            path.contains("PatternThumbnailCache")
                || path.hasSuffix(".jpg")
                || path.hasSuffix(".jpeg")
                || path.hasSuffix(".mp4")
                || path.hasSuffix(".mov")
        })

        let restoredLive = fixture.cleanupRoot.appendingPathComponent("RestoredKnitNote")
        try BackupFixture.writeDisposableArchive(to: restoredLive)
        let restoreService = KnitNoteBackupService(
            liveRoot: restoredLive,
            workRoot: fixture.cleanupRoot.appendingPathComponent("RestoreWork")
        )
        let staged = try restoreService.stagePackage(at: fixture.url)
        let installation = try restoreService.install(staged)
        restoreService.commit(installation)

        let restoredArchive = try JSONDecoder().decode(
            ProjectArchive.self,
            from: Data(contentsOf: restoredLive.appendingPathComponent("projects-v1.json"))
        )
        let restoredPattern = try #require(restoredArchive.patterns.first)
        let restoredUsages = restoredArchive.patternUsages.sorted { $0.projectID.uuidString < $1.projectID.uuidString }
        let expectedUsages = fixture.archive.patternUsages.sorted { $0.projectID.uuidString < $1.projectID.uuidString }
        let restoredAsset = try #require(restoredArchive.patternAssets.first)

        #expect(restoredPattern.displayName == "Custom cable tutorial")
        #expect(restoredPattern.note == "Use the sleeve section twice")
        #expect(restoredUsages == expectedUsages)
        #expect(restoredUsages.map(\.projectID) == fixture.projectIDs.sorted { $0.uuidString < $1.uuidString })
        #expect(restoredUsages.contains { !$0.isActive && $0.unlinkedAt != nil })
        #expect(try YouTubePatternMetadata(
            link: try YouTubePatternLink(videoID: "dQw4w9WgXcQ")
        ).validated().canonicalURL == fixture.link.canonicalURL)
        #expect(restoredAsset == fixture.asset)
        #expect(try JSONDecoder().decode(
            YouTubePatternMetadata.self,
            from: Data(contentsOf: restoredLive.appendingPathComponent(sidecarPath))
        ).validated() == fixture.link)
        #expect(!FileManager.default.fileExists(
            atPath: restoredLive.appendingPathComponent("PatternThumbnailCache/\(fixture.asset.id.uuidString).jpg").path
        ))
        #expect(throws: PatternThumbnailFileError.unreadableSource) {
            _ = try PatternThumbnailFileService(
                directory: fixture.cleanupRoot.appendingPathComponent("RestoredCache")
            ).thumbnailURL(
                asset: restoredAsset,
                sourceURL: restoredLive.appendingPathComponent(sidecarPath)
            )
        }
    }

    @Test func versionTwelveYouTubeBackupRejectsInvalidSidecarsBeforeReplacingLiveData() throws {
        for mutation in YouTubeSidecarBackupMutation.allCases {
            let fixture = try BackupFixture.youtubePackage()
            defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
            try fixture.mutateYouTubeSidecar(mutation)

            let restoredLive = fixture.cleanupRoot.appendingPathComponent("RestoredKnitNote")
            try BackupFixture.writeDisposableArchive(to: restoredLive)
            let restoreService = KnitNoteBackupService(
                liveRoot: restoredLive,
                workRoot: fixture.cleanupRoot.appendingPathComponent("RestoreWork")
            )

            #expect(throws: KnitNoteBackupError.self) {
                _ = try restoreService.stagePackage(at: fixture.url)
            }
            let liveArchive = try JSONDecoder().decode(
                ProjectArchive.self,
                from: Data(contentsOf: restoredLive.appendingPathComponent("projects-v1.json"))
            )
            #expect(liveArchive.projects.map(\.name) == ["Disposable"])
        }
    }

    @Test func formatTwoInspectionRejectsSameSizeContentTampering() throws {
        let package = try BackupFixture.patternLibraryPackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let assetPath = try #require(
            package.manifest.files.first { $0.relativePath.hasPrefix("Patterns/Assets/") }
        ).relativePath
        let assetURL = package.url.appendingPathComponent("Data/\(assetPath)")
        let original = try Data(contentsOf: assetURL)
        try Data(repeating: 0x5A, count: original.count).write(to: assetURL, options: .atomic)

        #expect(throws: KnitNoteBackupError.integrityMismatch(assetPath)) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test(arguments: [
        "/tmp/absolute.pdf",
        "../traversal.pdf",
        "Patterns/../escape.pdf",
        #"Patterns\Assets\escape.pdf"#,
    ])
    func formatTwoInspectionRejectsUnsafeManifestPaths(_ unsafePath: String) throws {
        let package = try BackupFixture.patternLibraryPackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        try package.rewriteManifest { manifest in
            var files = manifest.files
            let first = files.removeFirst()
            files.insert(
                .init(
                    relativePath: unsafePath,
                    byteCount: first.byteCount,
                    sha256: first.sha256
                ),
                at: 0
            )
            return manifest.replacing(files: files)
        }

        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func formatTwoInspectionRejectsDuplicateAndCaseCollidingPaths() throws {
        for useUppercase in [false, true] {
            let package = try BackupFixture.patternLibraryPackage()
            defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
            let first = try #require(package.manifest.files.first)
            let duplicatePath = useUppercase
                ? first.relativePath.uppercased()
                : first.relativePath
            try package.rewriteManifest { manifest in
                manifest.replacing(files: manifest.files + [
                    .init(
                        relativePath: duplicatePath,
                        byteCount: first.byteCount,
                        sha256: first.sha256
                    ),
                ])
            }
            #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
                _ = try package.service.inspectPackage(at: package.url)
            }
        }
    }

    @Test func formatTwoInspectionRejectsUnknownCriticalFeature() throws {
        let package = try BackupFixture.patternLibraryPackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        try package.rewriteManifest { manifest in
            manifest.replacing(
                criticalFeatures: manifest.criticalFeatures + ["future-required-semantics"]
            )
        }

        #expect(throws: KnitNoteBackupError.invalidManifest) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

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
        try package.downgradeManifestToVersionOne()
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

    @Test(arguments: ["legacy", "usage"])
    func exportRejectsMarkupOwnerAboveEntryLimitWithoutLeavingPackage(
        _ ownerKind: String
    ) throws {
        let package = try ownerKind == "legacy"
            ? BackupFixture.completePackage()
            : BackupFixture.patternLibraryPackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let owner = package.service.liveRoot
            .appendingPathComponent(package.markupRelativePath)
            .deletingLastPathComponent()
        let documentData = try JSONEncoder().encode(PatternMarkupDocument())
        for page in 1...KnitNoteBackupLimits.maximumMarkupEntriesPerPattern {
            try documentData.write(to: owner.appendingPathComponent("\(page + 1_000).json"))
        }
        let before = try BackupFixture.childNames(in: package.service.workRoot)

        #expect(throws: KnitNoteBackupError.invalidMarkup) {
            _ = try package.service.createPackage(appVersion: "1.2.0")
        }

        #expect(try BackupFixture.childNames(in: package.service.workRoot) == before)
    }

    @Test(arguments: ["legacy", "usage"])
    func exportRejectsMarkupOwnerSwapDuringDescriptorDiscovery(
        _ ownerKind: String
    ) throws {
        let package = try ownerKind == "legacy"
            ? BackupFixture.completePackage()
            : BackupFixture.patternLibraryPackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let ownerPath = package.markupRelativePath
            .split(separator: "/")
            .dropLast()
            .joined(separator: "/")
        let sourceDirectory = package.service.liveRoot.appendingPathComponent(
            ownerPath,
            isDirectory: true
        )
        let movedDirectory = package.cleanupRoot.appendingPathComponent(
            "MovedMarkup-\(ownerKind)",
            isDirectory: true
        )
        let replacementDirectory = package.cleanupRoot.appendingPathComponent(
            "ReplacementMarkup-\(ownerKind)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacementDirectory,
            withIntermediateDirectories: false
        )
        try JSONEncoder().encode(PatternMarkupDocument()).write(
            to: replacementDirectory.appendingPathComponent("0.json")
        )
        let swap = StageSourceDirectorySwapInjector(
            sourceDirectory: sourceDirectory,
            movedDirectory: movedDirectory,
            replacementDirectory: replacementDirectory,
            targetRelativePath: "\(ownerPath)/.enumerating"
        )
        let before = try BackupFixture.childNames(in: package.service.workRoot)
        let service = KnitNoteBackupService(
            liveRoot: package.service.liveRoot,
            workRoot: package.service.workRoot,
            beforeSourceEntryOpen: { try swap.swapOnce(relativePath: $0) }
        )

        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            _ = try service.createPackage(appVersion: "1.2.0")
        }

        #expect(swap.didSwap)
        #expect(try BackupFixture.childNames(in: package.service.workRoot) == before)
    }

    @Test(arguments: ["legacy", "usage"])
    func exportRejectsUnsupportedAndSymlinkMarkupEntries(_ ownerKind: String) throws {
        let package = try ownerKind == "legacy"
            ? BackupFixture.completePackage()
            : BackupFixture.patternLibraryPackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let owner = package.service.liveRoot
            .appendingPathComponent(package.markupRelativePath)
            .deletingLastPathComponent()
        let unsupported = owner.appendingPathComponent("notes.txt")
        try Data("not markup".utf8).write(to: unsupported)

        #expect(throws: KnitNoteBackupError.unknownPackageEntry) {
            _ = try package.service.createPackage(appVersion: "1.2.0")
        }

        try FileManager.default.removeItem(at: unsupported)
        let symlink = owner.appendingPathComponent("99.json")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: package.service.liveRoot
                .appendingPathComponent(package.markupRelativePath)
        )
        #expect(throws: KnitNoteBackupError.unknownPackageEntry) {
            _ = try package.service.createPackage(appVersion: "1.2.0")
        }
    }

    @Test func descriptorMarkupDiscoveryProducesDeterministicManifestOrder() throws {
        let package = try BackupFixture.patternLibraryPackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let owner = package.service.liveRoot
            .appendingPathComponent(package.markupRelativePath)
            .deletingLastPathComponent()
        let documentData = try JSONEncoder().encode(PatternMarkupDocument())
        for page in [9, 1, 7, 3] {
            try documentData.write(to: owner.appendingPathComponent("\(page).json"))
        }

        let first = try package.service.createPackage(appVersion: "1.2.0")
        let second = try package.service.createPackage(appVersion: "1.2.0")
        let firstManifest = try JSONDecoder().decode(
            KnitNoteBackupManifest.self,
            from: Data(contentsOf: first.appendingPathComponent("manifest.json"))
        )
        let secondManifest = try JSONDecoder().decode(
            KnitNoteBackupManifest.self,
            from: Data(contentsOf: second.appendingPathComponent("manifest.json"))
        )
        let firstPaths = firstManifest.files.map(\.relativePath)
        let secondPaths = secondManifest.files.map(\.relativePath)
        #expect(firstPaths == firstPaths.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
        #expect(secondPaths == firstPaths)
    }

    @Test func markupStrokeCapAcceptsExactAndRejectsLimitPlusOne() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        try package.downgradeManifestToVersionOne()
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
        try package.downgradeManifestToVersionOne()
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
        try package.downgradeManifestToVersionOne()
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

        #expect(throws: KnitNoteBackupError.unsupportedNewerVersion(3)) {
            _ = try package.service.inspectPackage(at: package.url)
        }
    }

    @Test func projectArchiveDeclaresSharedCurrentAndSupportedLegacyVersions() {
        #expect(ProjectArchive.currentVersion == 12)
        #expect(ProjectArchive.minimumSupportedVersion == 1)
        for version in 1...11 {
            #expect(ProjectArchive.isSupported(version: version))
        }
        #expect(ProjectArchive.isSupported(version: ProjectArchive.currentVersion))
        #expect(!ProjectArchive.isSupported(version: 0))
        #expect(!ProjectArchive.isSupported(version: ProjectArchive.currentVersion + 1))
    }

    @Test func patternLibrarySupportIsBoundedByIntroducedAndCurrentVersions() {
        #expect(!ProjectArchive.supportsPatternLibrary(version: 9))
        #expect(ProjectArchive.supportsPatternLibrary(version: 10))
        #expect(ProjectArchive.supportsPatternLibrary(version: 11))
        #expect(ProjectArchive.supportsPatternLibrary(version: 12))
        #expect(!ProjectArchive.supportsPatternLibrary(version: 13))
    }

    @Test func supportedLegacyProjectArchiveIsAcceptedDuringInspection() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        try package.downgradeManifestToVersionOne()
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
        #expect(throws: KnitNoteBackupError.unsupportedNewerVersion(ProjectArchive.currentVersion + 1)) {
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
        #expect(throws: KnitNoteBackupError.unsupportedNewerVersion(ProjectArchive.currentVersion + 1)) {
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

        #expect(throws: KnitNoteBackupError.unsupportedNewerVersion(ProjectArchive.currentVersion + 1)) {
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

        #expect(throws: KnitNoteBackupError.unsupportedNewerVersion(ProjectArchive.currentVersion + 1)) {
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
                formatVersion: manifest.formatVersion,
                createdAt: manifest.createdAt,
                appVersion: manifest.appVersion,
                projectCount: manifest.projectCount + 1,
                yarnCount: manifest.yarnCount,
                patternCount: manifest.patternCount,
                files: manifest.files,
                criticalFeatures: manifest.criticalFeatures
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

    @Test func exportStopsWhenSourceGrowsAndCleansPartialPackage() throws {
        let package = try BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: package.cleanupRoot) }
        let target = package.service.liveRoot.appendingPathComponent(package.firstRelativePath)
        let growth = StageSourceGrowthInjector(
            target: target,
            grownSize: UInt64(KnitNoteBackupLimits.maximumFileBytes + 1)
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
            _ = try service.createPackage(appVersion: "1.0")
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

    @Test func exportSourceContractUsesBoundedDescriptorCopy() throws {
        let sourceURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("readLiveRegularFileBounded("))
        #expect(source.contains("copyLiveRegularFileBounded("))
        #expect(!source.contains("archiveData = try Data(contentsOf: archiveURL)"))
        #expect(!source.contains("try FileManager.default.copyItem(at: source, to: destination)"))
    }

    @Test func exportRejectsSparseOversizedArchiveWithoutLeavingPackage() throws {
        let (service, live, root) = try makeServiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try BackupFixture.writeCompleteArchive(to: live)
        let archiveURL = live.appendingPathComponent("projects-v1.json")
        let handle = try FileHandle(forWritingTo: archiveURL)
        try handle.truncate(atOffset: UInt64(KnitNoteBackupLimits.maximumArchiveBytes + 1))
        try handle.close()
        try FileManager.default.createDirectory(
            at: service.workRoot,
            withIntermediateDirectories: true
        )
        let before = try BackupFixture.childNames(in: service.workRoot)

        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            _ = try service.createPackage(appVersion: "1.0")
        }

        #expect(try BackupFixture.childNames(in: service.workRoot) == before)
    }

    @Test func exportRejectsSparseAggregateBeforeCopyingAnyFile() throws {
        let (service, live, root) = try makeServiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var projects: [StoredProject] = []
        for _ in 0..<21 {
            var project = try StoredProject(name: "Aggregate")
            let patternID = UUID()
            let pattern = PatternDocument(
                id: patternID,
                displayName: "Aggregate",
                kind: .pdf,
                storedFilename: "\(patternID.uuidString).pdf"
            )
            project.addPattern(pattern)
            projects.append(project)
            let file = live
                .appendingPathComponent("Patterns/\(project.id.uuidString)")
                .appendingPathComponent(pattern.storedFilename)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 199_000_000)
            try handle.close()
        }
        try JSONEncoder().encode(ProjectArchive(version: 9, projects: projects)).write(
            to: live.appendingPathComponent("projects-v1.json"),
            options: .atomic
        )
        try FileManager.default.createDirectory(
            at: service.workRoot,
            withIntermediateDirectories: true
        )
        let before = try BackupFixture.childNames(in: service.workRoot)

        #expect(throws: KnitNoteBackupError.packageTooLarge) {
            _ = try service.createPackage(appVersion: "1.0")
        }

        #expect(try BackupFixture.childNames(in: service.workRoot) == before)
    }

    @Test func exportRejectsSparseOversizedPatternAsset() throws {
        let (service, live, root) = try makeServiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try StoredProject(name: "Oversized asset")
        let patternID = UUID()
        let pattern = PatternDocument(
            id: patternID,
            displayName: "Oversized asset",
            kind: .pdf,
            storedFilename: "\(patternID.uuidString).pdf"
        )
        project.addPattern(pattern)
        let file = live
            .appendingPathComponent("Patterns/\(project.id.uuidString)")
            .appendingPathComponent(pattern.storedFilename)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(KnitNoteBackupLimits.maximumFileBytes + 1))
        try handle.close()
        try JSONEncoder().encode(ProjectArchive(version: 9, projects: [project])).write(
            to: live.appendingPathComponent("projects-v1.json"),
            options: .atomic
        )

        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            _ = try service.createPackage(appVersion: "1.0")
        }
    }

    @Test func exportRejectsSparseOversizedMarkup() throws {
        let (service, live, root) = try makeServiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try StoredProject(name: "Oversized markup")
        let patternID = UUID()
        let pattern = PatternDocument(
            id: patternID,
            displayName: "Oversized markup",
            kind: .pdf,
            storedFilename: "\(patternID.uuidString).pdf"
        )
        project.addPattern(pattern)
        let patternRoot = live.appendingPathComponent("Patterns/\(project.id.uuidString)")
        try FileManager.default.createDirectory(
            at: patternRoot,
            withIntermediateDirectories: true
        )
        try Data("bounded source".utf8).write(
            to: patternRoot.appendingPathComponent(pattern.storedFilename)
        )
        let markup = patternRoot
            .appendingPathComponent("Markup/\(pattern.id.uuidString)")
            .appendingPathComponent("0.json")
        try FileManager.default.createDirectory(
            at: markup.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(atPath: markup.path, contents: nil))
        let handle = try FileHandle(forWritingTo: markup)
        try handle.truncate(atOffset: UInt64(KnitNoteBackupLimits.maximumMarkupBytes + 1))
        try handle.close()
        try JSONEncoder().encode(ProjectArchive(version: 9, projects: [project])).write(
            to: live.appendingPathComponent("projects-v1.json"),
            options: .atomic
        )

        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            _ = try service.createPackage(appVersion: "1.0")
        }
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

    @Test func rollbackSynchronizesEveryMutationParentBeforeRolledBackJournal() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let installation = try fixture.service.install(
            try fixture.service.stagePackage(at: fixture.replacementPackage)
        )
        let recorder = RollbackDurabilityRecorder()
        let service = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot,
            replacementStepHook: { recorder.record(step: $0) },
            synchronizeDirectory: { try recorder.synchronize($0) }
        )

        try service.rollback(installation)

        let events = recorder.events
        let removal = try #require(events.firstIndex(of: "step:afterRollbackLiveRemoval"))
        let restore = try #require(events.firstIndex(of: "step:afterRollbackRestore"))
        let finalized = try #require(events.firstIndex(of: "step:afterRollbackFinalized"))
        let liveParent = "sync:\(fixture.liveRoot.deletingLastPathComponent().standardizedFileURL.path)"
        let rollbackParent = "sync:\(fixture.workRoot.standardizedFileURL.path)"
        #expect(events[(removal + 1)..<finalized].contains(liveParent))
        #expect(events[(restore + 1)..<finalized].contains(liveParent))
        #expect(events[(restore + 1)..<finalized].contains(rollbackParent))
    }

    @Test func rollbackSynchronizesSharedRenameParentOnceBeforeJournalSync() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let installed = try fixture.service.install(
            try fixture.service.stagePackage(at: fixture.replacementPackage)
        )
        let sharedParent = fixture.liveRoot.deletingLastPathComponent()
        let sharedRollback = sharedParent.appendingPathComponent(
            "Rollback-\(installed.transactionID.uuidString)",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: installed.rollbackRoot,
            to: sharedRollback
        )
        let installation = KnitNoteBackupInstallation(
            liveRoot: installed.liveRoot,
            rollbackRoot: sharedRollback,
            hadLiveRoot: true,
            transactionID: installed.transactionID
        )
        let recorder = RollbackDurabilityRecorder()
        let service = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot,
            replacementStepHook: { recorder.record(step: $0) },
            synchronizeDirectory: { try recorder.synchronize($0) }
        )

        try service.rollback(installation)

        let events = recorder.events
        let restore = try #require(events.firstIndex(of: "step:afterRollbackRestore"))
        let finalized = try #require(events.firstIndex(of: "step:afterRollbackFinalized"))
        let sharedSync = "sync:\(sharedParent.standardizedFileURL.path)"
        #expect(events[(restore + 1)..<finalized].filter { $0 == sharedSync }.count == 1)
    }

    @Test func rollbackParentSyncFailureKeepsRollingBackEvidenceForRestart() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let originalBytes = try Data(
            contentsOf: fixture.liveRoot.appendingPathComponent("projects-v1.json")
        )
        let installation = try fixture.service.install(
            try fixture.service.stagePackage(at: fixture.replacementPackage)
        )
        let recorder = RollbackDurabilityRecorder(
            failingDirectory: fixture.liveRoot.deletingLastPathComponent(),
            failAfterStep: .afterRollbackLiveRemoval
        )
        let service = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot,
            replacementStepHook: { recorder.record(step: $0) },
            synchronizeDirectory: { try recorder.synchronize($0) }
        )

        #expect(throws: KnitNoteBackupError.rollbackFailed) {
            try service.rollback(installation)
        }

        #expect(try fixture.journalPhase() == "rollingBack")
        let restarted = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot
        )
        #expect(try restarted.recoverInterruptedReplacement().map { _ in true } == nil)
        #expect(try Data(
            contentsOf: fixture.liveRoot.appendingPathComponent("projects-v1.json")
        ) == originalBytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.replacementJournal.path))
    }

    @Test func interruptedRollbackRecoverySyncFailureKeepsEvidenceForNextRestart() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let originalBytes = try Data(
            contentsOf: fixture.liveRoot.appendingPathComponent("projects-v1.json")
        )
        let crashing = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot,
            replacementStepHook: { step in
                if step == .afterRollbackRestore {
                    throw BackupInstallFixture.InjectedFailure()
                }
            }
        )
        let installation = try crashing.install(
            try crashing.stagePackage(at: fixture.replacementPackage)
        )
        #expect(throws: KnitNoteBackupError.rollbackFailed) {
            try crashing.rollback(installation)
        }
        #expect(try fixture.journalPhase() == "rollingBack")
        let recorder = RollbackDurabilityRecorder(
            failingDirectory: fixture.liveRoot.deletingLastPathComponent()
        )
        let failingRecovery = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot,
            replacementStepHook: { _ in },
            synchronizeDirectory: { try recorder.synchronize($0) }
        )

        #expect(throws: KnitNoteBackupError.rollbackFailed) {
            _ = try failingRecovery.recoverInterruptedReplacement()
        }

        #expect(try fixture.journalPhase() == "rollingBack")
        let restarted = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot
        )
        #expect(try restarted.recoverInterruptedReplacement().map { _ in true } == nil)
        #expect(try Data(
            contentsOf: fixture.liveRoot.appendingPathComponent("projects-v1.json")
        ) == originalBytes)
    }

    @Test(arguments: ["rollback", "cleanup"])
    func rolledBackRecoveryPrefersAvailableOriginalOverReplacementLive(
        _ evidenceKind: String
    ) throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let originalBytes = try Data(
            contentsOf: fixture.liveRoot.appendingPathComponent("projects-v1.json")
        )
        let service = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot,
            replacementStepHook: { step in
                if step == .afterRollbackFinalized {
                    throw BackupInstallFixture.InjectedFailure()
                }
            }
        )
        let installation = try service.install(
            try service.stagePackage(at: fixture.replacementPackage)
        )
        let replacementCopy = fixture.root.appendingPathComponent("ReplacementCopy")
        let originalCopy = fixture.root.appendingPathComponent("OriginalCopy")
        try FileManager.default.copyItem(at: fixture.liveRoot, to: replacementCopy)
        try FileManager.default.copyItem(at: installation.rollbackRoot, to: originalCopy)
        #expect(throws: KnitNoteBackupError.rollbackFailed) {
            try service.rollback(installation)
        }
        #expect(try fixture.journalPhase() == "rolledBack")
        try FileManager.default.removeItem(at: fixture.liveRoot)
        try FileManager.default.copyItem(at: replacementCopy, to: fixture.liveRoot)
        let evidenceRoot = evidenceKind == "rollback"
            ? installation.rollbackRoot
            : fixture.workRoot.appendingPathComponent(
                "Cleanup-\(installation.transactionID.uuidString)",
                isDirectory: true
            )
        try FileManager.default.copyItem(at: originalCopy, to: evidenceRoot)

        let restarted = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot
        )
        #expect(try restarted.recoverInterruptedReplacement().map { _ in true } == nil)

        #expect(try Data(
            contentsOf: fixture.liveRoot.appendingPathComponent("projects-v1.json")
        ) == originalBytes)
        #expect(!FileManager.default.fileExists(atPath: installation.rollbackRoot.path))
        #expect(!FileManager.default.fileExists(atPath: evidenceRoot.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.replacementJournal.path))
    }

    @Test func rolledBackRecoveryWithoutOriginalRemovesInconsistentLive() throws {
        let fixture = try BackupInstallFixture.make(hadLiveRoot: false)
        defer { fixture.cleanup() }
        let service = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot,
            replacementStepHook: { step in
                if step == .afterRollbackFinalized {
                    throw BackupInstallFixture.InjectedFailure()
                }
            }
        )
        let installation = try service.install(
            try service.stagePackage(at: fixture.replacementPackage)
        )
        let replacementCopy = fixture.root.appendingPathComponent("ReplacementCopy")
        try FileManager.default.copyItem(at: fixture.liveRoot, to: replacementCopy)
        #expect(throws: KnitNoteBackupError.rollbackFailed) {
            try service.rollback(installation)
        }
        #expect(try fixture.journalPhase() == "rolledBack")
        try FileManager.default.copyItem(at: replacementCopy, to: fixture.liveRoot)

        let restarted = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot
        )
        #expect(try restarted.recoverInterruptedReplacement().map { _ in true } == nil)

        #expect(!FileManager.default.fileExists(atPath: fixture.liveRoot.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.replacementJournal.path))
    }

    @Test(arguments: [
        KnitNoteBackupReplacementStep.afterRollbackJournal,
        .afterRollbackLiveRemoval,
        .afterRollbackRestore,
        .afterRollbackFinalized,
    ])
    func interruptedRollbackWithOriginalLiveTreeFinishesIdempotently(
        _ failedStep: KnitNoteBackupReplacementStep
    ) throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let originalBytes = try Data(
            contentsOf: fixture.liveRoot.appendingPathComponent("projects-v1.json")
        )
        let service = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot,
            replacementStepHook: { step in
                if step == failedStep { throw BackupInstallFixture.InjectedFailure() }
            }
        )
        let installation = try service.install(
            try service.stagePackage(at: fixture.replacementPackage)
        )

        #expect(throws: KnitNoteBackupError.rollbackFailed) {
            try service.rollback(installation)
        }

        let restarted = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot
        )
        #expect(try restarted.recoverInterruptedReplacement() == nil)
        #expect(try Data(
            contentsOf: fixture.liveRoot.appendingPathComponent("projects-v1.json")
        ) == originalBytes)
        #expect(try fixture.rollbackRoots().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.workRoot.appendingPathComponent(".ReplacementJournal.json").path
        ))
        #expect(try restarted.recoverInterruptedReplacement() == nil)
    }

    @Test(arguments: [
        KnitNoteBackupReplacementStep.afterRollbackJournal,
        .afterRollbackLiveRemoval,
        .afterRollbackRestore,
        .afterRollbackFinalized,
    ])
    func interruptedRollbackWithoutOriginalLiveTreeFinishesIdempotently(
        _ failedStep: KnitNoteBackupReplacementStep
    ) throws {
        let fixture = try BackupInstallFixture.make(hadLiveRoot: false)
        defer { fixture.cleanup() }
        let service = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot,
            replacementStepHook: { step in
                if step == failedStep { throw BackupInstallFixture.InjectedFailure() }
            }
        )
        let installation = try service.install(
            try service.stagePackage(at: fixture.replacementPackage)
        )

        #expect(throws: KnitNoteBackupError.rollbackFailed) {
            try service.rollback(installation)
        }

        let restarted = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot
        )
        #expect(try restarted.recoverInterruptedReplacement() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.liveRoot.path))
        #expect(try fixture.rollbackRoots().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.workRoot.appendingPathComponent(".ReplacementJournal.json").path
        ))
        #expect(try restarted.recoverInterruptedReplacement() == nil)
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

        let restarted = KnitNoteBackupService(
            liveRoot: fixture.liveRoot,
            workRoot: fixture.workRoot
        )
        #expect(try restarted.recoverInterruptedReplacement().map { _ in true } == nil)
        #expect(try fixture.liveArchiveName() == "replacement")
        #expect(try fixture.cleanupRoots().isEmpty)
        #expect(try restarted.recoverInterruptedReplacement().map { _ in true } == nil)
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

    @Test func replacementRecoveryFailsClosedForCorruptJournal() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let installation = try fixture.service.install(
            try fixture.service.stagePackage(at: fixture.replacementPackage)
        )
        let liveBytes = try Data(
            contentsOf: fixture.liveRoot.appendingPathComponent("projects-v1.json")
        )
        let rollbackBytes = try Data(
            contentsOf: installation.rollbackRoot.appendingPathComponent("projects-v1.json")
        )
        try Data("{\"phase\":\"rollingBack\"}".utf8).write(
            to: fixture.workRoot.appendingPathComponent(".ReplacementJournal.json"),
            options: .atomic
        )

        #expect(throws: KnitNoteBackupError.rollbackFailed) {
            _ = try fixture.service.recoverInterruptedReplacement()
        }

        #expect(try Data(
            contentsOf: fixture.liveRoot.appendingPathComponent("projects-v1.json")
        ) == liveBytes)
        #expect(try Data(
            contentsOf: installation.rollbackRoot.appendingPathComponent("projects-v1.json")
        ) == rollbackBytes)
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

        _ = try fixture.service.recoverInterruptedReplacement()

        #expect(try fixture.liveArchiveName() == "original")
        #expect(!FileManager.default.fileExists(atPath: installation.rollbackRoot.path))
    }

    @Test func installRecoveryPreservesRollbackUntilReloadIsCommitted() throws {
        let fixture = try BackupInstallFixture.make()
        defer { fixture.cleanup() }
        let installation = try fixture.service.install(
            try fixture.service.stagePackage(at: fixture.replacementPackage)
        )

        let pending = try fixture.service.recoverInterruptedReplacement()
        let recovered = try #require(pending)

        #expect(try fixture.liveArchiveName() == "replacement")
        #expect(FileManager.default.fileExists(atPath: installation.rollbackRoot.path))
        fixture.service.commit(recovered)
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

        _ = try fixture.service.recoverInterruptedReplacement()

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

        _ = try service.recoverInterruptedReplacement()

        #expect(try fixture.liveArchiveName() == "replacement")
        for artifact in [installation.rollbackRoot, cleanupRoot, exportRoot, stagedRoot] {
            #expect(FileManager.default.fileExists(atPath: artifact.path))
        }
    }
}

private enum YouTubeSidecarBackupMutation: CaseIterable, Sendable {
    case missing
    case tampered
    case oversized
    case symlinked
    case schemaInvalid

}

private struct BackupInstallFixture {
    struct InjectedFailure: Error {}

    let root: URL
    let liveRoot: URL
    let workRoot: URL
    let replacementPackage: URL
    let service: KnitNoteBackupService

    var replacementJournal: URL {
        workRoot.appendingPathComponent(".ReplacementJournal.json")
    }

    static func make(
        failingAt failedStep: KnitNoteBackupReplacementStep? = nil,
        hadLiveRoot: Bool = true
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
        if hadLiveRoot {
            try writeArchive(named: "original", to: liveRoot)
        }
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

    func journalPhase() throws -> String {
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: replacementJournal)
        )
        let dictionary = try #require(object as? [String: Any])
        return try #require(dictionary["phase"] as? String)
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

        var manifest: KnitNoteBackupManifest {
            get throws {
                try JSONDecoder().decode(
                    KnitNoteBackupManifest.self,
                    from: Data(contentsOf: url.appendingPathComponent("manifest.json"))
                )
            }
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

        func downgradeManifestToVersionOne() throws {
            let current = try manifest
            try JSONEncoder().encode(KnitNoteBackupManifest(
                formatVersion: 1,
                createdAt: current.createdAt,
                appVersion: current.appVersion,
                projectCount: current.projectCount,
                yarnCount: current.yarnCount
            )).write(
                to: url.appendingPathComponent("manifest.json"),
                options: .atomic
            )
        }
    }

    struct YouTubePackage {
        let service: KnitNoteBackupService
        let url: URL
        let cleanupRoot: URL
        let archive: ProjectArchive
        let asset: PatternAsset
        let link: YouTubePatternLink
        let projectIDs: [UUID]

        var manifest: KnitNoteBackupManifest {
            get throws {
                try JSONDecoder().decode(
                    KnitNoteBackupManifest.self,
                    from: Data(contentsOf: url.appendingPathComponent("manifest.json"))
                )
            }
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

        func mutateYouTubeSidecar(_ mutation: YouTubeSidecarBackupMutation) throws {
            let relativePath = "Patterns/Assets/\(asset.storedFilename)"
            let sidecar = url.appendingPathComponent("Data/\(relativePath)")
            switch mutation {
            case .missing:
                try FileManager.default.removeItem(at: sidecar)
            case .tampered:
                let original = try Data(contentsOf: sidecar)
                try Data(repeating: 0x5A, count: original.count).write(to: sidecar, options: .atomic)
            case .oversized:
                let handle = try FileHandle(forWritingTo: sidecar)
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(KnitNoteBackupLimits.maximumFileBytes + 1))
            case .symlinked:
                let target = cleanupRoot.appendingPathComponent("youtube-sidecar-target")
                try Data("target".utf8).write(to: target, options: .atomic)
                try FileManager.default.removeItem(at: sidecar)
                try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
            case .schemaInvalid:
                let invalid = Data(#"{"version":1,"videoID":"dQw4w9WgXcQ","canonicalURL":"https:\/\/www.youtube.com\/watch?v=abcdefghijk"}"#.utf8)
                try invalid.write(to: sidecar, options: .atomic)
                try rewriteArchive { archive in
                    let assets = archive.patternAssets.map { asset in
                        guard asset.id == self.asset.id else { return asset }
                        return PatternAsset(
                            id: asset.id,
                            sha256: sha256(invalid),
                            kind: .youtube,
                            storedFilename: asset.storedFilename,
                            byteCount: Int64(invalid.count),
                            pageCount: nil
                        )
                    }
                    return ProjectArchive(
                        version: archive.version,
                        projects: archive.projects,
                        yarns: archive.yarns,
                        patternAssets: assets,
                        patterns: archive.patterns,
                        patternUsages: archive.patternUsages
                    )
                }
                let archiveData = try Data(
                    contentsOf: url.appendingPathComponent("Data/projects-v1.json")
                )
                try rewriteManifest { manifest in
                    let files = manifest.files.map { file in
                        if file.relativePath == "projects-v1.json" {
                            return KnitNoteBackupManifestFile(
                                relativePath: file.relativePath,
                                byteCount: Int64(archiveData.count),
                                sha256: sha256(archiveData)
                            )
                        }
                        guard file.relativePath == relativePath else { return file }
                        return KnitNoteBackupManifestFile(
                            relativePath: file.relativePath,
                            byteCount: Int64(invalid.count),
                            sha256: sha256(invalid)
                        )
                    }
                    return manifest.replacing(files: files)
                }
            }
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

    static func patternLibraryPackage() throws -> Package {
        let (service, live, root) = try makeServiceFixture()
        let complete = try writePatternLibraryArchive(to: live)
        let packageURL = try service.createPackage(
            appVersion: "1.2.0",
            now: .init(timeIntervalSince1970: 20)
        )
        let assetPath = try #require(
            complete.referencedRelativePaths.first { $0.hasPrefix("Patterns/Assets/") }
        )
        let markupPath = try #require(
            complete.referencedRelativePaths.first { $0.hasPrefix("Patterns/UsageMarkup/") }
        )
        return Package(
            service: service,
            url: packageURL,
            cleanupRoot: root,
            firstRelativePath: assetPath,
            markupRelativePath: markupPath
        )
    }

    static func youtubePackage() throws -> YouTubePackage {
        let (service, live, root) = try makeServiceFixture()
        let firstProject = try StoredProject(name: "Cable cardigan")
        let secondProject = try StoredProject(name: "Cable vest")
        let assetID = UUID()
        let patternID = UUID()
        let link = try YouTubePatternLink(videoID: "dQw4w9WgXcQ")
        let metadataData = try JSONEncoder().encode(YouTubePatternMetadata(link: link))
        let asset = PatternAsset(
            id: assetID,
            sha256: sha256(metadataData),
            kind: .youtube,
            storedFilename: "\(assetID.uuidString).youtube",
            byteCount: Int64(metadataData.count),
            pageCount: nil
        )
        let pattern = StoredPattern(
            id: patternID,
            assetID: assetID,
            displayName: "Custom cable tutorial",
            note: "Use the sleeve section twice",
            createdAt: .init(timeIntervalSince1970: 42)
        )
        let firstUsage = PatternProjectUsage(
            patternID: patternID,
            projectID: firstProject.id,
            isActive: true,
            linkedAt: .init(timeIntervalSince1970: 43),
            sortOrder: 1
        )
        let secondUsage = PatternProjectUsage(
            patternID: patternID,
            projectID: secondProject.id,
            isActive: false,
            linkedAt: .init(timeIntervalSince1970: 44),
            unlinkedAt: .init(timeIntervalSince1970: 45),
            sortOrder: 2
        )
        let archive = ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [firstProject, secondProject],
            patternAssets: [asset],
            patterns: [pattern],
            patternUsages: [firstUsage, secondUsage]
        )
        try JSONEncoder().encode(archive).write(
            to: live.appendingPathComponent("projects-v1.json"),
            options: .atomic
        )
        let sidecar = live.appendingPathComponent("Patterns/Assets/\(asset.storedFilename)")
        try FileManager.default.createDirectory(
            at: sidecar.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try metadataData.write(to: sidecar, options: .atomic)
        let cache = live.appendingPathComponent("PatternThumbnailCache/\(assetID.uuidString).jpg")
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("generated thumbnail".utf8).write(to: cache, options: .atomic)

        return YouTubePackage(
            service: service,
            url: try service.createPackage(appVersion: "1.3.1"),
            cleanupRoot: root,
            archive: archive,
            asset: asset,
            link: link,
            projectIDs: [firstProject.id, secondProject.id]
        )
    }

    static func writeDisposableArchive(to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [try StoredProject(name: "Disposable")]
        )).write(
            to: root.appendingPathComponent("projects-v1.json"),
            options: .atomic
        )
    }

    static func schemaTenPatternLibraryPackage() throws -> Package {
        let (service, live, root) = try makeServiceFixture()
        let complete = try writePatternLibraryArchive(
            to: live,
            archiveVersion: 10,
            omitPDFWidthScaleRatio: true,
            includeLinkedYarn: true
        )
        let packageURL = try service.createPackage(
            appVersion: "1.2.0",
            now: .init(timeIntervalSince1970: 20)
        )
        let assetPath = try #require(
            complete.referencedRelativePaths.first { $0.hasPrefix("Patterns/Assets/") }
        )
        let markupPath = try #require(
            complete.referencedRelativePaths.first { $0.hasPrefix("Patterns/UsageMarkup/") }
        )
        return Package(
            service: service,
            url: packageURL,
            cleanupRoot: root,
            firstRelativePath: assetPath,
            markupRelativePath: markupPath
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

    static func jpegData(red: CGFloat) throws -> Data {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: 20,
            height: 20,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func writePatternLibraryArchive(
        to live: URL,
        archiveVersion: Int = ProjectArchive.currentVersion,
        omitPDFWidthScaleRatio: Bool = false,
        includeLinkedYarn: Bool = false
    ) throws -> CompleteArchive {
        let project = try StoredProject(name: "Pattern project")
        var yarns: [StoredYarn] = []
        if includeLinkedYarn {
            var yarn = try StoredYarn(name: "Pattern yarn")
            yarn.setLinkedProjectIDs([project.id])
            yarns = [yarn]
        }
        let assetID = UUID()
        let patternID = UUID()
        let usageID = UUID()
        let assetBytes = try patternPDFData()
        let storedFilename = "\(assetID.uuidString).pdf"
        let asset = PatternAsset(
            id: assetID,
            sha256: sha256(assetBytes),
            kind: .pdf,
            storedFilename: storedFilename,
            byteCount: Int64(assetBytes.count),
            pageCount: 5
        )
        let pattern = StoredPattern(
            id: patternID,
            assetID: assetID,
            displayName: "Shared chart",
            note: "Designer and shop",
            createdAt: .init(timeIntervalSince1970: 11),
            lastOpenedAt: .init(timeIntervalSince1970: 12)
        )
        let readingState = PatternReadingState(
            pageIndex: 2,
            zoomScale: 2.25,
            offsetX: 0.35,
            offsetY: 0.65,
            highlightEnabled: true,
            highlightPosition: 0.4,
            highlightMode: .vertical,
            verticalHighlightPosition: 0.7,
            pageNote: "Cable repeat",
            pageStates: [
                2: .init(
                    horizontalPosition: 0.4,
                    verticalPosition: 0.7,
                    note: "Cable repeat"
                ),
            ]
        )
        let usage = PatternProjectUsage(
            id: usageID,
            patternID: patternID,
            projectID: project.id,
            isActive: false,
            linkedAt: .init(timeIntervalSince1970: 13),
            unlinkedAt: .init(timeIntervalSince1970: 14),
            sortOrder: 3,
            readingState: readingState
        )
        let archive = ProjectArchive(
            version: archiveVersion,
            projects: [project],
            yarns: yarns,
            patternAssets: [asset],
            patterns: [pattern],
            patternUsages: [usage]
        )
        let archivePath = "projects-v1.json"
        let assetPath = "Patterns/Assets/\(storedFilename)"
        let markupPath = "Patterns/UsageMarkup/\(usageID.uuidString)/2.json"
        let markup = PatternMarkupDocument(strokes: [
            .init(
                points: [.init(x: 0.2, y: 0.3), .init(x: 0.4, y: 0.5)],
                color: .red,
                width: 0.006
            ),
        ])
        let files: [(String, Data)] = [
            (archivePath, try encodedArchive(
                archive,
                omittingPDFWidthScaleRatio: omitPDFWidthScaleRatio
            )),
            (assetPath, assetBytes),
            (markupPath, try JSONEncoder().encode(markup)),
        ]
        for (relativePath, data) in files {
            let destination = live.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        }
        return CompleteArchive(referencedRelativePaths: files.map(\.0))
    }

    private static func patternPDFData() throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BackupPattern-\(UUID().uuidString).pdf"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for _ in 0..<5 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        return try Data(contentsOf: url)
    }

    private static func encodedArchive(
        _ archive: ProjectArchive,
        omittingPDFWidthScaleRatio: Bool
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(archive)
        guard omittingPDFWidthScaleRatio else { return encoded }
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var usages = try #require(object["patternUsages"] as? [[String: Any]])
        var usage = try #require(usages.first)
        var readingState = try #require(usage["readingState"] as? [String: Any])
        readingState.removeValue(forKey: "pdfWidthScaleRatio")
        usage["readingState"] = readingState
        usages[0] = usage
        object["patternUsages"] = usages
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func writeExcludedPatternArtifacts(to live: URL) throws {
        let paths = [
            "Patterns/Assets/.Candidates/candidate.pdf",
            "Patterns/Assets/.Transactions/transaction.json",
            "Patterns/Assets/.PublicationReceipts/receipt.json",
            "Patterns/Assets/.Quarantine/quarantined.json",
            "PatternInbox/inbox.pdf",
        ]
        for path in paths {
            let destination = live.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("excluded".utf8).write(to: destination)
        }
    }

    static func relativeFilePaths(below root: URL) throws -> [String] {
        let prefix = root.standardizedFileURL.path + "/"
        let enumerator = try #require(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ))
        return try enumerator.compactMap { item -> String? in
            let url = try #require(item as? URL)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            let path = url.standardizedFileURL.path
            return String(path.dropFirst(prefix.count))
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

private final class RollbackDurabilityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private let failingDirectory: String?
    private let failAfterStep: KnitNoteBackupReplacementStep?
    private var observedFailureStep = false
    private var hasFailed = false

    init(
        failingDirectory: URL? = nil,
        failAfterStep: KnitNoteBackupReplacementStep? = nil
    ) {
        self.failingDirectory = failingDirectory?.standardizedFileURL.path
        self.failAfterStep = failAfterStep
    }

    var events: [String] {
        lock.withLock { recordedEvents }
    }

    func record(step: KnitNoteBackupReplacementStep) {
        lock.withLock {
            recordedEvents.append("step:\(label(for: step))")
            if step == failAfterStep {
                observedFailureStep = true
            }
        }
    }

    func synchronize(_ directory: URL) throws {
        let path = directory.standardizedFileURL.path
        let shouldFail = lock.withLock {
            recordedEvents.append("sync:\(path)")
            guard !hasFailed, path == failingDirectory else { return false }
            guard failAfterStep == nil || observedFailureStep else { return false }
            hasFailed = true
            return true
        }
        if shouldFail {
            throw BackupInstallFixture.InjectedFailure()
        }
    }

    private func label(for step: KnitNoteBackupReplacementStep) -> String {
        switch step {
        case .beforeLiveMove: "beforeLiveMove"
        case .afterLiveMove: "afterLiveMove"
        case .afterStagedMove: "afterStagedMove"
        case .beforeRollback: "beforeRollback"
        case .afterRollbackJournal: "afterRollbackJournal"
        case .afterRollbackLiveRemoval: "afterRollbackLiveRemoval"
        case .afterRollbackRestore: "afterRollbackRestore"
        case .afterRollbackFinalized: "afterRollbackFinalized"
        case .beforeCommitCleanup: "beforeCommitCleanup"
        }
    }
}

private extension KnitNoteBackupManifest {
    func replacing(
        files: [KnitNoteBackupManifestFile]? = nil,
        criticalFeatures: [String]? = nil
    ) -> KnitNoteBackupManifest {
        KnitNoteBackupManifest(
            formatVersion: formatVersion,
            createdAt: createdAt,
            appVersion: appVersion,
            projectCount: projectCount,
            yarnCount: yarnCount,
            patternCount: patternCount,
            files: files ?? self.files,
            criticalFeatures: criticalFeatures ?? self.criticalFeatures
        )
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
