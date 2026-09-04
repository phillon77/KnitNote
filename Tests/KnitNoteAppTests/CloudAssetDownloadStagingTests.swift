import CryptoKit
import Darwin
import Foundation
import Testing

@testable import KnitNote

@Suite(.serialized) struct CloudAssetDownloadStagingTests {
    @Test func exactInstallIsIdempotentAndDivergenceNeverOverwrites() throws {
        let fixture = try DownloadFixture()
        let bytes = Data("verified download".utf8)
        let version = try fixture.version(bytes: bytes, id: 1)
        let source = try fixture.source(bytes: bytes, name: "exact.asset")

        let boundary: any CloudAssetStagingBoundary = fixture.service
        let first = try boundary.installDownload(version: version, sourceURL: source)
        let second = try boundary.installDownload(version: version, sourceURL: source)
        #expect(first == second)
        #expect(try Data(contentsOf: first) == bytes)

        try Data("divergent installed bytes".utf8).write(to: first)
        #expect(throws: CloudAssetStagingError.immutableIdentityMismatch) {
            _ = try boundary.installDownload(version: version, sourceURL: source)
        }
        #expect(try Data(contentsOf: first) == Data("divergent installed bytes".utf8))
    }

    @Test func hashMismatchQuarantinesAlreadyReadBytesAndPreservesInstalled() throws {
        let fixture = try DownloadFixture()
        let expected = Data("expected".utf8)
        let received = Data("received".utf8)
        let version = try fixture.version(
            bytes: expected,
            id: 2,
            byteCount: Int64(received.count)
        )
        let installed = fixture.installedURL(version.versionID)
        try Data("keep installed".utf8).write(to: installed)
        let source = try fixture.source(bytes: received, name: "hash-mismatch.asset")

        #expect(throws: CloudAssetStagingError.contentMismatch) {
            _ = try fixture.service.installDownload(version: version, sourceURL: source)
        }

        #expect(try Data(contentsOf: installed) == Data("keep installed".utf8))
        let entries = try fixture.quarantineEntries()
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.versionID == version.versionID)
        #expect(entry.reason == .contentHashMismatch)
        #expect(try Data(contentsOf: fixture.quarantineURL(entry)) == received)
    }

    @Test func shortSizeMismatchQuarantinesBoundedBytesAndPreservesInstalled() throws {
        let fixture = try DownloadFixture()
        let expected = Data("longer expected payload".utf8)
        let received = Data("short".utf8)
        let version = try fixture.version(bytes: expected, id: 3)
        let installed = fixture.installedURL(version.versionID)
        try Data("existing".utf8).write(to: installed)
        let source = try fixture.source(bytes: received, name: "short.asset")

        #expect(throws: CloudAssetStagingError.contentMismatch) {
            _ = try fixture.service.installDownload(version: version, sourceURL: source)
        }

        #expect(try Data(contentsOf: installed) == Data("existing".utf8))
        let entry = try #require(fixture.quarantineEntries().first)
        #expect(entry.reason == .byteCountMismatch)
        #expect(entry.byteCount == Int64(received.count))
        #expect(try Data(contentsOf: fixture.quarantineURL(entry)) == received)
    }

    @Test func oversizedAndReadTimeGrowthBecomeBoundedSizeDiagnostics() throws {
        let fixture = try DownloadFixture()
        let expected = Data("safe".utf8)
        let version = try fixture.version(bytes: expected, id: 4)
        let oversized = try fixture.source(bytes: Data("safe+".utf8), name: "oversized.asset")

        #expect(throws: CloudAssetStagingError.contentMismatch) {
            _ = try fixture.service.installDownload(version: version, sourceURL: oversized)
        }
        let oversizedEntry = try #require(fixture.quarantineEntries().first)
        #expect(oversizedEntry.reason == .byteCountMismatch)
        #expect(try Data(contentsOf: fixture.quarantineURL(oversizedEntry)) == expected)

        let growingURL = try fixture.source(bytes: expected, name: "growing.asset")
        let counters = SyncRegularFileReaderIOCounters()
        let growingReader = SyncRegularFileReader(
            beforeRead: {
                let handle = try FileHandle(forWritingTo: growingURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 0x41, count: 1_000_000))
                try handle.close()
            },
            ioCounters: counters
        )
        let service = try fixture.makeService(externalReader: growingReader)
        #expect(throws: CloudAssetStagingError.contentMismatch) {
            _ = try service.installDownload(version: version, sourceURL: growingURL)
        }
        #expect(counters.bytesRead == expected.count + 1)
        let entries = try fixture.quarantineEntries()
        #expect(entries.count == 2)
        let growthEntry = try #require(entries.last)
        #expect(growthEntry.reason == .byteCountMismatch)
        #expect(try Data(contentsOf: fixture.quarantineURL(growthEntry)) == expected)
    }

    @Test(arguments: ["symlink", "hardlink", "fifo"])
    func unsafeSourcesFailWithoutQuarantine(_ kind: String) throws {
        let fixture = try DownloadFixture()
        let bytes = Data("unsafe".utf8)
        let version = try fixture.version(bytes: bytes, id: 5)
        let source = fixture.sources.appendingPathComponent("unsafe-\(kind).asset")
        let target = fixture.sources.appendingPathComponent("target-\(kind).asset")
        try bytes.write(to: target)
        if kind == "symlink" {
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        } else if kind == "hardlink" {
            try #require(target.path.withCString { old in
                source.path.withCString { Darwin.link(old, $0) }
            } == 0)
        } else {
            try #require(source.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) } == 0)
        }

        #expect(throws: CloudAssetStagingError.unsafeFile) {
            _ = try fixture.service.installDownload(version: version, sourceURL: source)
        }
        #expect(try fixture.quarantineEntries().isEmpty)
    }

    @Test func crashAfterInstallTemporaryFsyncLeavesRestartCleanableOrphan() throws {
        let fixture = try DownloadFixture()
        let bytes = Data("crash before install rename".utf8)
        let version = try fixture.version(bytes: bytes, id: 6)
        let source = try fixture.source(bytes: bytes, name: "crash.asset")
        let interrupted = try fixture.makeService { boundary in
            if boundary == .installAfterTemporaryFileSync { throw DownloadInterruption.crash }
        }

        #expect(throws: CloudAssetStagingError.unavailable) {
            _ = try interrupted.installDownload(version: version, sourceURL: source)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.installedURL(version.versionID).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: interrupted.installedRootURL.path)
            .contains(where: { $0.hasPrefix(".tmp-") }))

        let restarted = try fixture.makeService()
        #expect(try FileManager.default.contentsOfDirectory(atPath: interrupted.installedRootURL.path)
            .allSatisfy { !$0.hasPrefix(".tmp-") })
        let installed = try restarted.installDownload(version: version, sourceURL: source)
        #expect(try Data(contentsOf: installed) == bytes)
    }

    @Test func corruptAuthoritiesDoNotBlockIndependentWorkflowsAfterRestart() throws {
        let quarantineCorrupt = try DownloadFixture(account: "corrupt-quarantine")
        let mismatch = Data("wrong".utf8)
        let mismatchVersion = try quarantineCorrupt.version(
            bytes: Data("RIGHT".utf8), id: 7
        )
        try quarantineCorrupt.service.quarantine(
            version: mismatchVersion,
            sourceURL: try quarantineCorrupt.source(bytes: mismatch, name: "diagnostic.asset"),
            reason: .contentHashMismatch
        )
        try Data("{}".utf8).write(to: quarantineCorrupt.quarantineManifestURL)
        let uploadBytes = Data("upload survives quarantine corruption".utf8)
        let uploadVersion = try quarantineCorrupt.version(bytes: uploadBytes, id: 8)
        let uploadSource = try quarantineCorrupt.attachmentSource(
            bytes: uploadBytes, name: "upload.asset"
        )
        let mutation = quarantineCorrupt.uuid(801)
        let uploadRestart = try quarantineCorrupt.makeService()
        try uploadRestart.stageUpload(
            version: uploadVersion,
            source: uploadSource,
            mutationID: mutation
        )
        _ = try uploadRestart.assetForUpload(
            versionID: uploadVersion.versionID,
            mutationID: mutation
        )
        try uploadRestart.reconcile()
        try uploadRestart.acknowledgeUpload(
            versionID: uploadVersion.versionID,
            mutationID: mutation
        )

        let uploadCorrupt = try DownloadFixture(account: "corrupt-upload")
        let installedBytes = Data("install survives upload corruption".utf8)
        let installedVersion = try uploadCorrupt.version(bytes: installedBytes, id: 9)
        let pendingMutation = uploadCorrupt.uuid(901)
        try uploadCorrupt.service.stageUpload(
            version: installedVersion,
            source: try uploadCorrupt.attachmentSource(
                bytes: installedBytes, name: "pending.asset"
            ),
            mutationID: pendingMutation
        )
        try Data("{}".utf8).write(to: uploadCorrupt.uploadManifestURL)
        let installRestart = try uploadCorrupt.makeService()
        let installed = try installRestart.installDownload(
            version: installedVersion,
            sourceURL: try uploadCorrupt.source(bytes: installedBytes, name: "download.asset")
        )
        #expect(try Data(contentsOf: installed) == installedBytes)
    }

    @Test func installedBindingRejectsEveryImmutableMetadataDivergence() throws {
        let fixture = try DownloadFixture()
        let bytes = Data("same immutable bytes".utf8)
        let version = try fixture.version(bytes: bytes, id: 40)
        let source = try fixture.source(bytes: bytes, name: "binding.asset")
        let installed = try fixture.service.installDownload(version: version, sourceURL: source)

        let differentOwner = SyncAttachmentSlot(
            owner: .init(kind: .project, uuid: fixture.uuid(777)),
            role: version.slot.role,
            slotID: version.slot.slotID
        )
        let differentRole = SyncAttachmentSlot(
            owner: version.slot.owner,
            role: "other-role",
            slotID: version.slot.slotID
        )
        let differentSlotID = SyncAttachmentSlot(
            owner: version.slot.owner,
            role: version.slot.role,
            slotID: "other-slot"
        )
        let divergences = [
            try fixture.rebuild(version, slot: differentOwner),
            try fixture.rebuild(version, slot: differentRole),
            try fixture.rebuild(version, slot: differentSlotID),
            try fixture.rebuild(version, mediaType: "image/jpeg"),
            try fixture.rebuild(version, displayFilename: "other.bin"),
            try fixture.rebuild(version, replacesVersionID: fixture.uuid(778)),
        ]
        for divergent in divergences {
            #expect(throws: CloudAssetStagingError.immutableIdentityMismatch) {
                _ = try fixture.service.installDownload(version: divergent, sourceURL: source)
            }
            #expect(try Data(contentsOf: installed) == bytes)
        }
    }

    @Test(arguments: ["missing", "corrupt"])
    func missingOrCorruptInstalledBindingFailsClosedWithoutClobber(_ mode: String) throws {
        let fixture = try DownloadFixture(account: "binding-\(mode)")
        let bytes = Data("bound bytes".utf8)
        let version = try fixture.version(bytes: bytes, id: 41)
        let source = try fixture.source(bytes: bytes, name: "bound.asset")
        let installed = try fixture.service.installDownload(version: version, sourceURL: source)
        try fixture.mutateInstalledBinding(at: installed, mode: mode)

        let restarted = try fixture.makeService()
        #expect(throws: CloudAssetStagingError.immutableIdentityMismatch) {
            _ = try restarted.installDownload(version: version, sourceURL: source)
        }
        #expect(try Data(contentsOf: installed) == bytes)
    }

    @Test func quarantineEvictsOldestByCountAndBytesDeterministically() throws {
        let fixture = try DownloadFixture(maximumQuarantineBytes: 10)
        var firstReference: CloudAssetQuarantineReference?
        for index in 1...4 {
            let bytes = Data(repeating: UInt8(index), count: index == 4 ? 4 : 3)
            let version = try fixture.version(
                bytes: Data(repeating: 0xff, count: bytes.count),
                id: 10 + index
            )
            try fixture.service.quarantine(
                version: version,
                sourceURL: try fixture.source(bytes: bytes, name: "q\(index).asset"),
                reason: .contentHashMismatch
            )
            if index == 1 { firstReference = try fixture.quarantineEntries().first }
            usleep(2_000)
        }

        let entries = try fixture.quarantineEntries()
        #expect(entries.count == 3)
        #expect(entries.reduce(Int64(0)) { $0 + $1.byteCount } == 10)
        #expect(entries.map(\.versionID) == [fixture.uuid(12), fixture.uuid(13), fixture.uuid(14)])
        #expect(!FileManager.default.fileExists(
            atPath: fixture.quarantineURL(try #require(firstReference)).path
        ))
    }

    @Test func cleanupFailureRejectsNewQuarantineAndRestartRemovesOrphan() throws {
        let fixture = try DownloadFixture(maximumQuarantineEntries: 1)
        let firstBytes = Data("one".utf8)
        let firstVersion = try fixture.version(bytes: Data("ONE".utf8), id: 21)
        try fixture.service.quarantine(
            version: firstVersion,
            sourceURL: try fixture.source(bytes: firstBytes, name: "one.asset"),
            reason: .contentHashMismatch
        )
        let first = try #require(fixture.quarantineEntries().first)
        let fault = try fixture.makeService(
            maximumQuarantineEntries: 1,
            beforeDownloadBoundary: { boundary in
                if boundary == .quarantineAfterEvictionManifestCommit {
                    throw DownloadInterruption.crash
                }
            }
        )
        let secondBytes = Data("two".utf8)
        let secondVersion = try fixture.version(bytes: Data("TWO".utf8), id: 22)

        #expect(throws: CloudAssetStagingError.unavailable) {
            try fault.quarantine(
                version: secondVersion,
                sourceURL: try fixture.source(bytes: secondBytes, name: "two.asset"),
                reason: .contentHashMismatch
            )
        }
        #expect(try fixture.quarantineEntries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.quarantineURL(first).path))
        let unexpectedFinal = try fixture.quarantineFinals().first {
            $0.lastPathComponent != first.relativeFilename
        }
        #expect(unexpectedFinal == nil)

        _ = try fixture.makeService(maximumQuarantineEntries: 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.quarantineURL(first).path))
        #expect(try fixture.quarantineEntries().isEmpty)
    }

    @Test func accountsCannotReadReuseOrCleanEachOthersDownloads() throws {
        let fixture = try DownloadFixture(account: "account-a")
        let other = try fixture.makeService(account: "account-b")
        let bytes = Data("isolated".utf8)
        let version = try fixture.version(bytes: bytes, id: 30)
        let source = try fixture.source(bytes: bytes, name: "isolated.asset")

        let installed = try fixture.service.installDownload(version: version, sourceURL: source)
        #expect(installed.path.hasPrefix(fixture.service.accountRootURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: other.installedRootURL.appendingPathComponent(installed.lastPathComponent).path
        ))
        try other.reconcile()
        #expect(try Data(contentsOf: installed) == bytes)

        let mutation = fixture.uuid(3001)
        try fixture.service.stageUpload(
            version: version,
            source: try fixture.attachmentSource(bytes: bytes, name: "upload-source.asset"),
            mutationID: mutation
        )
        let upload = try #require(fixture.service.assetForUpload(
            versionID: version.versionID,
            mutationID: mutation
        ).fileURL)
        let badVersion = try fixture.version(bytes: Data("ISOLATED".utf8), id: 31)
        try fixture.service.quarantine(
            version: badVersion,
            sourceURL: source,
            reason: .contentHashMismatch
        )
        let quarantine = fixture.quarantineURL(try #require(fixture.quarantineEntries().first))
        let foreignFiles = [upload, installed, quarantine]
        let foreignSources = foreignFiles + foreignFiles.map(fixture.alias)
        for foreign in foreignSources {
            #expect(throws: CloudAssetStagingError.unsafeFile) {
                _ = try other.installDownload(version: version, sourceURL: foreign)
            }
            #expect(throws: CloudAssetStagingError.unsafeFile) {
                try other.quarantine(
                    version: badVersion,
                    sourceURL: foreign,
                    reason: .contentHashMismatch
                )
            }
        }
    }
}

