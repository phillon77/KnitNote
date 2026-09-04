import CryptoKit
import Darwin
import Foundation
import Testing

@testable import KnitNote

@Suite(.serialized) struct CloudAssetManifestStoreTests {
    @Test func canonicalUploadRoundTripSortsDeterministically() throws {
        let fixture = try ManifestFixture()
        let first = try fixture.upload(mutation: 2, version: 4)
        let second = try fixture.upload(mutation: 1, version: 3)

        let initial = try fixture.withLock { directories in
            try fixture.manifests.commitUploads([first, second], in: directories)
            return try Data(contentsOf: fixture.uploadManifestURL)
        }
        let loaded = try fixture.withLock { try fixture.manifests.loadUploads(in: $0) }
        #expect(loaded == [second, first])

        let repeated = try fixture.withLock { directories in
            try fixture.manifests.commitUploads([second, first], in: directories)
            return try Data(contentsOf: fixture.uploadManifestURL)
        }
        #expect(repeated == initial)
    }

    @Test func uploadAndQuarantineUseSeparateDomainSeparatedAuthorities() throws {
        let fixture = try ManifestFixture()
        let upload = try fixture.upload(mutation: 1, version: 2)
        try fixture.withLock { try fixture.manifests.commitUploads([upload], in: $0) }
        let uploadBytes = try Data(contentsOf: fixture.uploadManifestURL)
        try uploadBytes.write(to: fixture.quarantineManifestURL)

        #expect(throws: CloudAssetManifestStoreError.corruptManifest) {
            try fixture.withLock { try fixture.manifests.loadQuarantine(in: $0) }
        }
        #expect(try fixture.withLock { try fixture.manifests.loadUploads(in: $0) } == [upload])
    }

    @Test func checksumBitFlipFailsClosed() throws {
        let fixture = try ManifestFixture()
        try fixture.withLock {
            try fixture.manifests.commitUploads([try fixture.upload(mutation: 1, version: 1)], in: $0)
        }
        var bytes = try Data(contentsOf: fixture.uploadManifestURL)
        bytes[bytes.count / 2] ^= 1
        try bytes.write(to: fixture.uploadManifestURL)
        #expect(throws: CloudAssetManifestStoreError.corruptManifest) {
            try fixture.withLock { try fixture.manifests.loadUploads(in: $0) }
        }
    }

    @Test(arguments: ["mutation", "removal"])
    func validJSONPayloadMutationOrRemovalFailsClosed(_ mutation: String) throws {
        let fixture = try ManifestFixture()
        try fixture.withLock {
            try fixture.manifests.commitUploads([try fixture.upload(mutation: 1, version: 1)], in: $0)
        }
        let bytes = try fixture.rewriteUploadPayload {
            if mutation == "mutation" {
                $0["entries"] = "not-an-array"
            } else {
                $0.removeValue(forKey: "entries")
            }
        }
        try bytes.write(to: fixture.uploadManifestURL)
        #expect(throws: CloudAssetManifestStoreError.corruptManifest) {
            try fixture.withLock { try fixture.manifests.loadUploads(in: $0) }
        }
    }

    @Test func duplicateUploadMutationAndFilenameAreRejected() throws {
        let fixture = try ManifestFixture()
        let first = try fixture.upload(mutation: 1, version: 1)
        let sameMutation = try fixture.upload(mutation: 1, version: 2)
        let sameFilename = CloudAssetUploadReference(
            mutationID: fixture.uuid(3),
            version: try fixture.version(3),
            relativeFilename: first.relativeFilename
        )
        #expect(throws: CloudAssetManifestStoreError.corruptManifest) {
            try fixture.withLock { try fixture.manifests.commitUploads([first, sameMutation], in: $0) }
        }
        #expect(throws: CloudAssetManifestStoreError.corruptManifest) {
            try fixture.withLock { try fixture.manifests.commitUploads([first, sameFilename], in: $0) }
        }
    }

    @Test(arguments: ["/tmp/escape.asset", "../escape.asset", "nested/escape.asset"])
    func unsafeUploadFilenamesAreRejected(_ filename: String) throws {
        let fixture = try ManifestFixture()
        let reference = CloudAssetUploadReference(
            mutationID: fixture.uuid(1),
            version: try fixture.version(1),
            relativeFilename: filename
        )
        #expect(throws: CloudAssetManifestStoreError.corruptManifest) {
            try fixture.withLock { try fixture.manifests.commitUploads([reference], in: $0) }
        }
    }

    @Test func unsupportedVersionAndNoncanonicalJSONFailClosed() throws {
        let fixture = try ManifestFixture()
        try fixture.withLock {
            try fixture.manifests.commitUploads([try fixture.upload(mutation: 1, version: 1)], in: $0)
        }
        let unsupported = try fixture.rewriteUploadPayload { $0["schemaVersion"] = 2 }
        try unsupported.write(to: fixture.uploadManifestURL)
        #expect(throws: CloudAssetManifestStoreError.corruptManifest) {
            try fixture.withLock { try fixture.manifests.loadUploads(in: $0) }
        }

        try fixture.withLock {
            try fixture.manifests.commitUploads([try fixture.upload(mutation: 1, version: 1)], in: $0)
        }
        var unsupportedEnvelope = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.uploadManifestURL))
                as? [String: Any]
        )
        unsupportedEnvelope["integrityVersion"] = 2
        try JSONSerialization.data(withJSONObject: unsupportedEnvelope, options: [.sortedKeys])
            .write(to: fixture.uploadManifestURL)
        #expect(throws: CloudAssetManifestStoreError.corruptManifest) {
            try fixture.withLock { try fixture.manifests.loadUploads(in: $0) }
        }

        try fixture.withLock {
            try fixture.manifests.commitUploads([try fixture.upload(mutation: 1, version: 1)], in: $0)
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.uploadManifestURL))
        let noncanonical = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try noncanonical.write(to: fixture.uploadManifestURL)
        #expect(throws: CloudAssetManifestStoreError.corruptManifest) {
            try fixture.withLock { try fixture.manifests.loadUploads(in: $0) }
        }
    }

    @Test func invalidImmutableVersionBindingFailsClosed() throws {
        let fixture = try ManifestFixture()
        let valid = try fixture.upload(mutation: 1, version: 1)
        let invalid = CloudAssetUploadReference(
            mutationID: valid.mutationID,
            version: valid.version,
            relativeFilename: "\(fixture.uuid(2).uuidString.lowercased())-\(valid.version.versionID.uuidString.lowercased()).asset"
        )
        #expect(throws: CloudAssetManifestStoreError.immutableIdentityMismatch) {
            try fixture.withLock { try fixture.manifests.commitUploads([invalid], in: $0) }
        }
    }

    @Test func validJSONInvalidAttachmentMetadataFailsClosed() throws {
        let fixture = try ManifestFixture()
        try fixture.withLock {
            try fixture.manifests.commitUploads([try fixture.upload(mutation: 1, version: 1)], in: $0)
        }
        let corrupted = try fixture.rewriteUploadPayload { payload in
            var entries = payload["entries"] as! [[String: Any]]
            var entry = entries[0]
            var version = entry["version"] as! [String: Any]
            version["byteCount"] = -1
            entry["version"] = version
            entries[0] = entry
            payload["entries"] = entries
        }
        try corrupted.write(to: fixture.uploadManifestURL)
        #expect(throws: CloudAssetManifestStoreError.corruptManifest) {
            try fixture.withLock { try fixture.manifests.loadUploads(in: $0) }
        }
    }

    @Test func missingAuthorityRequiresNoFinalOwnedFiles() throws {
        let empty = try ManifestFixture()
        #expect(try empty.withLock { try empty.manifests.loadUploads(in: $0) }.isEmpty)
        #expect(try empty.withLock { try empty.manifests.loadQuarantine(in: $0) }.isEmpty)

        let upload = try ManifestFixture()
        try upload.withLock {
            try upload.fileStore.publishNoClobber(Data("x".utf8), named: "\(upload.uuid(1).uuidString.lowercased())-\(upload.uuid(2).uuidString.lowercased()).asset", in: $0.uploads)
        }
        #expect(throws: CloudAssetManifestStoreError.corruptManifest) {
            try upload.withLock { try upload.manifests.loadUploads(in: $0) }
        }

        let quarantine = try ManifestFixture()
        try quarantine.withLock {
            try quarantine.fileStore.publishNoClobber(Data("x".utf8), named: "\(quarantine.uuid(1).uuidString.lowercased()).asset", in: $0.quarantine)
        }
        #expect(throws: CloudAssetManifestStoreError.corruptManifest) {
            try quarantine.withLock { try quarantine.manifests.loadQuarantine(in: $0) }
        }
    }

    @Test func quarantineLimitsAndDuplicateIdentityAreRejected() throws {
        let fixture = try ManifestFixture()
        let four = (1...4).map { fixture.quarantine($0, bytes: 100_000_000) }
        try fixture.withLock { try fixture.manifests.commitQuarantine(four, in: $0) }
        #expect(try fixture.withLock { try fixture.manifests.loadQuarantine(in: $0) } == four)

        #expect(throws: CloudAssetManifestStoreError.quarantineLimitExceeded) {
            try fixture.withLock {
                try fixture.manifests.commitQuarantine(four + [fixture.quarantine(5, bytes: 0)], in: $0)
            }
        }
        #expect(throws: CloudAssetManifestStoreError.corruptManifest) {
            try fixture.withLock {
                try fixture.manifests.commitQuarantine([four[0], four[0]], in: $0)
            }
        }
    }

    @Test func atomicCommitFailurePreservesPriorManifest() throws {
        let fixture = try ManifestFixture()
        let original = try fixture.upload(mutation: 1, version: 1)
        try fixture.withLock { try fixture.manifests.commitUploads([original], in: $0) }
        try #require(Darwin.chmod(fixture.accountURL.path, S_IRUSR | S_IXUSR) == 0)
        defer { _ = Darwin.chmod(fixture.accountURL.path, S_IRWXU) }

        #expect(throws: (any Error).self) {
            try fixture.withLock {
                try fixture.manifests.commitUploads([try fixture.upload(mutation: 2, version: 2)], in: $0)
            }
        }
        try #require(Darwin.chmod(fixture.accountURL.path, S_IRWXU) == 0)
        #expect(try fixture.withLock { try fixture.manifests.loadUploads(in: $0) } == [original])
    }
}

