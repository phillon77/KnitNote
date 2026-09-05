import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

struct SyncConflictInputTests {
    @Test @MainActor func fixtureProvidesExactlyThreeSameRecordSaves() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()

        #expect(input.expectedRecordQueue.count == 3)
        #expect(input.expectedRecordQueue.allSatisfy { $0.intent == .save })
        #expect(Set(input.expectedRecordQueue.map(\.recordID)) == Set([input.serverRecord.id]))
        #expect(input.expectedVersions.allSatisfy { $0.journalRevision == 0 })
        #expect(input.failedMutation == input.expectedRecordQueue[0])
        #expect(input.failedVersion == input.expectedVersions[0])
    }

    @Test @MainActor func samePayloadHasRepeatableToken() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let mutation = try f.input().expectedRecordQueue[0]

        #expect(
            try SyncMutationVersionToken(mutation: mutation)
                == SyncMutationVersionToken(mutation: mutation)
        )
    }

    @Test @MainActor func journalRevisionDoesNotChangePortableContentDigest() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let mutation = try f.input().expectedRecordQueue[0]
        let issued = try SyncMutationVersionToken(mutation: mutation)
        let rebased = try SyncMutationVersionToken(mutation: mutation, journalRevision: 1)

        #expect(issued.contentSHA256 == rebased.contentSHA256)
        #expect(issued != rebased)
    }

    @Test @MainActor func differentPayloadWithSameIDHasDifferentToken() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()
        let first = input.expectedRecordQueue[0]
        let changed = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: input.serverRecord),
            mutationID: first.mutationID
        )
        #expect(first.identity == changed.identity)
        #expect(
            try SyncMutationVersionToken(mutation: first)
                != SyncMutationVersionToken(mutation: changed)
        )
    }

    @Test @MainActor func deletionOverlayChangesToken() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let original = try f.input().expectedRecordQueue[0]
        var record = try #require(original.savedRecordVersion?.record)
        let deletionStamp = SyncMutationStamp(
            logicalRevision: record.entityRevision,
            modifiedAt: Date(timeIntervalSince1970: 2_000_000_100),
            deviceID: "deletion-overlay"
        )
        record.payload.deletionCascade = .init(value: [], stamp: deletionStamp)
        record.deletedAt = .init(
            value: Date(timeIntervalSince1970: 2_000_000_100),
            stamp: deletionStamp
        )
        let changed = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: record),
            mutationID: original.mutationID
        )

        #expect(original.identity == changed.identity)
        #expect(
            try SyncMutationVersionToken(mutation: original)
                != SyncMutationVersionToken(mutation: changed)
        )
    }

    @Test @MainActor func attachmentContentChangesToken() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let remote = try f.photoBatch(id: UUID())
        let originalRecord = try #require(remote.batch.records.first {
            $0.id.kind == .attachment
        })
        let originalAttachment = try #require(originalRecord.payload.attachment)
        let originalSource = try #require(remote.attachments[originalAttachment.versionID])
        let mutationID = UUID()
        let original = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: originalRecord),
            attachmentSource: originalSource,
            mutationID: mutationID
        )

        let changedBytes = Data("different attachment bytes".utf8)
        let changedDigest = Data(SHA256.hash(data: changedBytes))
        let changedAttachment = try SyncAttachmentVersion(
            slot: originalAttachment.slot,
            versionID: originalAttachment.versionID,
            conflictGroupID: originalAttachment.conflictGroupID,
            contentSHA256: changedDigest,
            byteCount: Int64(changedBytes.count),
            mediaType: originalAttachment.mediaType,
            displayFilename: originalAttachment.displayFilename,
            replacesVersionID: originalAttachment.replacesVersionID
        )
        let changedURL = f.root.appendingPathComponent("changed-attachment.jpg")
        try changedBytes.write(to: changedURL)
        let changedRecord = SyncRecord(
            schemaVersion: originalRecord.schemaVersion,
            id: originalRecord.id,
            createdAt: originalRecord.createdAt,
            entityRevision: originalRecord.entityRevision,
            payload: .init(
                fields: originalRecord.payload.fields,
                deletionCascade: originalRecord.payload.deletionCascade,
                atomicDomain: originalRecord.payload.atomicDomain,
                attachment: changedAttachment
            ),
            relationships: originalRecord.relationships,
            deletedAt: originalRecord.deletedAt
        )
        let changed = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: changedRecord),
            attachmentSource: SyncAttachmentSource(
                fileURL: changedURL,
                contentSHA256: changedDigest,
                byteCount: Int64(changedBytes.count)
            ),
            mutationID: mutationID
        )

        #expect(original.identity == changed.identity)
        #expect(
            try SyncMutationVersionToken(mutation: original)
                != SyncMutationVersionToken(mutation: changed)
        )
    }

    @Test @MainActor func tokenIsPortableAcrossSafeSourceRelocation() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let remote = try f.photoBatch(id: UUID())
        let record = try #require(remote.batch.records.first { $0.id.kind == .attachment })
        let attachment = try #require(record.payload.attachment)
        let source = try #require(remote.attachments[attachment.versionID])
        let relocatedURL = f.root.appendingPathComponent("relocated-source.jpg")
        try FileManager.default.copyItem(at: source.fileURL, to: relocatedURL)
        let relocatedSource = try SyncAttachmentSource(
            fileURL: relocatedURL,
            contentSHA256: source.contentSHA256,
            byteCount: source.byteCount
        )
        let mutationID = UUID()
        let original = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: record),
            attachmentSource: source,
            mutationID: mutationID
        )
        let relocated = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: record),
            attachmentSource: relocatedSource,
            mutationID: mutationID
        )

        #expect(original != relocated)
        #expect(
            try SyncMutationVersionToken(mutation: original)
                == SyncMutationVersionToken(mutation: relocated)
        )
    }

    @Test @MainActor func orderedPendingDigestChangesWithQueueOrder() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()
        let versioned = try zip(input.expectedRecordQueue, input.expectedVersions).map {
            try SyncVersionedMutation(mutation: $0.0, token: $0.1)
        }

        #expect(
            try SyncConflictRebaseCoding.pendingDigest(versioned)
                != SyncConflictRebaseCoding.pendingDigest(Array(versioned.reversed()))
        )
    }

    @Test @MainActor func invalidAccountHashIsRejected() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()

        #expect(throws: SyncConflictError.invalidInput) {
            try copied(input, accountIDHash: String(repeating: "A", count: 64))
        }
    }

    @Test @MainActor func serverRecordMustMatchFailedRecord() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()
        let unrelated = try #require(f.base.records.first { $0.id != input.failedMutation.recordID })

        #expect(throws: SyncConflictError.invalidInput) {
            try copied(input, serverRecord: unrelated)
        }
    }

    @Test @MainActor func failedMutationMustMatchQueueHeadIdentity() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()
        let second = input.expectedRecordQueue[1]

        #expect(throws: SyncConflictError.invalidInput) {
            try copied(
                input,
                failedMutation: second,
                failedVersion: SyncMutationVersionToken(mutation: second)
            )
        }
    }

    @Test @MainActor func emptyQueueIsRejected() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()

        #expect(throws: SyncConflictError.invalidInput) {
            try copied(input, expectedRecordQueue: [], expectedVersions: [])
        }
    }

    @Test @MainActor func duplicateMutationIDsAreRejected() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()
        let duplicate = input.expectedRecordQueue[0]
        let token = input.expectedVersions[0]

        #expect(throws: SyncConflictError.invalidInput) {
            try copied(
                input,
                expectedRecordQueue: [duplicate, duplicate],
                expectedVersions: [token, token]
            )
        }
    }

    @Test @MainActor func multipleRecordIDsAreRejected() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()
        let unrelatedRecord = try #require(f.base.records.first {
            $0.id != input.failedMutation.recordID
        })
        let unrelated = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: unrelatedRecord),
            mutationID: UUID()
        )

        #expect(throws: SyncConflictError.invalidInput) {
            try copied(
                input,
                expectedRecordQueue: input.expectedRecordQueue + [unrelated],
                expectedVersions: input.expectedVersions + [
                    try SyncMutationVersionToken(mutation: unrelated)
                ]
            )
        }
    }

    @Test @MainActor func expectedVersionMustMatchQueueContent() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()
        let head = input.expectedRecordQueue[0]
        let changed = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: input.serverRecord),
            mutationID: head.mutationID
        )
        var versions = input.expectedVersions
        versions[0] = try SyncMutationVersionToken(mutation: changed)

        #expect(throws: SyncConflictError.invalidInput) {
            try copied(input, expectedVersions: versions)
        }
    }

    @Test @MainActor func malformedTokenDigestIsRejectedOnDecode() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let token = try f.input().failedVersion
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(token)) as? [String: Any]
        )
        object["contentSHA256"] = Data([0]).base64EncodedString()
        let malformed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        #expect(throws: SyncConflictError.invalidInput) {
            try JSONDecoder().decode(SyncMutationVersionToken.self, from: malformed)
        }
    }

    @Test @MainActor func invalidAttachmentBindingInInputIsRejected() throws {
        let f = try RemoteBatchFixture(); defer { f.remove() }
        let remote = try f.photoBatch(id: UUID())
        let record = try #require(remote.batch.records.first { $0.id.kind == .attachment })
        let attachment = try #require(record.payload.attachment)
        let source = try #require(remote.attachments[attachment.versionID])
        let valid = try SyncMutation.save(
            recordVersion: SyncRecordVersion(record: record),
            attachmentSource: source,
            mutationID: UUID()
        )
        let invalid = try mutationWithTamperedAttachmentByteCount(valid)

        #expect(throws: SyncConflictError.invalidInput) {
            try SyncConflictInput(
                accountIDHash: f.account.accountIDHash,
                failedAttemptID: UUID(),
                failedMutation: invalid,
                failedVersion: SyncMutationVersionToken(mutation: valid),
                serverRecord: record,
                expectedRecordQueue: [invalid],
                expectedVersions: [try SyncMutationVersionToken(mutation: valid)]
            )
        }
    }

    @Test @MainActor func transitionRejectsInvalidPositions() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()
        let after = try replacements(for: input)
        let afterVersions = try after.map {
            try SyncMutationVersionToken(mutation: $0, journalRevision: 1)
        }

        #expect(throws: SyncConflictError.invalidInput) {
            try SyncJournalRebaseTransition(
                transactionID: UUID(),
                input: input,
                predecessorPendingSHA256: Data(repeating: 1, count: 32),
                recordPositions: [1, 0, 2],
                before: input.expectedRecordQueue,
                after: after,
                beforeVersions: input.expectedVersions,
                afterVersions: afterVersions
            )
        }
    }

    @Test @MainActor func transitionRejectsSameTransactionIDWithChangedContent() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let input = try f.input()
        let transition = try validTransition(input)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(transition)) as? [String: Any]
        )
        let transactionID = try #require(object["transactionID"] as? String)
        object["recordPositions"] = [0, 1, 3]
        #expect(object["transactionID"] as? String == transactionID)
        let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        #expect(throws: SyncConflictError.invalidInput) {
            try JSONDecoder().decode(SyncJournalRebaseTransition.self, from: changed)
        }
    }

    @Test @MainActor func transitionRoundTripsWithValidatedIntegrity() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let transition = try validTransition(f.input())

        let decoded = try JSONDecoder().decode(
            SyncJournalRebaseTransition.self,
            from: JSONEncoder().encode(transition)
        )

        #expect(decoded == transition)
        #expect(decoded.integrity.count == 32)
    }

    @Test @MainActor func transitionRejectsRevisionOverflow() throws {
        let f = try ConflictRebaseFixture(); defer { f.remove() }
        let original = try f.input()
        let versions = try original.expectedRecordQueue.map {
            try SyncMutationVersionToken(mutation: $0, journalRevision: UInt64.max)
        }
        let input = try copied(original, failedVersion: versions[0], expectedVersions: versions)

        #expect(throws: SyncConflictError.invalidInput) {
            try SyncJournalRebaseTransition(
                transactionID: UUID(),
                input: input,
                predecessorPendingSHA256: Data(repeating: 1, count: 32),
                recordPositions: Array(input.expectedRecordQueue.indices),
                before: input.expectedRecordQueue,
                after: input.expectedRecordQueue,
                beforeVersions: versions,
                afterVersions: versions
            )
        }
    }

    @Test func transitionRejectsEncodingBeyondJournalCapacity() throws {
        let stamp = SyncMutationStamp(
            logicalRevision: 1,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 1),
            deviceID: "conflict-capacity"
        )
        let record = SyncRecord(
            schemaVersion: 1,
            id: .init(kind: .project, uuid: UUID()),
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            entityRevision: 1,
            payload: .init(fields: [
                "payload": .init(
                    value: .data(Data(
                        repeating: 7,
                        count: SyncRecordValidator.maximumScalarByteCount
                    )),
                    stamp: stamp
                ),
            ]),
            relationships: [],
            deletedAt: .init(value: nil, stamp: stamp)
        )
        let version = try SyncRecordVersion(record: record)
        let before = try (0..<90).map { _ in
            try SyncMutation.save(recordVersion: version, mutationID: UUID())
        }
        let beforeVersions = try before.map {
            try SyncMutationVersionToken(mutation: $0)
        }
        let input = try SyncConflictInput(
            accountIDHash: String(repeating: "a", count: 64),
            failedAttemptID: UUID(),
            failedMutation: before[0],
            failedVersion: beforeVersions[0],
            serverRecord: record,
            expectedRecordQueue: before,
            expectedVersions: beforeVersions
        )
        let afterVersions = try before.map {
            try SyncMutationVersionToken(mutation: $0, journalRevision: 1)
        }

        #expect(throws: SyncConflictError.capacity) {
            try SyncJournalRebaseTransition(
                transactionID: UUID(),
                input: input,
                predecessorPendingSHA256: try SyncConflictRebaseCoding.pendingDigest(
                    zip(before, beforeVersions).map {
                        try SyncVersionedMutation(mutation: $0.0, token: $0.1)
                    }
                ),
                recordPositions: Array(before.indices),
                before: before,
                after: before,
                beforeVersions: beforeVersions,
                afterVersions: afterVersions
            )
        }
    }
}

