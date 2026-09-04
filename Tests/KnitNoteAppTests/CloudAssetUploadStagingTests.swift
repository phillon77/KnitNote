import CloudKit
import CryptoKit
import Foundation
import Testing

@testable import KnitNote

// Task 4 extends this production protocol with download/quarantine methods.
// Keeping this compile-time seam prevents a fault-injection type from taking
// over the approved public boundary name again.
private protocol Task4CloudAssetBoundaryCompileSeam: CloudAssetStagingBoundary {}

@Suite(.serialized) struct CloudAssetUploadStagingTests {
    @Test func stageCopiesAndVerifiesDistinctMutationOwnedBytes() throws {
        let fixture = try UploadFixture()
        let bytes = Data("immutable upload".utf8)
        let version = try fixture.version(bytes: bytes, id: 1)
        let source = try fixture.source(bytes: bytes)
        let first = fixture.uuid(11)
        let second = fixture.uuid(12)

        try fixture.service.stageUpload(version: version, source: source, mutationID: first)
        try fixture.service.stageUpload(version: version, source: source, mutationID: second)

        let firstURL = try #require(fixture.service.assetForUpload(versionID: version.versionID, mutationID: first).fileURL)
        let secondURL = try #require(fixture.service.assetForUpload(versionID: version.versionID, mutationID: second).fileURL)
        #expect(firstURL != secondURL)
        #expect(try Data(contentsOf: firstURL) == bytes)
        #expect(try Data(contentsOf: secondURL) == bytes)
        #expect(try Data(contentsOf: source.fileURL) == bytes)
    }

    @Test func exactStageRetryIsIdempotentAndDivergenceFailsClosed() throws {
        let fixture = try UploadFixture()
        let bytes = Data("retry".utf8)
        let version = try fixture.version(bytes: bytes, id: 2)
        let source = try fixture.source(bytes: bytes)
        let mutation = fixture.uuid(21)
        try fixture.service.stageUpload(version: version, source: source, mutationID: mutation)
        let firstURL = try #require(fixture.service.assetForUpload(versionID: version.versionID, mutationID: mutation).fileURL)

        try fixture.service.stageUpload(version: version, source: source, mutationID: mutation)
        let repeatedURL = try #require(fixture.service.assetForUpload(versionID: version.versionID, mutationID: mutation).fileURL)
        #expect(repeatedURL == firstURL)

        let divergentBytes = Data("divergent".utf8)
        let divergent = try fixture.version(bytes: divergentBytes, id: 3)
        #expect(throws: CloudAssetStagingError.immutableIdentityMismatch) {
            try fixture.service.stageUpload(
                version: divergent,
                source: try fixture.source(bytes: divergentBytes, name: "divergent"),
                mutationID: mutation
            )
        }
        #expect(try Data(contentsOf: firstURL) == bytes)
    }

    @Test func everySaveAttemptCreatesFreshCKAssetAtStableURL() throws {
        let fixture = try UploadFixture()
        let bytes = Data("fresh CKAsset".utf8)
        let version = try fixture.version(bytes: bytes, id: 4)
        let mutation = fixture.uuid(41)
        try fixture.service.stageUpload(version: version, source: try fixture.source(bytes: bytes), mutationID: mutation)

        let first = try fixture.service.assetForUpload(versionID: version.versionID, mutationID: mutation)
        let second = try fixture.service.assetForUpload(versionID: version.versionID, mutationID: mutation)
        #expect(first !== second)
        #expect(first.fileURL == second.fileURL)
    }

    @Test func acknowledgementRemovesOnlyExactMutationAfterManifestCommit() throws {
        let fixture = try UploadFixture()
        let bytes = Data("shared version, distinct mutation".utf8)
        let version = try fixture.version(bytes: bytes, id: 5)
        let source = try fixture.source(bytes: bytes)
        let first = fixture.uuid(51)
        let second = fixture.uuid(52)
        try fixture.service.stageUpload(version: version, source: source, mutationID: first)
        try fixture.service.stageUpload(version: version, source: source, mutationID: second)
        let firstURL = try #require(fixture.service.assetForUpload(versionID: version.versionID, mutationID: first).fileURL)
        let secondURL = try #require(fixture.service.assetForUpload(versionID: version.versionID, mutationID: second).fileURL)

        try fixture.service.acknowledgeUpload(versionID: version.versionID, mutationID: first)

        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        _ = try fixture.service.assetForUpload(versionID: version.versionID, mutationID: second)
        #expect(try Data(contentsOf: source.fileURL) == bytes)
    }

    @Test func crashAfterManifestRemovalLeavesRecoverableOrphan() throws {
        let fixture = try UploadFixture()
        let bytes = Data("ack crash".utf8)
        let version = try fixture.version(bytes: bytes, id: 6)
        let mutation = fixture.uuid(61)
        try fixture.service.stageUpload(version: version, source: try fixture.source(bytes: bytes), mutationID: mutation)
        let url = try #require(fixture.service.assetForUpload(versionID: version.versionID, mutationID: mutation).fileURL)
        let interrupted = try fixture.makeService { boundary in
            if boundary == .acknowledgementAfterManifest { throw UploadInterruption.crash }
        }

        #expect(throws: CloudAssetStagingError.unavailable) {
            try interrupted.acknowledgeUpload(versionID: version.versionID, mutationID: mutation)
        }
        #expect(FileManager.default.fileExists(atPath: url.path))

        let restarted = try fixture.makeService()
        try restarted.reconcile()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func corruptOrMissingManifestPreservesEveryFinalUpload() throws {
        for mode in ["missing", "corrupt"] {
            let fixture = try UploadFixture(account: mode)
            let bytes = Data(mode.utf8)
            let version = try fixture.version(bytes: bytes, id: mode == "missing" ? 7 : 8)
            let mutation = fixture.uuid(mode == "missing" ? 71 : 81)
            try fixture.service.stageUpload(version: version, source: try fixture.source(bytes: bytes), mutationID: mutation)
            let url = try #require(fixture.service.assetForUpload(versionID: version.versionID, mutationID: mutation).fileURL)
            if mode == "missing" {
                try FileManager.default.removeItem(at: fixture.uploadManifestURL)
            } else {
                try Data("{}".utf8).write(to: fixture.uploadManifestURL)
            }

            #expect(throws: CloudAssetStagingError.corruptManifest) { _ = try fixture.makeService() }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func restartReconcilesOnlyCanonicalUnreferencedFiles() throws {
        let fixture = try UploadFixture()
        let bytes = Data("referenced".utf8)
        let version = try fixture.version(bytes: bytes, id: 9)
        let mutation = fixture.uuid(91)
        try fixture.service.stageUpload(version: version, source: try fixture.source(bytes: bytes), mutationID: mutation)
        let referenced = try #require(fixture.service.assetForUpload(versionID: version.versionID, mutationID: mutation).fileURL)
        let orphan = fixture.service.uploadsRootURL.appendingPathComponent(
            "\(fixture.uuid(92).uuidString.lowercased())-\(fixture.uuid(93).uuidString.lowercased()).asset"
        )
        try Data("orphan".utf8).write(to: orphan)

        let restarted = try fixture.makeService()
        try restarted.reconcile()
        #expect(FileManager.default.fileExists(atPath: referenced.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))

        let unknown = fixture.service.uploadsRootURL.appendingPathComponent("do-not-guess.txt")
        try Data("unknown".utf8).write(to: unknown)
        #expect(throws: CloudAssetStagingError.unsafeFile) { try restarted.reconcile() }
        #expect(FileManager.default.fileExists(atPath: unknown.path))
    }

    @Test func tenThousandStageAcknowledgementCyclesRemainBounded() throws {
        let fixture = try UploadFixture()
        let bytes = Data([0x4b])
        let version = try fixture.version(bytes: bytes, id: 10)
        let source = try fixture.source(bytes: bytes)
        for index in 1...10_000 {
            let mutation = fixture.uuid(10_000 + index)
            try fixture.service.stageUpload(version: version, source: source, mutationID: mutation)
            try fixture.service.acknowledgeUpload(versionID: version.versionID, mutationID: mutation)
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.service.uploadsRootURL.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.service.accountRootURL.appendingPathComponent("Retired").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.service.accountRootURL.appendingPathComponent(".zero-retirement-evidence").path))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.service.accountRootURL.path)
        #expect(Set(names) == [".lock", "Installed", "Quarantine", "Uploads", "manifest.json"])
    }
}

