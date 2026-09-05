import CryptoKit
import Darwin
import Foundation

public protocol SyncMutationSink: Sendable {
    func publish(_ mutation: SyncMutation) throws
    func publish(_ mutations: [SyncMutation]) throws
}

public protocol SyncRecordProvider: Sendable {
    func record(for id: SyncEntityID) throws -> SyncRecord?
}

public extension SyncMutationSink {
    func publish(_ mutations: [SyncMutation]) throws {
        for mutation in mutations {
            try publish(mutation)
        }
    }
}

public struct DisabledSyncMutationSink: SyncMutationSink {
    public init() {}

    public func publish(_ mutation: SyncMutation) throws {}

    public func publish(_ mutations: [SyncMutation]) throws {}
}

public struct JournalSyncMutationSink: SyncMutationSink {
    private let journal: any SyncMutationJournalProtocol

    public init(journal: any SyncMutationJournalProtocol) {
        self.journal = journal
    }

    public func publish(_ mutation: SyncMutation) throws {
        try journal.enqueue(mutation)
    }

    public func publish(_ mutations: [SyncMutation]) throws {
        try journal.enqueue(mutations)
    }

    func withExclusivePending<T>(_ body: (SyncJournalWriteLease) throws -> T) throws -> T {
        guard let fileJournal = journal as? FileSyncMutationJournal else {
            throw SyncRemoteBatchError.missingAuthority
        }
        return try fileJournal.withExclusivePending(body)
    }

    /// Activation checks pending upload bytes independently from displayed
    /// media. Acknowledged history remains owned by the journal's cleanup rules.
    func validatePendingAttachmentSources(validateOwnership: () throws -> Void) throws {
        try validateOwnership()
        for mutation in try journal.pending() {
            guard case let .save(save) = mutation, let source = save.attachmentSource else { continue }
            try validateOwnership()
            _ = try SyncRegularFileReader().read(source.fileURL, maximumBytes: 100_000_000,
                expected: .init(byteCount: source.byteCount, sha256: source.contentSHA256))
        }
        try validateOwnership()
    }
}

public enum SyncPublicationError: Error, Equatable, Sendable {
    case pendingRepair
    case corruptTransaction
    case transactionUnavailable
    case sinkUnavailable
}

enum SyncPublicationCommitBoundary: String, Codable, Equatable, Sendable {
    case archive
    case artifacts
}

struct SyncPublicationArtifactEvidence: Codable, Equatable, Sendable {
    let relativePath: String
    let expectedSHA256: Data?

    init(relativePath: String, expectedSHA256: Data?) throws {
        self.relativePath = relativePath
        self.expectedSHA256 = expectedSHA256
        try validate()
    }

    func validated() throws -> Self {
        try validate()
        return self
    }

    private func validate() throws {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              relativePath.utf8.count <= 1_024,
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              expectedSHA256 == nil || expectedSHA256?.count == SHA256.byteCount else {
            throw SyncPublicationTransactionFileError.corrupt
        }
    }
}

struct SyncRestorationWitness: Codable, Equatable, Sendable {
    let entryID: UUID
    let attemptID: UUID
    let beforeArchiveSHA256: Data
}

struct SyncCanonicalTransition: Codable, Equatable, Sendable {
    let predecessorSHA256: Data?
    let candidate: SyncCanonicalCheckpoint

    init(
        predecessorSHA256: Data?,
        candidate: SyncCanonicalCheckpoint
    ) throws {
        self.predecessorSHA256 = predecessorSHA256
        self.candidate = candidate
        _ = try validated()
    }

    func validated() throws -> Self {
        guard predecessorSHA256 == nil
                || predecessorSHA256?.count == SHA256.byteCount else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        _ = try candidate.validated()
        _ = try candidate.encoded()
        return self
    }
}

struct SyncPublicationTransaction: Codable, Equatable, Sendable {
    static let currentVersion = 6
    private static let canonicalTransitionVersion = 5
    private static let attachmentManifestVersion = 4
    private static let causalReceiptVersion = 3
    private static let legacyVersion = 2