private extension SyncConflictInputTests {
    @MainActor
    func copied(
        _ input: SyncConflictInput,
        accountIDHash: String? = nil,
        failedMutation: SyncMutation? = nil,
        failedVersion: SyncMutationVersionToken? = nil,
        serverRecord: SyncRecord? = nil,
        expectedRecordQueue: [SyncMutation]? = nil,
        expectedVersions: [SyncMutationVersionToken]? = nil
    ) throws -> SyncConflictInput {
        try SyncConflictInput(
            accountIDHash: accountIDHash ?? input.accountIDHash,
            failedAttemptID: input.failedAttemptID,
            failedMutation: failedMutation ?? input.failedMutation,
            failedVersion: failedVersion ?? input.failedVersion,
            serverRecord: serverRecord ?? input.serverRecord,
            expectedRecordQueue: expectedRecordQueue ?? input.expectedRecordQueue,
            expectedVersions: expectedVersions ?? input.expectedVersions
        )
    }

    @MainActor
    func replacements(for input: SyncConflictInput) throws -> [SyncMutation] {
        try input.expectedRecordQueue.map {
            try SyncMutation.save(
                recordVersion: SyncRecordVersion(record: input.serverRecord),
                mutationID: $0.mutationID
            )
        }
    }

    @MainActor
    func validTransition(_ input: SyncConflictInput) throws -> SyncJournalRebaseTransition {
        let beforeVersioned = try zip(
            input.expectedRecordQueue,
            input.expectedVersions
        ).map { try SyncVersionedMutation(mutation: $0.0, token: $0.1) }
        let after = try replacements(for: input)
        return try SyncJournalRebaseTransition(
            transactionID: UUID(),
            input: input,
            predecessorPendingSHA256: SyncConflictRebaseCoding.pendingDigest(beforeVersioned),
            recordPositions: Array(input.expectedRecordQueue.indices),
            before: input.expectedRecordQueue,
            after: after,
            beforeVersions: input.expectedVersions,
            afterVersions: try after.map {
                try SyncMutationVersionToken(mutation: $0, journalRevision: 1)
            }
        )
    }

    func mutationWithTamperedAttachmentByteCount(_ mutation: SyncMutation) throws -> SyncMutation {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(mutation)) as? [String: Any]
        )
        var save = try #require(object["save"] as? [String: Any])
        var value = try #require(save["_0"] as? [String: Any])
        var source = try #require(value["attachmentSource"] as? [String: Any])
        source["byteCount"] = (source["byteCount"] as? Int ?? 0) + 1
        value["attachmentSource"] = source
        save["_0"] = value
        object["save"] = save
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(SyncMutation.self, from: bytes)
    }
}
