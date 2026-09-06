import CryptoKit
import Foundation

public struct SyncMutationVersionToken: Codable, Equatable, Sendable {
    public let identity: SyncMutationIdentity
    public let contentSHA256: Data
    public let journalRevision: UInt64

    public init(mutation: SyncMutation, journalRevision: UInt64 = 0) throws {
        do {
            _ = try mutation.validated()
            identity = mutation.identity
            contentSHA256 = try SyncConflictRebaseCoding.mutationContentDigest(mutation)
            self.journalRevision = journalRevision
        } catch let error as SyncConflictError {
            throw error
        } catch {
            throw SyncConflictError.invalidInput
        }
    }

    private enum CodingKeys: String, CodingKey {
        case identity, contentSHA256, journalRevision
    }

    public init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identity = try container.decode(SyncMutationIdentity.self, forKey: .identity)
            contentSHA256 = try container.decode(Data.self, forKey: .contentSHA256)
            journalRevision = try container.decode(UInt64.self, forKey: .journalRevision)
            guard contentSHA256.count == SHA256.byteCount else {
                throw SyncConflictError.invalidInput
            }
        } catch let error as SyncConflictError {
            throw error
        } catch {
            throw SyncConflictError.invalidInput
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard contentSHA256.count == SHA256.byteCount else {
            throw SyncConflictError.invalidInput
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identity, forKey: .identity)
        try container.encode(contentSHA256, forKey: .contentSHA256)
        try container.encode(journalRevision, forKey: .journalRevision)
    }

    func validated(for mutation: SyncMutation) throws -> Self {
        guard self == (try SyncMutationVersionToken(
            mutation: mutation,
            journalRevision: journalRevision
        )) else {
            throw SyncConflictError.invalidInput
        }
        return self
    }
}

public struct SyncVersionedMutation: Codable, Equatable, Sendable {
    public let mutation: SyncMutation
    public let token: SyncMutationVersionToken

    public init(mutation: SyncMutation, journalRevision: UInt64) throws {
        self.mutation = mutation
        token = try SyncMutationVersionToken(
            mutation: mutation,
            journalRevision: journalRevision
        )
    }

    init(mutation: SyncMutation, token: SyncMutationVersionToken) throws {
        self.mutation = mutation
        self.token = try token.validated(for: mutation)
    }

    private enum CodingKeys: String, CodingKey {
        case mutation, token
    }

    public init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                mutation: container.decode(SyncMutation.self, forKey: .mutation),
                token: container.decode(SyncMutationVersionToken.self, forKey: .token)
            )
        } catch let error as SyncConflictError {
            throw error
        } catch {
            throw SyncConflictError.invalidInput
        }
    }

    public func encode(to encoder: any Encoder) throws {
        _ = try token.validated(for: mutation)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mutation, forKey: .mutation)
        try container.encode(token, forKey: .token)
    }
}

public struct SyncConflictInput: Codable, Equatable, Sendable {
    public let accountIDHash: String
    public let failedAttemptID: UUID
    public let failedMutation: SyncMutation
    public let failedVersion: SyncMutationVersionToken
    public let serverRecord: SyncRecord
    public let expectedRecordQueue: [SyncMutation]
    public let expectedVersions: [SyncMutationVersionToken]

    public init(
        accountIDHash: String,
        failedAttemptID: UUID,
        failedMutation: SyncMutation,
        failedVersion: SyncMutationVersionToken,
        serverRecord: SyncRecord,
        expectedRecordQueue: [SyncMutation],
        expectedVersions: [SyncMutationVersionToken]
    ) throws {
        self.accountIDHash = accountIDHash
        self.failedAttemptID = failedAttemptID
        self.failedMutation = failedMutation
        self.failedVersion = failedVersion
        self.serverRecord = serverRecord
        self.expectedRecordQueue = expectedRecordQueue
        self.expectedVersions = expectedVersions
        _ = try validated()
        try requireEncodedCapacity()
    }

    private enum CodingKeys: String, CodingKey {
        case accountIDHash, failedAttemptID, failedMutation, failedVersion
        case serverRecord, expectedRecordQueue, expectedVersions
    }