    let version: Int
    let expectedArchiveSHA256: Data
    let commitBoundary: SyncPublicationCommitBoundary
    let artifactEvidence: [SyncPublicationArtifactEvidence]
    let mutations: [SyncMutation]
    let revisionReceipts: [SyncRevisionReceipt]
    let candidateAttachmentManifest: [SyncAttachmentManifestEntry]?
    let deletionLedgerID: UUID?
    let restorationWitness: SyncRestorationWitness?
    let canonicalTransition: SyncCanonicalTransition?
    let remoteSource: SyncRemoteBatchPublicationSource?
    let integrity: Data

    private enum CodingKeys: String, CodingKey {
        case version
        case expectedArchiveSHA256
        case commitBoundary
        case artifactEvidence
        case mutations
        case revisionReceipts
        case candidateAttachmentManifest
        case deletionLedgerID
        case restorationWitness
        case canonicalTransition
        case remoteSource
        case integrity
    }

    init(
        expectedArchiveSHA256: Data,
        mutations: [SyncMutation],
        commitBoundary: SyncPublicationCommitBoundary = .archive,
        artifactEvidence: [SyncPublicationArtifactEvidence] = [],
        revisionReceipts: [SyncRevisionReceipt],
        candidateAttachmentManifest: [SyncAttachmentManifestEntry]? = nil,
        deletionLedgerID: UUID? = nil,
        restorationWitness: SyncRestorationWitness? = nil,
        canonicalTransition: SyncCanonicalTransition? = nil,
        remoteSource: SyncRemoteBatchPublicationSource? = nil
    ) throws {
        try self.init(
            version: Self.currentVersion,
            expectedArchiveSHA256: expectedArchiveSHA256,
            mutations: mutations,
            commitBoundary: commitBoundary,
            artifactEvidence: artifactEvidence,
            revisionReceipts: revisionReceipts,
            candidateAttachmentManifest: candidateAttachmentManifest,
            deletionLedgerID: deletionLedgerID,
            restorationWitness: restorationWitness,
            canonicalTransition: canonicalTransition,
            remoteSource: remoteSource
        )
        _ = try validated()
    }

    static func legacy(
        expectedArchiveSHA256: Data,
        mutations: [SyncMutation],
        commitBoundary: SyncPublicationCommitBoundary = .archive,
        artifactEvidence: [SyncPublicationArtifactEvidence] = []
    ) throws -> Self {
        let transaction = try Self(
            version: Self.legacyVersion,
            expectedArchiveSHA256: expectedArchiveSHA256,
            mutations: mutations,
            commitBoundary: commitBoundary,
            artifactEvidence: artifactEvidence,
            revisionReceipts: [],
            candidateAttachmentManifest: nil
        )
        return try transaction.validated()
    }

