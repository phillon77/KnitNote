import CryptoKit
import Darwin
import Foundation

public protocol SyncMutationSink: Sendable {
    func publish(_ mutation: SyncMutation) throws
    func publish(_ mutations: [SyncMutation]) throws
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

struct SyncPublicationTransaction: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let version: Int
    let expectedArchiveSHA256: Data
    let commitBoundary: SyncPublicationCommitBoundary
    let artifactEvidence: [SyncPublicationArtifactEvidence]
    let mutations: [SyncMutation]
    let integrity: Data

    init(
        expectedArchiveSHA256: Data,
        mutations: [SyncMutation],
        commitBoundary: SyncPublicationCommitBoundary = .archive,
        artifactEvidence: [SyncPublicationArtifactEvidence] = []
    ) throws {
        version = Self.currentVersion
        self.expectedArchiveSHA256 = expectedArchiveSHA256
        self.commitBoundary = commitBoundary
        self.artifactEvidence = artifactEvidence.sorted {
            $0.relativePath < $1.relativePath
        }
        self.mutations = mutations
        integrity = try Self.integrity(
            version: version,
            expectedArchiveSHA256: expectedArchiveSHA256,
            commitBoundary: commitBoundary,
            artifactEvidence: self.artifactEvidence,
            mutations: mutations
        )
    }

    func validated() throws -> Self {
        let validatedEvidence = try artifactEvidence.map { try $0.validated() }
        guard version == Self.currentVersion,
              expectedArchiveSHA256.count == SHA256.byteCount,
              !mutations.isEmpty,
              artifactEvidence == artifactEvidence.sorted(by: {
                  $0.relativePath < $1.relativePath
              }),
              Set(validatedEvidence.map(\.relativePath)).count == validatedEvidence.count,
              commitBoundary != .artifacts || !artifactEvidence.isEmpty,
              integrity == (try Self.integrity(
                  version: version,
                  expectedArchiveSHA256: expectedArchiveSHA256,
                  commitBoundary: commitBoundary,
                  artifactEvidence: artifactEvidence,
                  mutations: mutations
              )) else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        return self
    }

    private static func integrity(
        version: Int,
        expectedArchiveSHA256: Data,
        commitBoundary: SyncPublicationCommitBoundary,
        artifactEvidence: [SyncPublicationArtifactEvidence],
        mutations: [SyncMutation]
    ) throws -> Data {
        let payload = IntegrityPayload(
            version: version,
            expectedArchiveSHA256: expectedArchiveSHA256,
            commitBoundary: commitBoundary,
            artifactEvidence: artifactEvidence,
            mutations: mutations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(payload)))
    }

    private struct IntegrityPayload: Codable {
        let version: Int
        let expectedArchiveSHA256: Data
        let commitBoundary: SyncPublicationCommitBoundary
        let artifactEvidence: [SyncPublicationArtifactEvidence]
        let mutations: [SyncMutation]
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
    private static let maximumEncodedBytes = 1 * 1_024 * 1_024
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
        try fingerprintOfRegularFile(at: archiveURL)
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
        guard let fingerprint = try fingerprintOfRegularFile(at: fileURL) else {
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
        guard Self.isRegularFile(pathStatus) else {
            throw SyncPublicationTransactionFileError.unsafeFile
        }
        guard pathStatus.st_size >= 0,
              pathStatus.st_size <= Self.maximumEncodedBytes else {
            throw SyncPublicationTransactionFileError.corrupt
        }

        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            // Absence was already established by the first lstat. Disappearing
            // between that check and open is an unsafe race, not an empty state.
            throw SyncPublicationTransactionFileError.unavailable
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw SyncPublicationTransactionFileError.unavailable
        }
        guard Self.isRegularFile(status) else {
            throw SyncPublicationTransactionFileError.unsafeFile
        }
        guard status.st_size >= 0,
              status.st_size <= Self.maximumEncodedBytes,
              status.st_dev == pathStatus.st_dev,
              status.st_ino == pathStatus.st_ino else {
            throw SyncPublicationTransactionFileError.corrupt
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw SyncPublicationTransactionFileError.unavailable
            }
            guard count > 0 else { return data }
            data.append(buffer, count: count)
            guard data.count <= Self.maximumEncodedBytes else {
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
        return try fingerprintOfRegularFile(at: fileURL) == expectedSHA256
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

    private func fingerprintOfRegularFile(at fileURL: URL) throws -> Data? {
        var pathStatus = stat()
        let pathResult = fileURL.path.withCString { Darwin.lstat($0, &pathStatus) }
        if pathResult != 0 {
            guard errno == ENOENT else {
                throw SyncPublicationTransactionFileError.unavailable
            }
            return nil
        }
        guard Self.isRegularFile(pathStatus) else {
            throw SyncPublicationTransactionFileError.unsafeFile
        }
        let descriptor = fileURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw SyncPublicationTransactionFileError.unavailable
        }
        defer { Darwin.close(descriptor) }

        var descriptorStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              Self.isRegularFile(descriptorStatus),
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            throw SyncPublicationTransactionFileError.unsafeFile
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw SyncPublicationTransactionFileError.unavailable
            }
            guard count > 0 else {
                return Data(hasher.finalize())
            }
            hasher.update(data: Data(buffer.prefix(count)))
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