    public init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                accountIDHash: container.decode(String.self, forKey: .accountIDHash),
                failedAttemptID: container.decode(UUID.self, forKey: .failedAttemptID),
                failedMutation: container.decode(SyncMutation.self, forKey: .failedMutation),
                failedVersion: container.decode(
                    SyncMutationVersionToken.self,
                    forKey: .failedVersion
                ),
                serverRecord: container.decode(SyncRecord.self, forKey: .serverRecord),
                expectedRecordQueue: container.decode(
                    [SyncMutation].self,
                    forKey: .expectedRecordQueue
                ),
                expectedVersions: container.decode(
                    [SyncMutationVersionToken].self,
                    forKey: .expectedVersions
                )
            )
        } catch let error as SyncConflictError {
            throw error
        } catch {
            throw SyncConflictError.invalidInput
        }
    }

    public func encode(to encoder: any Encoder) throws {
        _ = try validated()
        try requireEncodedCapacity()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountIDHash, forKey: .accountIDHash)
        try container.encode(failedAttemptID, forKey: .failedAttemptID)
        try container.encode(failedMutation, forKey: .failedMutation)
        try container.encode(failedVersion, forKey: .failedVersion)
        try container.encode(serverRecord, forKey: .serverRecord)
        try container.encode(expectedRecordQueue, forKey: .expectedRecordQueue)
        try container.encode(expectedVersions, forKey: .expectedVersions)
    }

    func validated() throws -> Self {
        guard SyncConflictRebaseCoding.isAccountIDHash(accountIDHash),
              !expectedRecordQueue.isEmpty,
              expectedRecordQueue.count == expectedVersions.count,
              Set(expectedRecordQueue.map(\.mutationID)).count
                  == expectedRecordQueue.count,
              Set(expectedRecordQueue.map(\.recordID)).count == 1,
              let head = expectedRecordQueue.first,
              head.identity == failedMutation.identity,
              serverRecord.id == head.recordID else {
            throw SyncConflictError.invalidInput
        }
        do {
            _ = try failedMutation.validated()
            _ = try failedVersion.validated(for: failedMutation)
            _ = try SyncRecordValidator().validate(serverRecord)
            for (mutation, version) in zip(expectedRecordQueue, expectedVersions) {
                _ = try mutation.validated()
                _ = try version.validated(for: mutation)
            }
        } catch {
            throw SyncConflictError.invalidInput
        }
        return self
    }

    private func requireEncodedCapacity() throws {
        let wire = Wire(
            accountIDHash: accountIDHash,
            failedAttemptID: failedAttemptID,
            failedMutation: failedMutation,
            failedVersion: failedVersion,
            serverRecord: serverRecord,
            expectedRecordQueue: expectedRecordQueue,
            expectedVersions: expectedVersions
        )
        guard (try SyncConflictRebaseCoding.encoder().encode(wire)).count
                <= SyncCanonicalCheckpoint.maximumBytes else {
            throw SyncConflictError.capacity
        }
    }

    private struct Wire: Codable {
        let accountIDHash: String
        let failedAttemptID: UUID
        let failedMutation: SyncMutation
        let failedVersion: SyncMutationVersionToken
        let serverRecord: SyncRecord
        let expectedRecordQueue: [SyncMutation]
        let expectedVersions: [SyncMutationVersionToken]
    }
}

public struct SyncConflictPreparation: Sendable {
    let liveRoot: URL
    let input: SyncConflictInput
    let predecessor: SyncCanonicalCheckpoint
    let authority: [SyncRemoteAuthorityFile]
    let pending: [SyncVersionedMutation]
    let rebaseHistoryHeadSHA256: Data
    let watchContext: SyncCounterReminderMergeContext
    let transaction: SyncPublicationTransaction?
    let previousResolution: SyncConflictResolution?
}

public struct SyncConflictResolution: Codable, Equatable, Sendable {
    public let transactionID: UUID
    public let input: SyncConflictInput
    public let replacement: SyncMutation
    public let followingReplacements: [SyncMutation]
    public let versions: [SyncMutationVersionToken]

    init(
        transactionID: UUID,
        input: SyncConflictInput,
        replacement: SyncMutation,
        followingReplacements: [SyncMutation],
        versions: [SyncMutationVersionToken]
    ) throws {
        self.transactionID = transactionID
        self.input = input
        self.replacement = replacement
        self.followingReplacements = followingReplacements
        self.versions = versions
        _ = try validated()
    }

    private enum CodingKeys: String, CodingKey {
        case transactionID, input, replacement, followingReplacements, versions
    }

