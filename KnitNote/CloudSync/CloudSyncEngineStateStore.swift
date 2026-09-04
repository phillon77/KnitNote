import CloudKit
import Darwin
import Foundation

enum CloudSyncEngineStateStoreError: Error, Equatable {
    case corrupt
    case unsafeFile
    case unavailable
}

struct FileCloudSyncEngineStateStore: @unchecked Sendable {
    typealias BeforeWriteBoundary = @Sendable (SyncDurableFileWriteBoundary) throws -> Void

    private let file: DescriptorRelativeAtomicFile
    private let url: URL

    init(url: URL) {
        self.init(url: url, beforeWriteBoundary: { _ in })
    }

    init(url: URL, beforeWriteBoundary: @escaping BeforeWriteBoundary) {
        self.url = url
        file = DescriptorRelativeAtomicFile(url: url, beforeWriteBoundary: beforeWriteBoundary)
    }

    func relatedURL(pathExtension: String) -> URL {
        url.appendingPathExtension(pathExtension)
    }

    func load() throws -> CKSyncEngine.State.Serialization? {
        do {
            guard let data = try file.read() else { return nil }
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        } catch is DecodingError {
            throw CloudSyncEngineStateStoreError.corrupt
        } catch {
            throw CloudSyncEngineStateStoreError.unavailable
        }
    }

    @discardableResult
    func save(_ state: CKSyncEngine.State.Serialization) throws -> Data {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(state)
        } catch {
            throw CloudSyncEngineStateStoreError.corrupt
        }
        do {
            try file.write(data)
            return data
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        }
    }

    func clear() throws {
        do {
            try file.remove()
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        }
    }

    private static func map(
        _ error: DescriptorRelativeAtomicFileError
    ) -> CloudSyncEngineStateStoreError {
        switch error {
        case .corrupt: .corrupt
        case .unsafeFile: .unsafeFile
        case .unavailable: .unavailable
        }
    }
}

enum CloudIncomingBatchStoreError: Error, Equatable {
    case corrupt
    case unsafeFile
    case unavailable
    case capacityExceeded
}

struct CloudIncomingBatchEnvelope: Codable, Equatable, Sendable {
    let batchID: UUID
    let accountIdentifier: String
    let zoneName: String
    let ownerName: String
    var deliveryGeneration: UInt64
    var awaitingSourceRedelivery: Bool
    var acknowledged: Bool
    let records: [SyncRecord]
    let deletedRecordIDs: [SyncEntityID]

    func belongs(
        to accountIdentifier: String,
        zoneID: CKRecordZone.ID
    ) -> Bool {
        self.accountIdentifier == accountIdentifier
            && zoneName == zoneID.zoneName
            && ownerName == zoneID.ownerName
    }
}

struct CloudIncomingBatchRecordingResult: Sendable {
    let envelope: CloudIncomingBatchEnvelope
    let shouldDeliver: Bool
}

/// Durable handoff between CKSyncEngine callbacks and the domain committer.
/// Entries remain until a covering engine-state update is durably installed.
struct FileCloudIncomingBatchStore: @unchecked Sendable {
    private static let version = 1
    private static let defaultMaximumBatchCount = 128
    private static let defaultMaximumEncodedBytes = 16 * 1_024 * 1_024

    private let file: DescriptorRelativeAtomicFile
    private let maximumBatchCount: Int
    private let maximumEncodedBytes: Int

    init(
        url: URL,
        maximumBatchCount: Int = Self.defaultMaximumBatchCount,
        maximumEncodedBytes: Int = Self.defaultMaximumEncodedBytes
    ) {
        file = DescriptorRelativeAtomicFile(url: url)
        self.maximumBatchCount = maximumBatchCount
        self.maximumEncodedBytes = maximumEncodedBytes
    }

    func beginGeneration(
        accountIdentifier: String,
        zoneID: CKRecordZone.ID,
        persistedEngineState: Data?
    ) throws -> (generation: UInt64, batches: [CloudIncomingBatchEnvelope]) {
        var store = try load()
        if let staged = store.stagedStateCommit {
            if staged.engineState == persistedEngineState {
                let covered = Set(staged.coveredBatchIDs)
                store.batches.removeAll { covered.contains($0.batchID) }
            }
            store.stagedStateCommit = nil
        }
        let scope = CloudIncomingBatchScope(
            accountIdentifier: accountIdentifier,
            zoneName: zoneID.zoneName,
            ownerName: zoneID.ownerName
        )
        let previous = store.generations.firstIndex { $0.scope == scope }
        let generation: UInt64
        if let previous {
            guard store.generations[previous].generation < UInt64.max else {
                throw CloudIncomingBatchStoreError.corrupt
            }
            generation = store.generations[previous].generation + 1
            store.generations[previous].generation = generation
        } else {
            generation = 1
            store.generations.append(.init(scope: scope, generation: generation))
        }
        for index in store.batches.indices where store.batches[index].belongs(
            to: accountIdentifier,
            zoneID: zoneID
        ) {
            store.batches[index].deliveryGeneration = generation
            store.batches[index].awaitingSourceRedelivery = true
            store.batches[index].acknowledged = false
        }
        try save(store)
        return (
            generation,
            store.batches.filter { $0.belongs(to: accountIdentifier, zoneID: zoneID) }
        )
    }

