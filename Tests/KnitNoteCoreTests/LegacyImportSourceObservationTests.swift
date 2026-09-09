import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

private func sourceFixture() throws -> (KnitNoteBackupService, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let live = root.appendingPathComponent("Source")
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
    try JSONEncoder().encode(archive).write(to: live.appendingPathComponent("projects-v1.json"))
    return (
        KnitNoteBackupService(
            liveRoot: live,
            workRoot: root.appendingPathComponent("Work")
        ),
        live,
        root
    )
}

@Suite struct LegacyImportSourceObservationTests {
    @Test func actualArchiveIsObservedWithoutWritingSource() throws {
        let (service, live, root) = try sourceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = live.appendingPathComponent("projects-v1.json")
        let bytes = try Data(contentsOf: url)

        let snapshot = try service.observeLegacyImportSource()
        let file = try #require(snapshot.entries.first)

        #expect(snapshot.entries.count == 1)
        #expect(file.relativePath == "projects-v1.json")
        #expect(file.sha256 == Data(SHA256.hash(data: bytes)))
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try service.observeLegacyImportSource() == snapshot)
    }

    @Test func equalContentsAcrossRootsHaveEqualDigestAndDifferentRootIdentity() throws {
        let first = try sourceFixture()
        let second = try sourceFixture()
        defer {
            try? FileManager.default.removeItem(at: first.2)
            try? FileManager.default.removeItem(at: second.2)
        }
        let archiveName = "projects-v1.json"
        let identicalArchive = try Data(
            contentsOf: first.1.appendingPathComponent(archiveName)
        )
        try identicalArchive.write(to: second.1.appendingPathComponent(archiveName))

        let firstSnapshot = try first.0.observeLegacyImportSource()
        let secondSnapshot = try second.0.observeLegacyImportSource()

        #expect(firstSnapshot.contentDigest == secondSnapshot.contentDigest)
        #expect(firstSnapshot.rootIdentity != secondSnapshot.rootIdentity)
    }

    @Test func sameSizeReferencedContentChangeChangesDigest() throws {
        let fixture = try sourcePhotoFixture(data: Data(repeating: 0x11, count: 4))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try fixture.service.observeLegacyImportSource()

        try Data(repeating: 0x22, count: 4).write(to: fixture.photoURL)
        let after = try fixture.service.observeLegacyImportSource()

        #expect(before.contentDigest != after.contentDigest)
    }

    @Test func sameContentReplacementChangesIdentityButNotDigest() throws {
        let bytes = Data(repeating: 0x31, count: 32)
        let fixture = try sourcePhotoFixture(data: bytes)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try fixture.service.observeLegacyImportSource()
        let moved = fixture.root.appendingPathComponent("moved-photo")

        try FileManager.default.moveItem(at: fixture.photoURL, to: moved)
        try bytes.write(to: fixture.photoURL)
        let after = try fixture.service.observeLegacyImportSource()

        #expect(before.contentDigest == after.contentDigest)
        #expect(before.fileIdentities[fixture.relativePath] != after.fileIdentities[fixture.relativePath])
    }

    @Test func replacementBetweenStatAndOpenIsRejectedWithoutSourceCleanup() throws {
        let bytes = Data(repeating: 0x41, count: 16)
        let fixture = try sourcePhotoFixture(data: bytes)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let moved = fixture.root.appendingPathComponent("moved-photo")
        let swap = LegacySourceSwap(
            targetPath: fixture.relativePath,
            source: fixture.photoURL,
            moved: moved,
            replacement: bytes
        )
        let service = KnitNoteBackupService(
            liveRoot: fixture.live,
            workRoot: fixture.root.appendingPathComponent("Work"),
            beforeSourceEntryOpen: swap.run
        )

        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            _ = try service.observeLegacyImportSource()
        }
        #expect(swap.didRun)
        #expect(try Data(contentsOf: fixture.photoURL) == bytes)
        #expect(try Data(contentsOf: moved) == bytes)
    }

    @Test func symlinkHardlinkAndMissingReferencesAreRejectedWithoutCleanup() throws {
        for fault in LegacySourceFault.allCases {
            let bytes = Data(repeating: 0x51, count: 8)
            let fixture = try sourcePhotoFixture(data: bytes)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let external = fixture.root.appendingPathComponent("external")
            try bytes.write(to: external)
            try FileManager.default.removeItem(at: fixture.photoURL)
            switch fault {
            case .symlink:
                try FileManager.default.createSymbolicLink(
                    at: fixture.photoURL,
                    withDestinationURL: external
                )
            case .hardlink:
                try FileManager.default.linkItem(at: external, to: fixture.photoURL)
            case .missing:
                break
            }
            let archiveURL = fixture.live.appendingPathComponent("projects-v1.json")
            let archiveBytes = try Data(contentsOf: archiveURL)

            #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
                _ = try fixture.service.observeLegacyImportSource()
            }
            #expect(try Data(contentsOf: archiveURL) == archiveBytes)
            #expect(try Data(contentsOf: external) == bytes)
            if fault != .missing {
                #expect(try Data(contentsOf: fixture.photoURL) == bytes)
            }
        }
    }

    @Test func mutationDuringStreamingIsRejectedAndObserverDoesNotRestoreSource() throws {
        let original = Data(repeating: 0x61, count: 70_000)
        let replacement = Data(repeating: 0x62, count: original.count)
        let fixture = try sourcePhotoFixture(data: original)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mutation = LegacySourceContentMutation(
            target: fixture.photoURL,
            replacement: replacement
        )
        let service = KnitNoteBackupService(
            liveRoot: fixture.live,
            workRoot: fixture.root.appendingPathComponent("Work"),
            copyChunkHook: mutation.run
        )

        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            _ = try service.observeLegacyImportSource()
        }
        #expect(mutation.didRun)
        #expect(try Data(contentsOf: fixture.photoURL) == replacement)
    }

    @Test func backupMatchesAndLaterSourceChangeIsRejected() throws {
        let (service, live, root) = try sourceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try service.prepareLegacyImportBackup(appVersion: "1.7.0")
        #expect(prepared.contentDigest == prepared.source.contentDigest)
        try service.revalidateLegacyImportBackup(prepared)
        let archive = ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [try StoredProject(name: "new edit")]
        )
        try JSONEncoder().encode(archive).write(
            to: live.appendingPathComponent("projects-v1.json"),
            options: .atomic
        )
        #expect(throws: (any Error).self) {
            try service.revalidateLegacyImportBackup(prepared)
        }
        #expect(FileManager.default.fileExists(atPath: prepared.packageURL.path))
    }

    @Test func manifestCreatedAtDoesNotAffectObservedContent() throws {
        let (service, _, root) = try sourceFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try service.prepareLegacyImportBackup(appVersion: "1.7.0")
        let second = try service.prepareLegacyImportBackup(appVersion: "1.7.0")
        let firstManifest = try manifest(at: first.packageURL)
        let secondManifest = try manifest(at: second.packageURL)

        #expect(firstManifest.createdAt != secondManifest.createdAt)
        #expect(first.contentDigest == second.contentDigest)
    }

    @Test func packageContentAndManifestTamperingAreRejectedWithoutCleanup() throws {
        for fault in LegacyPreparedBackupFault.allCases {
            let fixture = try sourcePhotoFixture(data: Data(repeating: 0x71, count: 32))
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let prepared = try fixture.service.prepareLegacyImportBackup(appVersion: "1.7.0")

            switch fault {
            case .content:
                try Data(repeating: 0x72, count: 32).write(
                    to: prepared.packageURL.appendingPathComponent("Data/\(fixture.relativePath)"),
                    options: .atomic
                )
            case .manifestHash:
                try rewriteManifest(at: prepared.packageURL) { current in
                    let files = current.files.map { file in
                        KnitNoteBackupManifestFile(
                            relativePath: file.relativePath,
                            byteCount: file.byteCount,
                            sha256: file.relativePath == fixture.relativePath
                                ? String(repeating: "0", count: 64)
                                : file.sha256
                        )
                    }
                    return KnitNoteBackupManifest(
                        formatVersion: current.formatVersion,
                        createdAt: current.createdAt,
                        appVersion: current.appVersion,
                        projectCount: current.projectCount,
                        yarnCount: current.yarnCount,
                        patternCount: current.patternCount,
                        files: files,
                        criticalFeatures: current.criticalFeatures
                    )
                }
            }

            #expect(throws: (any Error).self) {
                try fixture.service.revalidateLegacyImportBackup(prepared)
            }
            #expect(FileManager.default.fileExists(atPath: prepared.packageURL.path))
            #expect(FileManager.default.fileExists(atPath: fixture.photoURL.path))
        }
    }

    @Test func sameContentPackageRootReplacementIsRejected() throws {
        let (service, _, root) = try sourceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try service.prepareLegacyImportBackup(appVersion: "1.7.0")
        let moved = root.appendingPathComponent("moved-package")

        try FileManager.default.moveItem(at: prepared.packageURL, to: moved)
        try FileManager.default.copyItem(at: moved, to: prepared.packageURL)

        #expect(throws: (any Error).self) {
            try service.revalidateLegacyImportBackup(prepared)
        }
        #expect(FileManager.default.fileExists(atPath: prepared.packageURL.path))
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }

    @Test func equivalentServiceCanRevalidateButDifferentRootsCannot() throws {
        let first = try sourceFixture()
        let second = try sourceFixture()
        defer {
            try? FileManager.default.removeItem(at: first.2)
            try? FileManager.default.removeItem(at: second.2)
        }
        let prepared = try first.0.prepareLegacyImportBackup(appVersion: "1.7.0")
        let equivalent = KnitNoteBackupService(
            liveRoot: first.1,
            workRoot: first.2.appendingPathComponent("Work")
        )

        try equivalent.revalidateLegacyImportBackup(prepared)
        #expect(throws: (any Error).self) {
            try second.0.revalidateLegacyImportBackup(prepared)
        }
    }

    @Test func sourceChangesAfterInitialObservationAndBeforeFinalObservationAreRejected() throws {
        for step in [
            LegacyImportPreparationStep.afterInitialSourceObservation,
            .afterBackupObservation,
        ] {
            let (base, live, root) = try sourceFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let mutation = LegacyPreparationMutation(
                targetStep: step,
                archiveURL: live.appendingPathComponent("projects-v1.json")
            )
            let service = KnitNoteBackupService(
                liveRoot: base.liveRoot,
                workRoot: base.workRoot,
                legacyImportPreparationStepHook: mutation.run
            )

            #expect(throws: KnitNoteBackupError.integrityMismatch("projects-v1.json")) {
                _ = try service.prepareLegacyImportBackup(appVersion: "1.7.0")
            }
            #expect(mutation.didRun)
            #expect(try !FileManager.default.contentsOfDirectory(atPath: base.workRoot.path).isEmpty)
        }
    }

    @Test func sourceMutationDuringBackupCopyIsRejected() throws {
        let fixture = try sourcePhotoFixture(data: Data(repeating: 0x81, count: 70_000))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mutation = LegacyNthSourceContentMutation(
            target: fixture.photoURL,
            replacement: Data(repeating: 0x82, count: 70_000),
            targetRead: 3
        )
        let service = KnitNoteBackupService(
            liveRoot: fixture.live,
            workRoot: fixture.root.appendingPathComponent("Work"),
            copyChunkHook: mutation.run
        )

        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            _ = try service.prepareLegacyImportBackup(appVersion: "1.7.0")
        }
        #expect(mutation.didRun)
        #expect(try Data(contentsOf: fixture.photoURL) == Data(repeating: 0x82, count: 70_000))
    }

    @Test func injectedLegacyFileBudgetAcceptsBoundaryAndRejectsOneMore() throws {
        let exact = try sourcePhotoFixture(data: Data(repeating: 0x91, count: 10_000))
        let oversized = try sourcePhotoFixture(data: Data(repeating: 0x92, count: 10_001))
        defer {
            try? FileManager.default.removeItem(at: exact.root)
            try? FileManager.default.removeItem(at: oversized.root)
        }
        let exactService = KnitNoteBackupService(
            liveRoot: exact.live,
            workRoot: exact.root.appendingPathComponent("Work"),
            legacyImportMaximumFileBytes: 10_000
        )
        let oversizedService = KnitNoteBackupService(
            liveRoot: oversized.live,
            workRoot: oversized.root.appendingPathComponent("Work"),
            legacyImportMaximumFileBytes: 10_000
        )

        _ = try exactService.prepareLegacyImportBackup(appVersion: "1.7.0")
        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            _ = try oversizedService.prepareLegacyImportBackup(appVersion: "1.7.0")
        }
    }

    @Test func portableBackupOverLegacyCapStillInspectsButPreparationRejectsBeforeReadingIt() throws {
        let fixture = try sparseSourcePhotoFixture(
            byteCount: UInt64(100_000_001)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let package = try fixture.service.createPackage(appVersion: "1.7.0")
        _ = try fixture.service.inspectPackage(at: package)
        let tracker = LegacySourceReadTracker(target: fixture.photoURL)
        let legacyService = KnitNoteBackupService(
            liveRoot: fixture.live,
            workRoot: fixture.root.appendingPathComponent("Work"),
            copyChunkHook: tracker.run
        )

        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            _ = try legacyService.prepareLegacyImportBackup(appVersion: "1.7.0")
        }
        #expect(!tracker.didReadTarget)
        #expect(FileManager.default.fileExists(atPath: package.path))
    }
}

