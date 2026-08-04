import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@MainActor
@Suite struct YouTubePatternStoreTests {
    @Test func addsOneReusableYouTubePatternAndLinksTwoProjects() async throws {
        let harness = try YouTubePatternStoreHarness()
        let link = try YouTubePatternLink(videoID: "dQw4w9WgXcQ")

        let first = try await harness.store.addYouTubePattern(
            link: link,
            title: "Cable tutorial",
            targetProjectID: harness.firstProjectID
        )
        let second = try await harness.store.addYouTubePattern(
            link: link,
            title: "Ignored duplicate title",
            targetProjectID: harness.secondProjectID
        )

        #expect(first.resolution == .created)
        #expect(second.resolution == .existing)
        #expect(first.resolvedPatternID == second.resolvedPatternID)
        #expect(harness.store.patternAssets.filter { $0.kind == .youtube }.count == 1)
        #expect(harness.store.patternUsages.filter { $0.patternID == first.resolvedPatternID }.count == 2)
        #expect(harness.store.patterns.first { $0.id == first.resolvedPatternID }?.displayName == "Cable tutorial")
    }

    @Test func addsLibraryOnlyYouTubePatternWithoutAUsage() async throws {
        let harness = try YouTubePatternStoreHarness()

        let result = try await harness.store.addYouTubePattern(
            link: try YouTubePatternLink(videoID: "dQw4w9WgXcQ"),
            title: "Library tutorial"
        )

        #expect(result.resolution == .created)
        #expect(harness.store.patternUsages.isEmpty)
        #expect(harness.store.patternAssets.filter { $0.kind == .youtube }.count == 1)
    }

    @Test func blankTitleIsRejectedBeforeMutatingTheLibrary() async throws {
        let harness = try YouTubePatternStoreHarness()

        let link = try YouTubePatternLink(videoID: "dQw4w9WgXcQ")
        let sidecarURL = try harness.sidecarURL(for: link)
        await #expect(throws: YouTubePatternStoreError.emptyTitle) {
            _ = try await harness.store.addYouTubePattern(
                link: link,
                title: " \n\t "
            )
        }

        #expect(harness.store.patternAssets.filter { $0.kind == .youtube }.isEmpty)
        #expect(harness.store.patterns.filter { $0.displayName != "Existing PDF" }.isEmpty)
        #expect(harness.store.patternUsages.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    @Test func missingProjectIsRejectedBeforeWritingTheSidecar() async throws {
        let harness = try YouTubePatternStoreHarness()

