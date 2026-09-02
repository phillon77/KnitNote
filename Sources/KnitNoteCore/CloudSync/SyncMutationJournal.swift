import Darwin
import Foundation

public enum SyncMutation: Codable, Equatable, Sendable {
    case save(SyncEntityID, mutationID: UUID)
    case delete(SyncEntityID, mutationID: UUID)

    fileprivate var recordID: SyncEntityID {
        switch self {
        case let .save(recordID, _), let .delete(recordID, _):
            recordID
        }
    }

    fileprivate var mutationID: UUID {
        switch self {
        case let .save(_, mutationID), let .delete(_, mutationID):
            mutationID
        }
    }
}

public enum SyncMutationJournalError: Error, Equatable, Sendable {
    case corrupt
}

public protocol SyncMutationJournalProtocol: Sendable {
    func enqueue(_ mutation: SyncMutation) throws
    func pending() throws -> [SyncMutation]
    func acknowledge(recordID: SyncEntityID, mutationID: UUID) throws
}

public final class FileSyncMutationJournal: SyncMutationJournalProtocol, @unchecked Sendable {
    typealias AtomicWrite = @Sendable (Data, URL) throws -> Void
    typealias SynchronizeDirectory = @Sendable (URL) throws -> Void

    private let url: URL
    private let atomicWrite: AtomicWrite
    private let lock = NSLock()
    private var loadedMutations: [SyncMutation]?

    public convenience init(url: URL) {
        self.init(url: url, synchronizeDirectory: Self.defaultSynchronizeDirectory)
    }

    convenience init(
        url: URL,
        synchronizeDirectory: @escaping SynchronizeDirectory
    ) {
        self.init(
            url: url,
            atomicWrite: { data, destination in
                try Self.defaultAtomicWrite(
                    data,
                    to: destination,
                    synchronizeDirectory: synchronizeDirectory
                )
            }
        )
    }

    init(url: URL, atomicWrite: @escaping AtomicWrite) {
        self.url = url
        self.atomicWrite = atomicWrite
    }

    public func enqueue(_ mutation: SyncMutation) throws {
        try lock.withLock {
            var candidate = try mutationsLocked()
            candidate.append(mutation)
            try persistLocked(candidate)
            loadedMutations = candidate
        }
    }

    public func pending() throws -> [SyncMutation] {
        try lock.withLock {
            try mutationsLocked()
        }
    }

    public func acknowledge(recordID: SyncEntityID, mutationID: UUID) throws {
        try lock.withLock {
            let current = try mutationsLocked()
            let candidate = current.filter {
                $0.recordID != recordID || $0.mutationID != mutationID
            }
            guard candidate.count != current.count else { return }
            try persistLocked(candidate)
            loadedMutations = candidate
        }
    }

    private func mutationsLocked() throws -> [SyncMutation] {
        if let loadedMutations {
            return loadedMutations
        }
        let mutations = try readLiveMutationsLocked()
        loadedMutations = mutations
        return mutations
    }

    private func readLiveMutationsLocked() throws -> [SyncMutation] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw SyncMutationJournalError.corrupt
        }
        guard envelope.version == Envelope.currentVersion else {
            throw SyncMutationJournalError.corrupt
        }
        return envelope.mutations
    }

    private func persistLocked(_ mutations: [SyncMutation]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(mutations: mutations))
        do {
            try atomicWrite(data, url)
        } catch {
            let persistenceError = error
            do {
                loadedMutations = try readLiveMutationsLocked()
            } catch {
                loadedMutations = nil
            }
            throw persistenceError
        }
    }

    private struct Envelope: Codable {
        static let currentVersion = 1

        let version: Int
        let mutations: [SyncMutation]

        init(mutations: [SyncMutation]) {
            version = Self.currentVersion
            self.mutations = mutations
        }
    }

    private static func defaultAtomicWrite(
        _ data: Data,
        to destination: URL,
        synchronizeDirectory: SynchronizeDirectory
    ) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var temporaryExists = false
        defer {
            if temporaryExists {
                try? fileManager.removeItem(at: temporary)
            }
        }

        let descriptor = try openNewFile(at: temporary)
        temporaryExists = true
        do {
            defer { Darwin.close(descriptor) }
            try write(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw currentPOSIXError()
            }
        }

        let renameResult = temporary.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw currentPOSIXError()
        }
        temporaryExists = false
        try synchronizeDirectory(parent)
    }

    private static func openNewFile(at url: URL) throws -> Int32 {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw currentPOSIXError()
        }
        return descriptor
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
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw currentPOSIXError()
                }
                writtenByteCount += result
            }
        }
    }

    private static func defaultSynchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw currentPOSIXError()
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw currentPOSIXError()
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