private enum DownloadInterruption: Error { case crash }

private final class DownloadFixture {
    let root: URL
    let sources: URL
    let stagingRoot: URL
    let account: String
    let service: CloudAssetStagingService

    init(
        account: String = "download-account",
        maximumQuarantineEntries: Int = 4,
        maximumQuarantineBytes: Int64 = 400_000_000
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CloudAssetDownloadTests-\(UUID().uuidString)", isDirectory: true
        )
        sources = root.appendingPathComponent("Sources", isDirectory: true)
        stagingRoot = root.appendingPathComponent("CloudAssetStaging", isDirectory: true)
        self.account = account
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        service = try CloudAssetStagingService(
            rootURL: stagingRoot,
            accountIdentifier: account,
            maximumQuarantineEntries: maximumQuarantineEntries,
            maximumQuarantineBytes: maximumQuarantineBytes
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeService(
        account: String? = nil,
        externalReader: any SyncRegularFileReading = SyncRegularFileReader(),
        maximumQuarantineEntries: Int = 4,
        maximumQuarantineBytes: Int64 = 400_000_000,
        beforeDownloadBoundary: @escaping CloudAssetStagingService.BeforeDownloadBoundary = { _ in }
    ) throws -> CloudAssetStagingService {
        try CloudAssetStagingService(
            rootURL: stagingRoot,
            accountIdentifier: account ?? self.account,
            externalReader: externalReader,
            maximumQuarantineEntries: maximumQuarantineEntries,
            maximumQuarantineBytes: maximumQuarantineBytes,
            beforeDownloadBoundary: beforeDownloadBoundary
        )
    }

    func source(bytes: Data, name: String) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func attachmentSource(bytes: Data, name: String) throws -> SyncAttachmentSource {
        let url = try source(bytes: bytes, name: name)
        return try SyncAttachmentSource(
            fileURL: url,
            contentSHA256: Data(SHA256.hash(data: bytes)),
            byteCount: Int64(bytes.count)
        )
    }

    func version(
        bytes: Data,
        id: Int,
        byteCount: Int64? = nil
    ) throws -> SyncAttachmentVersion {
        try .issuing(
            slot: .init(
                owner: .init(kind: .project, uuid: uuid(900)),
                role: "cover",
                slotID: "main"
            ),
            contentSHA256: Data(SHA256.hash(data: bytes)),
            byteCount: byteCount ?? Int64(bytes.count),
            mediaType: "application/octet-stream",
            displayFilename: "asset.bin",
            versionID: uuid(id)
        )
    }

    func installedURL(_ versionID: UUID) -> URL {
        service.installedRootURL.appendingPathComponent(
            "\(versionID.uuidString.lowercased()).asset"
        )
    }

    var uploadManifestURL: URL {
        service.accountRootURL.appendingPathComponent("manifest.json")
    }

    var quarantineManifestURL: URL {
        service.quarantineRootURL.appendingPathComponent("manifest.json")
    }

    func rebuild(
        _ version: SyncAttachmentVersion,
        slot: SyncAttachmentSlot? = nil,
        mediaType: String? = nil,
        displayFilename: String? = nil,
        replacesVersionID: UUID? = nil
    ) throws -> SyncAttachmentVersion {
        let selectedSlot = slot ?? version.slot
        return try SyncAttachmentVersion(
            slot: selectedSlot,
            versionID: version.versionID,
            conflictGroupID: try SyncAttachmentVersion.conflictGroupID(for: selectedSlot),
            contentSHA256: version.contentSHA256,
            byteCount: version.byteCount,
            mediaType: mediaType ?? version.mediaType,
            displayFilename: displayFilename ?? version.displayFilename,
            replacesVersionID: replacesVersionID ?? version.replacesVersionID
        )
    }

    func mutateInstalledBinding(at url: URL, mode: String) throws {
        let name = "com.phillon.KnitNote.cloud-asset-version-binding.v1"
        if mode == "missing" {
            try #require(url.path.withCString { path in
                name.withCString { Darwin.removexattr(path, $0, 0) }
            } == 0)
        } else {
            let bytes = Data(repeating: 0xa5, count: 32)
            try #require(bytes.withUnsafeBytes { raw in
                url.path.withCString { path in
                    name.withCString { attribute in
                        Darwin.setxattr(path, attribute, raw.baseAddress, raw.count, 0, 0)
                    }
                }
            } == 0)
        }
    }

    func alias(of url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent(
                url.deletingLastPathComponent().lastPathComponent,
                isDirectory: true
            )
            .appendingPathComponent(url.lastPathComponent)
    }

    func quarantineEntries() throws -> [CloudAssetQuarantineReference] {
        let store = try CloudAssetAccountFileStore(
            rootURL: stagingRoot,
            accountIdentifier: account
        )
        let manifests = CloudAssetManifestStore(fileStore: store)
        return try store.withAccountLock { try manifests.loadQuarantine(in: $0) }
    }

    func quarantineURL(_ reference: CloudAssetQuarantineReference) -> URL {
        service.quarantineRootURL.appendingPathComponent(reference.relativeFilename)
    }

    func quarantineFinals() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: service.quarantineRootURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "asset" }
    }

    func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }
}