@Suite struct LegacyImportContentProjectionTests {
    @Test func digestUsesCanonicalEncodingRegardlessOfInputOrder() throws {
        let archive = archiveEntry()
        let first = LegacyImportContentEntry(
            relativePath: "a",
            byteCount: 1,
            sha256: Data(repeating: 0xaa, count: 32)
        )
        let second = LegacyImportContentEntry(
            relativePath: "b",
            byteCount: 2,
            sha256: Data(repeating: 0xbb, count: 32)
        )
        let expected = Data([
            0x41, 0xf3, 0x3c, 0x32, 0xe0, 0x00, 0xc6, 0x34,
            0x4b, 0x75, 0xc5, 0x30, 0xc5, 0x1d, 0xa1, 0xe7,
            0xd4, 0xff, 0x5d, 0xd9, 0x37, 0xa8, 0xe4, 0xa5,
            0xd4, 0x98, 0xca, 0x82, 0xad, 0x08, 0x21, 0x62,
        ])

        #expect(try LegacyImportContentProjection.digest([archive, first, second]) == expected)
        #expect(try LegacyImportContentProjection.digest([second, archive, first]) == expected)
    }

    @Test func rejectsUnsafeEntriesAndPathAliases() {
        let invalidEntries = [
            LegacyImportContentEntry(relativePath: "", byteCount: 0, sha256: hash()),
            LegacyImportContentEntry(relativePath: "/absolute", byteCount: 0, sha256: hash()),
            LegacyImportContentEntry(relativePath: "a//b", byteCount: 0, sha256: hash()),
            LegacyImportContentEntry(relativePath: ".", byteCount: 0, sha256: hash()),
            LegacyImportContentEntry(relativePath: "..", byteCount: 0, sha256: hash()),
            LegacyImportContentEntry(relativePath: "a/./b", byteCount: 0, sha256: hash()),
            LegacyImportContentEntry(relativePath: "a/../b", byteCount: 0, sha256: hash()),
            LegacyImportContentEntry(relativePath: "a\\b", byteCount: 0, sha256: hash()),
            LegacyImportContentEntry(relativePath: "a\0b", byteCount: 0, sha256: hash()),
            LegacyImportContentEntry(relativePath: "a", byteCount: -1, sha256: hash()),
            LegacyImportContentEntry(relativePath: "a", byteCount: 0, sha256: hash(count: 31)),
            LegacyImportContentEntry(relativePath: "a", byteCount: 0, sha256: hash(count: 33)),
        ]
        for entry in invalidEntries {
            #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
                try LegacyImportContentProjection.digest([archiveEntry(), entry])
            }
        }