private enum UploadInterruption: Error { case crash }

private final class UploadFixture {
    let root: URL
    let sources: URL
    let account: String
    let service: CloudAssetStagingService

    var uploadManifestURL: URL { service.accountRootURL.appendingPathComponent("manifest.json") }

    init(account: String = "test-account") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudAssetUploadTests-\(UUID().uuidString)", isDirectory: true)
        sources = root.appendingPathComponent("Sources", isDirectory: true)
        self.account = account
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        service = try CloudAssetStagingService(rootURL: root.appendingPathComponent("CloudAssetStaging", isDirectory: true), accountIdentifier: account)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeService(beforeBoundary: @escaping CloudAssetStagingService.BeforeBoundary = { _ in }) throws -> CloudAssetStagingService {
        try CloudAssetStagingService(
            rootURL: root.appendingPathComponent("CloudAssetStaging", isDirectory: true),
            accountIdentifier: account,
            beforeBoundary: beforeBoundary
        )
    }

    func source(bytes: Data, name: String = UUID().uuidString) throws -> SyncAttachmentSource {
        let url = sources.appendingPathComponent(name)
        try bytes.write(to: url)
        return try SyncAttachmentSource(fileURL: url, contentSHA256: Data(SHA256.hash(data: bytes)), byteCount: Int64(bytes.count))
    }

    func version(bytes: Data, id: Int) throws -> SyncAttachmentVersion {
        try .issuing(
            slot: SyncAttachmentSlot(owner: SyncEntityID(kind: .project, uuid: uuid(900)), role: "cover", slotID: "main"),
            contentSHA256: Data(SHA256.hash(data: bytes)),
            byteCount: Int64(bytes.count),
            mediaType: "application/octet-stream",
            displayFilename: "asset.bin",
            versionID: uuid(id)
        )
    }

    func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }
}