    public init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                transactionID: container.decode(UUID.self, forKey: .transactionID),
                input: container.decode(SyncConflictInput.self, forKey: .input),
                replacement: container.decode(SyncMutation.self, forKey: .replacement),
                followingReplacements: container.decode(
                    [SyncMutation].self,
                    forKey: .followingReplacements
                ),
                versions: container.decode(
                    [SyncMutationVersionToken].self,
                    forKey: .versions
                )
            )
        } catch let error as SyncConflictError {
            throw error
        } catch {
            throw SyncConflictError.invalidInput
        }
    }

    public func encode(to encoder: any Encoder) throws {
        _ = try validated()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transactionID, forKey: .transactionID)
        try container.encode(input, forKey: .input)
        try container.encode(replacement, forKey: .replacement)
        try container.encode(followingReplacements, forKey: .followingReplacements)
        try container.encode(versions, forKey: .versions)
    }

    func validated() throws -> Self {
        _ = try input.validated()
        let replacements = [replacement] + followingReplacements
        guard replacements.count == input.expectedRecordQueue.count,
              versions.count == replacements.count,
              replacements.map(\.identity)
                  == input.expectedRecordQueue.map(\.identity),
              replacements.map(\.intent)
                  == input.expectedRecordQueue.map(\.intent) else {
            throw SyncConflictError.invalidInput
        }
        for index in replacements.indices {
            let beforeRevision = input.expectedVersions[index].journalRevision
            guard beforeRevision < UInt64.max,
                  versions[index] == (try SyncMutationVersionToken(
                    mutation: replacements[index],
                    journalRevision: beforeRevision + 1
                  )) else {
                throw SyncConflictError.invalidInput
            }
        }
        return self
    }
}

public enum SyncConflictCommitResult: Equatable, Sendable {
    case committed(SyncConflictResolution)
    case stalePredecessor
    case obsoleteFailure
}

public enum SyncConflictError: Error, Equatable, Sendable {
    case invalidInput
    case missingAuthority
    case identityCollision
    case capacity
}

public enum SyncVersionedAcknowledgementResult: Equatable, Sendable {
    case acknowledged
    case alreadyAcknowledged
    case staleVersion
}

struct SyncConflictPublicationSource: Codable, Equatable, Sendable {
    private static let currentVersion = 1

    let version: Int
    let input: SyncConflictInput
    let transition: SyncJournalRebaseTransition
    let plan: SyncRemoteBatchDurablePlan
    let beforePending: [SyncMutation]
    let afterPending: [SyncMutation]
    let beforeVersions: [SyncMutationVersionToken]
    let afterVersions: [SyncMutationVersionToken]

    init(
        version: Int = Self.currentVersion,
        input: SyncConflictInput,
        transition: SyncJournalRebaseTransition,
        plan: SyncRemoteBatchDurablePlan,
        beforePending: [SyncMutation],
        afterPending: [SyncMutation],
        beforeVersions: [SyncMutationVersionToken],
        afterVersions: [SyncMutationVersionToken]
    ) throws {
        self.version = version
        self.input = input
        self.transition = transition
        self.plan = plan
        self.beforePending = beforePending
        self.afterPending = afterPending
        self.beforeVersions = beforeVersions
        self.afterVersions = afterVersions
        _ = try validated()
    }