        for aliases in [
            [entry("same"), entry("same")],
            [entry("Photo.JPG"), entry("photo.jpg")],
            [entry("café"), entry("cafe")],
        ] {
            #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
                try LegacyImportContentProjection.digest([archiveEntry()] + aliases)
            }
        }
        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            try LegacyImportContentProjection.digest([entry("not-the-archive")])
        }
    }

    @Test func acceptsExactProjectionCapAndRejectsOneMoreByte() throws {
        let exactPath = String(repeating: "a", count: 999_848)
        let oversizedPath = exactPath + "a"

        _ = try LegacyImportContentProjection.digest([archiveEntry(), entry(exactPath)])
        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            try LegacyImportContentProjection.digest([archiveEntry(), entry(oversizedPath)])
        }
    }

    @Test func aggregateManyEntryBudgetAcceptsExactCapAndRejectsOneMoreByte() throws {
        let many = (0..<18_000).map { index in
            entry(String(format: "f%05d", index))
        }
        let exactFiller = String(repeating: "z", count: 27_848)
        let exact = [archiveEntry()] + many + [entry(exactFiller)]

        _ = try LegacyImportContentProjection.digest(exact)
        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            try LegacyImportContentProjection.digest(
                [archiveEntry()] + many + [entry(exactFiller + "z")]
            )
        }
    }

    @Test func oversizedCardinalityFailsBudgetBeforePathOrAliasWork() {
        let invalidDuplicate = LegacyImportContentEntry(
            relativePath: "",
            byteCount: 0,
            sha256: hash()
        )
        let oversized = Array(repeating: invalidDuplicate, count: 20_834)

        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            try LegacyImportContentProjection.digest(oversized)
        }
    }

    private func entry(_ path: String) -> LegacyImportContentEntry {
        LegacyImportContentEntry(relativePath: path, byteCount: 0, sha256: hash())
    }

    private func hash(count: Int = 32) -> Data {
        Data(repeating: 0x5a, count: count)
    }

    private func archiveEntry() -> LegacyImportContentEntry {
        LegacyImportContentEntry(
            relativePath: "projects-v1.json",
            byteCount: 10,
            sha256: Data(repeating: 0, count: 32)
        )
    }
}