    private init(
        version: Int,
        expectedArchiveSHA256: Data,
        mutations: [SyncMutation],
        commitBoundary: SyncPublicationCommitBoundary,
        artifactEvidence: [SyncPublicationArtifactEvidence],
        revisionReceipts: [SyncRevisionReceipt],
        candidateAttachmentManifest: [SyncAttachmentManifestEntry]?,
        deletionLedgerID: UUID? = nil,
        restorationWitness: SyncRestorationWitness? = nil,
        canonicalTransition: SyncCanonicalTransition? = nil,
        remoteSource: SyncRemoteBatchPublicationSource? = nil
    ) throws {
        self.version = version
        self.deletionLedgerID = deletionLedgerID
        self.restorationWitness = restorationWitness
        self.canonicalTransition = canonicalTransition
        self.remoteSource = remoteSource
        self.expectedArchiveSHA256 = expectedArchiveSHA256
        self.commitBoundary = commitBoundary
        self.artifactEvidence = artifactEvidence.sorted {
            $0.relativePath < $1.relativePath
        }
        self.mutations = mutations
        self.revisionReceipts = revisionReceipts
        self.candidateAttachmentManifest = try candidateAttachmentManifest.map {
            try SyncAttachmentManifestStore.orderedEntries(
                SyncAttachmentManifestStore.dictionary(from: $0)
            )
        }
        integrity = try Self.integrity(
            version: version,
            expectedArchiveSHA256: expectedArchiveSHA256,
            commitBoundary: commitBoundary,
            artifactEvidence: self.artifactEvidence,
            mutations: mutations,
            revisionReceipts: revisionReceipts,
            candidateAttachmentManifest: self.candidateAttachmentManifest,
            deletionLedgerID: deletionLedgerID,
            restorationWitness: restorationWitness,
            canonicalTransition: canonicalTransition,
            remoteSource: remoteSource
        )
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        expectedArchiveSHA256 = try values.decode(Data.self, forKey: .expectedArchiveSHA256)
        commitBoundary = try values.decode(
            SyncPublicationCommitBoundary.self,
            forKey: .commitBoundary
        )
        artifactEvidence = try values.decode(
            [SyncPublicationArtifactEvidence].self,
            forKey: .artifactEvidence
        )
        mutations = try values.decode([SyncMutation].self, forKey: .mutations)
        revisionReceipts = try values.decodeIfPresent(
            [SyncRevisionReceipt].self,
            forKey: .revisionReceipts
        ) ?? []
        candidateAttachmentManifest = try values.decodeIfPresent(
            [SyncAttachmentManifestEntry].self,
            forKey: .candidateAttachmentManifest
        )
        integrity = try values.decode(Data.self, forKey: .integrity)
        deletionLedgerID = try values.decodeIfPresent(UUID.self, forKey: .deletionLedgerID)
        restorationWitness = try values.decodeIfPresent(SyncRestorationWitness.self, forKey: .restorationWitness)
        canonicalTransition = try values.decodeIfPresent(
            SyncCanonicalTransition.self,
            forKey: .canonicalTransition
        )
        remoteSource = try values.decodeIfPresent(
            SyncRemoteBatchPublicationSource.self,
            forKey: .remoteSource
        )
    }

    func validated() throws -> Self {
        let validatedEvidence = try artifactEvidence.map { try $0.validated() }
        let validatedManifest = try candidateAttachmentManifest.map {
            try SyncAttachmentManifestStore.orderedEntries(
                SyncAttachmentManifestStore.dictionary(from: $0)
            )
        }
        let validatedCanonicalTransition = try canonicalTransition.map {
            try $0.validated()
        }
        let validatedRemoteSource = try remoteSource.map { try $0.validated() }
        let supportsAttachmentAuthorities = version == Self.attachmentManifestVersion
            || version == Self.canonicalTransitionVersion
            || version == Self.currentVersion
        let supportsCanonicalTransition = version == Self.canonicalTransitionVersion
            || version == Self.currentVersion
        let receiptsAreComplete = revisionReceipts.count == mutations.count
            && Set(revisionReceipts.map(\.mutationID)).count == revisionReceipts.count
            && Set(revisionReceipts.map(\.deviceID)).count <= 1
            && revisionReceipts.allSatisfy { !$0.deviceID.isEmpty }
            // One canonical mutation per entity is the publication contract;
            // accepting two receipts for one entity would make replay order an
            // undeclared second merge authority.
            && Set(revisionReceipts.map(\.entityID)).count == revisionReceipts.count
            && Set(revisionReceipts.map(\.mutationID)) == Set(mutations.map(\.mutationID))
            && revisionReceipts.allSatisfy { receipt in
                receipt.logicalRevision > 0 && mutations.contains {
                    $0.mutationID == receipt.mutationID && $0.recordID == receipt.entityID
                }
            }
        guard [
                Self.legacyVersion,
                Self.causalReceiptVersion,
                Self.attachmentManifestVersion,
                Self.canonicalTransitionVersion,
                Self.currentVersion
              ].contains(version),
              expectedArchiveSHA256.count == SHA256.byteCount,
              !mutations.isEmpty
                || (supportsAttachmentAuthorities && validatedManifest != nil)
                || (supportsCanonicalTransition && validatedCanonicalTransition != nil),
              version != Self.legacyVersion || revisionReceipts.isEmpty,
              version != Self.legacyVersion || candidateAttachmentManifest == nil,
              version != Self.causalReceiptVersion || candidateAttachmentManifest == nil,
              canonicalTransition == nil || supportsCanonicalTransition,
              canonicalTransition == validatedCanonicalTransition,
              canonicalTransition == nil
                || canonicalTransition?.candidate.archiveSHA256 == expectedArchiveSHA256,
              deletionLedgerID == nil || supportsAttachmentAuthorities,
              restorationWitness == nil || (supportsAttachmentAuthorities && deletionLedgerID == nil
                  && restorationWitness?.beforeArchiveSHA256.count == 32),
              remoteSource == nil || version == Self.currentVersion,
              remoteSource == validatedRemoteSource,
              try Self.remoteSourceIsValid(
                  remoteSource,
                  transition: validatedCanonicalTransition
              ),
              artifactEvidence == artifactEvidence.sorted(by: {
                  $0.relativePath < $1.relativePath
              }),
              Set(validatedEvidence.map(\.relativePath)).count == validatedEvidence.count,
              commitBoundary != .artifacts || !artifactEvidence.isEmpty,
              version == Self.legacyVersion
                || (remoteSource != nil ? revisionReceipts.isEmpty : receiptsAreComplete),
              candidateAttachmentManifest == validatedManifest,
              integrity == (try Self.integrity(
                  version: version,
                  expectedArchiveSHA256: expectedArchiveSHA256,
                  commitBoundary: commitBoundary,
                  artifactEvidence: artifactEvidence,
                  mutations: mutations,
                  revisionReceipts: revisionReceipts,
                  candidateAttachmentManifest: candidateAttachmentManifest,
                  deletionLedgerID: deletionLedgerID,
                  restorationWitness: restorationWitness,
                  canonicalTransition: canonicalTransition,
                  remoteSource: remoteSource
              )) else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        return self
    }