private final class ManifestFixture {
    let root: URL
    let accountIdentifier = "manifest-account"
    let fileStore: CloudAssetAccountFileStore
    let manifests: CloudAssetManifestStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cloud-asset-manifest-\(UUID().uuidString)", isDirectory: true
        )
        fileStore = try CloudAssetAccountFileStore(
            rootURL: root,
            accountIdentifier: accountIdentifier
        )
        manifests = CloudAssetManifestStore(fileStore: fileStore)
        try fileStore.withAccountLock { _ in }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var accountURL: URL {
        let token = Data(SHA256.hash(data: Data(accountIdentifier.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("Accounts/\(token)", isDirectory: true)
    }

    var uploadManifestURL: URL { accountURL.appendingPathComponent("manifest.json") }
    var quarantineManifestURL: URL {
        accountURL.appendingPathComponent("Quarantine/manifest.json")
    }

    func withLock<T>(_ body: (CloudAssetAccountDirectories) throws -> T) throws -> T {
        try fileStore.withAccountLock(body)
    }

    func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    func version(_ suffix: Int) throws -> SyncAttachmentVersion {
        let bytes = Data("payload-\(suffix)".utf8)
        return try SyncAttachmentVersion.issuing(
            slot: .init(owner: .init(kind: .project, uuid: uuid(900)), role: "project-photo", slotID: "cover"),
            contentSHA256: Data(SHA256.hash(data: bytes)),
            byteCount: Int64(bytes.count),
            mediaType: "image/jpeg",
            displayFilename: "cover.jpg",
            versionID: uuid(100 + suffix)
        )
    }

    func upload(mutation: Int, version: Int) throws -> CloudAssetUploadReference {
        let mutationID = uuid(mutation)
        let attachment = try self.version(version)
        return CloudAssetUploadReference(
            mutationID: mutationID,
            version: attachment,
            relativeFilename: "\(mutationID.uuidString.lowercased())-\(attachment.versionID.uuidString.lowercased()).asset"
        )
    }

    func quarantine(_ suffix: Int, bytes: Int64) -> CloudAssetQuarantineReference {
        let id = uuid(500 + suffix)
        return CloudAssetQuarantineReference(
            id: id,
            createdAt: Date(timeIntervalSince1970: TimeInterval(suffix)),
            byteCount: bytes,
            contentSHA256: Data(repeating: UInt8(suffix), count: 32),
            relativeFilename: "\(id.uuidString.lowercased()).asset"
        )
    }

    func rewriteUploadPayload(
        _ mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        let envelope = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: uploadManifestURL))
                as? [String: Any]
        )
        let payloadString = try #require(envelope["payload"] as? String)
        let payloadData = try #require(Data(base64Encoded: payloadString))
        var payload = try #require(
            JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        )
        mutate(&payload)
        let canonicalPayload = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var material = Data("knitnote.cloud-asset.upload-manifest.v1".utf8)
        material.append(0)
        material.append(canonicalPayload)
        let rewritten: [String: Any] = [
            "checksum": Data(SHA256.hash(data: material)).base64EncodedString(),
            "integrityVersion": 1,
            "payload": canonicalPayload.base64EncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: rewritten, options: [.sortedKeys])
    }
}
