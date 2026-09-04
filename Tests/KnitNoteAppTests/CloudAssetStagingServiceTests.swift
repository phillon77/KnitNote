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

    @Test(.timeLimit(.minutes(1)))
    func accountFileLockSerializesAgainstASeparateProcess() throws {
        let fixture = try Fixture()
        let seedBytes = Data("seed lock file".utf8)
        _ = try fixture.service.stageUpload(
            source: fixture.source(seedBytes),
            version: fixture.version(for: seedBytes),
            mutationID: fixedUUID(27)
        )
        let lockURL = fixture.service.accountRootURL
            .appendingPathComponent(".asset-staging.lock")
        let readyURL = fixture.root.appendingPathComponent("child-lock-ready")
        let releaseURL = fixture.root.appendingPathComponent("child-lock-release")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [
            "-c",
            """
            import fcntl, os, sys, time
            descriptor = os.open(sys.argv[1], os.O_RDWR)
            fcntl.lockf(descriptor, fcntl.LOCK_EX)
            open(sys.argv[2], "x").close()
            while not os.path.exists(sys.argv[3]):
                time.sleep(0.01)
            fcntl.lockf(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
            """,
            lockURL.path,
            readyURL.path,
            releaseURL.path,
        ]
        try child.run()
        defer {
            if child.isRunning {
                _ = FileManager.default.createFile(atPath: releaseURL.path, contents: Data())
                child.terminate()
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: readyURL.path), Date() < deadline {
            usleep(10_000)
        }
        #expect(FileManager.default.fileExists(atPath: readyURL.path))

        let started = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let results = ConcurrentResults()
        let blockedBytes = Data("must wait for subprocess lock".utf8)
        let blockedSource = try fixture.source(blockedBytes, named: "blocked.asset")
        let blockedVersion = try fixture.version(for: blockedBytes)
        DispatchQueue.global().async {
            started.signal()
            do {
                results.append(.success(try fixture.service.stageUpload(
                    source: blockedSource,
                    version: blockedVersion,
                    mutationID: fixedUUID(28)
                )))
            } catch {
                results.append(.failure(error))
            }
            completed.signal()
        }
        #expect(started.wait(timeout: .now() + 1) == .success)
        #expect(completed.wait(timeout: .now() + 0.2) == .timedOut)

        #expect(FileManager.default.createFile(atPath: releaseURL.path, contents: Data()))
        #expect(completed.wait(timeout: .now() + 5) == .success)
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        #expect(try results.values.map { try $0.get() }.count == 1)
    }

    @Test func sameVersionIDDivergenceRejectsEveryImmutableFieldWithoutChangingState() throws {
        let fixture = try Fixture()
        let baseBytes = Data("base immutable version".utf8)
        let versionID = fixedUUID(29)
        let base = try fixture.version(for: baseBytes, versionID: versionID)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(baseBytes),
            version: base,
            mutationID: fixedUUID(30)
        )
        let manifestURL = fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json")
        let originalManifest = try Data(contentsOf: manifestURL)
        let otherBytes = Data("other immutable bytes".utf8)
        let otherOwner = SyncEntityID(kind: .project, uuid: fixedUUID(101))
        let otherRoleSlot = SyncAttachmentSlot(
            owner: base.slot.owner,
            role: "other-role",
            slotID: base.slot.slotID
        )
        let otherOwnerSlot = SyncAttachmentSlot(
            owner: otherOwner,
            role: base.slot.role,
            slotID: base.slot.slotID
        )
        let otherIDSlot = SyncAttachmentSlot(
            owner: base.slot.owner,
            role: base.slot.role,
            slotID: "other-slot"
        )
        func divergent(
            slot: SyncAttachmentSlot? = nil,
            bytes: Data? = nil,
            mediaType: String? = nil,
            filename: String? = nil,
            replaces: UUID? = nil
        ) throws -> (SyncAttachmentVersion, Data) {
            let chosenSlot = slot ?? base.slot
            let chosenBytes = bytes ?? baseBytes
            return (
                try SyncAttachmentVersion(
                    slot: chosenSlot,
                    versionID: versionID,
                    conflictGroupID: try SyncAttachmentVersion.conflictGroupID(for: chosenSlot),
                    contentSHA256: Data(SHA256.hash(data: chosenBytes)),
                    byteCount: Int64(chosenBytes.count),
                    mediaType: mediaType ?? base.mediaType,
                    displayFilename: filename ?? base.displayFilename,
                    replacesVersionID: replaces
                ),
                chosenBytes
            )
        }
        let variants = try [
            divergent(bytes: otherBytes),
            divergent(slot: otherRoleSlot),
            divergent(slot: otherOwnerSlot),
            divergent(slot: otherIDSlot),
            divergent(mediaType: "application/octet-stream"),
            divergent(filename: "other.jpg"),
            divergent(replaces: fixedUUID(102)),
        ]

        for (index, variant) in variants.enumerated() {
            #expect(throws: CloudAssetStagingError.immutableIdentityMismatch) {
                _ = try fixture.service.stageUpload(
                    source: fixture.source(variant.1, named: "divergent-\(index).asset"),
                    version: variant.0,
                    mutationID: fixedUUID(40 + index)
                )
            }
            #expect(try Data(contentsOf: manifestURL) == originalManifest)
            #expect(try Data(contentsOf: upload.stagedFileURL) == baseBytes)
            #expect(try fixture.regularFiles(in: fixture.service.uploadsRootURL).count == 1)
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
        var corruptBytes = goodBytes
        corruptBytes[corruptBytes.startIndex] ^= 0x01
        let corruptSource = try fixture.source(corruptBytes, named: "bad.asset")

        #expect(throws: CloudAssetStagingError.contentMismatch) {
            _ = try fixture.service.installDownload(
                from: corruptSource.fileURL,
                version: version
            )
        }

        #expect(try Data(contentsOf: destination) == goodBytes)
        let quarantined = try fixture.regularFiles(in: fixture.service.quarantineRootURL)
        #expect(quarantined.count == 1)
        #expect(try Data(contentsOf: quarantined[0]) == corruptBytes)
        #expect(FileManager.default.fileExists(atPath: corruptSource.fileURL.path))
    }

    @Test func oversizedDeclaredDownloadIsNotReadOrCopiedIntoQuarantine() throws {
        let fixture = try Fixture(maximumAssetBytes: 2_000_000)
        let expected = Data("safe".utf8)
        let oversized = Data(repeating: 0x41, count: 1_000_000)
        let source = try fixture.source(oversized, named: "oversized-download.asset")

        #expect(throws: CloudAssetStagingError.contentMismatch) {
            _ = try fixture.service.installDownload(
                from: source.fileURL,
                version: fixture.version(for: expected)
            )
        }

        let quarantined = try fixture.regularFiles(in: fixture.service.quarantineRootURL)
        #expect(quarantined.count == 1)
        #expect(try Data(contentsOf: quarantined[0]).count <= expected.count + 1)
        #expect(try Data(contentsOf: source.fileURL) == oversized)
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

    @Test func exactRestageCancelsInterruptedAcknowledgementAndSurvivesRestart() throws {
        let fixture = try Fixture()
        let bytes = Data("restaged acknowledgement bytes".utf8)
        let source = try fixture.source(bytes)
        let version = try fixture.version(for: bytes, versionID: fixedUUID(103))
        let mutationID = fixedUUID(104)
        let upload = try fixture.service.stageUpload(
            source: source,
            version: version,
            mutationID: mutationID
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

        let restaged = try interrupted.stageUpload(
            source: source,
            version: version,
            mutationID: mutationID
        )
        #expect(restaged == upload)

        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        _ = try restarted.asset(for: restaged)
        try restarted.reconcile()
        _ = try restarted.asset(for: restaged)
        try restarted.acknowledgeUpload(restaged)
        #expect(!FileManager.default.fileExists(atPath: restaged.stagedFileURL.path))
    }

    @Test func divergentRestageAfterInterruptedAcknowledgementPreservesDurableState() throws {
        let fixture = try Fixture()
        let originalBytes = Data("original acknowledgement bytes".utf8)
        let original = try fixture.service.stageUpload(
            source: fixture.source(originalBytes),
            version: fixture.version(for: originalBytes, versionID: fixedUUID(105)),
            mutationID: fixedUUID(106)
        )
        let controller = BoundaryController(failOnceAt: .acknowledgementAfterManifest)
        let interrupted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        #expect(throws: BoundaryFailure.interrupted) {
            try interrupted.acknowledgeUpload(original)
        }
        let manifestURL = interrupted.accountRootURL
            .appendingPathComponent("upload-references.json")
        let durableManifest = try Data(contentsOf: manifestURL)
        let durableFiles = try fixture.regularFiles(in: interrupted.uploadsRootURL)
        let divergentBytes = Data("divergent acknowledgement bytes".utf8)

        #expect(throws: CloudAssetStagingError.immutableIdentityMismatch) {
            _ = try interrupted.stageUpload(
                source: fixture.source(divergentBytes, named: "divergent-restage.asset"),
                version: fixture.version(for: divergentBytes, versionID: fixedUUID(107)),
                mutationID: original.mutationID
            )
        }
        #expect(try Data(contentsOf: manifestURL) == durableManifest)
        #expect(try fixture.regularFiles(in: interrupted.uploadsRootURL) == durableFiles)
        #expect(try Data(contentsOf: original.stagedFileURL) == originalBytes)

        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        try restarted.reconcile()
        #expect(!FileManager.default.fileExists(atPath: original.stagedFileURL.path))
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

    @Test func validJSONReferenceRemovalCannotAuthorizeStagedByteCleanup() throws {
        let fixture = try Fixture()
        let bytes = Data("checksum protects upload authority".utf8)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(71)
        )
        let manifestURL = fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        )
        if var payload = object["payload"] as? [String: Any] {
            payload["references"] = []
            object["payload"] = payload
        } else {
            object["references"] = []
        }
        let mutatedManifest = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try mutatedManifest.write(to: manifestURL)

        #expect(throws: CloudAssetStagingError.corruptManifest) {
            try fixture.service.reconcile()
        }
        #expect(try Data(contentsOf: manifestURL) == mutatedManifest)
        #expect(try Data(contentsOf: upload.stagedFileURL) == bytes)
    }

    @Test func validJSONReferenceMutationCannotChangeUploadAuthority() throws {
        let fixture = try Fixture()
        let bytes = Data("mutated manifest reference".utf8)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(72)
        )
        let manifestURL = fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        )
        if var payload = object["payload"] as? [String: Any],
            var references = payload["references"] as? [[String: Any]],
            !references.isEmpty
        {
            references[0]["mutationID"] = fixedUUID(73).uuidString
            payload["references"] = references
            object["payload"] = payload
        } else if var references = object["references"] as? [[String: Any]],
            !references.isEmpty
        {
            references[0]["mutationID"] = fixedUUID(73).uuidString
            object["references"] = references
        } else {
            Issue.record("Manifest did not contain an upload reference")
        }
        let mutatedManifest = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try mutatedManifest.write(to: manifestURL)

        #expect(throws: CloudAssetStagingError.corruptManifest) {
            try fixture.service.reconcile()
        }
        #expect(try Data(contentsOf: manifestURL) == mutatedManifest)
        #expect(try Data(contentsOf: upload.stagedFileURL) == bytes)
    }

    @Test func missingManifestWithFinalUploadFailsClosedAndPreservesBytes() throws {
        let fixture = try Fixture()
        let bytes = Data("missing manifest cannot revoke authority".utf8)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(74)
        )
        let manifestURL = fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json")
        try FileManager.default.removeItem(at: manifestURL)

        #expect(throws: CloudAssetStagingError.corruptManifest) {
            try fixture.service.reconcile()
        }
        #expect(try Data(contentsOf: upload.stagedFileURL) == bytes)
        #expect(!FileManager.default.fileExists(atPath: manifestURL.path))
    }

    @Test func uploadPublishedBeforeManifestIsPreservedWithoutCleanupAuthority() throws {
        let fixture = try Fixture()
        let bytes = Data("published before manifest".utf8)
        let controller = BoundaryController(failOnceAt: .uploadBeforeDirectorySync)
        let interrupted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )

        #expect(throws: BoundaryFailure.interrupted) {
            _ = try interrupted.stageUpload(
                source: fixture.source(bytes),
                version: fixture.version(for: bytes),
                mutationID: fixedUUID(75)
            )
        }
        let published = try #require(
            fixture.regularFiles(in: interrupted.uploadsRootURL).first
        )

        #expect(throws: CloudAssetStagingError.corruptManifest) {
            try fixture.service.reconcile()
        }
        #expect(try Data(contentsOf: published) == bytes)
    }

    @Test func interruptedCleanupMoveIsCompletedOnlyFromExactDurableAckIntent() throws {
        let fixture = try Fixture()
        let bytes = Data("cleanup tombstone bytes".utf8)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(76)
        )
        let controller = BoundaryController(failOnceAt: .cleanupAfterMove)
        let interrupted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )

        #expect(throws: BoundaryFailure.interrupted) {
            try interrupted.acknowledgeUpload(upload)
        }
        #expect(!FileManager.default.fileExists(atPath: upload.stagedFileURL.path))
        let tombstone = try #require(
            fixture.regularFiles(in: interrupted.uploadsRootURL)
                .first(where: { $0.lastPathComponent.hasSuffix(".cleanup") })
        )
        #expect(try Data(contentsOf: tombstone) == bytes)

        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        try restarted.reconcile()
        #expect(try fixture.regularFiles(in: restarted.uploadsRootURL).isEmpty)
        #expect(throws: CloudAssetStagingError.unknownUpload) {
            try restarted.acknowledgeUpload(upload)
        }
    }

    @Test func reconcileRemovesOnlyExactServiceGeneratedCrashTemporaries() throws {
        let fixture = try Fixture()
        let bytes = Data("keeps manifest valid".utf8)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(77)
        )
        let manifestTemporary = fixture.service.accountRootURL
            .appendingPathComponent(".upload-references.json.\(UUID().uuidString).tmp")
        let uploadTemporary = fixture.service.uploadsRootURL.appendingPathComponent(
            ".\(upload.stagedFileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let installedTemporary = fixture.service.installedRootURL.appendingPathComponent(
            ".\(upload.stagedFileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let quarantineTemporary = fixture.service.quarantineRootURL
            .appendingPathComponent(
                ".\(UUID().uuidString.lowercased()).asset.\(UUID().uuidString).tmp"
            )
        try Data("old manifest bytes".utf8).write(to: manifestTemporary)
        try Data("partial upload bytes".utf8).write(to: uploadTemporary)
        try Data("partial install bytes".utf8).write(to: installedTemporary)
        try Data("partial quarantine bytes".utf8).write(to: quarantineTemporary)

        try fixture.service.reconcile()

        #expect(!FileManager.default.fileExists(atPath: manifestTemporary.path))
        #expect(!FileManager.default.fileExists(atPath: uploadTemporary.path))
        #expect(!FileManager.default.fileExists(atPath: installedTemporary.path))
        #expect(!FileManager.default.fileExists(atPath: quarantineTemporary.path))
        #expect(try Data(contentsOf: upload.stagedFileURL) == bytes)
        _ = try fixture.service.asset(for: upload)
    }

    @Test func reconcileRejectsAndPreservesUnknownTemporaryNamesInEveryRoot() throws {
        for location in 0 ..< 4 {
            let fixture = try Fixture()
            let unknown: URL
            switch location {
            case 0:
                unknown = fixture.service.uploadsRootURL.appendingPathComponent("unknown.tmp")
            case 1:
                unknown = fixture.service.installedRootURL.appendingPathComponent(".unknown.tmp")
            case 2:
                unknown = fixture.service.accountRootURL
                    .appendingPathComponent(".upload-references.json.not-a-uuid.tmp")
            default:
                unknown = fixture.service.quarantineRootURL
                    .appendingPathComponent(".unknown.asset.not-a-uuid.tmp")
            }
            let bytes = Data("unknown temporary \(location)".utf8)
            try bytes.write(to: unknown)

            #expect(throws: CloudAssetStagingError.unsafeFile, "location \(location)") {
                try fixture.service.reconcile()
            }
            #expect(try Data(contentsOf: unknown) == bytes)
        }
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

    @Test func mismatchGrowthBeforeQuarantineReopenNeverReadsPastDeclaredBound() throws {
        let fixture = try Fixture(maximumAssetBytes: 1_000_000)
        let expected = Data("safe".utf8)
        let corrupt = Data("evil".utf8)
        let source = try fixture.source(corrupt, named: "growing-mismatch.asset")
        let counters = SyncRegularFileReaderIOCounters()
        let invocations = ReadInvocationController(runOnInvocation: 2) {
            try Data(repeating: 0x41, count: 900_000).write(to: source.fileURL)
        }
        let reader = SyncRegularFileReader(
            beforeRead: invocations.visit,
            ioCounters: counters
        )
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            maximumAssetBytes: 1_000_000,
            externalReader: reader
        )

        #expect(throws: CloudAssetStagingError.contentMismatch) {
            _ = try service.installDownload(
                from: source.fileURL,
                version: fixture.version(for: expected)
            )
        }
        #expect(counters.bytesRead == corrupt.count + expected.count + 1)
        #expect(try Data(contentsOf: source.fileURL).count == 900_000)
        let quarantined = try fixture.regularFiles(in: service.quarantineRootURL)
        #expect(quarantined.count == 1)
        #expect(try Data(contentsOf: quarantined[0]).isEmpty)
    }

    @Test func manifestSubstitutionAfterIdentityCheckIsNotOverwritten() throws {
        let fixture = try Fixture()
        let firstBytes = Data("first manifest authority".utf8)
        let first = try fixture.service.stageUpload(
            source: fixture.source(firstBytes),
            version: fixture.version(for: firstBytes),
            mutationID: fixedUUID(81)
        )
        let replacementBytes = Data("attacker replacement manifest".utf8)
        let controller = BoundaryController { boundary in
            guard case .manifestAfterIdentityCheck(let destination) = boundary else { return }
            try FileManager.default.removeItem(at: destination)
            try replacementBytes.write(to: destination)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let secondBytes = Data("second manifest authority".utf8)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(secondBytes, named: "second-manifest.asset"),
                version: fixture.version(for: secondBytes),
                mutationID: fixedUUID(82)
            )
        }
        let manifestURL = fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json")
        #expect(try Data(contentsOf: manifestURL) == replacementBytes)
        #expect(try Data(contentsOf: first.stagedFileURL) == firstBytes)
    }

    @Test func manifestContentChangedAfterLoadFailsPublicationCASWithoutTruncatingReplacement()
        throws
    {
        let fixture = try Fixture()
        let firstBytes = Data("manifest authority loaded before mutation".utf8)
        let first = try fixture.service.stageUpload(
            source: fixture.source(firstBytes),
            version: fixture.version(for: firstBytes),
            mutationID: fixedUUID(127)
        )
        let manifestURL = fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json")
        let replacementBytes = Data("same inode but different manifest generation".utf8)
        let controller = BoundaryController { boundary in
            guard case .manifestAfterLoad(let destination) = boundary else { return }
            let handle = try FileHandle(forWritingTo: destination)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: replacementBytes)
            try handle.synchronize()
            try handle.close()
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let secondBytes = Data("must not publish from stale loaded manifest".utf8)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(secondBytes, named: "load-cas.asset"),
                version: fixture.version(for: secondBytes),
                mutationID: fixedUUID(128)
            )
        }
        #expect(try Data(contentsOf: manifestURL) == replacementBytes)
        #expect(try Data(contentsOf: first.stagedFileURL) == firstBytes)
    }

    @Test func manifestDestinationSubstitutionAfterSwapRestoresPriorManifest() throws {
        let fixture = try Fixture()
        let firstBytes = Data("prior manifest upload".utf8)
        let first = try fixture.service.stageUpload(
            source: fixture.source(firstBytes),
            version: fixture.version(for: firstBytes),
            mutationID: fixedUUID(108)
        )
        let manifestURL = fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json")
        let priorManifest = try Data(contentsOf: manifestURL)
        let movedNewManifest = fixture.sources.appendingPathComponent("moved-new-manifest")
        let attackerBytes = Data("post-swap attacker bytes".utf8)
        let controller = BoundaryController { boundary in
            guard case .manifestAfterSwap(let destination, _) = boundary else { return }
            try FileManager.default.moveItem(at: destination, to: movedNewManifest)
            try attackerBytes.write(to: destination)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let secondBytes = Data("never published upload".utf8)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(secondBytes, named: "post-swap.asset"),
                version: fixture.version(for: secondBytes),
                mutationID: fixedUUID(109)
            )
        }
        #expect(try Data(contentsOf: manifestURL) == priorManifest)
        #expect(try Data(contentsOf: movedNewManifest) != priorManifest)
        #expect(try Data(contentsOf: first.stagedFileURL) == firstBytes)
        let preservedAttacker = try FileManager.default.contentsOfDirectory(
            at: fixture.service.accountRootURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).first { url in
            (try? Data(contentsOf: url)) == attackerBytes
        }
        #expect(preservedAttacker != nil)
    }

    @Test func firstManifestDestinationSubstitutionBeforeDirectorySyncCannotSucceed() throws {
        let fixture = try Fixture()
        let savedCandidate = fixture.sources.appendingPathComponent("saved-first-manifest")
        let replacementBytes = Data("first manifest path replacement".utf8)
        let controller = BoundaryController { boundary in
            guard case .manifestBeforeDirectorySync = boundary else { return }
            let manifest = fixture.service.accountRootURL
                .appendingPathComponent("upload-references.json")
            try FileManager.default.moveItem(at: manifest, to: savedCandidate)
            try replacementBytes.write(to: manifest)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let bytes = Data("first manifest candidate upload".utf8)
        let version = try fixture.version(for: bytes)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(bytes),
                version: version,
                mutationID: fixedUUID(120)
            )
        }
        #expect(FileManager.default.fileExists(atPath: savedCandidate.path))
        let preservedReplacement = try FileManager.default.contentsOfDirectory(
            at: service.accountRootURL,
            includingPropertiesForKeys: nil
        ).first(where: { (try? Data(contentsOf: $0)) == replacementBytes })
        #expect(preservedReplacement != nil)

        let recovered = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        _ = try recovered.stageUpload(
            source: fixture.source(bytes, named: "retry-first-manifest.asset"),
            version: version,
            mutationID: fixedUUID(120)
        )
        try recovered.reconcile()
        #expect(try Data(contentsOf: preservedReplacement!) == replacementBytes)
    }

    @Test func immutableDestinationSubstitutionBeforeDirectorySyncCannotSucceed() throws {
        let fixture = try Fixture()
        let bytes = Data("immutable destination candidate".utf8)
        let replacementBytes = Data("immutable destination replacement".utf8)
        let displaced = fixture.sources.appendingPathComponent("saved-immutable-candidate")
        let controller = BoundaryController { boundary in
            guard case .uploadBeforeDirectorySync = boundary else { return }
            let published = try #require(
                fixture.regularFiles(in: fixture.service.uploadsRootURL)
                    .first(where: { $0.lastPathComponent.hasSuffix(".asset") })
            )
            try FileManager.default.moveItem(at: published, to: displaced)
            try replacementBytes.write(to: published)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(bytes),
                version: fixture.version(for: bytes),
                mutationID: fixedUUID(121)
            )
        }
        #expect(try Data(contentsOf: displaced) == bytes)
        let survivingReplacement = try fixture.regularFiles(in: service.uploadsRootURL)
            .first(where: { (try? Data(contentsOf: $0)) == replacementBytes })
        #expect(survivingReplacement != nil)
    }

    @Test func manifestSubstitutionAfterFinalCheckCannotDeleteReplacementOrPublishCandidate()
        throws
    {
        let fixture = try Fixture()
        let firstBytes = Data("manifest authority before final-check race".utf8)
        _ = try fixture.service.stageUpload(
            source: fixture.source(firstBytes),
            version: fixture.version(for: firstBytes),
            mutationID: fixedUUID(114)
        )
        let manifestURL = fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json")
        let priorManifest = try Data(contentsOf: manifestURL)
        let savedPriorManifest = fixture.sources.appendingPathComponent("saved-final-check-prior")
        let replacementBytes = Data("final-check replacement manifest".utf8)
        let controller = BoundaryController { boundary in
            guard case .manifestAfterFinalIdentityCheck(_, let displaced) = boundary else {
                return
            }
            try FileManager.default.moveItem(at: displaced, to: savedPriorManifest)
            try replacementBytes.write(to: displaced)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let secondBytes = Data("candidate must not remain published".utf8)
        let secondVersion = try fixture.version(for: secondBytes)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(secondBytes, named: "final-check-candidate.asset"),
                version: secondVersion,
                mutationID: fixedUUID(115)
            )
        }
        #expect(try Data(contentsOf: savedPriorManifest) == priorManifest)
        #expect(try Data(contentsOf: manifestURL) == priorManifest)
        let preservedReplacement = try FileManager.default.contentsOfDirectory(
            at: service.accountRootURL,
            includingPropertiesForKeys: nil
        ).first(where: { (try? Data(contentsOf: $0)) == replacementBytes })
        #expect(preservedReplacement != nil)

        let recovered = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        _ = try recovered.stageUpload(
            source: fixture.source(secondBytes, named: "retry-final-check.asset"),
            version: secondVersion,
            mutationID: fixedUUID(115)
        )
        try recovered.reconcile()
        #expect(try Data(contentsOf: preservedReplacement!) == replacementBytes)
    }

    @Test func manifestSubstitutionAtCommitBoundaryRollsBackPublishedCandidate() throws {
        let fixture = try Fixture()
        let firstBytes = Data("manifest before commit-boundary substitution".utf8)
        _ = try fixture.service.stageUpload(
            source: fixture.source(firstBytes),
            version: fixture.version(for: firstBytes),
            mutationID: fixedUUID(124)
        )
        let manifest = fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json")
        let priorManifest = try Data(contentsOf: manifest)
        let savedCandidate = fixture.sources.appendingPathComponent("saved-commit-candidate")
        let replacementBytes = Data("commit boundary replacement".utf8)
        let controller = BoundaryController { boundary in
            guard case .manifestBeforeDirectorySync = boundary else { return }
            try FileManager.default.moveItem(at: manifest, to: savedCandidate)
            try replacementBytes.write(to: manifest)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let secondBytes = Data("manifest candidate rejected at commit boundary".utf8)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(secondBytes),
                version: fixture.version(for: secondBytes),
                mutationID: fixedUUID(125)
            )
        }
        #expect(try Data(contentsOf: manifest) == priorManifest)
        #expect(FileManager.default.fileExists(atPath: savedCandidate.path))
        let preservedReplacement = try FileManager.default.contentsOfDirectory(
            at: service.accountRootURL,
            includingPropertiesForKeys: nil
        ).first(where: { (try? Data(contentsOf: $0)) == replacementBytes })
        #expect(preservedReplacement != nil)
    }

    @Test func firstManifestInPlaceMutationAtCommitBoundaryFailsClosedAndReinstallsCandidate()
        throws
    {
        let fixture = try Fixture()
        let adversarialBytes = Data("same-inode first-manifest mutation".utf8)
        let controller = BoundaryController { boundary in
            guard case .manifestBeforeDirectorySync = boundary else { return }
            let manifest = fixture.service.accountRootURL
                .appendingPathComponent("upload-references.json")
            let handle = try FileHandle(forWritingTo: manifest)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: adversarialBytes)
            try handle.synchronize()
            try handle.close()
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let bytes = Data("recoverable first-manifest authority".utf8)
        let version = try fixture.version(for: bytes)
        let mutationID = fixedUUID(131)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(bytes),
                version: version,
                mutationID: mutationID
            )
        }
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))

        let recovered = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        let reference = try recovered.stageUpload(
            source: fixture.source(bytes, named: "retry-first-in-place.asset"),
            version: version,
            mutationID: mutationID
        )
        _ = try recovered.asset(for: reference)
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))
    }

    @Test func replacementManifestInPlaceMutationAtCommitBoundaryRestoresLoadedAuthority()
        throws
    {
        let fixture = try Fixture()
        let firstBytes = Data("loaded manifest survives candidate mutation".utf8)
        let first = try fixture.service.stageUpload(
            source: fixture.source(firstBytes),
            version: fixture.version(for: firstBytes),
            mutationID: fixedUUID(132)
        )
        let manifest = fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json")
        let loadedAuthority = try Data(contentsOf: manifest)
        let adversarialBytes = Data("same-inode replacement-manifest mutation".utf8)
        let controller = BoundaryController { boundary in
            guard case .manifestBeforeDirectorySync = boundary else { return }
            let handle = try FileHandle(forWritingTo: manifest)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: adversarialBytes)
            try handle.synchronize()
            try handle.close()
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let secondBytes = Data("candidate rejected after in-place mutation".utf8)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(secondBytes),
                version: fixture.version(for: secondBytes),
                mutationID: fixedUUID(133)
            )
        }
        #expect(try Data(contentsOf: manifest) == loadedAuthority)
        #expect(try Data(contentsOf: first.stagedFileURL) == firstBytes)
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))
    }

    @Test func displacedManifestInPlaceMutationAfterFinalCheckIsPreservedAndFailsClosed()
        throws
    {
        let fixture = try Fixture()
        let firstBytes = Data("loaded displaced manifest authority".utf8)
        let first = try fixture.service.stageUpload(
            source: fixture.source(firstBytes),
            version: fixture.version(for: firstBytes),
            mutationID: fixedUUID(134)
        )
        let manifest = fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json")
        let loadedAuthority = try Data(contentsOf: manifest)
        let adversarialBytes = Data("same-inode displaced-manifest mutation".utf8)
        let controller = BoundaryController { boundary in
            guard case .manifestAfterFinalIdentityCheck(_, let displaced) = boundary else {
                return
            }
            let handle = try FileHandle(forWritingTo: displaced)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: adversarialBytes)
            try handle.synchronize()
            try handle.close()
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let secondBytes = Data("candidate cannot retire mutated authority".utf8)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(secondBytes),
                version: fixture.version(for: secondBytes),
                mutationID: fixedUUID(135)
            )
        }
        #expect(try Data(contentsOf: manifest) == loadedAuthority)
        #expect(try Data(contentsOf: first.stagedFileURL) == firstBytes)
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))
    }

    @Test func displacedManifestMutationAtDirectorySyncIsNeverTruncatedDuringRollback() throws {
        let fixture = try Fixture()
        let firstBytes = Data("manifest authority before rollback retirement".utf8)
        let first = try fixture.service.stageUpload(
            source: fixture.source(firstBytes),
            version: fixture.version(for: firstBytes),
            mutationID: fixedUUID(142)
        )
        let manifest = fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json")
        let loadedAuthority = try Data(contentsOf: manifest)
        let adversarialBytes = Data("manifest mutation at directory sync".utf8)
        let controller = BoundaryController { boundary in
            guard case .manifestBeforeDirectorySync = boundary else { return }
            let retired = fixture.service.accountRootURL.appendingPathComponent("Retired")
            let displaced = try #require(
                fixture.regularFiles(in: retired).first(where: {
                    $0.lastPathComponent.hasPrefix("manifest.")
                        && ((try? Data(contentsOf: $0).isEmpty) == false)
                })
            )
            let handle = try FileHandle(forWritingTo: displaced)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: adversarialBytes)
            try handle.synchronize()
            try handle.close()
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let secondBytes = Data("candidate rejected before rollback retirement".utf8)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(secondBytes),
                version: fixture.version(for: secondBytes),
                mutationID: fixedUUID(143)
            )
        }
        #expect(try Data(contentsOf: manifest) == loadedAuthority)
        #expect(try Data(contentsOf: first.stagedFileURL) == firstBytes)
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))

        let recovered = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        let recoveredSecond = try recovered.stageUpload(
            source: fixture.source(secondBytes, named: "retry-directory-sync-retirement.asset"),
            version: fixture.version(for: secondBytes),
            mutationID: fixedUUID(143)
        )
        _ = try recovered.asset(for: recoveredSecond)
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))
    }

    @Test func committedManifestMutationImmediatelyBeforeRetirementFailsAndSurvives() throws {
        let fixture = try Fixture()
        let firstBytes = Data("manifest authority before committed retirement".utf8)
        _ = try fixture.service.stageUpload(
            source: fixture.source(firstBytes),
            version: fixture.version(for: firstBytes),
            mutationID: fixedUUID(144)
        )
        let oldManifest = try Data(contentsOf: fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json"))
        let adversarialBytes = Data("committed manifest final-retirement mutation".utf8)
        let controller = BoundaryController { boundary in
            guard case .retirementBeforeTruncate(let candidate) = boundary,
                candidate.lastPathComponent.hasPrefix("manifest.")
            else { return }
            let handle = try FileHandle(forWritingTo: candidate)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: adversarialBytes)
            try handle.synchronize()
            try handle.close()
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let secondBytes = Data("manifest candidate committed before cleanup failure".utf8)
        let secondVersion = try fixture.version(for: secondBytes)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(secondBytes),
                version: secondVersion,
                mutationID: fixedUUID(145)
            )
        }
        let committedManifest = try Data(contentsOf: service.accountRootURL
            .appendingPathComponent("upload-references.json"))
        #expect(committedManifest != oldManifest)
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))

        let recovered = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        let recoveredSecond = try recovered.stageUpload(
            source: fixture.source(secondBytes, named: "retry-committed-retirement.asset"),
            version: secondVersion,
            mutationID: fixedUUID(145)
        )
        _ = try recovered.asset(for: recoveredSecond)
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))
    }

    @Test func rollbackManifestMutationImmediatelyBeforeRetirementFailsAndSurvives() throws {
        let fixture = try Fixture()
        let firstBytes = Data("manifest authority before interrupted retirement".utf8)
        let first = try fixture.service.stageUpload(
            source: fixture.source(firstBytes),
            version: fixture.version(for: firstBytes),
            mutationID: fixedUUID(146)
        )
        let manifest = fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json")
        let loadedAuthority = try Data(contentsOf: manifest)
        let adversarialBytes = Data("rollback manifest final-retirement mutation".utf8)
        let controller = ManifestRollbackRetirementController(adversarialBytes: adversarialBytes)
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let secondBytes = Data("manifest candidate interrupted before commit".utf8)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(secondBytes),
                version: fixture.version(for: secondBytes),
                mutationID: fixedUUID(147)
            )
        }
        #expect(try Data(contentsOf: manifest) == loadedAuthority)
        #expect(try Data(contentsOf: first.stagedFileURL) == firstBytes)
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))

        let recovered = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        let recoveredSecond = try recovered.stageUpload(
            source: fixture.source(secondBytes, named: "retry-interrupted-retirement.asset"),
            version: fixture.version(for: secondBytes),
            mutationID: fixedUUID(147)
        )
        _ = try recovered.asset(for: recoveredSecond)
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))
    }

    @Test func nonregularDisplacedManifestAfterSwapCannotLeaveNewManifestPublished() throws {
        let fixture = try Fixture()
        let firstBytes = Data("manifest before displaced substitution".utf8)
        _ = try fixture.service.stageUpload(
            source: fixture.source(firstBytes),
            version: fixture.version(for: firstBytes),
            mutationID: fixedUUID(110)
        )
        let manifestURL = fixture.service.accountRootURL
            .appendingPathComponent("upload-references.json")
        let priorManifest = try Data(contentsOf: manifestURL)
        let savedPriorManifest = fixture.sources.appendingPathComponent("saved-prior-manifest")
        let controller = BoundaryController { boundary in
            guard case .manifestAfterSwap(_, let displaced) = boundary else { return }
            try FileManager.default.moveItem(at: displaced, to: savedPriorManifest)
            #expect(Darwin.mkfifo(displaced.path, S_IRUSR | S_IWUSR) == 0)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let secondBytes = Data("manifest that must roll back".utf8)
        let secondVersion = try fixture.version(for: secondBytes)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(secondBytes, named: "displaced-nonregular.asset"),
                version: secondVersion,
                mutationID: fixedUUID(111)
            )
        }
        #expect(try Data(contentsOf: savedPriorManifest) == priorManifest)
        #expect(try Data(contentsOf: manifestURL) == priorManifest)
        let preservedFIFO = try FileManager.default.contentsOfDirectory(
            at: service.accountRootURL,
            includingPropertiesForKeys: nil
        ).contains { candidate in
            var status = stat()
            return candidate.path.withCString { Darwin.lstat($0, &status) } == 0
                && (status.st_mode & S_IFMT) == S_IFIFO
        }
        #expect(preservedFIFO)

        let recovered = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        _ = try recovered.stageUpload(
            source: fixture.source(secondBytes, named: "retry-displaced-nonregular.asset"),
            version: secondVersion,
            mutationID: fixedUUID(111)
        )
        try recovered.reconcile()
    }

    @Test func cleanupSubstitutionAfterIdentityCheckIsMovedBackWithoutUnlinking() throws {
        let fixture = try Fixture()
        let bytes = Data("acknowledged immutable bytes".utf8)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(83)
        )
        let displaced = fixture.sources.appendingPathComponent("displaced-upload.asset")
        let replacementBytes = Data("replacement must survive".utf8)
        let controller = BoundaryController { boundary in
            guard case .cleanupAfterIdentityCheck(let candidate) = boundary else { return }
            try FileManager.default.moveItem(at: candidate, to: displaced)
            try replacementBytes.write(to: candidate)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            try service.acknowledgeUpload(upload)
        }
        #expect(try Data(contentsOf: upload.stagedFileURL) == replacementBytes)
        #expect(try Data(contentsOf: displaced) == bytes)
    }

    @Test func cleanupSubstitutionImmediatelyBeforeUnlinkPreservesBothFiles() throws {
        let fixture = try Fixture()
        let bytes = Data("descriptor-bound cleanup bytes".utf8)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(112)
        )
        let displaced = fixture.sources.appendingPathComponent("pre-unlink-displaced.asset")
        let replacementBytes = Data("pre-unlink replacement survives".utf8)
        let controller = BoundaryController { boundary in
            guard case .cleanupBeforeUnlink(let tombstone) = boundary else { return }
            try FileManager.default.moveItem(at: tombstone, to: displaced)
            try replacementBytes.write(to: tombstone)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            try service.acknowledgeUpload(upload)
        }
        #expect(try Data(contentsOf: displaced) == bytes)
        let cleanupResidue = try #require(
            fixture.regularFiles(in: service.uploadsRootURL)
                .first(where: { $0.lastPathComponent.hasSuffix(".cleanup") })
        )
        #expect(try Data(contentsOf: cleanupResidue) == replacementBytes)

        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        #expect(throws: CloudAssetStagingError.contentMismatch) {
            try restarted.reconcile()
        }
        #expect(try Data(contentsOf: displaced) == bytes)
        #expect(try Data(contentsOf: cleanupResidue) == replacementBytes)
    }

    @Test func cleanupSubstitutionAfterFinalCheckNeverDeletesReplacementOrAcknowledges() throws {
        let fixture = try Fixture()
        let bytes = Data("cleanup original after final check".utf8)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(116)
        )
        let displaced = fixture.sources.appendingPathComponent("final-check-displaced-upload")
        let replacementBytes = Data("cleanup final-check replacement survives".utf8)
        let controller = BoundaryController { boundary in
            guard case .cleanupAfterFinalIdentityCheck(let tombstone) = boundary else { return }
            try FileManager.default.moveItem(at: tombstone, to: displaced)
            try replacementBytes.write(to: tombstone)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            try service.acknowledgeUpload(upload)
        }
        #expect(try Data(contentsOf: displaced) == bytes)
        let cleanupResidue = try #require(
            fixture.regularFiles(in: service.uploadsRootURL)
                .first(where: { $0.lastPathComponent.hasSuffix(".cleanup") })
        )
        #expect(try Data(contentsOf: cleanupResidue) == replacementBytes)

        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        #expect(throws: CloudAssetStagingError.contentMismatch) {
            try restarted.reconcile()
        }
        #expect(try Data(contentsOf: displaced) == bytes)
        #expect(try Data(contentsOf: cleanupResidue) == replacementBytes)
    }

    @Test func failedTemporaryCleanupNeverDeletesAPathSubstitution() throws {
        let fixture = try Fixture()
        let bytes = Data("temporary inode retained for proof".utf8)
        let replacementBytes = Data("temporary path replacement survives".utf8)
        let displaced = fixture.sources.appendingPathComponent("displaced-upload-temporary")
        let controller = BoundaryController { boundary in
            guard case .uploadBeforeFileSync = boundary else { return }
            let temporary = try #require(
                FileManager.default.contentsOfDirectory(
                    at: fixture.service.uploadsRootURL,
                    includingPropertiesForKeys: nil
                ).first(where: { $0.lastPathComponent.hasSuffix(".tmp") })
            )
            try FileManager.default.moveItem(at: temporary, to: displaced)
            try replacementBytes.write(to: temporary)
            throw BoundaryFailure.interrupted
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(bytes),
                version: fixture.version(for: bytes),
                mutationID: fixedUUID(117)
            )
        }
        #expect(try Data(contentsOf: displaced) == bytes)
        let survivingReplacement = try fixture.regularFiles(in: service.uploadsRootURL)
            .first(where: { (try? Data(contentsOf: $0)) == replacementBytes })
        #expect(survivingReplacement != nil)
    }

    @Test func retainedTombstonesAreZeroAndUnknownOrNonzeroEntriesFailClosed() throws {
        let fixture = try Fixture()
        let bytes = Data("retired payload becomes descriptor-bound zero".utf8)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(118)
        )
        try fixture.service.acknowledgeUpload(upload)
        let retired = fixture.service.accountRootURL.appendingPathComponent(
            "Retired",
            isDirectory: true
        )
        let generated = try fixture.regularFiles(in: retired)
        #expect(!generated.isEmpty)
        #expect(try generated.allSatisfy { try Data(contentsOf: $0).isEmpty })

        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        try restarted.reconcile()

        let unknown = retired.appendingPathComponent("unknown.retired")
        let unknownBytes = Data("unknown retirement marker".utf8)
        try unknownBytes.write(to: unknown)
        #expect(throws: CloudAssetStagingError.unsafeFile) {
            try restarted.reconcile()
        }
        #expect(try Data(contentsOf: unknown) == unknownBytes)
        try FileManager.default.removeItem(at: unknown)

        let forged = retired.appendingPathComponent(
            "asset.\(String(repeating: "a", count: 64)).0.\(String(repeating: "b", count: 64)).\(fixedUUID(119).uuidString.lowercased()).retired"
        )
        let forgedBytes = Data("nonzero retirement marker".utf8)
        try forgedBytes.write(to: forged)
        #expect(throws: CloudAssetStagingError.contentMismatch) {
            try restarted.reconcile()
        }
        #expect(try Data(contentsOf: forged) == forgedBytes)
    }

    @Test(.timeLimit(.minutes(2)))
    func sustainedUploadRetirementKeepsRetiredInodesAndRestartScanBounded() throws {
        let fixture = try Fixture()
        let retired = fixture.service.accountRootURL.appendingPathComponent(
            "Retired",
            isDirectory: true
        )

        for index in 0 ..< 2_048 {
            let bytes = Data("bounded-retirement-\(index)".utf8)
            let upload = try fixture.service.stageUpload(
                source: fixture.source(bytes, named: "bounded-\(index).asset"),
                version: fixture.version(for: bytes),
                mutationID: UUID()
            )
            try fixture.service.acknowledgeUpload(upload)
        }

        let tombstones = try fixture.regularFiles(in: retired)
        #expect(tombstones.count <= 3)
        #expect(try tombstones.allSatisfy { try Data(contentsOf: $0).isEmpty })

        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        try restarted.reconcile()
        #expect(try fixture.regularFiles(in: retired).count <= 3)
        #expect(try fixture.regularFiles(in: restarted.uploadsRootURL).isEmpty)
    }

    @Test func reusableRetirementSlotPathReplacementIsNeverClobbered() throws {
        let fixture = try Fixture()
        let seedBytes = Data("seed reusable retirement slot".utf8)
        let seed = try fixture.service.stageUpload(
            source: fixture.source(seedBytes),
            version: fixture.version(for: seedBytes),
            mutationID: fixedUUID(136)
        )
        try fixture.service.acknowledgeUpload(seed)
        let savedSlot = fixture.sources.appendingPathComponent("saved-reusable-slot")
        let adversarialBytes = Data("replacement at reusable retirement slot".utf8)
        let controller = BoundaryController { boundary in
            guard case .retirementAfterReusableSlotValidation(let slot) = boundary,
                slot.lastPathComponent.hasPrefix("asset.")
            else { return }
            try FileManager.default.moveItem(at: slot, to: savedSlot)
            try adversarialBytes.write(to: slot)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let bytes = Data("second retirement remains recoverable".utf8)
        let source = try fixture.source(bytes)
        let upload = try service.stageUpload(
            source: source,
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(137)
        )

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            try service.acknowledgeUpload(upload)
        }
        #expect(try Data(contentsOf: savedSlot).isEmpty)
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))
        #expect(try Data(contentsOf: source.fileURL) == bytes)
    }

    @Test func reusableRetirementSlotInPlaceMutationIsNeverTruncated() throws {
        let fixture = try Fixture()
        let seedBytes = Data("seed in-place reusable slot".utf8)
        let seed = try fixture.service.stageUpload(
            source: fixture.source(seedBytes),
            version: fixture.version(for: seedBytes),
            mutationID: fixedUUID(138)
        )
        try fixture.service.acknowledgeUpload(seed)
        let adversarialBytes = Data("in-place reusable retirement mutation".utf8)
        let controller = BoundaryController { boundary in
            guard case .retirementAfterReusableSlotValidation(let slot) = boundary,
                slot.lastPathComponent.hasPrefix("asset.")
            else { return }
            let handle = try FileHandle(forWritingTo: slot)
            try handle.write(contentsOf: adversarialBytes)
            try handle.synchronize()
            try handle.close()
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let bytes = Data("retirement blocked by slot mutation".utf8)
        let source = try fixture.source(bytes)
        let upload = try service.stageUpload(
            source: source,
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(139)
        )

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            try service.acknowledgeUpload(upload)
        }
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))
        #expect(try Data(contentsOf: source.fileURL) == bytes)
    }

    @Test func reusableRetirementCrashBeforeCASLeavesRestartRecoverable() throws {
        let fixture = try Fixture()
        let seedBytes = Data("seed crash retirement slot".utf8)
        let seed = try fixture.service.stageUpload(
            source: fixture.source(seedBytes),
            version: fixture.version(for: seedBytes),
            mutationID: fixedUUID(140)
        )
        try fixture.service.acknowledgeUpload(seed)
        let controller = BoundaryController { boundary in
            guard case .retirementAfterReusableSlotValidation(let slot) = boundary,
                slot.lastPathComponent.hasPrefix("asset.")
            else { return }
            throw BoundaryFailure.interrupted
        }
        let interrupted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let bytes = Data("crash-phase retirement bytes".utf8)
        let upload = try interrupted.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(141)
        )

        #expect(throws: BoundaryFailure.interrupted) {
            try interrupted.acknowledgeUpload(upload)
        }
        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        try restarted.reconcile()
        #expect(!FileManager.default.fileExists(atPath: upload.stagedFileURL.path))
        #expect(try fixture.regularFiles(
            in: restarted.accountRootURL.appendingPathComponent("Retired")
        ).count <= 3)
    }

    @Test func reusableRetirementPostSwapPathReplacementIsPreservedWithoutClobbering() throws {
        let fixture = try Fixture()
        let seedBytes = Data("seed post-swap replacement slot".utf8)
        let seed = try fixture.service.stageUpload(
            source: fixture.source(seedBytes),
            version: fixture.version(for: seedBytes),
            mutationID: fixedUUID(148)
        )
        try fixture.service.acknowledgeUpload(seed)
        let savedSurvivor = fixture.sources.appendingPathComponent("saved-post-swap-survivor")
        let adversarialBytes = Data("post-swap retirement pathname replacement".utf8)
        let controller = BoundaryController { boundary in
            guard case .retirementAfterSwapBeforeArchive(let survivor, _) = boundary,
                survivor.lastPathComponent.hasPrefix("asset.")
            else { return }
            try FileManager.default.moveItem(at: survivor, to: savedSurvivor)
            try adversarialBytes.write(to: survivor)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let bytes = Data("post-swap replacement retirement payload".utf8)
        let source = try fixture.source(bytes)
        let upload = try service.stageUpload(
            source: source,
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(149)
        )

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            try service.acknowledgeUpload(upload)
        }
        #expect(try Data(contentsOf: savedSurvivor).isEmpty)
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))
        #expect(try Data(contentsOf: source.fileURL) == bytes)
    }

    @Test func reusableRetirementPostSwapSameInodeMutationIsPreservedWithoutUnlinking() throws {
        let fixture = try Fixture()
        let seedBytes = Data("seed post-swap same-inode slot".utf8)
        let seed = try fixture.service.stageUpload(
            source: fixture.source(seedBytes),
            version: fixture.version(for: seedBytes),
            mutationID: fixedUUID(150)
        )
        try fixture.service.acknowledgeUpload(seed)
        let adversarialBytes = Data("post-swap same-inode retirement mutation".utf8)
        let controller = BoundaryController { boundary in
            guard case .retirementAfterSwapBeforeArchive(let survivor, _) = boundary,
                survivor.lastPathComponent.hasPrefix("asset.")
            else { return }
            let handle = try FileHandle(forWritingTo: survivor)
            try handle.write(contentsOf: adversarialBytes)
            try handle.synchronize()
            try handle.close()
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let bytes = Data("post-swap same-inode retirement payload".utf8)
        let source = try fixture.source(bytes)
        let upload = try service.stageUpload(
            source: source,
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(151)
        )

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            try service.acknowledgeUpload(upload)
        }
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))
        #expect(try Data(contentsOf: source.fileURL) == bytes)
    }

    @Test func reusableRetirementCrashAfterSwapPreservesBothMarkersForRestartArchive() throws {
        let fixture = try Fixture()
        let seedBytes = Data("seed post-swap crash slot".utf8)
        let seed = try fixture.service.stageUpload(
            source: fixture.source(seedBytes),
            version: fixture.version(for: seedBytes),
            mutationID: fixedUUID(152)
        )
        try fixture.service.acknowledgeUpload(seed)
        let controller = BoundaryController { boundary in
            guard case .retirementAfterSwapBeforeArchive(let survivor, _) = boundary,
                survivor.lastPathComponent.hasPrefix("asset.")
            else { return }
            throw BoundaryFailure.interrupted
        }
        let interrupted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let bytes = Data("post-swap crash retirement payload".utf8)
        let upload = try interrupted.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(153)
        )

        #expect(throws: BoundaryFailure.interrupted) {
            try interrupted.acknowledgeUpload(upload)
        }
        let retired = interrupted.accountRootURL.appendingPathComponent("Retired")
        #expect(try fixture.regularFiles(in: retired).filter {
            $0.lastPathComponent.hasPrefix("asset.")
        }.count == 2)
        let evidence = retired.appendingPathComponent(".zero-retirement-evidence")
        let evidenceBeforeRestart = try fixture.regularFiles(in: evidence).filter {
            $0.lastPathComponent.hasPrefix("asset.")
        }.count

        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        try restarted.reconcile()
        #expect(try fixture.regularFiles(in: retired).filter {
            $0.lastPathComponent.hasPrefix("asset.")
        }.count == 1)
        #expect(try fixture.regularFiles(in: evidence).filter {
            $0.lastPathComponent.hasPrefix("asset.")
        }.count == evidenceBeforeRestart + 1)
    }

    @Test func restartCompactsLegacyZeroRetirementMarkersToOnePerKind() throws {
        let fixture = try Fixture()
        let retired = fixture.service.accountRootURL.appendingPathComponent("Retired")
        let token = String(repeating: "a", count: 64)
        let emptyHash = Data(SHA256.hash(data: Data()))
            .map { String(format: "%02x", $0) }.joined()
        for _ in 0 ..< 1_024 {
            let marker = retired.appendingPathComponent(
                "asset.\(token).0.\(emptyHash).\(UUID().uuidString.lowercased()).retired"
            )
            #expect(FileManager.default.createFile(atPath: marker.path, contents: Data()))
        }

        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        try restarted.reconcile()

        let remaining = try fixture.regularFiles(in: retired)
        #expect(remaining.count == 1)
        #expect(try Data(contentsOf: remaining[0]).isEmpty)
    }

    @Test func legacyCompactionPathReplacementIsNeverClobbered() throws {
        let fixture = try Fixture()
        let retired = fixture.service.accountRootURL.appendingPathComponent("Retired")
        let markers = try createLegacyRetirementMarkers(count: 2, in: retired)
        let savedSurvivor = fixture.sources.appendingPathComponent("saved-legacy-survivor")
        let adversarialBytes = Data("replacement at legacy compaction destination".utf8)
        let controller = BoundaryController { boundary in
            guard case .retirementAfterLegacyCompactionValidation(let survivor, _) = boundary
            else { return }
            try FileManager.default.moveItem(at: survivor, to: savedSurvivor)
            try adversarialBytes.write(to: survivor)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            try service.reconcile()
        }
        #expect(try Data(contentsOf: savedSurvivor).isEmpty)
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))
        #expect(markers.contains { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func legacyCompactionInPlaceMutationIsNeverUnlinked() throws {
        let fixture = try Fixture()
        let retired = fixture.service.accountRootURL.appendingPathComponent("Retired")
        _ = try createLegacyRetirementMarkers(count: 2, in: retired)
        let adversarialBytes = Data("in-place legacy compaction mutation".utf8)
        let controller = BoundaryController { boundary in
            guard case .retirementAfterLegacyCompactionValidation(let survivor, _) = boundary
            else { return }
            let handle = try FileHandle(forWritingTo: survivor)
            try handle.write(contentsOf: adversarialBytes)
            try handle.synchronize()
            try handle.close()
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            try service.reconcile()
        }
        #expect(try accountContains(service.accountRootURL, bytes: adversarialBytes))
    }

    @Test func legacyCompactionCrashBeforeCASLeavesEveryMarkerRecoverable() throws {
        let fixture = try Fixture()
        let retired = fixture.service.accountRootURL.appendingPathComponent("Retired")
        _ = try createLegacyRetirementMarkers(count: 1_024, in: retired)
        let controller = BoundaryController(failOnceAt: .retirementAfterLegacyCompactionValidation(
            survivor: retired.appendingPathComponent("unused"),
            candidate: retired.appendingPathComponent("unused")
        ))
        let interrupted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )

        #expect(throws: BoundaryFailure.interrupted) {
            try interrupted.reconcile()
        }
        #expect(try fixture.regularFiles(in: retired).count == 1_024)

        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        try restarted.reconcile()
        #expect(try fixture.regularFiles(in: retired).count == 1)
    }

    @Test func malformedCleanupNamePreservesBytesAndDurableAcknowledgementIntent() throws {
        let fixture = try Fixture()
        let bytes = Data("cleanup grammar authority".utf8)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(129)
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
        let manifestURL = interrupted.accountRootURL
            .appendingPathComponent("upload-references.json")
        let intentManifest = try Data(contentsOf: manifestURL)
        let malformed = interrupted.uploadsRootURL.appendingPathComponent(
            ".\(upload.stagedFileURL.lastPathComponent).not-a-canonical-uuid.cleanup"
        )
        try bytes.write(to: malformed)

        #expect(throws: CloudAssetStagingError.corruptManifest) {
            try interrupted.reconcile()
        }
        #expect(try Data(contentsOf: malformed) == bytes)
        #expect(try Data(contentsOf: upload.stagedFileURL) == bytes)
        #expect(try Data(contentsOf: manifestURL) == intentManifest)
    }

    @Test func restartCompletesCorrelatedRetirementInterruptedBeforeTruncation() throws {
        let fixture = try Fixture()
        let bytes = Data("correlated live retirement bytes".utf8)
        let upload = try fixture.service.stageUpload(
            source: fixture.source(bytes),
            version: fixture.version(for: bytes),
            mutationID: fixedUUID(122)
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
        let retirementToken = Data(
            SHA256.hash(data: Data(upload.stagedFileURL.lastPathComponent.utf8))
        ).map { String(format: "%02x", $0) }.joined()
        let retired = interrupted.accountRootURL.appendingPathComponent("Retired")
        let contentSHA256 = Data(SHA256.hash(data: bytes))
            .map { String(format: "%02x", $0) }.joined()
        let liveRetirement = retired.appendingPathComponent(
            "asset.\(retirementToken).\(bytes.count).\(contentSHA256).\(fixedUUID(123).uuidString.lowercased()).retired"
        )
        try FileManager.default.moveItem(at: upload.stagedFileURL, to: liveRetirement)

        let restarted = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier
        )
        try restarted.reconcile()
        #expect(!FileManager.default.fileExists(atPath: upload.stagedFileURL.path))
        #expect(try Data(contentsOf: liveRetirement).isEmpty)

        let uncorrelatedBytes = Data("uncorrelated quarantine retirement".utf8)
        let uncorrelatedToken = String(repeating: "c", count: 64)
        let uncorrelatedSHA256 = Data(SHA256.hash(data: uncorrelatedBytes))
            .map { String(format: "%02x", $0) }.joined()
        let uncorrelated = retired.appendingPathComponent(
            "quarantine.\(uncorrelatedToken).\(uncorrelatedBytes.count).\(uncorrelatedSHA256).\(fixedUUID(126).uuidString.lowercased()).retired"
        )
        try uncorrelatedBytes.write(to: uncorrelated)
        try restarted.reconcile()
        #expect(try Data(contentsOf: uncorrelated).isEmpty)
    }

    @Test func nonRegularAccountLockIsRejectedBeforeCoordination() throws {
        let fixture = try Fixture()
        let lockURL = fixture.service.accountRootURL
            .appendingPathComponent(".asset-staging.lock")
        #expect(Darwin.mkfifo(lockURL.path, S_IRUSR | S_IWUSR) == 0)
        let bytes = Data("must not trust fifo lock".utf8)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try fixture.service.stageUpload(
                source: fixture.source(bytes),
                version: fixture.version(for: bytes),
                mutationID: fixedUUID(84)
            )
        }
        #expect(try fixture.regularFiles(in: fixture.service.uploadsRootURL).isEmpty)
    }

    @Test func lockPathSubstitutionAfterAcquisitionFailsBeforeBodyMutation() throws {
        let fixture = try Fixture()
        let lockURL = fixture.service.accountRootURL
            .appendingPathComponent(".asset-staging.lock")
        let displacedLock = fixture.sources.appendingPathComponent("displaced-lock")
        let replacementBytes = Data("replacement lock".utf8)
        let controller = BoundaryController { boundary in
            guard case .coordinationAfterLock(let acquiredLock) = boundary else { return }
            try FileManager.default.moveItem(at: acquiredLock, to: displacedLock)
            try replacementBytes.write(to: acquiredLock)
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let bytes = Data("must not stage under substituted lock".utf8)
        let source = try fixture.source(bytes)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: source,
                version: fixture.version(for: bytes),
                mutationID: fixedUUID(113)
            )
        }
        #expect(try fixture.regularFiles(in: service.uploadsRootURL).isEmpty)
        #expect(try Data(contentsOf: source.fileURL) == bytes)
        #expect(FileManager.default.fileExists(atPath: displacedLock.path))
        #expect(try Data(contentsOf: lockURL) == replacementBytes)
    }

    @Test func accountDirectoryReplacementBeforeReturnFailsClosedOnLockedTree() throws {
        let fixture = try Fixture()
        let displacedAccount = fixture.sources.appendingPathComponent("displaced-account")
        let controller = BoundaryController { boundary in
            guard case .coordinationBeforeReturn(let account) = boundary else { return }
            try FileManager.default.moveItem(at: account, to: displacedAccount)
            try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
            for child in ["Uploads", "Installed", "Quarantine", "Retired"] {
                try FileManager.default.createDirectory(
                    at: account.appendingPathComponent(child),
                    withIntermediateDirectories: false
                )
            }
        }
        let service = try CloudAssetStagingService(
            rootURL: fixture.cloudRoot,
            accountIdentifier: fixture.accountIdentifier,
            beforeBoundary: controller.visit
        )
        let bytes = Data("must remain bound to displaced locked account".utf8)

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try service.stageUpload(
                source: fixture.source(bytes),
                version: fixture.version(for: bytes),
                mutationID: fixedUUID(130)
            )
        }
        #expect(try fixture.regularFiles(in: service.uploadsRootURL).isEmpty)
        let displacedUploads = displacedAccount.appendingPathComponent("Uploads")
        #expect(try fixture.regularFiles(in: displacedUploads).contains {
            (try? Data(contentsOf: $0)) == bytes
        })
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
    private var storage: [Result<LegacyCloudAssetUploadReference, Error>] = []

    var values: [Result<LegacyCloudAssetUploadReference, Error>] {
        lock.withLock { storage }
    }

    func append(_ result: Result<LegacyCloudAssetUploadReference, Error>) {
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

private final class ManifestRollbackRetirementController: @unchecked Sendable {
    private let lock = NSLock()
    private let adversarialBytes: Data
    private var interruptedCommit = false
    private var mutatedRetirement = false

    init(adversarialBytes: Data) {
        self.adversarialBytes = adversarialBytes
    }

    func visit(_ boundary: CloudAssetStagingBoundary) throws {
        switch boundary {
        case .manifestBeforeDirectorySync:
            let shouldInterrupt = lock.withLock {
                guard !interruptedCommit else { return false }
                interruptedCommit = true
                return true
            }
            if shouldInterrupt { throw BoundaryFailure.interrupted }
        case .retirementBeforeTruncate(let candidate)
        where candidate.lastPathComponent.hasPrefix("manifest."):
            let shouldMutate = lock.withLock {
                guard interruptedCommit, !mutatedRetirement else { return false }
                mutatedRetirement = true
                return true
            }
            guard shouldMutate else { return }
            let handle = try FileHandle(forWritingTo: candidate)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: adversarialBytes)
            try handle.synchronize()
            try handle.close()
        default:
            break
        }
    }
}

