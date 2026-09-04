import CloudKit
import Darwin
import Foundation

enum CloudSyncEngineStateStoreError: Error, Equatable {
    case corrupt
    case unsafeFile
    case unavailable
}

struct FileCloudSyncEngineStateStore: @unchecked Sendable {
    typealias BeforeWriteBoundary = (SyncDurableFileWriteBoundary) throws -> Void

    private let url: URL
    private let beforeWriteBoundary: BeforeWriteBoundary

    init(url: URL) {
        self.init(url: url, beforeWriteBoundary: { _ in })
    }

    init(url: URL, beforeWriteBoundary: @escaping BeforeWriteBoundary) {
        self.url = url
        self.beforeWriteBoundary = beforeWriteBoundary
    }

    func load() throws -> CKSyncEngine.State.Serialization? {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        if result != 0 {
            guard errno == ENOENT else { throw CloudSyncEngineStateStoreError.unavailable }
            return nil
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw CloudSyncEngineStateStoreError.unsafeFile
        }
        do {
            let data = try SyncDurableFile.readRegularFile(at: url)
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch let error as SyncDurableFileError {
            throw Self.map(error)
        } catch is DecodingError {
            throw CloudSyncEngineStateStoreError.corrupt
        } catch {
            throw CloudSyncEngineStateStoreError.unavailable
        }
    }

    @discardableResult
    func save(_ state: CKSyncEngine.State.Serialization) throws -> Data {
        try validateDestinationForWrite()
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(state)
        } catch {
            throw CloudSyncEngineStateStoreError.corrupt
        }
        do {
            try SyncDurableFile.write(data, to: url, beforeBoundary: beforeWriteBoundary)
            return data
        } catch let error as SyncDurableFileError {
            throw Self.map(error)
        } catch {
            throw error
        }
    }

    func clear() throws {
        do {
            try SyncDurableFile.removeRegularFile(at: url)
        } catch let error as SyncDurableFileError {
            throw Self.map(error)
        } catch {
            throw CloudSyncEngineStateStoreError.unavailable
        }
    }

    private static func map(_ error: SyncDurableFileError) -> CloudSyncEngineStateStoreError {
        switch error {
        case .corrupt: .corrupt
        case .unsafeFile: .unsafeFile
        case .unavailable: .unavailable
        }
    }

    private func validateDestinationForWrite() throws {
        let parent = url.deletingLastPathComponent()
        var parentStatus = stat()
        let parentResult = parent.path.withCString { Darwin.lstat($0, &parentStatus) }
        if parentResult == 0 {
            guard (parentStatus.st_mode & S_IFMT) == S_IFDIR else {
                throw CloudSyncEngineStateStoreError.unsafeFile
            }
        } else if errno != ENOENT {
            throw CloudSyncEngineStateStoreError.unavailable
        }

        var destinationStatus = stat()
        let destinationResult = url.path.withCString { Darwin.lstat($0, &destinationStatus) }
        if destinationResult == 0 {
            guard (destinationStatus.st_mode & S_IFMT) == S_IFREG else {
                throw CloudSyncEngineStateStoreError.unsafeFile
            }
        } else if errno != ENOENT {
            throw CloudSyncEngineStateStoreError.unavailable
        }
    }
}