private struct SourcePhotoFixture {
    let service: KnitNoteBackupService
    let live: URL
    let root: URL
    let photoURL: URL
    let relativePath: String
}

private func sourcePhotoFixture(data: Data) throws -> SourcePhotoFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let live = root.appendingPathComponent("Source")
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    let projectID = UUID()
    let filename = "\(projectID.uuidString)-\(UUID().uuidString).jpg"
    var project = try StoredProject(id: projectID, name: "Observed")
    project.setPhotoFilename(filename)
    let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [project])
    try JSONEncoder().encode(archive).write(to: live.appendingPathComponent("projects-v1.json"))
    let relativePath = "ProjectPhotos/\(filename)"
    let photoURL = live.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: photoURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: photoURL)
    return SourcePhotoFixture(
        service: KnitNoteBackupService(
            liveRoot: live,
            workRoot: root.appendingPathComponent("Work")
        ),
        live: live,
        root: root,
        photoURL: photoURL,
        relativePath: relativePath
    )
}

private enum LegacySourceFault: CaseIterable {
    case symlink
    case hardlink
    case missing
}

private final class LegacySourceSwap: @unchecked Sendable {
    private let targetPath: String
    private let source: URL
    private let moved: URL
    private let replacement: Data
    private let lock = NSLock()
    private var hasRun = false