private final class ReadInvocationController: @unchecked Sendable {
    private let lock = NSLock()
    private let runOnInvocation: Int
    private let body: @Sendable () throws -> Void
    private var invocation = 0

    init(runOnInvocation: Int, body: @escaping @Sendable () throws -> Void) {
        self.runOnInvocation = runOnInvocation
        self.body = body
    }

    func visit() throws {
        let shouldRun = lock.withLock {
            invocation += 1
            return invocation == runOnInvocation
        }
        if shouldRun { try body() }
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

private func accountContains(_ accountRoot: URL, bytes: Data) throws -> Bool {
    guard let enumerator = FileManager.default.enumerator(
        at: accountRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else {
        return false
    }
    for case let candidate as URL in enumerator {
        guard try candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else { continue }
        if try Data(contentsOf: candidate) == bytes { return true }
    }
    return false
}

private func createLegacyRetirementMarkers(count: Int, in retired: URL) throws -> [URL] {
    let token = String(repeating: "a", count: 64)
    let emptyHash = Data(SHA256.hash(data: Data()))
        .map { String(format: "%02x", $0) }.joined()
    return try (0 ..< count).map { _ in
        let marker = retired.appendingPathComponent(
            "asset.\(token).0.\(emptyHash).\(UUID().uuidString.lowercased()).retired"
        )
        guard FileManager.default.createFile(atPath: marker.path, contents: Data()) else {
            throw CloudAssetStagingError.unavailable
        }
        return marker
    }
}
