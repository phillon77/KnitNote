import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncCanonicalPublicationTransactionTests {
    @Test func canonicalOnlyRoundTripCarriesExactlyOneCandidateAndNoMutation() throws {
        let candidate = try checkpoint(commitID: uuid(1))
        let transition = try SyncCanonicalTransition(
            predecessorSHA256: nil,
            candidate: candidate
        )
        let transaction = try SyncPublicationTransaction(
            expectedArchiveSHA256: candidate.archiveSHA256,
            mutations: [],
            revisionReceipts: [],
            canonicalTransition: transition
        )

        let decoded = try JSONDecoder().decode(
            SyncPublicationTransaction.self,
            from: JSONEncoder().encode(transaction)
        ).validated()

        #expect(decoded.canonicalTransition == transition)
        #expect(decoded.version == 7)
        #expect(decoded.conflictSource == nil)
        #expect(decoded.mutations.isEmpty)
        #expect(decoded.revisionReceipts.isEmpty)
    }

    @Test func transitionRejectsInvalidPredecessorDigestLength() throws {
        let candidate = try checkpoint(commitID: uuid(2))

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try SyncCanonicalTransition(
                predecessorSHA256: Data(repeating: 1, count: 31),
                candidate: candidate
            )
        }
    }

    @Test func transactionRejectsCandidateBoundToAnotherArchive() throws {
        let candidate = try checkpoint(commitID: uuid(3), archiveByte: 3)
        let transition = try SyncCanonicalTransition(
            predecessorSHA256: nil,
            candidate: candidate
        )

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try SyncPublicationTransaction(
                expectedArchiveSHA256: Data(repeating: 4, count: 32),
                mutations: [],
                revisionReceipts: [],
                canonicalTransition: transition
            )
        }
    }

    @Test func replacingValidCandidateWithoutUpdatingIntegrityIsRejected() throws {
        let first = try checkpoint(commitID: uuid(4))
        let second = try checkpoint(commitID: uuid(5))
        let original = try transaction(candidate: first, predecessorByte: 6)
        let replacement = try transaction(candidate: second, predecessorByte: 6)
        var object = try jsonObject(original)
        let replacementObject = try jsonObject(replacement)
        var transition = try #require(object["canonicalTransition"] as? [String: Any])
        let replacementTransition = try #require(
            replacementObject["canonicalTransition"] as? [String: Any]
        )
        transition["candidate"] = replacementTransition["candidate"]
        object["canonicalTransition"] = transition

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try JSONDecoder().decode(
                SyncPublicationTransaction.self,
                from: JSONSerialization.data(withJSONObject: object)
            ).validated()
        }
    }

    @Test func replacingValidPredecessorWithoutUpdatingIntegrityIsRejected() throws {
        let candidate = try checkpoint(commitID: uuid(6))
        let original = try transaction(candidate: candidate, predecessorByte: 7)
        var object = try jsonObject(original)
        var transition = try #require(object["canonicalTransition"] as? [String: Any])
        transition["predecessorSHA256"] = Data(repeating: 8, count: 32)
            .base64EncodedString()
        object["canonicalTransition"] = transition

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try JSONDecoder().decode(
                SyncPublicationTransaction.self,
                from: JSONSerialization.data(withJSONObject: object)
            ).validated()
        }
    }

    @Test func artifactOnlyCandidatesWithEqualArchiveDigestsKeepDistinctCommitIdentities() throws {
        let first = try checkpoint(commitID: uuid(9), archiveByte: 9)
        let second = try checkpoint(commitID: uuid(10), archiveByte: 9)
        let firstTransaction = try artifactOnlyTransaction(
            candidate: first,
            artifactByte: 1
        )
        let secondTransaction = try artifactOnlyTransaction(
            candidate: second,
            artifactByte: 2
        )

        #expect(firstTransaction.canonicalTransition?.candidate.commitID == uuid(9))
        #expect(secondTransaction.canonicalTransition?.candidate.commitID == uuid(10))
        #expect(firstTransaction != secondTransaction)
        #expect(firstTransaction.expectedArchiveSHA256 == secondTransaction.expectedArchiveSHA256)
        #expect(firstTransaction.mutations.isEmpty)
        #expect(secondTransaction.mutations.isEmpty)
    }

    @Test func mutationAndReceiptOrderSurvivesCanonicalTransactionRoundTrip() throws {
        let candidate = try checkpoint(commitID: uuid(11))
        let firstID = SyncEntityID(kind: .project, uuid: uuid(12))
        let secondID = SyncEntityID(kind: .yarn, uuid: uuid(13))
        let firstMutationID = uuid(14)
        let secondMutationID = uuid(15)
        let mutations: [SyncMutation] = [
            .delete(firstID, mutationID: firstMutationID),
            .delete(secondID, mutationID: secondMutationID)
        ]
        let receipts = [
            SyncRevisionReceipt(
                entityID: firstID,
                mutationID: firstMutationID,
                logicalRevision: 4,
                deviceID: "ordered-device"
            ),
            SyncRevisionReceipt(
                entityID: secondID,
                mutationID: secondMutationID,
                logicalRevision: 5,
                deviceID: "ordered-device"
            )
        ]
        let transaction = try SyncPublicationTransaction(
            expectedArchiveSHA256: candidate.archiveSHA256,
            mutations: mutations,
            revisionReceipts: receipts,
            canonicalTransition: try SyncCanonicalTransition(
                predecessorSHA256: nil,
                candidate: candidate
            )
        )

        let decoded = try JSONDecoder().decode(
            SyncPublicationTransaction.self,
            from: JSONEncoder().encode(transaction)
        ).validated()

        #expect(decoded.mutations == mutations)
        #expect(decoded.revisionReceipts == receipts)
        #expect(decoded.conflictSource == nil)
    }

    @Test func versionFiveRetainsManifestDeletionAndRestorationEligibility() throws {
        let candidate = try checkpoint(commitID: uuid(19))
        let transition = try SyncCanonicalTransition(
            predecessorSHA256: nil,
            candidate: candidate
        )
        let deletionLedgerID = uuid(20)
        let restorationWitness = SyncRestorationWitness(
            entryID: uuid(21),
            attemptID: uuid(22),
            beforeArchiveSHA256: Data(repeating: 2, count: 32)
        )
        let deletion = try SyncPublicationTransaction(
            expectedArchiveSHA256: candidate.archiveSHA256,
            mutations: [],
            revisionReceipts: [],
            candidateAttachmentManifest: [],
            deletionLedgerID: deletionLedgerID,
            canonicalTransition: transition
        )
        let restoration = try SyncPublicationTransaction(
            expectedArchiveSHA256: candidate.archiveSHA256,
            mutations: [],
            revisionReceipts: [],
            candidateAttachmentManifest: [],
            restorationWitness: restorationWitness,
            canonicalTransition: transition
        )

        #expect(try deletion.validated().deletionLedgerID == deletionLedgerID)
        #expect(try restoration.validated().restorationWitness == restorationWitness)
        #expect(deletion.candidateAttachmentManifest == [])
        #expect(restoration.candidateAttachmentManifest == [])
    }

    @Test func transactionFileWritesAndReadsCanonicalCandidateAboveOldOneMiBLimit() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = try sizedCheckpoint(encodedByteCount: 1_100_000)
        let transaction = try transaction(candidate: candidate, predecessorByte: nil)
        let file = SyncPublicationTransactionFile(
            archiveURL: root.appendingPathComponent("projects.json")
        )

        try file.write(transaction)

        #expect(try Data(contentsOf: file.url).count > 1_048_576)
        #expect(try file.load() == transaction)
    }

    @Test func transactionFileRejectsOverallBytesBeyondNewCapWithSmallCandidate() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = try checkpoint(commitID: uuid(16))
        #expect(try candidate.encoded().count < 1_048_576)
        let file = SyncPublicationTransactionFile(
            archiveURL: root.appendingPathComponent("projects.json")
        )
        try file.write(try transaction(candidate: candidate, predecessorByte: nil))
        let handle = try FileHandle(forWritingTo: file.url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var remaining = 100_000_001 - Int(try handle.offset())
        let whitespace = Data(repeating: 32, count: 1_000_000)
        while remaining > 0 {
            let byteCount = min(remaining, whitespace.count)
            try handle.write(contentsOf: whitespace.prefix(byteCount))
            remaining -= byteCount
        }

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try file.load()
        }
    }

    @Test func transactionFileRejectsEncodingBeyondNewCapEvenWhenCandidateFits() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = try sizedCheckpoint(encodedByteCount: 100_000_000)
        #expect(try candidate.encoded().count == 100_000_000)
        let file = SyncPublicationTransactionFile(
            archiveURL: root.appendingPathComponent("projects.json")
        )

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            try file.write(try transaction(candidate: candidate, predecessorByte: nil))
        }
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    private func transaction(
        candidate: SyncCanonicalCheckpoint,
        predecessorByte: UInt8?
    ) throws -> SyncPublicationTransaction {
        try SyncPublicationTransaction(
            expectedArchiveSHA256: candidate.archiveSHA256,
            mutations: [],
            revisionReceipts: [],
            canonicalTransition: SyncCanonicalTransition(
                predecessorSHA256: predecessorByte.map { Data(repeating: $0, count: 32) },
                candidate: candidate
            )
        )
    }

    private func artifactOnlyTransaction(
        candidate: SyncCanonicalCheckpoint,
        artifactByte: UInt8
    ) throws -> SyncPublicationTransaction {
        try SyncPublicationTransaction(
            expectedArchiveSHA256: candidate.archiveSHA256,
            mutations: [],
            commitBoundary: .artifacts,
            artifactEvidence: [try SyncPublicationArtifactEvidence(
                relativePath: "Photos/project-cover.jpg",
                expectedSHA256: Data(repeating: artifactByte, count: 32)
            )],
            revisionReceipts: [],
            canonicalTransition: SyncCanonicalTransition(
                predecessorSHA256: nil,
                candidate: candidate
            )
        )
    }

    private func checkpoint(
        commitID: UUID,
        archiveByte: UInt8 = 1,
        records: [SyncRecord] = []
    ) throws -> SyncCanonicalCheckpoint {
        try SyncCanonicalCheckpoint(
            accountIDHash: String(repeating: "a", count: 64),
            commitID: commitID,
            archiveSHA256: Data(repeating: archiveByte, count: 32),
            records: records,
            legacyRecordIDsToDelete: []
        )
    }

    private func sizedCheckpoint(encodedByteCount: Int) throws -> SyncCanonicalCheckpoint {
        var fields: [String: SyncFieldVersion<SyncScalar>] = [:]
        let fullScalarCount = max(
            1,
            (encodedByteCount / 250_000) - (encodedByteCount > 10_000_000 ? 1 : 0)
        )
        for index in 0..<fullScalarCount {
            fields["padding\(index)"] = .init(
                value: .string(String(repeating: "x", count: 250_000)),
                stamp: .transactionFixture
            )
        }
        fields["tail"] = .init(value: .string(""), stamp: .transactionFixture)
        let recordID = uuid(17)
        let commitID = uuid(18)
        let initial = try checkpoint(
            commitID: commitID,
            records: [.transactionFixture(id: recordID, fields: fields)]
        )
        let tailCount = encodedByteCount - (try initial.encoded().count)
        #expect((0...SyncRecordValidator.maximumScalarByteCount).contains(tailCount))
        fields["tail"] = .init(
            value: .string(String(repeating: "x", count: tailCount)),
            stamp: .transactionFixture
        )
        let result = try checkpoint(
            commitID: commitID,
            records: [.transactionFixture(id: recordID, fields: fields)]
        )
        #expect(try result.encoded().count == encodedByteCount)
        return result
    }

    private func jsonObject(
        _ transaction: SyncPublicationTransaction
    ) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(transaction))
                as? [String: Any]
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "canonical-publication-\(UUID().uuidString)",
            isDirectory: true
        )
        try! FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-0000-0000-%012x",
            value
        ))!
    }
}

private extension SyncMutationStamp {
    static var transactionFixture: Self {
        .init(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "transaction-fixture"
        )
    }
}

private extension SyncRecord {
    static func transactionFixture(
        id: UUID,
        fields: [String: SyncFieldVersion<SyncScalar>]
    ) -> Self {
        .init(
            schemaVersion: 1,
            id: .init(kind: .project, uuid: id),
            createdAt: Date(timeIntervalSince1970: 1),
            entityRevision: 1,
            payload: .init(fields: fields),
            relationships: [],
            deletedAt: .init(value: nil, stamp: .transactionFixture)
        )
    }
}