    init(targetPath: String, source: URL, moved: URL, replacement: Data) {
        self.targetPath = targetPath
        self.source = source
        self.moved = moved
        self.replacement = replacement
    }

    var didRun: Bool { lock.withLock { hasRun } }

    func run(relativePath: String) throws {
        guard relativePath == targetPath else { return }
        let shouldRun = lock.withLock {
            guard !hasRun else { return false }
            hasRun = true
            return true
        }
        guard shouldRun else { return }
        try FileManager.default.moveItem(at: source, to: moved)
        try replacement.write(to: source)
    }
}

private final class LegacySourceContentMutation: @unchecked Sendable {
    private let target: URL
    private let replacement: Data
    private let lock = NSLock()
    private var hasRun = false

    init(target: URL, replacement: Data) {
        self.target = target.standardizedFileURL
        self.replacement = replacement
    }

    var didRun: Bool { lock.withLock { hasRun } }

    func run(source: URL, copiedBytes: Int64) throws {
        guard source.standardizedFileURL == target, copiedBytes > 0 else { return }
        let shouldRun = lock.withLock {
            guard !hasRun else { return false }
            hasRun = true
            return true
        }
        guard shouldRun else { return }
        try replacement.write(to: target)
    }
}

private enum LegacyPreparedBackupFault: CaseIterable {
    case content
    case manifestHash
}