        let link = try YouTubePatternLink(videoID: "dQw4w9WgXcQ")
        let sidecarURL = try harness.sidecarURL(for: link)
        await #expect(throws: PatternLibraryMutationError.projectNotFound) {
            _ = try await harness.store.addYouTubePattern(
                link: link,
                title: "Missing project",
                targetProjectID: UUID()
            )
        }

        #expect(harness.store.patternAssets.filter { $0.kind == .youtube }.isEmpty)
        #expect(harness.store.patterns.filter { $0.displayName != "Existing PDF" }.isEmpty)
        #expect(harness.store.patternUsages.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    @Test func existingActiveProjectLinkIsIdempotent() async throws {
        let harness = try YouTubePatternStoreHarness()
        let link = try YouTubePatternLink(videoID: "dQw4w9WgXcQ")
        let created = try await harness.store.addYouTubePattern(
            link: link,
            title: "Idempotent tutorial",
            targetProjectID: harness.firstProjectID
        )

        let existing = try await harness.store.addYouTubePattern(
            link: link,
            title: "Ignored",
            targetProjectID: harness.firstProjectID
        )

        #expect(existing.resolution == .existing)
        #expect(existing.resolvedPatternID == created.resolvedPatternID)
        #expect(harness.store.patternUsages.filter { $0.patternID == created.resolvedPatternID }.count == 1)
    }

    @Test func existingInactiveProjectLinkIsReactivated() async throws {
        let harness = try YouTubePatternStoreHarness()
        let link = try YouTubePatternLink(videoID: "dQw4w9WgXcQ")
        let created = try await harness.store.addYouTubePattern(
            link: link,
            title: "Reactivation tutorial",
            targetProjectID: harness.firstProjectID
        )
        try harness.store.unlinkPattern(patternID: created.resolvedPatternID, from: harness.firstProjectID)

        let existing = try await harness.store.addYouTubePattern(
            link: link,
            title: "Ignored",
            targetProjectID: harness.firstProjectID
        )

        #expect(existing.resolution == .existing)
        #expect(harness.store.patternUsages.filter { $0.patternID == created.resolvedPatternID }.count == 1)
        #expect(harness.store.patternUsages.first?.isActive == true)
    }

    @Test func authorizationDenialLeavesNoSidecarOrArchiveMutation() async throws {
        let harness = try YouTubePatternStoreHarness(authorizeMutation: { _ in .requiresUnlock })

        let link = try YouTubePatternLink(videoID: "dQw4w9WgXcQ")
        let sidecarURL = try harness.sidecarURL(for: link)
        await #expect(throws: ProjectStoreError.accessRestricted) {
            _ = try await harness.store.addYouTubePattern(
                link: link,
                title: "Restricted tutorial"
            )
        }

        #expect(harness.store.patternAssets.filter { $0.kind == .youtube }.isEmpty)
        #expect(harness.store.patterns.filter { $0.displayName != "Existing PDF" }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    @Test func archiveSaveFailureRollsBackTheUnpublishedSidecar() async throws {
        let harness = try YouTubePatternStoreHarness(failingArchiveWrites: true)
        harness.archiveWriteGate?.shouldFail = true
        let link = try YouTubePatternLink(videoID: "dQw4w9WgXcQ")
        let sidecarURL = try harness.sidecarURL(for: link)

        await #expect(throws: ProjectStoreError.persistenceFailed) {
            _ = try await harness.store.addYouTubePattern(link: link, title: "Archive failure")
        }

        #expect(harness.store.patternAssets.filter { $0.kind == .youtube }.isEmpty)
        #expect(harness.store.patterns.filter { $0.displayName != "Existing PDF" }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    @Test func sidecarWriteFailureLeavesTheArchiveAndLibraryUnchanged() async throws {
        let harness = try YouTubePatternStoreHarness(sidecarWrite: { data, destination in
            try data.write(to: destination, options: .atomic)
            throw YouTubeSidecarWriteFailure.expected
        })
        let link = try YouTubePatternLink(videoID: "dQw4w9WgXcQ")
        let sidecarURL = try harness.sidecarURL(for: link)

        await #expect(throws: YouTubeSidecarWriteFailure.expected) {
            _ = try await harness.store.addYouTubePattern(link: link, title: "Sidecar failure")
        }

        #expect(harness.store.patternAssets.filter { $0.kind == .youtube }.isEmpty)
        #expect(harness.store.patterns.filter { $0.displayName != "Existing PDF" }.isEmpty)
        #expect(harness.store.patternUsages.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    @Test func permanentlyDeletingAnUnlinkedYouTubePatternRemovesItsSidecar() async throws {
        let harness = try YouTubePatternStoreHarness()
        let link = try YouTubePatternLink(videoID: "dQw4w9WgXcQ")
        let result = try await harness.store.addYouTubePattern(link: link, title: "Delete tutorial")
        let sidecarURL = try harness.store.patternAssetURL(patternID: result.resolvedPatternID)

        try harness.store.deletePatternPermanently(id: result.resolvedPatternID)

        #expect(harness.store.patternAssets.filter { $0.kind == .youtube }.isEmpty)
        #expect(harness.store.patterns.filter { $0.id == result.resolvedPatternID }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    @Test func youtubeLinkValidatesTheResolvedYouTubeAsset() async throws {
        let harness = try YouTubePatternStoreHarness()
        let link = try YouTubePatternLink(videoID: "dQw4w9WgXcQ")
        let result = try await harness.store.addYouTubePattern(link: link, title: "Resolve tutorial")

        #expect(try harness.store.youtubeLink(patternID: result.resolvedPatternID) == link)
        #expect(throws: PatternLibraryMutationError.patternNotFound) {
            try harness.store.youtubeLink(patternID: UUID())
        }
        #expect(throws: PatternFileError.invalidContent) {
            try harness.store.youtubeLink(patternID: harness.existingPDFPatternID)
        }
    }
}