    private static func remoteSourceIsValid(
        _ source: SyncRemoteBatchPublicationSource?,
        transition: SyncCanonicalTransition?
    ) throws -> Bool {
        guard let source else { return true }
        guard let transition,
              let predecessorSHA256 = transition.predecessorSHA256,
              predecessorSHA256 == source.predecessor.checkpointSHA256,
              source.identity.accountIDHash == transition.candidate.accountIDHash,
              source.predecessor.accountIDHash == transition.candidate.accountIDHash,
              source.predecessor.commitID != transition.candidate.commitID,
              transition.candidate.formatVersion == 2 else {
            return false
        }
        let matching = transition.candidate.remoteBatchReceipts.first {
            $0.identity.accountIDHash == source.identity.accountIDHash
                && $0.identity.batchID == source.identity.batchID
        }
        switch source.receiptAction {
        case .insert:
            return matching?.identity == source.identity
                && matching?.commitID == transition.candidate.commitID
        case .retire:
            return matching == nil
        }
    }

    private static func integrity(
        version: Int,
        expectedArchiveSHA256: Data,
        commitBoundary: SyncPublicationCommitBoundary,
        artifactEvidence: [SyncPublicationArtifactEvidence],
        mutations: [SyncMutation],
        revisionReceipts: [SyncRevisionReceipt],
        candidateAttachmentManifest: [SyncAttachmentManifestEntry]?,
        deletionLedgerID: UUID?,
        restorationWitness: SyncRestorationWitness?,
        canonicalTransition: SyncCanonicalTransition?,
        remoteSource: SyncRemoteBatchPublicationSource?
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if version == Self.legacyVersion {
            return Data(SHA256.hash(data: try encoder.encode(LegacyIntegrityPayload(
                version: version,
                expectedArchiveSHA256: expectedArchiveSHA256,
                commitBoundary: commitBoundary,
                artifactEvidence: artifactEvidence,
                mutations: mutations
            ))))
        }
        if version == Self.causalReceiptVersion {
            return Data(SHA256.hash(data: try encoder.encode(IntegrityPayload(
                version: version,
                expectedArchiveSHA256: expectedArchiveSHA256,
                commitBoundary: commitBoundary,
                artifactEvidence: artifactEvidence,
                mutations: mutations,
                revisionReceipts: revisionReceipts
            ))))
        }
        if version == Self.attachmentManifestVersion {
            return Data(SHA256.hash(data: try encoder.encode(VersionFourIntegrityPayload(
                version: version,
                expectedArchiveSHA256: expectedArchiveSHA256,
                commitBoundary: commitBoundary,
                artifactEvidence: artifactEvidence,
                mutations: mutations,
                revisionReceipts: revisionReceipts,
                candidateAttachmentManifest: candidateAttachmentManifest,
                deletionLedgerID: deletionLedgerID,
                restorationWitness: restorationWitness
            ))))
        }
        if version == Self.canonicalTransitionVersion {
            return Data(SHA256.hash(data: try encoder.encode(CanonicalIntegrityPayload(
                version: version,
                expectedArchiveSHA256: expectedArchiveSHA256,
                commitBoundary: commitBoundary,
                artifactEvidence: artifactEvidence,
                mutations: mutations,
                revisionReceipts: revisionReceipts,
                candidateAttachmentManifest: candidateAttachmentManifest,
                deletionLedgerID: deletionLedgerID,
                restorationWitness: restorationWitness,
                canonicalTransition: canonicalTransition
            ))))
        }
        return Data(SHA256.hash(data: try encoder.encode(RemoteCanonicalIntegrityPayload(
            version: version,
            expectedArchiveSHA256: expectedArchiveSHA256,
            commitBoundary: commitBoundary,
            artifactEvidence: artifactEvidence,
            mutations: mutations,
            revisionReceipts: revisionReceipts,
            candidateAttachmentManifest: candidateAttachmentManifest,
            deletionLedgerID: deletionLedgerID,
            restorationWitness: restorationWitness,
            canonicalTransition: canonicalTransition,
            remoteSource: remoteSource
        ))))
    }