    func record(
        records: [SyncRecord],
        deletedRecordIDs: [SyncEntityID],
        accountIdentifier: String,
        zoneID: CKRecordZone.ID,
        generation: UInt64
    ) throws -> CloudIncomingBatchRecordingResult {
        var store = try load()
        if let index = store.batches.firstIndex(where: {
            $0.belongs(to: accountIdentifier, zoneID: zoneID)
                && $0.deliveryGeneration == generation
                && $0.awaitingSourceRedelivery
                && $0.records == records
                && $0.deletedRecordIDs == deletedRecordIDs
        }) {
            store.batches[index].awaitingSourceRedelivery = false
            try save(store)
            return .init(envelope: store.batches[index], shouldDeliver: false)
        }
        guard store.batches.count < maximumBatchCount else {
            throw CloudIncomingBatchStoreError.capacityExceeded
        }
        let batch = CloudIncomingBatchEnvelope(
            batchID: UUID(),
            accountIdentifier: accountIdentifier,
            zoneName: zoneID.zoneName,
            ownerName: zoneID.ownerName,
            deliveryGeneration: generation,
            awaitingSourceRedelivery: false,
            acknowledged: false,
            records: records,
            deletedRecordIDs: deletedRecordIDs
        )
        store.batches.append(batch)
        try save(store)
        return .init(envelope: batch, shouldDeliver: true)
    }

    func acknowledge(
        _ batchID: UUID,
        accountIdentifier: String,
        zoneID: CKRecordZone.ID
    ) throws {
        var store = try load()
        guard let index = store.batches.firstIndex(where: {
            $0.batchID == batchID && $0.belongs(to: accountIdentifier, zoneID: zoneID)
        }) else {
            throw CloudSyncTransportError.unknownFetchedBatch
        }
        guard !store.batches[index].acknowledged else { return }
        store.batches[index].acknowledged = true
        try save(store)
    }

    func stageStateCommit(engineState: Data, coveredBatchIDs: Set<UUID>) throws {
        var store = try load()
        guard coveredBatchIDs.isSubset(of: Set(store.batches.map(\.batchID))) else {
            throw CloudIncomingBatchStoreError.corrupt
        }
        store.stagedStateCommit = .init(
            engineState: engineState,
            coveredBatchIDs: coveredBatchIDs.sorted { $0.uuidString < $1.uuidString }
        )
        try save(store)
    }

    func completeStateCommit(engineState: Data) throws {
        var store = try load()
        guard let staged = store.stagedStateCommit,
              staged.engineState == engineState else {
            throw CloudIncomingBatchStoreError.corrupt
        }
        let covered = Set(staged.coveredBatchIDs)
        store.batches.removeAll { covered.contains($0.batchID) }
        store.stagedStateCommit = nil
        try save(store)
    }

    private func load() throws -> CloudIncomingBatchStoreFile {
        do {
            guard let data = try file.read(), !data.isEmpty else {
                return .init(
                    version: Self.version,
                    generations: [],
                    batches: [],
                    stagedStateCommit: nil
                )
            }
            guard data.count <= maximumEncodedBytes else {
                throw CloudIncomingBatchStoreError.capacityExceeded
            }
            let decoded = try JSONDecoder().decode(CloudIncomingBatchStoreFile.self, from: data)
            guard decoded.version == Self.version,
                  decoded.batches.count <= maximumBatchCount,
                  Set(decoded.batches.map(\.batchID)).count == decoded.batches.count,
                  Set(decoded.generations.map(\.scope)).count == decoded.generations.count else {
                throw CloudIncomingBatchStoreError.corrupt
            }
            return decoded
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        } catch let error as CloudIncomingBatchStoreError {
            throw error
        } catch {
            throw CloudIncomingBatchStoreError.corrupt
        }
    }

    private func save(_ store: CloudIncomingBatchStoreFile) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(store)
            guard store.batches.count <= maximumBatchCount,
                  data.count <= maximumEncodedBytes else {
                throw CloudIncomingBatchStoreError.capacityExceeded
            }
            try file.write(data)
        } catch let error as DescriptorRelativeAtomicFileError {
            throw Self.map(error)
        } catch let error as CloudIncomingBatchStoreError {
            throw error
        } catch {
            throw CloudIncomingBatchStoreError.corrupt
        }
    }

    private static func map(
        _ error: DescriptorRelativeAtomicFileError
    ) -> CloudIncomingBatchStoreError {
        switch error {
        case .corrupt: .corrupt
        case .unsafeFile: .unsafeFile
        case .unavailable: .unavailable
        }
    }
}

private struct CloudIncomingBatchStoreFile: Codable {
    let version: Int
    var generations: [CloudIncomingBatchGeneration]
    var batches: [CloudIncomingBatchEnvelope]
    var stagedStateCommit: CloudIncomingBatchStateCommit?
}