private func manifest(at packageURL: URL) throws -> KnitNoteBackupManifest {
    try JSONDecoder().decode(
        KnitNoteBackupManifest.self,
        from: Data(contentsOf: packageURL.appendingPathComponent("manifest.json"))
    )
}

private func rewriteManifest(
    at packageURL: URL,
    transform: (KnitNoteBackupManifest) throws -> KnitNoteBackupManifest
) throws {
    let url = packageURL.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(try transform(manifest(at: packageURL))).write(
        to: url,
        options: .atomic
    )
}

private final class LegacyPreparationMutation: @unchecked Sendable {
    private let targetStep: LegacyImportPreparationStep
    private let archiveURL: URL
    private let lock = NSLock()
    private var hasRun = false

    init(targetStep: LegacyImportPreparationStep, archiveURL: URL) {
        self.targetStep = targetStep
        self.archiveURL = archiveURL
    }

    var didRun: Bool { lock.withLock { hasRun } }

    func run(_ step: LegacyImportPreparationStep) throws {
        guard step == targetStep else { return }
        let shouldRun = lock.withLock {
            guard !hasRun else { return false }
            hasRun = true
            return true
        }
        guard shouldRun else { return }
        let archive = ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [try StoredProject(name: "changed during preparation")]
        )
        try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)
    }
}

private final class LegacyNthSourceContentMutation: @unchecked Sendable {
    private let target: URL
    private let replacement: Data
    private let targetRead: Int
    private let lock = NSLock()
    private var readCount = 0
    private var hasRun = false

    init(target: URL, replacement: Data, targetRead: Int) {
        self.target = target.standardizedFileURL
        self.replacement = replacement
        self.targetRead = targetRead
    }

    var didRun: Bool { lock.withLock { hasRun } }

    func run(source: URL, copiedBytes: Int64) throws {
        guard source.standardizedFileURL == target, copiedBytes > 0 else { return }
        let shouldRun = lock.withLock {
            readCount += 1
            guard readCount == targetRead, !hasRun else { return false }
            hasRun = true
            return true
        }
        guard shouldRun else { return }
        try replacement.write(to: target)
    }
}

private final class LegacySourceReadTracker: @unchecked Sendable {
    private let target: URL
    private let lock = NSLock()
    private var readTarget = false

    init(target: URL) {
        self.target = target.standardizedFileURL
    }

    var didReadTarget: Bool { lock.withLock { readTarget } }

    func run(source: URL, copiedBytes: Int64) {
        guard source.standardizedFileURL == target, copiedBytes > 0 else { return }
        lock.withLock { readTarget = true }
    }
}

private func sparseSourcePhotoFixture(byteCount: UInt64) throws -> SourcePhotoFixture {
    let fixture = try sourcePhotoFixture(data: Data())
    let handle = try FileHandle(forWritingTo: fixture.photoURL)
    try handle.truncate(atOffset: byteCount)
    try handle.close()
    return fixture
}