    func validated() throws -> Self {
        do {
            guard version == Self.currentVersion,
                  transition.input == input,
                  transition.before == input.expectedRecordQueue,
                  beforePending.count == afterPending.count,
                  beforePending.count == beforeVersions.count,
                  afterPending.count == afterVersions.count,
                  plan.pending == beforePending,
                  plan.records == [input.serverRecord],
                  plan.deletedRecordIDs.isEmpty,
                  plan.journalURL.isFileURL,
                  !plan.journalURL.path.isEmpty,
                  plan.archive.count <= SyncCanonicalCheckpoint.maximumBytes,
                  plan.predecessorEvidence.count <= SyncCanonicalCheckpoint.maximumBytes,
                  transition.recordPositions.allSatisfy(beforePending.indices.contains),
                  transition.recordPositions.map({ beforePending[$0] }) == transition.before,
                  transition.recordPositions.map({ afterPending[$0] }) == transition.after,
                  transition.recordPositions.map({ beforeVersions[$0] })
                    == transition.beforeVersions,
                  transition.recordPositions.map({ afterVersions[$0] })
                    == transition.afterVersions,
                  beforePending.indices.filter({
                      beforePending[$0].recordID == input.serverRecord.id
                  }) == transition.recordPositions else {
                throw SyncPublicationError.corruptTransaction
            }
            _ = try input.validated()
            _ = try transition.validated()

            let beforeVersioned = try zip(beforePending, beforeVersions).map {
                try SyncVersionedMutation(mutation: $0.0, token: $0.1)
            }
            let afterVersioned = try zip(afterPending, afterVersions).map {
                try SyncVersionedMutation(mutation: $0.0, token: $0.1)
            }
            guard transition.predecessorPendingSHA256
                    == (try SyncConflictRebaseCoding.pendingDigest(beforeVersioned)) else {
                throw SyncPublicationError.corruptTransaction
            }
            let selected = Set(transition.recordPositions)
            for index in beforePending.indices where !selected.contains(index) {
                guard beforeVersioned[index] == afterVersioned[index] else {
                    throw SyncPublicationError.corruptTransaction
                }
            }

            _ = try plan.predecessor.validated()
            _ = try SyncRecordValidator().validate(plan.records)
            _ = try JSONDecoder().decode(
                SyncAttachmentPublicationEvidence.self,
                from: plan.predecessorEvidence
            ).validated()
            guard !plan.authority.isEmpty,
                  Set(plan.authority.map(\.path)).count == plan.authority.count,
                  plan.authority.allSatisfy({
                      !$0.path.isEmpty && $0.device > 0 && $0.inode > 0 && $0.bytes >= 0
                        && (($0.bytes == 0 && $0.digest.isEmpty)
                            || $0.digest.count == SHA256.byteCount)
                  }),
                  plan.authority.contains(where: {
                      $0.digest == plan.predecessor.archiveSHA256
                  }),
                  Set(plan.files.map(\.relativePath)).count == plan.files.count,
                  Set(plan.files.map(\.version.versionID)).count == plan.files.count else {
                throw SyncPublicationError.corruptTransaction
            }
            for file in plan.files {
                _ = try file.version.validated()
                _ = try SyncPublicationArtifactEvidence(
                    relativePath: file.relativePath,
                    expectedSHA256: file.version.contentSHA256
                )
                guard file.data.count <= SyncCanonicalCheckpoint.maximumBytes,
                      Int64(file.data.count) == file.version.byteCount,
                      Data(SHA256.hash(data: file.data)) == file.version.contentSHA256 else {
                    throw SyncPublicationError.corruptTransaction
                }
            }
            for marker in plan.deletionMarkers {
                _ = try marker.validated()
            }
            return self
        } catch let error as SyncPublicationError {
            throw error
        } catch {
            throw SyncPublicationError.corruptTransaction
        }
    }
}

struct SyncJournalRebaseTransition: Codable, Equatable, Sendable {
    private static let currentVersion = 1

    let version: Int
    let transactionID: UUID
    let input: SyncConflictInput
    let predecessorPendingSHA256: Data
    let predecessorRebaseHeadSHA256: Data
    let recordPositions: [Int]
    let before: [SyncMutation]
    let after: [SyncMutation]
    let beforeVersions: [SyncMutationVersionToken]
    let afterVersions: [SyncMutationVersionToken]
    let integrity: Data

    init(
        transactionID: UUID,
        input: SyncConflictInput,
        predecessorPendingSHA256: Data,
        predecessorRebaseHeadSHA256: Data = SyncConflictRebaseCoding.emptyRebaseHistoryHeadSHA256,
        recordPositions: [Int],
        before: [SyncMutation],
        after: [SyncMutation],
        beforeVersions: [SyncMutationVersionToken],
        afterVersions: [SyncMutationVersionToken]
    ) throws {
        version = Self.currentVersion
        self.transactionID = transactionID
        self.input = input
        self.predecessorPendingSHA256 = predecessorPendingSHA256
        self.predecessorRebaseHeadSHA256 = predecessorRebaseHeadSHA256
        self.recordPositions = recordPositions
        self.before = before
        self.after = after
        self.beforeVersions = beforeVersions
        self.afterVersions = afterVersions
        integrity = try Self.digest(
            version: version,
            transactionID: transactionID,
            input: input,
            predecessorPendingSHA256: predecessorPendingSHA256,
            predecessorRebaseHeadSHA256: predecessorRebaseHeadSHA256,
            recordPositions: recordPositions,
            before: before,
            after: after,
            beforeVersions: beforeVersions,
            afterVersions: afterVersions
        )
        _ = try validated()
        try requireEncodedCapacity()
    }

