import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

struct SyncRemoteBatchTransactionTests {
    @Test func retainedFormatOneFixtureRoundTripsExactlyBeforeReceiptUpgrade() throws {
        let bytes = try #require(Data(base64Encoded: Self.formatOneCheckpointFixture))
        let predecessor = try JSONDecoder().decode(SyncCanonicalCheckpoint.self, from: bytes).validated()

        #expect(predecessor.formatVersion == 1)
        #expect(predecessor.remoteBatchReceipts.isEmpty)
        #expect(try predecessor.encoded() == bytes)

        let receipt = self.receipt(
            accountIDHash: predecessor.accountIDHash,
            commitID: predecessor.commitID
        )
        let candidate = try predecessor.insertingRemoteReceipt(receipt)
        let decoded = try JSONDecoder().decode(
            SyncCanonicalCheckpoint.self,
            from: candidate.encoded()
        ).validated()

        #expect(decoded.formatVersion == 2)
        #expect(decoded.remoteBatchReceipts == [receipt])
        #expect(decoded.records == predecessor.records)
        #expect(decoded.legacyRecordIDsToDelete == predecessor.legacyRecordIDsToDelete)
    }

    @Test func retainedReceiptIsIdempotentAndSameBatchCollisionIsRejected() throws {
        let base = try checkpoint(commitID: uuid(1))
        let receipt = receipt(accountIDHash: base.accountIDHash, commitID: base.commitID)
        let candidate = try base.insertingRemoteReceipt(receipt)

        #expect(try candidate.insertingRemoteReceipt(receipt) == candidate)

        let conflicting = SyncRemoteBatchReceipt(
            identity: .init(
                accountIDHash: receipt.identity.accountIDHash,
                batchID: receipt.identity.batchID,
                contentSHA256: Data(repeating: 9, count: 32)
            ),
            commitID: receipt.commitID,
            domainChanged: receipt.domainChanged
        )
        #expect(throws: SyncRemoteBatchError.identityCollision) {
            _ = try candidate.insertingRemoteReceipt(conflicting)
        }
    }

    @Test func retainedReceiptRemainsIdempotentAfterNormalSuccessor() throws {
        let base = try checkpoint(commitID: uuid(25))
        let receipt = receipt(accountIDHash: base.accountIDHash, commitID: base.commitID)
        let retained = try base.insertingRemoteReceipt(receipt)
        let successor = try retained.successor(
            commitID: uuid(26),
            archiveSHA256: retained.archiveSHA256,
            records: retained.records,
            legacyRecordIDsToDelete: retained.legacyRecordIDsToDelete
        )

        #expect(try successor.insertingRemoteReceipt(receipt) == successor)
    }

    @Test func receiptAccountDigestAndCommitMustBindTheCandidate() throws {
        let base = try checkpoint(commitID: uuid(2))
        let valid = receipt(accountIDHash: base.accountIDHash, commitID: base.commitID)
        let invalid: [SyncRemoteBatchReceipt] = [
            .init(
                identity: .init(
                    accountIDHash: String(repeating: "b", count: 64),
                    batchID: valid.identity.batchID,
                    contentSHA256: valid.identity.contentSHA256
                ),
                commitID: valid.commitID,
                domainChanged: true
            ),
            .init(
                identity: .init(
                    accountIDHash: valid.identity.accountIDHash,
                    batchID: valid.identity.batchID,
                    contentSHA256: Data(repeating: 3, count: 31)
                ),
                commitID: valid.commitID,
                domainChanged: true
            ),
            .init(
                identity: valid.identity,
                commitID: uuid(3),
                domainChanged: true
            ),
        ]

        for receipt in invalid {
            #expect(throws: SyncRemoteBatchError.invalidBatch) {
                _ = try base.insertingRemoteReceipt(receipt)
            }
        }
    }

    @Test func fourThousandNinetySixReceiptsAreAcceptedAndNextIsRejected() throws {
        let base = try checkpoint(commitID: uuid(4))
        let receipts = (0..<4_096).map { index in
            receipt(
                accountIDHash: base.accountIDHash,
                batchID: UUID(uuidString: String(
                    format: "10000000-0000-0000-0000-%012x",
                    index
                ))!,
                commitID: base.commitID
            )
        }
        let exact = try SyncCanonicalCheckpoint(
            accountIDHash: base.accountIDHash,
            commitID: base.commitID,
            archiveSHA256: base.archiveSHA256,
            records: base.records,
            legacyRecordIDsToDelete: base.legacyRecordIDsToDelete,
            remoteBatchReceipts: receipts
        )
        #expect(exact.remoteBatchReceipts.count == 4_096)

        let overflow = receipt(
            accountIDHash: base.accountIDHash,
            batchID: uuid(5),
            commitID: base.commitID
        )
        #expect(throws: SyncRemoteBatchError.receiptCapacity) {
            _ = try exact.insertingRemoteReceipt(overflow)
        }
        #expect(exact.remoteBatchReceipts == receipts)
    }

    @Test func receiptBearingEnvelopeAcceptsExactByteCapAndInsertionRejectsOverCap() throws {
        let account = String(repeating: "a", count: 64)
        let commitID = uuid(15)
        let recordID = uuid(16)
        let receipt = receipt(
            accountIDHash: account,
            batchID: uuid(17),
            commitID: commitID
        )
        var fields: [String: SyncFieldVersion<SyncScalar>] = [:]
        for index in 0..<399 {
            fields["padding\(index)"] = .init(
                value: .string(String(repeating: "x", count: 250_000)),
                stamp: .remoteTransactionFixture
            )
        }
        fields["tail"] = .init(value: .string(""), stamp: .remoteTransactionFixture)
        let initial = try SyncCanonicalCheckpoint(
            accountIDHash: account,
            commitID: commitID,
            archiveSHA256: Data(repeating: 7, count: 32),
            records: [.remoteTransactionFixture(id: recordID, fields: fields)],
            legacyRecordIDsToDelete: [],
            remoteBatchReceipts: [receipt]
        )
        let tailCount = SyncCanonicalCheckpoint.maximumBytes - (try initial.encoded().count)
        #expect((0...SyncRecordValidator.maximumScalarByteCount).contains(tailCount))
        fields["tail"] = .init(
            value: .string(String(repeating: "x", count: tailCount)),
            stamp: .remoteTransactionFixture
        )
        let exact = try SyncCanonicalCheckpoint(
            accountIDHash: account,
            commitID: commitID,
            archiveSHA256: Data(repeating: 7, count: 32),
            records: [.remoteTransactionFixture(id: recordID, fields: fields)],
            legacyRecordIDsToDelete: [],
            remoteBatchReceipts: [receipt]
        )
        #expect(try exact.encoded().count == SyncCanonicalCheckpoint.maximumBytes)

        let withoutReceipt = try SyncCanonicalCheckpoint(
            accountIDHash: account,
            commitID: commitID,
            archiveSHA256: Data(repeating: 7, count: 32),
            records: [.remoteTransactionFixture(id: recordID, fields: fields)],
            legacyRecordIDsToDelete: []
        )
        let receiptOverhead = try exact.encoded().count - withoutReceipt.encoded().count
        #expect(receiptOverhead > 0)
        fields["tail"] = .init(
            value: .string(String(repeating: "x", count: tailCount + receiptOverhead)),
            stamp: .remoteTransactionFixture
        )
        let predecessor = try SyncCanonicalCheckpoint(
            accountIDHash: account,
            commitID: commitID,
            archiveSHA256: Data(repeating: 7, count: 32),
            records: [.remoteTransactionFixture(id: recordID, fields: fields)],
            legacyRecordIDsToDelete: []
        )
        #expect(try predecessor.encoded().count == SyncCanonicalCheckpoint.maximumBytes)
        #expect(throws: SyncRegularFileReadError.tooLarge) {
            _ = try predecessor.insertingRemoteReceipt(receipt)
        }
    }

    @Test func retainedFormatFivePublicationFixtureRemainsValid() throws {
        let bytes = try #require(Data(base64Encoded: Self.formatFivePublicationFixture))
        let transaction = try JSONDecoder().decode(
            SyncPublicationTransaction.self,
            from: bytes
        ).validated()

        #expect(transaction.version == 5)
        #expect(transaction.remoteSource == nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(transaction) == bytes)
    }

    @Test func formatSixBindsRemoteInsertToExactPredecessorAndSuccessorReceipt() throws {
        let predecessor = try checkpoint(commitID: uuid(6))
        let successor = try checkpoint(commitID: uuid(7))
        let receipt = receipt(
            accountIDHash: predecessor.accountIDHash,
            batchID: uuid(8),
            commitID: successor.commitID
        )
        let candidate = try successor.insertingRemoteReceipt(receipt)
        let commitment = try SyncRemoteBatchPredecessorCommitment(checkpoint: predecessor)
        let source = try SyncRemoteBatchPublicationSource(
            identity: receipt.identity,
            predecessor: commitment,
            receiptAction: .insert
        )
        let transaction = try SyncPublicationTransaction(
            expectedArchiveSHA256: candidate.archiveSHA256,
            mutations: [],
            revisionReceipts: [],
            canonicalTransition: .init(
                predecessorSHA256: commitment.checkpointSHA256,
                candidate: candidate
            ),
            remoteSource: source
        )
        let decoded = try JSONDecoder().decode(
            SyncPublicationTransaction.self,
            from: JSONEncoder().encode(transaction)
        ).validated()

        #expect(decoded.version == 6)
        #expect(decoded.remoteSource == source)
        #expect(decoded.canonicalTransition?.candidate.remoteBatchReceipts == [receipt])
    }

    @Test func formatSixSupportsMetadataOnlyReceiptRetirement() throws {
        let predecessorBase = try checkpoint(commitID: uuid(9))
        let receipt = receipt(
            accountIDHash: predecessorBase.accountIDHash,
            batchID: uuid(10),
            commitID: predecessorBase.commitID,
            domainChanged: false
        )
        let predecessor = try predecessorBase.insertingRemoteReceipt(receipt)
        let candidate = try predecessor.retiringRemoteReceipt(
            receipt.identity,
            successorCommitID: uuid(11)
        )
        let commitment = try SyncRemoteBatchPredecessorCommitment(checkpoint: predecessor)
        let source = try SyncRemoteBatchPublicationSource(
            identity: receipt.identity,
            predecessor: commitment,
            receiptAction: .retire
        )
        let transaction = try SyncPublicationTransaction(
            expectedArchiveSHA256: candidate.archiveSHA256,
            mutations: [],
            revisionReceipts: [],
            canonicalTransition: .init(
                predecessorSHA256: commitment.checkpointSHA256,
                candidate: candidate
            ),
            remoteSource: source
        )

        #expect(try transaction.validated().remoteSource?.receiptAction == .retire)
        #expect(candidate.archiveSHA256 == predecessor.archiveSHA256)
        #expect(candidate.records == predecessor.records)
        #expect(candidate.remoteBatchReceipts.isEmpty)
        #expect(candidate.formatVersion == 2)
    }

    @Test func formatTwoWithNoReceiptsDoesNotDowngradeOnNormalSuccessor() throws {
        let base = try checkpoint(commitID: uuid(18))
        let receipt = receipt(accountIDHash: base.accountIDHash, commitID: base.commitID)
        let retained = try base.insertingRemoteReceipt(receipt)
        let retired = try retained.retiringRemoteReceipt(
            receipt.identity,
            successorCommitID: uuid(19)
        )

        let successor = try retired.successor(
            commitID: uuid(20),
            archiveSHA256: retired.archiveSHA256,
            records: retired.records,
            legacyRecordIDsToDelete: retired.legacyRecordIDsToDelete
        )

        #expect(successor.formatVersion == 2)
        #expect(successor.remoteBatchReceipts.isEmpty)
    }

    @Test func remoteSourcePredecessorCommitIDParticipatesInIntegrity() throws {
        let predecessor = try checkpoint(commitID: uuid(21))
        let successor = try checkpoint(commitID: uuid(22))
        let receipt = receipt(
            accountIDHash: predecessor.accountIDHash,
            batchID: uuid(23),
            commitID: successor.commitID
        )
        let candidate = try successor.insertingRemoteReceipt(receipt)
        let commitment = try SyncRemoteBatchPredecessorCommitment(checkpoint: predecessor)
        let transaction = try SyncPublicationTransaction(
            expectedArchiveSHA256: candidate.archiveSHA256,
            mutations: [],
            revisionReceipts: [],
            canonicalTransition: .init(
                predecessorSHA256: commitment.checkpointSHA256,
                candidate: candidate
            ),
            remoteSource: .init(
                identity: receipt.identity,
                predecessor: commitment,
                receiptAction: .insert
            )
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(transaction))
                as? [String: Any]
        )
        var source = try #require(object["remoteSource"] as? [String: Any])
        var predecessorObject = try #require(source["predecessor"] as? [String: Any])
        predecessorObject["commitID"] = uuid(24).uuidString
        source["predecessor"] = predecessorObject
        object["remoteSource"] = source

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try JSONDecoder().decode(
                SyncPublicationTransaction.self,
                from: JSONSerialization.data(withJSONObject: object)
            ).validated()
        }
    }

    @Test func unknownAndMismatchedRemoteSourcesAreRejected() throws {
        let predecessor = try checkpoint(commitID: uuid(12))
        let successor = try checkpoint(commitID: uuid(13))
        let receipt = receipt(
            accountIDHash: predecessor.accountIDHash,
            batchID: uuid(14),
            commitID: successor.commitID
        )
        let candidate = try successor.insertingRemoteReceipt(receipt)
        let commitment = try SyncRemoteBatchPredecessorCommitment(checkpoint: predecessor)

        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try SyncRemoteBatchPublicationSource(
                formatVersion: 2,
                identity: receipt.identity,
                predecessor: commitment,
                receiptAction: .insert
            )
        }
        let mismatched = try SyncRemoteBatchPublicationSource(
            identity: receipt.identity,
            predecessor: .init(
                accountIDHash: commitment.accountIDHash,
                commitID: commitment.commitID,
                checkpointSHA256: Data(repeating: 8, count: 32)
            ),
            receiptAction: .insert
        )
        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            _ = try SyncPublicationTransaction(
                expectedArchiveSHA256: candidate.archiveSHA256,
                mutations: [],
                revisionReceipts: [],
                canonicalTransition: .init(
                    predecessorSHA256: commitment.checkpointSHA256,
                    candidate: candidate
                ),
                remoteSource: mismatched
            )
        }
    }

    private func checkpoint(commitID: UUID) throws -> SyncCanonicalCheckpoint {
        try .init(
            accountIDHash: String(repeating: "a", count: 64),
            commitID: commitID,
            archiveSHA256: Data(repeating: 7, count: 32),
            records: [],
            legacyRecordIDsToDelete: []
        )
    }

    private func receipt(
        accountIDHash: String,
        batchID: UUID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        commitID: UUID,
        domainChanged: Bool = true
    ) -> SyncRemoteBatchReceipt {
        .init(
            identity: .init(
                accountIDHash: accountIDHash,
                batchID: batchID,
                contentSHA256: Data(repeating: 2, count: 32)
            ),
            commitID: commitID,
            domainChanged: domainChanged
        )
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-0000-0000-%012x",
            value
        ))!
    }

    private static let formatOneCheckpointFixture =
        "eyJhY2NvdW50SURIYXNoIjoiNWVmNzQxZmY0MDA0MWY2MGUyZTc2MGQzNjlkN2EzMjE0YzI4MGJhZmE2ZTk5MTk4NjM4NTdlOWZjMGYyOTYyOCIsImFyY2hpdmVTSEEyNTYiOiJCd2NIQndjSEJ3Y0hCd2NIQndjSEJ3Y0hCd2NIQndjSEJ3Y0hCd2NIQndjPSIsImNvbW1pdElEIjoiMjdCNTcxNzUtMTMzNS00MzA5LTkwMkUtMjRCODMxQkQxMDU0IiwiZm9ybWF0VmVyc2lvbiI6MSwiaW50ZWdyaXR5U0hBMjU2IjoiNWM0Y2NiNTZkOGY3MGM5NmZmMjU5ZjYwOWMyYzAxZmMwOGVlODI1YzAwYTY5Y2RmMDRhNjU1NTlhNzk3ZmU3MyIsImxlZ2FjeVJlY29yZElEc1RvRGVsZXRlIjpbXSwicmVjb3JkcyI6W119"

    private static let formatFivePublicationFixture =
        "eyJhcnRpZmFjdEV2aWRlbmNlIjpbXSwiY2FuZGlkYXRlQXR0YWNobWVudE1hbmlmZXN0IjpbXSwiY2Fub25pY2FsVHJhbnNpdGlvbiI6eyJjYW5kaWRhdGUiOnsiYWNjb3VudElESGFzaCI6ImFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJhcmNoaXZlU0hBMjU2IjoiQVFFQkFRRUJBUUVCQVFFQkFRRUJBUUVCQVFFQkFRRUJBUUVCQVFFQkFRRT0iLCJjb21taXRJRCI6IjAwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAxMyIsImZvcm1hdFZlcnNpb24iOjEsImludGVncml0eVNIQTI1NiI6IjI0NTlhNmQxYmJjY2UwMTBiNWYzMjVjYjE2YzdmMDNkNzRkM2UyZmQ1ZTE0NDMwMDJmNWU2OWMzMTUwNmE5ZjYiLCJsZWdhY3lSZWNvcmRJRHNUb0RlbGV0ZSI6W10sInJlY29yZHMiOltdfX0sImNvbW1pdEJvdW5kYXJ5IjoiYXJjaGl2ZSIsImRlbGV0aW9uTGVkZ2VySUQiOiIwMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMTQiLCJleHBlY3RlZEFyY2hpdmVTSEEyNTYiOiJBUUVCQVFFQkFRRUJBUUVCQVFFQkFRRUJBUUVCQVFFQkFRRUJBUUVCQVFFPSIsImludGVncml0eSI6InhyNVY0eXZMa2E3NXd4am9RMnpkS3lpejJVTU56S1RsaHB0TDZueFwvSFA0PSIsIm11dGF0aW9ucyI6W10sInJldmlzaW9uUmVjZWlwdHMiOltdLCJ2ZXJzaW9uIjo1fQ=="
}

private extension SyncMutationStamp {
    static var remoteTransactionFixture: Self {
        .init(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "remote-transaction-fixture"
        )
    }
}

private extension SyncRecord {
    static func remoteTransactionFixture(
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
            deletedAt: .init(value: nil, stamp: .remoteTransactionFixture)
        )
    }
}
