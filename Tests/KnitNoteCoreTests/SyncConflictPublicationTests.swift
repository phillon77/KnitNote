import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

struct SyncConflictPublicationTests {
    @Test func conflictFormatRoundTripsReconstructableGlobalFIFO() throws {
        let fixture = try publicationFixture()

        let encoded = try sortedEncoder().encode(fixture.transaction)
        let decoded = try JSONDecoder().decode(
            SyncPublicationTransaction.self,
            from: encoded
        ).validated()

        #expect(decoded.version == 7)
        #expect(decoded.mutations.isEmpty)
        #expect(decoded.remoteSource == nil)
        #expect(decoded.conflictSource == fixture.source)
        #expect(decoded.conflictSource?.beforePending == fixture.before.map(\.mutation))
        #expect(decoded.conflictSource?.afterPending == fixture.after.map(\.mutation))
        #expect(decoded.conflictSource?.beforeVersions == fixture.before.map(\.token))
        #expect(decoded.conflictSource?.afterVersions == fixture.after.map(\.token))
        #expect(decoded.canonicalTransition?.candidate.records.count == 1)
        #expect(decoded.canonicalTransition?.candidate.records.first?.id
            == fixture.before[0].mutation.recordID)
    }

    @Test func sourceRejectsPlanPendingThatDoesNotMatchGlobalPredecessor() throws {
        let fixture = try publicationFixture()
        let changedPlan = copy(
            fixture.source.plan,
            pending: Array(fixture.source.plan.pending.reversed())
        )

        #expect(throws: SyncPublicationError.corruptTransaction) {
            _ = try SyncConflictPublicationSource(
                input: fixture.source.input,
                transition: fixture.source.transition,
                plan: changedPlan,
                beforePending: fixture.source.beforePending,
                afterPending: fixture.source.afterPending,
                beforeVersions: fixture.source.beforeVersions,
                afterVersions: fixture.source.afterVersions
            )
        }
    }

    @Test func sourceRequiresOnlyTheRawServerRecordAndNoRawDeletionIDs() throws {
        let fixture = try publicationFixture()
        let wrongRecords = copy(fixture.source.plan, records: [])
        let rawDeletion = copy(
            fixture.source.plan,
            deletedRecordIDs: [fixture.source.input.serverRecord.id]
        )

        for plan in [wrongRecords, rawDeletion] {
            #expect(throws: SyncPublicationError.corruptTransaction) {
                _ = try SyncConflictPublicationSource(
                    input: fixture.source.input,
                    transition: fixture.source.transition,
                    plan: plan,
                    beforePending: fixture.source.beforePending,
                    afterPending: fixture.source.afterPending,
                    beforeVersions: fixture.source.beforeVersions,
                    afterVersions: fixture.source.afterVersions
                )
            }
        }
    }

    @Test func sourceRejectsAnyChangeAtAnUnselectedGlobalFIFOPosition() throws {
        let fixture = try publicationFixture()
        let unrelatedBefore = fixture.before[0]
        let unrelatedRecord = try #require(
            fixture.source.plan.predecessor.records.first {
                $0.id == unrelatedBefore.mutation.recordID
            }
        )
        let changedMutation = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: unrelatedRecord),
            mutationID: unrelatedBefore.mutation.mutationID
        )
        var changedAfter = fixture.source.afterPending
        var changedVersions = fixture.source.afterVersions
        changedAfter[0] = changedMutation
        changedVersions[0] = try SyncMutationVersionToken(mutation: changedMutation)

        #expect(throws: SyncPublicationError.corruptTransaction) {
            _ = try SyncConflictPublicationSource(
                input: fixture.source.input,
                transition: fixture.source.transition,
                plan: fixture.source.plan,
                beforePending: fixture.source.beforePending,
                afterPending: changedAfter,
                beforeVersions: fixture.source.beforeVersions,
                afterVersions: changedVersions
            )
        }
    }

    @Test func transactionRejectsCandidateThatDoesNotMatchProjectedQueue() throws {
        let fixture = try publicationFixture()
        let plan = fixture.source.plan
        let mismatched = try plan.predecessor.successor(
            commitID: fixture.source.transition.transactionID,
            archiveSHA256: Data(SHA256.hash(data: plan.archive)),
            records: [fixture.source.input.serverRecord],
            legacyRecordIDsToDelete: plan.predecessor.legacyRecordIDsToDelete
        )

        #expect(throws: (any Error).self) {
            _ = try SyncPublicationTransaction(
                expectedArchiveSHA256: mismatched.archiveSHA256,
                mutations: [],
                revisionReceipts: [],
                canonicalTransition: .init(
                    predecessorSHA256: Data(SHA256.hash(data: plan.predecessor.encoded())),
                    candidate: mismatched
                ),
                conflictSource: fixture.source
            )
        }
    }

    @Test func conflictCandidateCannotFabricateRemoteBatchReceipt() throws {
        let fixture = try publicationFixture()
        let plan = fixture.source.plan
        let identity = SyncRemoteBatchIdentity(
            accountIDHash: plan.predecessor.accountIDHash,
            batchID: UUID(uuidString: "40000000-0000-0000-0000-000000000008")!,
            contentSHA256: Data(repeating: 8, count: 32)
        )
        let candidate = try fixture.transaction.canonicalTransition!.candidate
            .insertingRemoteReceipt(.init(
                identity: identity,
                commitID: fixture.source.transition.transactionID,
                domainChanged: false
            ))

        #expect(throws: (any Error).self) {
            _ = try SyncPublicationTransaction(
                expectedArchiveSHA256: candidate.archiveSHA256,
                mutations: [],
                revisionReceipts: [],
                canonicalTransition: .init(
                    predecessorSHA256: Data(SHA256.hash(data: plan.predecessor.encoded())),
                    candidate: candidate
                ),
                conflictSource: fixture.source
            )
        }
    }

    @Test func remoteAndConflictSourcesCannotBothBeSet() throws {
        let fixture = try publicationFixture()
        let plan = fixture.source.plan
        let identity = SyncRemoteBatchIdentity(
            accountIDHash: plan.predecessor.accountIDHash,
            batchID: UUID(uuidString: "40000000-0000-0000-0000-000000000009")!,
            contentSHA256: Data(repeating: 9, count: 32)
        )
        let candidate = try fixture.transaction.canonicalTransition!.candidate
            .insertingRemoteReceipt(.init(
                identity: identity,
                commitID: fixture.source.transition.transactionID,
                domainChanged: false
            ))

        #expect(throws: (any Error).self) {
            _ = try SyncPublicationTransaction(
                expectedArchiveSHA256: candidate.archiveSHA256,
                mutations: [],
                revisionReceipts: [],
                canonicalTransition: .init(
                    predecessorSHA256: Data(SHA256.hash(data: plan.predecessor.encoded())),
                    candidate: candidate
                ),
                remoteSource: .init(
                    identity: identity,
                    predecessor: .init(checkpoint: plan.predecessor),
                    receiptAction: .insert
                ),
                conflictSource: fixture.source
            )
        }
    }

    @Test func conflictRawAttachmentRequiresCompleteMediaPlan() throws {
        let bytes = Data("required remote media".utf8)
        let digest = Data(SHA256.hash(data: bytes))
        let owner = SyncEntityID(kind: .project, uuid: UUID())
        let version = try SyncAttachmentVersion.issuing(
            slot: .init(owner: owner, role: "project-photo", slotID: "cover"),
            contentSHA256: digest,
            byteCount: Int64(bytes.count),
            mediaType: "image/jpeg",
            displayFilename: "cover.jpg"
        )
        let stamp = SyncMutationStamp(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 1),
            deviceID: "conflict-media"
        )
        let record = SyncRecord(
            schemaVersion: 1,
            id: .init(kind: .attachment, uuid: version.versionID),
            createdAt: stamp.modifiedAt,
            entityRevision: 1,
            payload: .init(fields: [:], attachment: version),
            relationships: [.init(role: "owner", target: owner)],
            deletedAt: .init(value: nil, stamp: stamp)
        )
        let sourceURL = URL(fileURLWithPath: "/tmp/conflict-media-source.jpg")
        let mutation = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: record),
            attachmentSource: .init(
                fileURL: sourceURL,
                contentSHA256: digest,
                byteCount: Int64(bytes.count)
            ),
            mutationID: UUID()
        )
        let beforeToken = try SyncMutationVersionToken(mutation: mutation)
        let afterToken = try SyncMutationVersionToken(
            mutation: mutation,
            journalRevision: 1
        )
        let input = try SyncConflictInput(
            accountIDHash: String(repeating: "a", count: 64),
            failedAttemptID: UUID(),
            failedMutation: mutation,
            failedVersion: beforeToken,
            serverRecord: record,
            expectedRecordQueue: [mutation],
            expectedVersions: [beforeToken]
        )
        let transition = try SyncJournalRebaseTransition(
            transactionID: UUID(),
            input: input,
            predecessorPendingSHA256: SyncConflictRebaseCoding.pendingDigest([
                try SyncVersionedMutation(mutation: mutation, token: beforeToken),
            ]),
            recordPositions: [0],
            before: [mutation],
            after: [mutation],
            beforeVersions: [beforeToken],
            afterVersions: [afterToken]
        )
        let predecessor = try SyncCanonicalCheckpoint(
            accountIDHash: input.accountIDHash,
            commitID: UUID(),
            archiveSHA256: Data(repeating: 1, count: 32),
            records: [],
            legacyRecordIDsToDelete: []
        )
        let archive = Data("media candidate archive".utf8)
        let plan = SyncRemoteBatchDurablePlan(
            predecessor: predecessor,
            journalURL: URL(fileURLWithPath: "/tmp/conflict-media-pending.json"),
            predecessorEvidence: try sortedEncoder().encode(
                SyncAttachmentPublicationEvidence()
            ),
            authority: [
                .init(
                    path: "/tmp/conflict-media",
                    device: 1,
                    inode: 1,
                    bytes: 0,
                    digest: Data()
                ),
                .init(
                    path: "/tmp/conflict-media/projects.json",
                    device: 1,
                    inode: 2,
                    bytes: 1,
                    digest: predecessor.archiveSHA256
                ),
            ],
            pending: [mutation],
            records: [record],
            deletedRecordIDs: [],
            preparedCommands: [],
            processedLedger: .init(),
            deletionMarkers: [],
            archive: archive,
            files: []
        )
        let source = try SyncConflictPublicationSource(
            input: input,
            transition: transition,
            plan: plan,
            beforePending: [mutation],
            afterPending: [mutation],
            beforeVersions: [beforeToken],
            afterVersions: [afterToken]
        )
        let candidate = try predecessor.successor(
            commitID: transition.transactionID,
            archiveSHA256: Data(SHA256.hash(data: archive)),
            records: [record],
            legacyRecordIDsToDelete: []
        )

        #expect(throws: (any Error).self) {
            _ = try SyncPublicationTransaction(
                expectedArchiveSHA256: candidate.archiveSHA256,
                mutations: [],
                revisionReceipts: [],
                canonicalTransition: .init(
                    predecessorSHA256: Data(SHA256.hash(data: predecessor.encoded())),
                    candidate: candidate
                ),
                conflictSource: source
            )
        }
    }

    @Test @MainActor
    func liveRawAttachmentDeleteSurvivesRoundTripAndRealLeaseWrite() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appendingPathComponent("pending.json")
        let journal = FileSyncMutationJournal(url: journalURL)
        let fixture = try attachmentPublicationFixture(
            outcome: .delete,
            journal: journal,
            journalURL: journalURL
        )
        let result = try await Task.detached {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(fixture.transaction)
            let decoded = try JSONDecoder().decode(
                SyncPublicationTransaction.self,
                from: encoded
            ).validated()
            let file = SyncPublicationTransactionFile(
                archiveURL: root.appendingPathComponent("projects.json")
            )
            try journal.withExclusivePending { lease in
                try file.write(decoded, preflightingWith: lease)
            }
            return (encoded: encoded, decoded: decoded, written: try Data(contentsOf: file.url))
        }.value

        #expect(result.decoded == fixture.transaction)
        #expect(result.decoded.conflictSource?.plan.files.count == 1)
        #expect(result.decoded.artifactEvidence.count == 1)
        #expect(result.decoded.conflictSource?.plan.records.first?.payload.attachment
            == result.decoded.conflictSource?.plan.files.first?.version)
        #expect(result.decoded.canonicalTransition?.candidate.records.isEmpty == true)
        #expect(result.written == result.encoded)
        #expect(try journal.pendingVersioned() == fixture.before)
    }

    @Test @MainActor
    func liveRawAttachmentTombstoneSurvivesRoundTripAndRealLeaseWrite() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appendingPathComponent("pending.json")
        let journal = FileSyncMutationJournal(url: journalURL)
        let fixture = try attachmentPublicationFixture(
            outcome: .tombstone,
            journal: journal,
            journalURL: journalURL
        )
        let result = try await Task.detached {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(fixture.transaction)
            let decoded = try JSONDecoder().decode(
                SyncPublicationTransaction.self,
                from: encoded
            ).validated()
            let file = SyncPublicationTransactionFile(
                archiveURL: root.appendingPathComponent("projects.json")
            )
            try journal.withExclusivePending { lease in
                try file.write(decoded, preflightingWith: lease)
            }
            return (encoded: encoded, decoded: decoded, written: try Data(contentsOf: file.url))
        }.value

        #expect(result.decoded == fixture.transaction)
        #expect(result.decoded.conflictSource?.plan.files.count == 1)
        #expect(result.decoded.artifactEvidence.count == 1)
        #expect(result.decoded.conflictSource?.plan.records.first?.payload.attachment
            == result.decoded.conflictSource?.plan.files.first?.version)
        #expect(result.decoded.canonicalTransition?.candidate.records.count == 1)
        #expect(result.decoded.canonicalTransition?.candidate.records.first?.deletedAt.value != nil)
        #expect(result.written == result.encoded)
        #expect(try journal.pendingVersioned() == fixture.before)
    }

    @Test func conflictMediaPlanRejectsFileWithNoRawOrLiveCandidatePurpose() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appendingPathComponent("pending.json")
        let journal = FileSyncMutationJournal(url: journalURL)
        let fixture = try attachmentPublicationFixture(
            outcome: .delete,
            journal: journal,
            journalURL: journalURL
        )
        let bytes = Data("unreferenced media".utf8)
        let owner = SyncEntityID(kind: .project, uuid: UUID())
        let version = try SyncAttachmentVersion.issuing(
            slot: .init(owner: owner, role: "project-photo", slotID: "unreferenced"),
            contentSHA256: Data(SHA256.hash(data: bytes)),
            byteCount: Int64(bytes.count),
            mediaType: "image/jpeg",
            displayFilename: "unreferenced.jpg"
        )
        let unreferenced = SyncRemoteInstallFile(
            relativePath: "Photos/\(version.versionID.uuidString).jpg",
            version: version,
            data: bytes
        )
        let changedPlan = copy(
            fixture.source.plan,
            files: fixture.source.plan.files + [unreferenced]
        )
        let changedSource = try SyncConflictPublicationSource(
            input: fixture.source.input,
            transition: fixture.source.transition,
            plan: changedPlan,
            beforePending: fixture.source.beforePending,
            afterPending: fixture.source.afterPending,
            beforeVersions: fixture.source.beforeVersions,
            afterVersions: fixture.source.afterVersions
        )
        let candidate = try #require(fixture.transaction.canonicalTransition?.candidate)
        let evidence = try changedPlan.files.map {
            try SyncPublicationArtifactEvidence(
                relativePath: $0.relativePath,
                expectedSHA256: $0.version.contentSHA256
            )
        }

        #expect(throws: (any Error).self) {
            _ = try SyncPublicationTransaction(
                expectedArchiveSHA256: candidate.archiveSHA256,
                mutations: [],
                artifactEvidence: evidence,
                revisionReceipts: [],
                canonicalTransition: .init(
                    predecessorSHA256: Data(SHA256.hash(
                        data: try changedPlan.predecessor.encoded()
                    )),
                    candidate: candidate
                ),
                conflictSource: changedSource
            )
        }
    }

    @Test func changedTransitionDigestIsRejectedOnDecode() throws {
        let fixture = try publicationFixture()
        var object = try #require(
            JSONSerialization.jsonObject(with: sortedEncoder().encode(fixture.transaction))
                as? [String: Any]
        )
        var source = try #require(object["conflictSource"] as? [String: Any])
        var transition = try #require(source["transition"] as? [String: Any])
        transition["integrity"] = Data(repeating: 9, count: 32).base64EncodedString()
        source["transition"] = transition
        object["conflictSource"] = source

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                SyncPublicationTransaction.self,
                from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
        }
    }

    @Test func ordinaryWriterCannotBypassConflictJournalPreflight() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appendingPathComponent("pending.json")
        let fixture = try publicationFixture(journalURL: journalURL)
        let file = SyncPublicationTransactionFile(
            archiveURL: root.appendingPathComponent("projects.json")
        )

        #expect(throws: (any Error).self) {
            try file.write(fixture.transaction)
        }
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func conflictWriterRejectsWrongAndStaleLeasesWithoutIntent() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appendingPathComponent("pending.json")
        let otherURL = root.appendingPathComponent("other-pending.json")
        let journal = FileSyncMutationJournal(url: journalURL)
        let other = FileSyncMutationJournal(url: otherURL)
        let fixture = try publicationFixture(journalURL: journalURL)
        try journal.enqueue(fixture.before.map(\.mutation))
        let file = SyncPublicationTransactionFile(
            archiveURL: root.appendingPathComponent("projects.json")
        )

        #expect(throws: (any Error).self) {
            try other.withExclusivePending { lease in
                try file.write(fixture.transaction, preflightingWith: lease)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: file.url.path))

        try journal.enqueue(.delete(
            .init(kind: .project, uuid: UUID()),
            mutationID: UUID()
        ))
        #expect(throws: (any Error).self) {
            try journal.withExclusivePending { lease in
                try file.write(fixture.transaction, preflightingWith: lease)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func conflictWriterPreflightsRealLeaseAndPersistsExactBytes() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appendingPathComponent("pending.json")
        let journal = FileSyncMutationJournal(url: journalURL)
        let fixture = try publicationFixture(journalURL: journalURL)
        try journal.enqueue(fixture.before.map(\.mutation))
        let file = SyncPublicationTransactionFile(
            archiveURL: root.appendingPathComponent("projects.json")
        )

        try journal.withExclusivePending { lease in
            try file.write(fixture.transaction, preflightingWith: lease)
        }

        #expect(try Data(contentsOf: file.url) == sortedEncoder().encode(fixture.transaction))
        #expect(try file.load() == fixture.transaction)
        #expect(try journal.pendingVersioned() == fixture.before)
    }

    @Test func conflictWriterEnforcesActualHundredMillionByteBoundary() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appendingPathComponent("pending.json")
        let journal = FileSyncMutationJournal(url: journalURL)
        let empty = try publicationFixture(journalURL: journalURL, archive: Data())
        let overhead = try sortedEncoder().encode(empty.transaction).count
        let estimatedLimitArchiveByteCount = ((100_000_000 - overhead) / 4) * 3 + 1
        let belowArchiveByteCount = estimatedLimitArchiveByteCount - 32
        let below = try publicationFixture(
            journalURL: journalURL,
            archive: Data(repeating: 1, count: belowArchiveByteCount)
        )
        let belowBytes = try sortedEncoder().encode(below.transaction)
        #expect(belowBytes.count < 100_000_000)
        #expect(belowBytes.count >= 99_999_900)
        try journal.enqueue(below.before.map(\.mutation))
        let file = SyncPublicationTransactionFile(
            archiveURL: root.appendingPathComponent("projects.json")
        )

        try journal.withExclusivePending { lease in
            try file.write(below.transaction, preflightingWith: lease)
        }
        #expect(try Data(contentsOf: file.url).count == belowBytes.count)
        try file.remove()

        let over = try publicationFixture(
            journalURL: journalURL,
            archive: Data(repeating: 1, count: estimatedLimitArchiveByteCount + 100)
        )
        #expect(try sortedEncoder().encode(over.transaction).count > 100_000_000)
        #expect(throws: (any Error).self) {
            try journal.withExclusivePending { lease in
                try file.write(over.transaction, preflightingWith: lease)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func retainedFormatsTwoThroughSixRoundTripExactly() throws {
        for (version, base64) in Self.preFormatSevenFixtures {
            let bytes = try #require(Data(base64Encoded: base64))
            let transaction = try JSONDecoder().decode(
                SyncPublicationTransaction.self,
                from: bytes
            ).validated()

            #expect(transaction.version == version)
            #expect(transaction.conflictSource == nil)
            #expect(try sortedEncoder().encode(transaction) == bytes)
        }
    }

    @Test func oldFormatsRejectConflictSourceInsteadOfIgnoringIt() throws {
        let source = try publicationFixture().source
        let sourceObject = try JSONSerialization.jsonObject(
            with: sortedEncoder().encode(source)
        )
        for (_, base64) in Self.preFormatSevenFixtures {
            let bytes = try #require(Data(base64Encoded: base64))
            var object = try #require(
                JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            )
            object["conflictSource"] = sourceObject
            let changed = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )

            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(
                    SyncPublicationTransaction.self,
                    from: changed
                ).validated()
            }
        }
    }

    private static let preFormatSevenFixtures: [(Int, String)] = [
        (2, "eyJhcnRpZmFjdEV2aWRlbmNlIjpbeyJleHBlY3RlZFNIQTI1NiI6IkF3TURBd01EQXdNREF3TURBd01EQXdNREF3TURBd01EQXdNREF3TURBd009IiwicmVsYXRpdmVQYXRoIjoiUGhvdG9zXC9maXh0dXJlLmpwZyJ9XSwiY29tbWl0Qm91bmRhcnkiOiJhcnRpZmFjdHMiLCJleHBlY3RlZEFyY2hpdmVTSEEyNTYiOiJCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVPSIsImludGVncml0eSI6ImhBZXpZRkt0dlFcL3hJNmV3TWNESzYxeXhwc0p3WVFvQlFTRnJDVTdZWURNPSIsIm11dGF0aW9ucyI6W3siZGVsZXRlIjp7Il8wIjp7Im11dGF0aW9uSUQiOiIzMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDIiLCJyZWNvcmRJRCI6eyJraW5kIjoicHJvamVjdCIsInV1aWQiOiIzMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDEifX19fV0sInJldmlzaW9uUmVjZWlwdHMiOltdLCJ2ZXJzaW9uIjoyfQ=="),
        (3, "eyJhcnRpZmFjdEV2aWRlbmNlIjpbeyJleHBlY3RlZFNIQTI1NiI6IkF3TURBd01EQXdNREF3TURBd01EQXdNREF3TURBd01EQXdNREF3TURBd009IiwicmVsYXRpdmVQYXRoIjoiUGhvdG9zXC9maXh0dXJlLmpwZyJ9XSwiY29tbWl0Qm91bmRhcnkiOiJhcnRpZmFjdHMiLCJleHBlY3RlZEFyY2hpdmVTSEEyNTYiOiJCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVPSIsImludGVncml0eSI6InRjQTFyakQ0SnhsK0JMR2g2eGlrY08rVEFxT0V4emlRaFRlRTVzeEhhczg9IiwibXV0YXRpb25zIjpbeyJkZWxldGUiOnsiXzAiOnsibXV0YXRpb25JRCI6IjMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMiIsInJlY29yZElEIjp7ImtpbmQiOiJwcm9qZWN0IiwidXVpZCI6IjMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMSJ9fX19XSwicmV2aXNpb25SZWNlaXB0cyI6W3siZGV2aWNlSUQiOiJmb3JtYXQtZml4dHVyZSIsImVudGl0eUlEIjp7ImtpbmQiOiJwcm9qZWN0IiwidXVpZCI6IjMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMSJ9LCJsb2dpY2FsUmV2aXNpb24iOjEsIm11dGF0aW9uSUQiOiIzMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDIifV0sInZlcnNpb24iOjN9"),
        (4, "eyJhcnRpZmFjdEV2aWRlbmNlIjpbeyJleHBlY3RlZFNIQTI1NiI6IkF3TURBd01EQXdNREF3TURBd01EQXdNREF3TURBd01EQXdNREF3TURBd009IiwicmVsYXRpdmVQYXRoIjoiUGhvdG9zXC9maXh0dXJlLmpwZyJ9XSwiY2FuZGlkYXRlQXR0YWNobWVudE1hbmlmZXN0IjpbXSwiY29tbWl0Qm91bmRhcnkiOiJhcnRpZmFjdHMiLCJleHBlY3RlZEFyY2hpdmVTSEEyNTYiOiJCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVPSIsImludGVncml0eSI6IldRM3lHT05ORVF3bU1Cbk9QT3RQSk45czd3QXVCZXlaZEVsOVkxOHJESmc9IiwibXV0YXRpb25zIjpbeyJkZWxldGUiOnsiXzAiOnsibXV0YXRpb25JRCI6IjMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMiIsInJlY29yZElEIjp7ImtpbmQiOiJwcm9qZWN0IiwidXVpZCI6IjMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMSJ9fX19XSwicmV2aXNpb25SZWNlaXB0cyI6W3siZGV2aWNlSUQiOiJmb3JtYXQtZml4dHVyZSIsImVudGl0eUlEIjp7ImtpbmQiOiJwcm9qZWN0IiwidXVpZCI6IjMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMSJ9LCJsb2dpY2FsUmV2aXNpb24iOjEsIm11dGF0aW9uSUQiOiIzMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDIifV0sInZlcnNpb24iOjR9"),
        (5, "eyJhcnRpZmFjdEV2aWRlbmNlIjpbeyJleHBlY3RlZFNIQTI1NiI6IkF3TURBd01EQXdNREF3TURBd01EQXdNREF3TURBd01EQXdNREF3TURBd009IiwicmVsYXRpdmVQYXRoIjoiUGhvdG9zXC9maXh0dXJlLmpwZyJ9XSwiY2FuZGlkYXRlQXR0YWNobWVudE1hbmlmZXN0IjpbXSwiY2Fub25pY2FsVHJhbnNpdGlvbiI6eyJjYW5kaWRhdGUiOnsiYWNjb3VudElESGFzaCI6ImFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJhcmNoaXZlU0hBMjU2IjoiQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVT0iLCJjb21taXRJRCI6IjMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMyIsImZvcm1hdFZlcnNpb24iOjEsImludGVncml0eVNIQTI1NiI6ImY0MmRhNTZlZTY1YzkzYWNlZDA1YWQyNzVjYzNiNzgyOWE2YWQ4YWVjZGEyZjdhYjk3MzgwMmZjODEwYzc4OGYiLCJsZWdhY3lSZWNvcmRJRHNUb0RlbGV0ZSI6W10sInJlY29yZHMiOltdfSwicHJlZGVjZXNzb3JTSEEyNTYiOiJCQVFFQkFRRUJBUUVCQVFFQkFRRUJBUUVCQVFFQkFRRUJBUUVCQVFFQkFRPSJ9LCJjb21taXRCb3VuZGFyeSI6ImFydGlmYWN0cyIsImV4cGVjdGVkQXJjaGl2ZVNIQTI1NiI6IkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVU9IiwiaW50ZWdyaXR5Ijoib0hTM1wveDNHeXYxd05EaHFDMzNPdXN2cTY5SlErMnNScml2cldaampTRXc9IiwibXV0YXRpb25zIjpbeyJkZWxldGUiOnsiXzAiOnsibXV0YXRpb25JRCI6IjMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMiIsInJlY29yZElEIjp7ImtpbmQiOiJwcm9qZWN0IiwidXVpZCI6IjMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMSJ9fX19XSwicmV2aXNpb25SZWNlaXB0cyI6W3siZGV2aWNlSUQiOiJmb3JtYXQtZml4dHVyZSIsImVudGl0eUlEIjp7ImtpbmQiOiJwcm9qZWN0IiwidXVpZCI6IjMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMSJ9LCJsb2dpY2FsUmV2aXNpb24iOjEsIm11dGF0aW9uSUQiOiIzMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDIifV0sInZlcnNpb24iOjV9"),
        (6, "eyJhcnRpZmFjdEV2aWRlbmNlIjpbeyJleHBlY3RlZFNIQTI1NiI6IkF3TURBd01EQXdNREF3TURBd01EQXdNREF3TURBd01EQXdNREF3TURBd009IiwicmVsYXRpdmVQYXRoIjoiUGhvdG9zXC9maXh0dXJlLmpwZyJ9XSwiY2Fub25pY2FsVHJhbnNpdGlvbiI6eyJjYW5kaWRhdGUiOnsiYWNjb3VudElESGFzaCI6ImFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJhcmNoaXZlU0hBMjU2IjoiQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVT0iLCJjb21taXRJRCI6IjMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMyIsImZvcm1hdFZlcnNpb24iOjIsImludGVncml0eVNIQTI1NiI6IjBjNGFmOTNmNTNjYzdiOTM1M2YzM2NjMjRkNTJiM2QzNTAxYjUyMDA1OGFhZWY4MTNmNGQ0MjNlOGZiZmYyOTMiLCJsZWdhY3lSZWNvcmRJRHNUb0RlbGV0ZSI6W10sInJlY29yZHMiOltdLCJyZW1vdGVCYXRjaFJlY2VpcHRzIjpbeyJjb21taXRJRCI6IjMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMyIsImRvbWFpbkNoYW5nZWQiOnRydWUsImlkZW50aXR5Ijp7ImFjY291bnRJREhhc2giOiJhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhIiwiYmF0Y2hJRCI6IjMwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwNSIsImNvbnRlbnRTSEEyNTYiOiJCZ1lHQmdZR0JnWUdCZ1lHQmdZR0JnWUdCZ1lHQmdZR0JnWUdCZ1lHQmdZPSJ9fV19LCJwcmVkZWNlc3NvclNIQTI1NiI6IkE0ZjBMYkVIZ0FUODRzcTgwcllVZDhKVGd6MlZMUTF2ZlVMSFlwWlRYaTg9In0sImNvbW1pdEJvdW5kYXJ5IjoiYXJjaGl2ZSIsImV4cGVjdGVkQXJjaGl2ZVNIQTI1NiI6IkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVVGQlFVRkJRVUZCUVU9IiwiaW50ZWdyaXR5Ijoiczc2TVNidktkdyt5Mm93RFZoSVJHeVlxb0w4V0k0dmRYZDZLTGhKc0RBbz0iLCJtdXRhdGlvbnMiOltdLCJyZW1vdGVTb3VyY2UiOnsiZm9ybWF0VmVyc2lvbiI6MSwiaWRlbnRpdHkiOnsiYWNjb3VudElESGFzaCI6ImFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJiYXRjaElEIjoiMzAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDA1IiwiY29udGVudFNIQTI1NiI6IkJnWUdCZ1lHQmdZR0JnWUdCZ1lHQmdZR0JnWUdCZ1lHQmdZR0JnWUdCZ1k9In0sInByZWRlY2Vzc29yIjp7ImFjY291bnRJREhhc2giOiJhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhIiwiY2hlY2twb2ludFNIQTI1NiI6IkE0ZjBMYkVIZ0FUODRzcTgwcllVZDhKVGd6MlZMUTF2ZlVMSFlwWlRYaTg9IiwiY29tbWl0SUQiOiIzMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDQifSwicmVjZWlwdEFjdGlvbiI6Imluc2VydCJ9LCJyZXZpc2lvblJlY2VpcHRzIjpbXSwidmVyc2lvbiI6Nn0="),
    ]

    private func publicationFixture(
        journalURL: URL = URL(fileURLWithPath: "/tmp/conflict-publication-pending.json"),
        archive suppliedArchive: Data? = nil
    ) throws -> ConflictPublicationFixture {
        let account = String(repeating: "a", count: 64)
        let affectedID = SyncEntityID(
            kind: .project,
            uuid: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        )
        let unrelatedID = SyncEntityID(
            kind: .yarn,
            uuid: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
        )
        let serverRecord = publicationRecord(id: affectedID, name: "Server")
        let unrelatedRecord = publicationRecord(id: unrelatedID, name: "Unrelated")
        let affected = SyncMutation.delete(
            affectedID,
            mutationID: UUID(uuidString: "40000000-0000-0000-0000-000000000003")!
        )
        let unrelated = SyncMutation.delete(
            unrelatedID,
            mutationID: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        )
        let affectedToken = try SyncMutationVersionToken(mutation: affected)
        let unrelatedToken = try SyncMutationVersionToken(mutation: unrelated)
        let input = try SyncConflictInput(
            accountIDHash: account,
            failedAttemptID: UUID(uuidString: "40000000-0000-0000-0000-000000000005")!,
            failedMutation: affected,
            failedVersion: affectedToken,
            serverRecord: serverRecord,
            expectedRecordQueue: [affected],
            expectedVersions: [affectedToken]
        )
        let before = [
            try SyncVersionedMutation(mutation: unrelated, token: unrelatedToken),
            try SyncVersionedMutation(mutation: affected, token: affectedToken),
        ]
        let after = [
            before[0],
            try SyncVersionedMutation(
                mutation: affected,
                token: SyncMutationVersionToken(mutation: affected, journalRevision: 1)
            ),
        ]
        let transactionID = UUID(uuidString: "40000000-0000-0000-0000-000000000006")!
        let transition = try SyncJournalRebaseTransition(
            transactionID: transactionID,
            input: input,
            predecessorPendingSHA256: SyncConflictRebaseCoding.pendingDigest(before),
            recordPositions: [1],
            before: [affected],
            after: [affected],
            beforeVersions: [affectedToken],
            afterVersions: [after[1].token]
        )
        let predecessor = try SyncCanonicalCheckpoint(
            accountIDHash: account,
            commitID: UUID(uuidString: "40000000-0000-0000-0000-000000000007")!,
            archiveSHA256: Data(repeating: 7, count: 32),
            records: [serverRecord, unrelatedRecord],
            legacyRecordIDsToDelete: []
        )
        let archive = suppliedArchive ?? Data("conflict candidate archive".utf8)
        let candidate = try predecessor.successor(
            commitID: transactionID,
            archiveSHA256: Data(SHA256.hash(data: archive)),
            records: [unrelatedRecord],
            legacyRecordIDsToDelete: predecessor.legacyRecordIDsToDelete
        )
        let evidence = try sortedEncoder().encode(SyncAttachmentPublicationEvidence())
        let plan = SyncRemoteBatchDurablePlan(
            predecessor: predecessor,
            journalURL: journalURL,
            predecessorEvidence: evidence,
            authority: [
                .init(
                    path: journalURL.deletingLastPathComponent().path,
                    device: 1,
                    inode: 1,
                    bytes: 0,
                    digest: Data()
                ),
                .init(
                    path: journalURL.deletingLastPathComponent()
                        .appendingPathComponent("projects.json").path,
                    device: 1,
                    inode: 2,
                    bytes: 1,
                    digest: predecessor.archiveSHA256
                ),
            ],
            pending: before.map(\.mutation),
            records: [serverRecord],
            deletedRecordIDs: [],
            preparedCommands: [],
            processedLedger: .init(),
            deletionMarkers: [],
            archive: archive,
            files: []
        )
        let source = try SyncConflictPublicationSource(
            input: input,
            transition: transition,
            plan: plan,
            beforePending: before.map(\.mutation),
            afterPending: after.map(\.mutation),
            beforeVersions: before.map(\.token),
            afterVersions: after.map(\.token)
        )
        let canonical = try SyncCanonicalTransition(
            predecessorSHA256: Data(SHA256.hash(data: predecessor.encoded())),
            candidate: candidate
        )
        let transaction = try SyncPublicationTransaction(
            expectedArchiveSHA256: candidate.archiveSHA256,
            mutations: [],
            revisionReceipts: [],
            canonicalTransition: canonical,
            conflictSource: source
        )
        return ConflictPublicationFixture(
            transaction: transaction,
            source: source,
            before: before,
            after: after
        )
    }

    private func attachmentPublicationFixture(
        outcome: AttachmentConflictOutcome,
        journal: FileSyncMutationJournal,
        journalURL: URL
    ) throws -> ConflictPublicationFixture {
        let bytes = Data("required raw conflict media".utf8)
        let digest = Data(SHA256.hash(data: bytes))
        let owner = SyncEntityID(kind: .project, uuid: UUID())
        let version = try SyncAttachmentVersion.issuing(
            slot: .init(owner: owner, role: "project-photo", slotID: "cover"),
            contentSHA256: digest,
            byteCount: Int64(bytes.count),
            mediaType: "image/jpeg",
            displayFilename: "cover.jpg"
        )
        let stamp = SyncMutationStamp(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 1),
            deviceID: "conflict-media"
        )
        let serverRecord = SyncRecord(
            schemaVersion: 1,
            id: .init(kind: .attachment, uuid: version.versionID),
            createdAt: stamp.modifiedAt,
            entityRevision: 1,
            payload: .init(fields: [:], attachment: version),
            relationships: [.init(role: "owner", target: owner)],
            deletedAt: .init(value: nil, stamp: stamp)
        )
        let mutationID = UUID()
        let requested: SyncMutation
        switch outcome {
        case .delete:
            requested = .delete(serverRecord.id, mutationID: mutationID)
        case .tombstone:
            var tombstone = serverRecord
            let deletionStamp = SyncMutationStamp(
                logicalRevision: 2,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 2),
                deviceID: "conflict-media"
            )
            tombstone.entityRevision = 2
            tombstone.deletedAt = .init(value: deletionStamp.modifiedAt, stamp: deletionStamp)
            requested = try .save(
                recordVersion: .init(record: tombstone),
                mutationID: mutationID
            )
        }
        try journal.enqueue(requested)
        let before = try journal.pendingVersioned()
        guard before.count == 1, let beforeEntry = before.first else {
            throw SyncPublicationError.corruptTransaction
        }
        let replacement = beforeEntry.mutation
        let afterEntry = try SyncVersionedMutation(
            mutation: replacement,
            journalRevision: beforeEntry.token.journalRevision + 1
        )
        let input = try SyncConflictInput(
            accountIDHash: String(repeating: "a", count: 64),
            failedAttemptID: UUID(),
            failedMutation: beforeEntry.mutation,
            failedVersion: beforeEntry.token,
            serverRecord: serverRecord,
            expectedRecordQueue: [beforeEntry.mutation],
            expectedVersions: [beforeEntry.token]
        )
        let transition = try SyncJournalRebaseTransition(
            transactionID: UUID(),
            input: input,
            predecessorPendingSHA256: SyncConflictRebaseCoding.pendingDigest(before),
            recordPositions: [0],
            before: [beforeEntry.mutation],
            after: [replacement],
            beforeVersions: [beforeEntry.token],
            afterVersions: [afterEntry.token]
        )
        let predecessor = try SyncCanonicalCheckpoint(
            accountIDHash: input.accountIDHash,
            commitID: UUID(),
            archiveSHA256: Data(repeating: 1, count: 32),
            records: [serverRecord],
            legacyRecordIDsToDelete: []
        )
        let archive = Data("attachment outcome candidate".utf8)
        let candidateRecords: [SyncRecord] = switch outcome {
        case .delete: []
        case .tombstone: [try #require(replacement.savedRecordVersion?.record)]
        }
        let candidate = try predecessor.successor(
            commitID: transition.transactionID,
            archiveSHA256: Data(SHA256.hash(data: archive)),
            records: candidateRecords,
            legacyRecordIDsToDelete: []
        )
        let file = SyncRemoteInstallFile(
            relativePath: "Photos/\(version.versionID.uuidString).jpg",
            version: version,
            data: bytes
        )
        let plan = SyncRemoteBatchDurablePlan(
            predecessor: predecessor,
            journalURL: journalURL,
            predecessorEvidence: try sortedEncoder().encode(
                SyncAttachmentPublicationEvidence()
            ),
            authority: [
                .init(
                    path: journalURL.deletingLastPathComponent().path,
                    device: 1,
                    inode: 1,
                    bytes: 0,
                    digest: Data()
                ),
                .init(
                    path: journalURL.deletingLastPathComponent()
                        .appendingPathComponent("projects.json").path,
                    device: 1,
                    inode: 2,
                    bytes: 1,
                    digest: predecessor.archiveSHA256
                ),
            ],
            pending: before.map(\.mutation),
            records: [serverRecord],
            deletedRecordIDs: [],
            preparedCommands: [],
            processedLedger: .init(),
            deletionMarkers: [],
            archive: archive,
            files: [file]
        )
        let source = try SyncConflictPublicationSource(
            input: input,
            transition: transition,
            plan: plan,
            beforePending: before.map(\.mutation),
            afterPending: [replacement],
            beforeVersions: before.map(\.token),
            afterVersions: [afterEntry.token]
        )
        let transaction = try SyncPublicationTransaction(
            expectedArchiveSHA256: candidate.archiveSHA256,
            mutations: [],
            artifactEvidence: [try .init(
                relativePath: file.relativePath,
                expectedSHA256: file.version.contentSHA256
            )],
            revisionReceipts: [],
            canonicalTransition: .init(
                predecessorSHA256: Data(SHA256.hash(data: predecessor.encoded())),
                candidate: candidate
            ),
            conflictSource: source
        )
        return ConflictPublicationFixture(
            transaction: transaction,
            source: source,
            before: before,
            after: [afterEntry]
        )
    }

    private func publicationRecord(id: SyncEntityID, name: String) -> SyncRecord {
        let stamp = SyncMutationStamp(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 1),
            deviceID: "conflict-publication"
        )
        return SyncRecord(
            schemaVersion: 1,
            id: id,
            createdAt: stamp.modifiedAt,
            entityRevision: 1,
            payload: .init(fields: [
                "name": .init(value: .string(name), stamp: stamp),
            ]),
            relationships: [],
            deletedAt: .init(value: nil, stamp: stamp)
        )
    }

    private func sortedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "conflict-publication-\(UUID().uuidString)",
            isDirectory: true
        )
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func copy(
        _ plan: SyncRemoteBatchDurablePlan,
        pending: [SyncMutation]? = nil,
        records: [SyncRecord]? = nil,
        deletedRecordIDs: [SyncEntityID]? = nil,
        files: [SyncRemoteInstallFile]? = nil
    ) -> SyncRemoteBatchDurablePlan {
        SyncRemoteBatchDurablePlan(
            predecessor: plan.predecessor,
            journalURL: plan.journalURL,
            predecessorEvidence: plan.predecessorEvidence,
            authority: plan.authority,
            pending: pending ?? plan.pending,
            records: records ?? plan.records,
            deletedRecordIDs: deletedRecordIDs ?? plan.deletedRecordIDs,
            preparedCommands: plan.preparedCommands,
            processedLedger: plan.processedLedger,
            deletionMarkers: plan.deletionMarkers,
            archive: plan.archive,
            files: files ?? plan.files
        )
    }
}

private struct ConflictPublicationFixture {
    let transaction: SyncPublicationTransaction
    let source: SyncConflictPublicationSource
    let before: [SyncVersionedMutation]
    let after: [SyncVersionedMutation]
}

private enum AttachmentConflictOutcome {
    case delete
    case tombstone
}