    private enum CodingKeys: String, CodingKey {
        case version, transactionID, input, predecessorPendingSHA256, predecessorRebaseHeadSHA256
        case recordPositions, before, after, beforeVersions, afterVersions, integrity
    }

    init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            transactionID = try container.decode(UUID.self, forKey: .transactionID)
            input = try container.decode(SyncConflictInput.self, forKey: .input)
            predecessorPendingSHA256 = try container.decode(
                Data.self,
                forKey: .predecessorPendingSHA256
            )
            predecessorRebaseHeadSHA256 = try container.decode(Data.self, forKey: .predecessorRebaseHeadSHA256)
            recordPositions = try container.decode([Int].self, forKey: .recordPositions)
            before = try container.decode([SyncMutation].self, forKey: .before)
            after = try container.decode([SyncMutation].self, forKey: .after)
            beforeVersions = try container.decode(
                [SyncMutationVersionToken].self,
                forKey: .beforeVersions
            )
            afterVersions = try container.decode(
                [SyncMutationVersionToken].self,
                forKey: .afterVersions
            )
            integrity = try container.decode(Data.self, forKey: .integrity)
            _ = try validated()
            guard integrity == (try Self.digest(
                version: version,
                transactionID: transactionID,
                input: input,
                predecessorPendingSHA256: predecessorPendingSHA256,
                predecessorRebaseHeadSHA256: predecessorRebaseHeadSHA256,
                recordPositions: recordPositions,
                before: before,
                after: after,
                beforeVersions: beforeVersions,
                afterVersions: afterVersions
            )) else {
                throw SyncConflictError.invalidInput
            }
            try requireEncodedCapacity()
        } catch let error as SyncConflictError {
            throw error
        } catch {
            throw SyncConflictError.invalidInput
        }
    }

    func encode(to encoder: any Encoder) throws {
        _ = try validated()
        guard integrity == (try Self.digest(
            version: version,
            transactionID: transactionID,
            input: input,
            predecessorPendingSHA256: predecessorPendingSHA256,
            predecessorRebaseHeadSHA256: predecessorRebaseHeadSHA256,
            recordPositions: recordPositions,
            before: before,
            after: after,
            beforeVersions: beforeVersions,
            afterVersions: afterVersions
        )) else {
            throw SyncConflictError.invalidInput
        }
        try requireEncodedCapacity()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(transactionID, forKey: .transactionID)
        try container.encode(input, forKey: .input)
        try container.encode(predecessorPendingSHA256, forKey: .predecessorPendingSHA256)
        try container.encode(predecessorRebaseHeadSHA256, forKey: .predecessorRebaseHeadSHA256)
        try container.encode(recordPositions, forKey: .recordPositions)
        try container.encode(before, forKey: .before)
        try container.encode(after, forKey: .after)
        try container.encode(beforeVersions, forKey: .beforeVersions)
        try container.encode(afterVersions, forKey: .afterVersions)
        try container.encode(integrity, forKey: .integrity)
    }

    func validated() throws -> Self {
        guard version == Self.currentVersion,
              predecessorPendingSHA256.count == SHA256.byteCount,
              predecessorRebaseHeadSHA256.count == SHA256.byteCount else {
            throw SyncConflictError.invalidInput
        }
        _ = try input.validated()

        guard !before.isEmpty, before == input.expectedRecordQueue,
              before.map(\.identity) == after.map(\.identity),
              before.map(\.intent) == after.map(\.intent),
              recordPositions.count == before.count,
              recordPositions == recordPositions.sorted(),
              Set(recordPositions).count == recordPositions.count,
              recordPositions.allSatisfy({ $0 >= 0 }) else {
            throw SyncConflictError.invalidInput
        }
        guard beforeVersions == input.expectedVersions,
              beforeVersions.count == before.count,
              afterVersions.count == after.count else {
            throw SyncConflictError.invalidInput
        }

        for index in before.indices {
            _ = try beforeVersions[index].validated(for: before[index])
            let revision = beforeVersions[index].journalRevision
            guard revision < UInt64.max,
                  afterVersions[index] == (try SyncMutationVersionToken(
                    mutation: after[index],
                    journalRevision: revision + 1
                  )) else {
                throw SyncConflictError.invalidInput
            }
        }
        return self
    }

    private func requireEncodedCapacity() throws {
        let wire = Wire(
            version: version,
            transactionID: transactionID,
            input: input,
            predecessorPendingSHA256: predecessorPendingSHA256,
            predecessorRebaseHeadSHA256: predecessorRebaseHeadSHA256,
            recordPositions: recordPositions,
            before: before,
            after: after,
            beforeVersions: beforeVersions,
            afterVersions: afterVersions,
            integrity: integrity
        )
        guard (try SyncConflictRebaseCoding.encoder().encode(wire)).count
                <= FileSyncMutationJournal.maximumEncodedBytes else {
            throw SyncConflictError.capacity
        }
    }

    private static func digest(
        version: Int,
        transactionID: UUID,
        input: SyncConflictInput,
        predecessorPendingSHA256: Data,
        predecessorRebaseHeadSHA256: Data,
        recordPositions: [Int],
        before: [SyncMutation],
        after: [SyncMutation],
        beforeVersions: [SyncMutationVersionToken],
        afterVersions: [SyncMutationVersionToken]
    ) throws -> Data {
        let material = IntegrityMaterial(
            version: version,
            transactionID: transactionID,
            input: input,
            predecessorPendingSHA256: predecessorPendingSHA256,
            predecessorRebaseHeadSHA256: predecessorRebaseHeadSHA256,
            recordPositions: recordPositions,
            before: before,
            after: after,
            beforeVersions: beforeVersions,
            afterVersions: afterVersions
        )
        return Data(SHA256.hash(
            data: try SyncConflictRebaseCoding.encoder().encode(material)
        ))
    }

    private struct IntegrityMaterial: Codable {
        let version: Int
        let transactionID: UUID
        let input: SyncConflictInput
        let predecessorPendingSHA256: Data
        let predecessorRebaseHeadSHA256: Data
        let recordPositions: [Int]
        let before: [SyncMutation]
        let after: [SyncMutation]
        let beforeVersions: [SyncMutationVersionToken]
        let afterVersions: [SyncMutationVersionToken]
    }

    private struct Wire: Codable {
        let version: Int
        let transactionID: UUID
        let input: SyncConflictInput
        let predecessorPendingSHA256: Data
        let predecessorRebaseHeadSHA256: Data
        let recordPositions: [Int]
        let before: [SyncMutation]
        let after: [SyncMutation]
        let beforeVersions: [SyncMutationVersionToken]
        let afterVersions: [SyncMutationVersionToken]
        let integrity: Data
    }
}