    private struct IntegrityPayload: Codable {
        let version: Int
        let expectedArchiveSHA256: Data
        let commitBoundary: SyncPublicationCommitBoundary
        let artifactEvidence: [SyncPublicationArtifactEvidence]
        let mutations: [SyncMutation]
        let revisionReceipts: [SyncRevisionReceipt]
    }

    private struct LegacyIntegrityPayload: Codable {
        let version: Int
        let expectedArchiveSHA256: Data
        let commitBoundary: SyncPublicationCommitBoundary
        let artifactEvidence: [SyncPublicationArtifactEvidence]
        let mutations: [SyncMutation]
    }

    private struct VersionFourIntegrityPayload: Codable {
        let version: Int
        let expectedArchiveSHA256: Data
        let commitBoundary: SyncPublicationCommitBoundary
        let artifactEvidence: [SyncPublicationArtifactEvidence]
        let mutations: [SyncMutation]
        let revisionReceipts: [SyncRevisionReceipt]
        let candidateAttachmentManifest: [SyncAttachmentManifestEntry]?
        let deletionLedgerID: UUID?
        let restorationWitness: SyncRestorationWitness?
    }

    private struct CanonicalIntegrityPayload: Codable {
        let version: Int
        let expectedArchiveSHA256: Data
        let commitBoundary: SyncPublicationCommitBoundary
        let artifactEvidence: [SyncPublicationArtifactEvidence]
        let mutations: [SyncMutation]
        let revisionReceipts: [SyncRevisionReceipt]
        let candidateAttachmentManifest: [SyncAttachmentManifestEntry]?
        let deletionLedgerID: UUID?
        let restorationWitness: SyncRestorationWitness?
        let canonicalTransition: SyncCanonicalTransition?
    }

    private struct RemoteCanonicalIntegrityPayload: Codable {
        let version: Int
        let expectedArchiveSHA256: Data
        let commitBoundary: SyncPublicationCommitBoundary
        let artifactEvidence: [SyncPublicationArtifactEvidence]
        let mutations: [SyncMutation]
        let revisionReceipts: [SyncRevisionReceipt]
        let candidateAttachmentManifest: [SyncAttachmentManifestEntry]?
        let deletionLedgerID: UUID?
        let restorationWitness: SyncRestorationWitness?
        let canonicalTransition: SyncCanonicalTransition?
        let remoteSource: SyncRemoteBatchPublicationSource?
    }
}

enum SyncPublicationCommitStatus: Equatable {
    case committed
    case uncommitted
    case corrupt
}

