import CloudKit
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import KnitNote

@Suite struct CloudAssetStagingServiceTests {
    @Test func canonicalMetadataRejectsInvalidDigestAndByteCount() throws {
        let slot = attachmentSlot()

        #expect(throws: SyncAttachmentVersionError.invalidMetadata) {
            _ = try SyncAttachmentVersion.issuing(
                slot: slot,
                contentSHA256: Data(repeating: 1, count: 31),
                byteCount: 1,
                mediaType: "image/jpeg",
                displayFilename: "cover.jpg"
            )
        }
        #expect(throws: SyncAttachmentVersionError.invalidMetadata) {
            _ = try SyncAttachmentVersion.issuing(
                slot: slot,
                contentSHA256: Data(repeating: 1, count: 32),
                byteCount: -1,
                mediaType: "image/jpeg",
                displayFilename: "cover.jpg"
            )
        }
    }

    @Test func stagesVerifiedImmutableBytesWithoutRetiringOriginalSource() throws {
        let fixture = try Fixture()
        let bytes = Data("durable upload".utf8)
        let source = try fixture.source(bytes, named: "original.jpg")
        let version = try fixture.version(for: bytes, versionID: fixedUUID(1))
        let mutationID = fixedUUID(11)

        let staged = try fixture.service.stageUpload(
            source: source,
            version: version,
            mutationID: mutationID
        )

        #expect(staged.version == version)
        #expect(staged.mutationID == mutationID)
        #expect(try Data(contentsOf: staged.stagedFileURL) == bytes)
        #expect(try Data(contentsOf: source.fileURL) == bytes)

        try Data("changed after staging".utf8).write(to: source.fileURL)
        #expect(try Data(contentsOf: staged.stagedFileURL) == bytes)
    }

    @Test func rejectsSourceWhoseHashOrSizeDoesNotMatchVersion() throws {
        let fixture = try Fixture()
        let expected = Data("expected".utf8)
        let source = try fixture.source(Data("different".utf8))
        let version = try fixture.version(for: expected)

        #expect(throws: CloudAssetStagingError.contentMismatch) {
            _ = try fixture.service.stageUpload(
                source: source,
                version: version,
                mutationID: UUID()
            )
        }
        #expect(try fixture.regularFiles(in: fixture.service.uploadsRootURL).isEmpty)
    }

    @Test func replacementVersionNeverMutatesOrOverwritesOldVersionBytes() throws {
        let fixture = try Fixture()
        let oldBytes = Data("old immutable version".utf8)
        let newBytes = Data("new immutable version".utf8)
        let oldVersion = try fixture.version(for: oldBytes, versionID: fixedUUID(2))
        let newVersion = try fixture.version(
            for: newBytes,
            versionID: fixedUUID(3),
            replacesVersionID: oldVersion.versionID
        )
        let old = try fixture.service.stageUpload(
            source: fixture.source(oldBytes, named: "old.jpg"),
            version: oldVersion,
            mutationID: fixedUUID(12)
        )
        let new = try fixture.service.stageUpload(
            source: fixture.source(newBytes, named: "new.jpg"),
            version: newVersion,
            mutationID: fixedUUID(13)
        )

        #expect(old.stagedFileURL != new.stagedFileURL)
        #expect(try Data(contentsOf: old.stagedFileURL) == oldBytes)
        #expect(try Data(contentsOf: new.stagedFileURL) == newBytes)
    }

    @Test func exactAcknowledgementsKeepSharedBytesUntilEveryReferenceIsRetired() throws {
        let fixture = try Fixture()
        let bytes = Data("one version two in-flight saves".utf8)
        let source = try fixture.source(bytes)
        let version = try fixture.version(for: bytes)
        let first = try fixture.service.stageUpload(
            source: source,
            version: version,
            mutationID: fixedUUID(21)
        )
        let second = try fixture.service.stageUpload(
            source: source,
            version: version,
            mutationID: fixedUUID(22)
        )

        #expect(first.stagedFileURL == second.stagedFileURL)
        #expect(throws: CloudAssetStagingError.unknownUpload) {
            try fixture.service.acknowledgeUpload(
                .init(
                    version: version,
                    mutationID: fixedUUID(99),
                    stagedFileURL: first.stagedFileURL
                ))
        }
        #expect(FileManager.default.fileExists(atPath: first.stagedFileURL.path))

        try fixture.service.acknowledgeUpload(first)
        #expect(FileManager.default.fileExists(atPath: first.stagedFileURL.path))
        #expect(try Data(contentsOf: source.fileURL) == bytes)

        try fixture.service.acknowledgeUpload(second)
        #expect(!FileManager.default.fileExists(atPath: first.stagedFileURL.path))
        #expect(throws: CloudAssetStagingError.unknownUpload) {
            try fixture.service.acknowledgeUpload(second)
        }
    }

    @Test func concurrentServiceInstancesPreserveEveryUploadReference() throws {
        let fixture = try Fixture()
        let other = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        let firstBytes = Data("first concurrent upload".utf8)
        let secondBytes = Data("second concurrent upload".utf8)
        let firstVersion = try fixture.version(for: firstBytes, versionID: fixedUUID(23))
        let secondVersion = try fixture.version(for: secondBytes, versionID: fixedUUID(24))
        let firstSource = try fixture.source(firstBytes, named: "first-concurrent.asset")
        let secondSource = try fixture.source(secondBytes, named: "second-concurrent.asset")
        let firstMutationID = fixedUUID(25)
        let secondMutationID = fixedUUID(26)
        let results = ConcurrentResults()

        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                let reference = try (index == 0 ? fixture.service : other).stageUpload(
                    source: index == 0 ? firstSource : secondSource,
                    version: index == 0 ? firstVersion : secondVersion,
                    mutationID: index == 0 ? firstMutationID : secondMutationID
                )
                results.append(.success(reference))
            } catch {
                results.append(.failure(error))
            }
        }

        let references = try results.values.map { try $0.get() }
        #expect(references.count == 2)
        for reference in references {
            _ = try fixture.service.asset(for: reference)
        }
    }

    @Test func createsFreshCKAssetForEveryAttemptAtStableStagedURL() throws {
        let fixture = try Fixture()
        let bytes = Data("fresh cloud assets".utf8)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: UUID()
        )

        let first = try fixture.service.asset(for: upload)
        let second = try fixture.service.asset(for: upload)

        #expect(first !== second)
        #expect(first.fileURL == upload.stagedFileURL)
        #expect(second.fileURL == upload.stagedFileURL)
    }

    @Test func accountsWithHostileIdentifiersRemainIsolatedBelowHashedRoots() throws {
        let fixture = try Fixture(accountIdentifier: "../../account-a")
        let other = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: "account-b"
        )
        let bytes = Data("isolated bytes".utf8)
        let version = try fixture.version(for: bytes)
        let first = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: version,
            mutationID: fixedUUID(31)
        )
        let second = try other.stageUpload(
            source: fixture.source(bytes, named: "other.jpg"),
            version: version,
            mutationID: fixedUUID(31)
        )

        #expect(first.stagedFileURL != second.stagedFileURL)
        #expect(first.stagedFileURL.path.hasPrefix(fixture.root.path + "/"))
        #expect(!first.stagedFileURL.path.contains("../"))
        try fixture.service.acknowledgeUpload(first)
        #expect(FileManager.default.fileExists(atPath: second.stagedFileURL.path))
    }

    @Test func downloadMismatchLeavesExistingVersionUntouchedAndQuarantinesDiagnosticBytes() throws
    {
        let fixture = try Fixture()
        let goodBytes = Data("verified download".utf8)
        let version = try fixture.version(for: goodBytes)
        let destination = try fixture.service.installDownload(
            from: fixture.source(goodBytes).fileURL,
            version: version
        )
        let corruptSource = try fixture.source(Data("corrupt download".utf8), named: "bad.asset")

        #expect(throws: CloudAssetStagingError.contentMismatch) {
            _ = try fixture.service.installDownload(
                from: corruptSource.fileURL,
                version: version
            )
        }

        #expect(try Data(contentsOf: destination) == goodBytes)
        let quarantined = try fixture.regularFiles(in: fixture.service.quarantineRootURL)
        #expect(quarantined.count == 1)
        #expect(try Data(contentsOf: quarantined[0]) == Data("corrupt download".utf8))
        #expect(FileManager.default.fileExists(atPath: corruptSource.fileURL.path))
    }

    @Test func installUsesNoClobberPathsForDistinctImmutableVersions() throws {
        let fixture = try Fixture()
        let firstBytes = Data("first installed".utf8)
        let secondBytes = Data("second installed".utf8)
        let firstVersion = try fixture.version(for: firstBytes, versionID: fixedUUID(41))
        let secondVersion = try fixture.version(
            for: secondBytes,
            versionID: fixedUUID(42),
            replacesVersionID: firstVersion.versionID
        )

        let first = try fixture.service.installDownload(
            from: fixture.source(firstBytes).fileURL,
            version: firstVersion
        )
        let second = try fixture.service.installDownload(
            from: fixture.source(secondBytes, named: "second.asset").fileURL,
            version: secondVersion
        )

        #expect(first != second)
        #expect(try Data(contentsOf: first) == firstBytes)
        #expect(try Data(contentsOf: second) == secondBytes)
    }

    @Test func interruptedAcknowledgementIsReconciledAfterRestart() throws {
        let fixture = try Fixture()
        let bytes = Data("ack crash bytes".utf8)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: UUID()
        )
        let controller = BoundaryController(failOnceAt: .acknowledgementAfterManifest)
        let interrupted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )

        #expect(throws: BoundaryFailure.interrupted) {
            try interrupted.acknowledgeUpload(upload)
        }
        #expect(FileManager.default.fileExists(atPath: upload.stagedFileURL.path))

        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        try restarted.reconcile()
        #expect(!FileManager.default.fileExists(atPath: upload.stagedFileURL.path))
    }

    @Test func interruptionBeforeUploadRenameLeavesNoPublishedReferenceAndRestartCleansTemps()
        throws
    {
        let fixture = try Fixture()
        let bytes = Data("interrupted upload".utf8)
        let controller = BoundaryController(failOnceAt: .uploadBeforeRename)
        let interrupted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )

        #expect(throws: BoundaryFailure.interrupted) {
            _ = try interrupted.stageUpload(
                source: fixture.source(bytes),
                version: fixture.version(for: bytes),
                mutationID: UUID()
            )
        }

        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        try restarted.reconcile()
        #expect(try fixture.regularFiles(in: restarted.uploadsRootURL).isEmpty)
    }

    @Test func interruptedManifestReplacementDoesNotCleanupAcknowledgedBytes() throws {
        let fixture = try Fixture()
        let bytes = Data("manifest crash bytes".utf8)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: UUID()
        )
        let controller = BoundaryController(failOnceAt: .manifestBeforeRename)
        let interrupted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )

        #expect(throws: BoundaryFailure.interrupted) {
            try interrupted.acknowledgeUpload(upload)
        }
        #expect(FileManager.default.fileExists(atPath: upload.stagedFileURL.path))

        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        _ = try restarted.asset(for: upload)
    }

    @Test func rejectsSymlinksFIFOsAndOversizedSourcesWithoutBlocking() throws {
        let fixture = try Fixture(maximumAssetBytes: 4)
        let target = try fixture.source(Data("safe".utf8), named: "target")
        let symlink = fixture.sources.appendingPathComponent("link")
        #expect(Darwin.symlink(target.fileURL.path, symlink.path) == 0)
        let symlinkSource = try SyncAttachmentSource(
            fileURL: symlink,
            contentSHA256: target.contentSHA256,
            byteCount: target.byteCount
        )
        let fifo = fixture.sources.appendingPathComponent("fifo")
        #expect(Darwin.mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0)
        let fifoSource = try SyncAttachmentSource(
            fileURL: fifo,
            contentSHA256: target.contentSHA256,
            byteCount: target.byteCount
        )
        let version = try fixture.version(for: Data("safe".utf8))

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try fixture.service.stageUpload(
                source: symlinkSource,
                version: version,
                mutationID: UUID()
            )
        }
        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try fixture.service.stageUpload(
                source: fifoSource,
                version: version,
                mutationID: UUID()
            )
        }

        let oversizedBytes = Data("12345".utf8)
        #expect(throws: CloudAssetStagingError.tooLarge) {
            _ = try fixture.service.stageUpload(
                source: fixture.source(oversizedBytes, named: "oversized"),
                version: fixture.version(for: oversizedBytes),
                mutationID: UUID()
            )
        }
    }

    @Test func rejectsUploadDirectorySymlinkSubstitution() throws {
        let fixture = try Fixture()
        let displaced = fixture.root.appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.service.uploadsRootURL, to: displaced)
        #expect(Darwin.symlink(displaced.path, fixture.service.uploadsRootURL.path) == 0)
        let bytes = Data("must not follow directory links".utf8)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try fixture.service.stageUpload(
                source: fixture.source(bytes),
                version: fixture.version(for: bytes),
                mutationID: UUID()
            )
        }
    }

    @Test func destinationSubstitutionCannotOverwriteOrEscapeInstallRoot() throws {
        let fixture = try Fixture()
        let bytes = Data("download substitution".utf8)
        let outside = try fixture.source(Data("outside".utf8), named: "outside")
        let controller = BoundaryController { boundary in
            guard case .downloadBeforeRename(let destination) = boundary else { return }
            #expect(Darwin.symlink(outside.fileURL.path, destination.path) == 0)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.installDownload(
                from: fixture.source(bytes).fileURL,
                version: fixture.version(for: bytes)
            )
        }
        #expect(try Data(contentsOf: outside.fileURL) == Data("outside".utf8))
    }

    @Test func quarantineUsesUniqueOwnedNamesAndNeverOverwritesDiagnostics() throws {
        let fixture = try Fixture()
        let bytes = Data("diagnostic bytes".utf8)
        let source = try fixture.source(bytes)

        let first = try fixture.service.quarantine(source.fileURL)
        let second = try fixture.service.quarantine(source.fileURL)

        #expect(first != second)
        #expect(first.deletingLastPathComponent() == fixture.service.quarantineRootURL)
        #expect(second.deletingLastPathComponent() == fixture.service.quarantineRootURL)
        #expect(try Data(contentsOf: first) == bytes)
        #expect(try Data(contentsOf: second) == bytes)
        #expect(FileManager.default.fileExists(atPath: source.fileURL.path))
    }
}

