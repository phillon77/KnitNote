import Darwin
import Foundation

public enum SyncInstallationIdentityError: Error, Equatable, Sendable {
    case corrupt
    case unsafeFile
}

public final class SyncInstallationIdentityStore: @unchecked Sendable {
    private static let currentVersion = 1
    private static let sharedLock = NSLock()

    private struct Envelope: Codable {
        let version: Int
        let identity: String
    }

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func loadOrCreate() throws -> String {
        Self.sharedLock.lock()
        defer { Self.sharedLock.unlock() }

        switch try existingIdentity() {
        case let .some(identity):
            return identity
        case .none:
            let identity = UUID().uuidString
            let data: Data
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                data = try encoder.encode(Envelope(
                    version: Self.currentVersion,
                    identity: identity
                ))
            } catch {
                throw SyncInstallationIdentityError.corrupt
            }
            try SyncDurableFile.write(data, to: url)
            return identity
        }
    }

    private func existingIdentity() throws -> String? {
        var status = stat()
        let lstatResult = url.path.withCString { Darwin.lstat($0, &status) }
        if lstatResult != 0 {
            guard errno == ENOENT else { throw SyncInstallationIdentityError.unsafeFile }
            return nil
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw SyncInstallationIdentityError.unsafeFile
        }
        let data: Data
        do {
            data = try SyncDurableFile.readRegularFile(at: url)
        } catch let error as SyncDurableFileError {
            throw error == .unsafeFile
                ? SyncInstallationIdentityError.unsafeFile
                : SyncInstallationIdentityError.corrupt
        } catch {
            throw SyncInstallationIdentityError.corrupt
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == Self.currentVersion,
                  UUID(uuidString: envelope.identity) != nil else {
                throw SyncInstallationIdentityError.corrupt
            }
            return envelope.identity
        } catch let error as SyncInstallationIdentityError {
            throw error
        } catch {
            throw SyncInstallationIdentityError.corrupt
        }
    }
}

enum SyncDurableFileError: Error, Equatable {
    case corrupt
    case unsafeFile
    case unavailable
}

enum SyncDurableFile {
    static func readRegularFile(at url: URL) throws -> Data {
        var before = stat()
        guard url.path.withCString({ Darwin.lstat($0, &before) }) == 0 else {
            throw SyncDurableFileError.unavailable
        }
        guard (before.st_mode & S_IFMT) == S_IFREG else {
            throw SyncDurableFileError.unsafeFile
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw SyncDurableFileError.unavailable }
        defer { Darwin.close(descriptor) }

        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino,
              opened.st_size >= 0 else {
            throw SyncDurableFileError.unsafeFile
        }
        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw SyncDurableFileError.unavailable }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              after.st_dev == opened.st_dev,
              after.st_ino == opened.st_ino,
              after.st_size == opened.st_size,
              data.count == Int(opened.st_size) else {
            throw SyncDurableFileError.corrupt
        }
        return data
    }

    static func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw SyncDurableFileError.unavailable }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary {
                _ = temporaryURL.path.withCString(Darwin.unlink)
            }
        }
        try writeAll(data, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw SyncDurableFileError.unavailable }
        guard temporaryURL.path.withCString({ temporaryPath in
            url.path.withCString { destinationPath in
                Darwin.rename(temporaryPath, destinationPath)
            }
        }) == 0 else {
            throw SyncDurableFileError.unavailable
        }
        shouldRemoveTemporary = false
        try synchronizeDirectory(parent)
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw SyncDurableFileError.unavailable }
                offset += result
            }
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw SyncDurableFileError.unavailable }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw SyncDurableFileError.unavailable }
    }
}