private struct CloudIncomingBatchScope: Codable, Equatable, Hashable {
    let accountIdentifier: String
    let zoneName: String
    let ownerName: String
}

private struct CloudIncomingBatchGeneration: Codable {
    let scope: CloudIncomingBatchScope
    var generation: UInt64
}

private struct CloudIncomingBatchStateCommit: Codable {
    let engineState: Data
    let coveredBatchIDs: [UUID]
}

enum DescriptorRelativeAtomicFileError: Error, Equatable {
    case corrupt
    case unsafeFile
    case unavailable
}

struct DescriptorRelativeAtomicFile: @unchecked Sendable {
    typealias BeforeWriteBoundary = @Sendable (SyncDurableFileWriteBoundary) throws -> Void

    private let parentURL: URL
    private let fileName: String
    private let beforeWriteBoundary: BeforeWriteBoundary

    init(url: URL, beforeWriteBoundary: @escaping BeforeWriteBoundary = { _ in }) {
        parentURL = url.deletingLastPathComponent()
        fileName = url.lastPathComponent
        self.beforeWriteBoundary = beforeWriteBoundary
    }

    func read() throws -> Data? {
        let parentDescriptor = try openParent(createIfMissing: false)
        guard parentDescriptor >= 0 else { return nil }
        defer { Darwin.close(parentDescriptor) }
        let descriptor = fileName.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw DescriptorRelativeAtomicFileError.unsafeFile }
            throw DescriptorRelativeAtomicFileError.unavailable
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            throw DescriptorRelativeAtomicFileError.unsafeFile
        }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw DescriptorRelativeAtomicFileError.unavailable }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              after.st_dev == status.st_dev,
              after.st_ino == status.st_ino,
              after.st_size == status.st_size,
              data.count == Int(status.st_size) else {
            throw DescriptorRelativeAtomicFileError.corrupt
        }
        return data
    }

    func write(_ data: Data) throws {
        let parentDescriptor = try openParent(createIfMissing: true)
        defer { Darwin.close(parentDescriptor) }
        let original = try destinationIdentity(parentDescriptor: parentDescriptor)
        let temporaryName = ".\(fileName).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw DescriptorRelativeAtomicFileError.unavailable }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary {
                _ = temporaryName.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) }
            }
        }
        try writeAll(data, descriptor: descriptor)
        try beforeWriteBoundary(.beforeFileSync)
        guard Darwin.fsync(descriptor) == 0 else {
            throw DescriptorRelativeAtomicFileError.unavailable
        }
        try beforeWriteBoundary(.beforeRename)
        let current = try destinationIdentity(parentDescriptor: parentDescriptor)
        guard current == original else { throw DescriptorRelativeAtomicFileError.unsafeFile }
        let renameResult = temporaryName.withCString { temporaryPath in
            fileName.withCString { destinationPath in
                Darwin.renameat(
                    parentDescriptor,
                    temporaryPath,
                    parentDescriptor,
                    destinationPath
                )
            }
        }
        guard renameResult == 0 else { throw DescriptorRelativeAtomicFileError.unavailable }
        shouldRemoveTemporary = false
        try beforeWriteBoundary(.beforeDirectorySync)
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw DescriptorRelativeAtomicFileError.unavailable
        }
    }

    func remove() throws {
        let parentDescriptor = try openParent(createIfMissing: false)
        guard parentDescriptor >= 0 else { return }
        defer { Darwin.close(parentDescriptor) }
        guard try destinationIdentity(parentDescriptor: parentDescriptor) != nil else { return }
        let result = fileName.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) }
        guard result == 0 else { throw DescriptorRelativeAtomicFileError.unavailable }
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw DescriptorRelativeAtomicFileError.unavailable
        }
    }

    private func openParent(createIfMissing: Bool) throws -> Int32 {
        guard !fileName.isEmpty, fileName != ".", fileName != ".." else {
            throw DescriptorRelativeAtomicFileError.unsafeFile
        }
        if createIfMissing {
            do {
                try FileManager.default.createDirectory(
                    at: parentURL,
                    withIntermediateDirectories: true
                )
            } catch {
                throw DescriptorRelativeAtomicFileError.unavailable
            }
        }
        let descriptor = parentURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT, !createIfMissing { return -1 }
            if errno == ELOOP { throw DescriptorRelativeAtomicFileError.unsafeFile }
            throw DescriptorRelativeAtomicFileError.unavailable
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(descriptor)
            throw DescriptorRelativeAtomicFileError.unsafeFile
        }
        return descriptor
    }

    private func destinationIdentity(parentDescriptor: Int32) throws -> FileIdentity? {
        var status = stat()
        let result = fileName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw DescriptorRelativeAtomicFileError.unavailable
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw DescriptorRelativeAtomicFileError.unsafeFile
        }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw DescriptorRelativeAtomicFileError.unavailable }
                offset += count
            }
        }
    }
}

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}