enum SyncConflictRebaseCoding {
    static let emptyRebaseHistoryHeadSHA256 = Data(SHA256.hash(
        data: Data("KnitNote.SyncMutationJournal.RebaseHistory.v1".utf8)))

    private struct MutationContent: Codable {
        let version: Int
        let identity: SyncMutationIdentity
        let intent: SyncMutationIntent
        let savedRecordVersion: SyncRecordVersion?
        let attachmentByteCount: Int64?
        let attachmentContentSHA256: Data?
    }

    static func mutationContentDigest(_ mutation: SyncMutation) throws -> Data {
        let material = MutationContent(
            version: 1,
            identity: mutation.identity,
            intent: mutation.intent,
            savedRecordVersion: mutation.savedRecordVersion,
            attachmentByteCount: mutation.attachmentSource?.byteCount,
            attachmentContentSHA256: mutation.attachmentSource?.contentSHA256
        )
        return Data(SHA256.hash(data: try encoder().encode(material)))
    }

    static func pendingDigest(_ mutations: [SyncVersionedMutation]) throws -> Data {
        do {
            for mutation in mutations {
                _ = try mutation.token.validated(for: mutation.mutation)
            }
            let bytes = try encoder().encode(mutations)
            guard bytes.count <= SyncCanonicalCheckpoint.maximumBytes else {
                throw SyncConflictError.capacity
            }
            return Data(SHA256.hash(data: bytes))
        } catch let error as SyncConflictError {
            throw error
        } catch {
            throw SyncConflictError.invalidInput
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func isAccountIDHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