private enum BoundaryFailure: Error {
    case interrupted
}

private final class ConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<CloudAssetUploadReference, Error>] = []

    var values: [Result<CloudAssetUploadReference, Error>] {
        lock.withLock { storage }
    }

    func append(_ result: Result<CloudAssetUploadReference, Error>) {
        lock.withLock { storage.append(result) }
    }
}

private final class BoundaryController: @unchecked Sendable {
    private let lock = NSLock()
    private let failOnceAt: CloudAssetStagingBoundary?
    private let body: @Sendable (CloudAssetStagingBoundary) throws -> Void
    private var didFail = false

    init(failOnceAt: CloudAssetStagingBoundary) {
        self.failOnceAt = failOnceAt
        body = { _ in }
    }

    init(body: @escaping @Sendable (CloudAssetStagingBoundary) throws -> Void) {
        failOnceAt = nil
        self.body = body
    }

    func visit(_ boundary: CloudAssetStagingBoundary) throws {
        try body(boundary)
        lock.lock()
        defer { lock.unlock() }
        guard !didFail, boundary.sameKind(as: failOnceAt) else { return }
        didFail = true
        throw BoundaryFailure.interrupted
    }
}

private struct Fixture {
    let root: URL
    let cloudRoot: URL
    let sources: URL
    let accountIdentifier: String
    let service: CloudAssetStagingService