@MainActor
private final class YouTubePatternStoreHarness {
    let root: URL
    let archiveURL: URL
    let patternsRoot: URL
    let assetsDirectory: URL
    let firstProjectID = UUID()
    let secondProjectID = UUID()
    let existingPDFPatternID = UUID()
    let store: JSONProjectStore
    let archiveWriteGate: YouTubeArchiveWriteGate?

    init(
        failingArchiveWrites: Bool = false,
        sidecarWrite: (@Sendable (Data, URL) throws -> Void)? = nil,
        authorizeMutation: @escaping MutationAuthorizer = { _ in .allow }
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YouTubePatternStoreHarness-\(UUID().uuidString)", isDirectory: true)
        archiveURL = root.appendingPathComponent("projects-v1.json")
        patternsRoot = root.appendingPathComponent("Patterns", isDirectory: true)
        assetsDirectory = patternsRoot.appendingPathComponent("Assets", isDirectory: true)
        let projects = [
            try StoredProject(id: firstProjectID, name: "First"),
            try StoredProject(id: secondProjectID, name: "Second")
        ]
        let existingAssetID = UUID()
        let existingAssetURL = assetsDirectory.appendingPathComponent("\(existingAssetID.uuidString).pdf")
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        try makeTestPatternPDF(at: existingAssetURL)
        let existingMetadata = try PatternFileService(root: patternsRoot).inspect(existingAssetURL)
        let archive = ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: projects,
            patternAssets: [PatternAsset(
                id: existingAssetID,
                sha256: existingMetadata.sha256,
                kind: .pdf,
                storedFilename: existingAssetURL.lastPathComponent,
                byteCount: existingMetadata.byteCount,
                pageCount: existingMetadata.pageCount
            )],
            patterns: [StoredPattern(
                id: existingPDFPatternID,
                assetID: existingAssetID,
                displayName: "Existing PDF"
            )]
        )
        try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)
        let gate = failingArchiveWrites ? YouTubeArchiveWriteGate() : nil
        archiveWriteGate = gate
        store = JSONProjectStore(
            url: archiveURL,
            patternFileService: PatternFileService(root: patternsRoot, writeData: sidecarWrite),
            patternInboxFileService: PatternInboxFileService(
                root: root.appendingPathComponent("PatternInbox", isDirectory: true)
            ),
            backupService: KnitNoteBackupService(
                liveRoot: root,
                workRoot: root.appendingPathComponent(".BackupWork", isDirectory: true)
            ),
            archiveWrite: { data, destination in
                if gate?.shouldFail == true { throw ProjectStoreError.persistenceFailed }
                try data.write(to: destination, options: .atomic)
            },
            authorizeMutation: authorizeMutation
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func sidecarURL(for link: YouTubePatternLink) throws -> URL {
        let metadata = YouTubePatternMetadata(link: link)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(metadata)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let assetID = PatternImportCoordinator().deterministicAssetID(for: digest)
        return assetsDirectory.appendingPathComponent("\(assetID.uuidString).youtube")
    }
}

private final class YouTubeArchiveWriteGate: @unchecked Sendable {
    var shouldFail = false
}

private enum YouTubeSidecarWriteFailure: Error {
    case expected
}
