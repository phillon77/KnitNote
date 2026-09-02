import CryptoKit
import Darwin
import Foundation

public protocol SyncMutationSink: Sendable {
    func publish(_ mutation: SyncMutation) throws
}

public protocol SyncRecordProvider: Sendable {
    func record(for id: SyncEntityID) throws -> SyncRecord?
}

public struct DisabledSyncMutationSink: SyncMutationSink {
    public init() {}

    public func publish(_ mutation: SyncMutation) throws {}
}

public struct JournalSyncMutationSink: SyncMutationSink {
    private let journal: any SyncMutationJournalProtocol

    public init(journal: any SyncMutationJournalProtocol) {
        self.journal = journal
    }

    public func publish(_ mutation: SyncMutation) throws {
        try journal.enqueue(mutation)
    }
}

public enum SyncPublicationError: Error, Equatable, Sendable {
    case pendingRepair
    case corruptTransaction
    case transactionUnavailable
    case sinkUnavailable
}

struct SyncPublicationTransaction: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let expectedArchiveSHA256: Data
    let mutations: [SyncMutation]
    let integrity: Data

    init(expectedArchiveSHA256: Data, mutations: [SyncMutation]) throws {
        version = Self.currentVersion
        self.expectedArchiveSHA256 = expectedArchiveSHA256
        self.mutations = mutations
        integrity = try Self.integrity(
            version: version,
            expectedArchiveSHA256: expectedArchiveSHA256,
            mutations: mutations
        )
    }

    func validated() throws -> Self {
        guard version == Self.currentVersion,
              expectedArchiveSHA256.count == SHA256.byteCount,
              !mutations.isEmpty,
              integrity == (try Self.integrity(
                  version: version,
                  expectedArchiveSHA256: expectedArchiveSHA256,
                  mutations: mutations
              )) else {
            throw SyncPublicationTransactionFileError.corrupt
        }
        return self
    }

    func replacingMutations(_ mutations: [SyncMutation]) throws -> Self {
        try Self(expectedArchiveSHA256: expectedArchiveSHA256, mutations: mutations)
    }

    private static func integrity(
        version: Int,
        expectedArchiveSHA256: Data,
        mutations: [SyncMutation]
    ) throws -> Data {
        let payload = IntegrityPayload(
            version: version,
            expectedArchiveSHA256: expectedArchiveSHA256,
            mutations: mutations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(payload)))
    }

    private struct IntegrityPayload: Codable {
        let version: Int
        let expectedArchiveSHA256: Data
        let mutations: [SyncMutation]
    }
}

enum SyncPublicationTransactionFileError: Error {
    case corrupt
    case unsafeFile
    case unavailable
}

struct SyncPublicationTransactionFile {
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
        guard FileManager.default.fileExists(atPath: archiveURL.path) else { return nil }
        do {
            return Self.fingerprint(of: try Data(contentsOf: archiveURL))
        } catch {
            throw SyncPublicationTransactionFileError.unavailable
        }
    }

    private func readData() throws -> Data? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            guard errno == ENOENT else {
                throw SyncPublicationTransactionFileError.unavailable
            }
            return nil
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw SyncPublicationTransactionFileError.unavailable
        }
        guard Self.isRegularFile(status) else {
            throw SyncPublicationTransactionFileError.unsafeFile
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