enum SyncPublicationTransactionFileError: Error {
    case corrupt
    case unsafeFile
    case unavailable
}

struct SyncPublicationTransactionFile {
    private static let maximumEncodedBytes = 100_000_000
    let url: URL

    init(archiveURL: URL) {
        url = archiveURL.deletingLastPathComponent().appendingPathComponent(
            ".\(archiveURL.lastPathComponent).sync-publication.json",
            isDirectory: false
        )
    }

    func load() throws -> SyncPublicationTransaction? {
        guard let data = try readData() else { return nil }
        do {
            return try JSONDecoder().decode(
                SyncPublicationTransaction.self,
                from: data
            ).validated()
        } catch let error as SyncPublicationTransactionFileError {
            throw error
        } catch {
            throw SyncPublicationTransactionFileError.corrupt
        }
    }

    func write(_ transaction: SyncPublicationTransaction) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(transaction.validated())
        } catch let error as SyncPublicationTransactionFileError {
            throw error
        } catch {
            throw SyncPublicationTransactionFileError.unavailable
        }
        guard data.count <= Self.maximumEncodedBytes else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        try atomicWrite(data)
    }

    func remove() throws {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        if result != 0 {
            guard errno == ENOENT else {
                throw SyncPublicationTransactionFileError.unavailable
            }
            return
        }
        guard Self.isRegularFile(status) else {
            throw SyncPublicationTransactionFileError.unsafeFile
        }
        guard url.path.withCString({ Darwin.unlink($0) }) == 0 else {
            throw SyncPublicationTransactionFileError.unavailable
        }
        try synchronizeParentDirectory()
    }

    static func fingerprint(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    func liveArchiveFingerprint(archiveURL: URL) throws -> Data? {
        try fingerprintOfRegularFile(
            at: archiveURL,
            maximumBytes: SyncPublicationFileLimits.maximumArchiveBytes
        )
    }

    func commitStatus(
        of transaction: SyncPublicationTransaction,
        archiveURL: URL
    ) throws -> SyncPublicationCommitStatus {
        guard try liveArchiveFingerprint(archiveURL: archiveURL)
                == transaction.expectedArchiveSHA256 else {
            return .uncommitted
        }
        let artifactsMatch = try transaction.artifactEvidence.allSatisfy {
            try artifactMatches($0, archiveURL: archiveURL)
        }
        if artifactsMatch {
            return .committed
        }
        return transaction.commitBoundary == .archive ? .corrupt : .uncommitted
    }

    func evidenceForExistingArtifact(
        relativePath: String,
        archiveURL: URL
    ) throws -> SyncPublicationArtifactEvidence {
        let evidence = try SyncPublicationArtifactEvidence(
            relativePath: relativePath,
            expectedSHA256: nil
        )
        let fileURL = try artifactURL(for: evidence, archiveURL: archiveURL)
        guard let fingerprint = try fingerprintOfRegularFile(
            at: fileURL,
            maximumBytes: SyncPublicationFileLimits.maximumAttachmentBytes
        ) else {
            throw SyncPublicationTransactionFileError.unavailable
        }
        return try SyncPublicationArtifactEvidence(
            relativePath: relativePath,
            expectedSHA256: fingerprint
        )
    }

    private func readData() throws -> Data? {
        var pathStatus = stat()
        let pathResult = url.path.withCString { Darwin.lstat($0, &pathStatus) }
        if pathResult != 0 {
            guard errno == ENOENT else {
                throw SyncPublicationTransactionFileError.unavailable
            }
            return nil
        }
        do {
            return try SyncRegularFileReader().read(
                url,
                maximumBytes: Self.maximumEncodedBytes
            ).data
        } catch let error as SyncRegularFileReadError {
            switch error {
            case .unsafeFile:
                throw SyncPublicationTransactionFileError.unsafeFile
            case .unavailable:
                throw SyncPublicationTransactionFileError.unavailable
            case .tooLarge, .replaced, .changed, .expectationMismatch:
                throw SyncPublicationTransactionFileError.corrupt
            }
        }
    }

    private func artifactMatches(
        _ evidence: SyncPublicationArtifactEvidence,
        archiveURL: URL
    ) throws -> Bool {
        let fileURL = try artifactURL(for: evidence, archiveURL: archiveURL)
        guard let expectedSHA256 = evidence.expectedSHA256 else {
            var status = stat()
            let result = fileURL.path.withCString { Darwin.lstat($0, &status) }
            if result != 0 {
                guard errno == ENOENT else {
                    throw SyncPublicationTransactionFileError.unavailable
                }
                return true
            }
            guard Self.isRegularFile(status) else {
                throw SyncPublicationTransactionFileError.unsafeFile
            }
            return false
        }
        return try fingerprintOfRegularFile(
            at: fileURL,
            maximumBytes: SyncPublicationFileLimits.maximumAttachmentBytes
        ) == expectedSHA256
    }

    private func artifactURL(
        for evidence: SyncPublicationArtifactEvidence,
        archiveURL: URL
    ) throws -> URL {
        _ = try evidence.validated()
        let root = archiveURL.deletingLastPathComponent().standardizedFileURL
        guard root.resolvingSymlinksInPath().path == root.path else {
            throw SyncPublicationTransactionFileError.unsafeFile
        }
        let candidate = root.appendingPathComponent(
            evidence.relativePath,
            isDirectory: false
        ).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"),
              candidate.resolvingSymlinksInPath().path == candidate.path else {
            throw SyncPublicationTransactionFileError.unsafeFile
        }
        return candidate
    }

    private func fingerprintOfRegularFile(
        at fileURL: URL,
        maximumBytes: Int
    ) throws -> Data? {
        var pathStatus = stat()
        let pathResult = fileURL.path.withCString { Darwin.lstat($0, &pathStatus) }
        if pathResult != 0 {
            guard errno == ENOENT else {
                throw SyncPublicationTransactionFileError.unavailable
            }
            return nil
        }
        do {
            return try SyncRegularFileReader().read(
                fileURL,
                maximumBytes: maximumBytes
            ).sha256
        } catch let error as SyncRegularFileReadError {
            switch error {
            case .unsafeFile:
                throw SyncPublicationTransactionFileError.unsafeFile
            case .unavailable:
                throw SyncPublicationTransactionFileError.unavailable
            case .tooLarge, .replaced, .changed, .expectationMismatch:
                throw SyncPublicationTransactionFileError.corrupt
            }
        }
    }

    private func atomicWrite(_ data: Data) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        } catch {
            throw SyncPublicationTransactionFileError.unavailable
        }

        var liveStatus = stat()
        let liveResult = url.path.withCString { Darwin.lstat($0, &liveStatus) }
        if liveResult == 0, !Self.isRegularFile(liveStatus) {
            throw SyncPublicationTransactionFileError.unsafeFile
        }
        if liveResult != 0, errno != ENOENT {
            throw SyncPublicationTransactionFileError.unavailable
        }

        let temporary = parent.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = temporary.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw SyncPublicationTransactionFileError.unavailable
        }
        var temporaryExists = true
        defer {
            Darwin.close(descriptor)
            if temporaryExists {
                _ = temporary.path.withCString { Darwin.unlink($0) }
            }
        }

        do {
            try Self.write(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw SyncPublicationTransactionFileError.unavailable
            }
            guard temporary.path.withCString({ source in
                url.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }) == 0 else {
                throw SyncPublicationTransactionFileError.unavailable
            }
            temporaryExists = false
            try synchronizeParentDirectory()
        } catch let error as SyncPublicationTransactionFileError {
            throw error
        } catch {
            throw SyncPublicationTransactionFileError.unavailable
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var writtenByteCount = 0
            while writtenByteCount < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: writtenByteCount),
                    bytes.count - writtenByteCount
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw SyncPublicationTransactionFileError.unavailable
                }
                writtenByteCount += result
            }
        }
    }

    private func synchronizeParentDirectory() throws {
        let parent = url.deletingLastPathComponent()
        let descriptor = parent.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw SyncPublicationTransactionFileError.unavailable
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw SyncPublicationTransactionFileError.unavailable
        }
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
    }
}