    init(
        accountIdentifier: String = "account-a",
        maximumAssetBytes: Int = 1_024 * 1_024
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CloudAssetStagingServiceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        sources = root.appendingPathComponent("Sources", isDirectory: true)
        cloudRoot = root.appendingPathComponent("Cloud", isDirectory: true)
        self.accountIdentifier = accountIdentifier
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        service = try CloudAssetStagingService(
            rootURL: cloudRoot,
            accountIdentifier: accountIdentifier,
            maximumAssetBytes: maximumAssetBytes
        )
    }

    func source(_ bytes: Data, named name: String = "source.asset") throws -> SyncAttachmentSource {
        let url = sources.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try bytes.write(to: url)
        return try SyncAttachmentSource(
            fileURL: url,
            contentSHA256: Data(SHA256.hash(data: bytes)),
            byteCount: Int64(bytes.count)
        )
    }

    func version(
        for bytes: Data,
        versionID: UUID = UUID(),
        replacesVersionID: UUID? = nil
    ) throws -> SyncAttachmentVersion {
        try SyncAttachmentVersion.issuing(
            slot: attachmentSlot(),
            contentSHA256: Data(SHA256.hash(data: bytes)),
            byteCount: Int64(bytes.count),
            mediaType: "image/jpeg",
            displayFilename: "cover.jpg",
            replacesVersionID: replacesVersionID,
            versionID: versionID
        )
    }

    func regularFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
    }
}

private func attachmentSlot() -> SyncAttachmentSlot {
    SyncAttachmentSlot(
        owner: .init(kind: .project, uuid: fixedUUID(100)),
        role: "project-photo",
        slotID: "cover"
    )
}

private func fixedUUID(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
}
