import CryptoKit
import Darwin
import Foundation

public enum SyncRegularFileReadError: Error, Equatable, Sendable {
    case unavailable
    case unsafeFile
    case tooLarge
    case replaced
    case changed
    case expectationMismatch
}

public struct SyncRegularFileExpectation: Sendable {
    public let byteCount: Int64?
    public let sha256: Data?

    public init(byteCount: Int64? = nil, sha256: Data? = nil) {
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct SyncRegularFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct SyncRegularFileRead: Sendable {
    public let data: Data
    public let device: UInt64
    public let inode: UInt64
    public let byteCount: Int64
    public let sha256: Data

    public var identity: SyncRegularFileIdentity {
        .init(device: device, inode: inode)
    }

    public init(
        data: Data,
        device: UInt64,
        inode: UInt64,
        byteCount: Int64,
        sha256: Data
    ) {
        self.data = data
        self.device = device
        self.inode = inode
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct SyncRegularFileReader: Sendable {
    private let beforeOpen: (@Sendable () throws -> Void)?
    private let beforeRead: (@Sendable () throws -> Void)?

    public init() {
        beforeOpen = nil
        beforeRead = nil
    }

    init(
        beforeOpen: (@Sendable () throws -> Void)? = nil,
        beforeRead: (@Sendable () throws -> Void)? = nil
    ) {
        self.beforeOpen = beforeOpen
        self.beforeRead = beforeRead
    }

    public func read(
        _ url: URL,
        maximumBytes: Int,
        expected: SyncRegularFileExpectation? = nil
    ) throws -> SyncRegularFileRead {
        guard maximumBytes >= 0 else { throw SyncRegularFileReadError.tooLarge }
        let maximumByteCount = Int64(maximumBytes)

        var pathStatus = stat()
        guard url.path.withCString({ Darwin.lstat($0, &pathStatus) }) == 0 else {
            throw SyncRegularFileReadError.unavailable
        }
        guard Self.isRegularFile(pathStatus) else {
            throw SyncRegularFileReadError.unsafeFile
        }
        guard let pathByteCount = Self.size(of: pathStatus) else {
            throw SyncRegularFileReadError.unsafeFile
        }
        guard pathByteCount <= maximumByteCount else {
            throw SyncRegularFileReadError.tooLarge
        }

        do {
            try beforeOpen?()
        } catch let error as SyncRegularFileReadError {
            throw error
        } catch {
            throw SyncRegularFileReadError.unavailable
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw SyncRegularFileReadError.unsafeFile }
            throw SyncRegularFileReadError.unavailable
        }
        defer { Darwin.close(descriptor) }

        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0 else {
            throw SyncRegularFileReadError.unavailable
        }
        guard Self.isRegularFile(openedStatus) else {
            throw SyncRegularFileReadError.unsafeFile
        }
        guard Self.identity(of: openedStatus) == Self.identity(of: pathStatus) else {
            throw SyncRegularFileReadError.replaced
        }
        guard let openedByteCount = Self.size(of: openedStatus) else {
            throw SyncRegularFileReadError.unsafeFile
        }
        guard openedByteCount <= maximumByteCount else {
            throw SyncRegularFileReadError.tooLarge
        }

        do {
            try beforeRead?()
        } catch let error as SyncRegularFileReadError {
            throw error
        } catch {
            throw SyncRegularFileReadError.unavailable
        }

        var data = Data()
        data.reserveCapacity(Int(openedByteCount))
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw SyncRegularFileReadError.unavailable }
            guard count > 0 else { break }
            guard data.count <= maximumBytes - count else {
                throw SyncRegularFileReadError.tooLarge
            }
            data.append(buffer, count: count)
            hasher.update(data: Data(buffer.prefix(count)))
        }

        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0 else {
            throw SyncRegularFileReadError.unavailable
        }
        guard Self.isRegularFile(finalStatus) else {
            throw SyncRegularFileReadError.unsafeFile
        }
        guard Self.identity(of: finalStatus) == Self.identity(of: openedStatus) else {
            throw SyncRegularFileReadError.replaced
        }
        guard let finalByteCount = Self.size(of: finalStatus) else {
            throw SyncRegularFileReadError.unsafeFile
        }
        guard finalByteCount <= maximumByteCount else {
            throw SyncRegularFileReadError.tooLarge
        }
        guard finalByteCount == openedByteCount,
              data.count == Int(openedByteCount) else {
            throw SyncRegularFileReadError.changed
        }

        let byteCount = Int64(data.count)
        let sha256 = Data(hasher.finalize())
        guard expected?.byteCount == nil || expected?.byteCount == byteCount,
              expected?.sha256 == nil || expected?.sha256 == sha256 else {
            throw SyncRegularFileReadError.expectationMismatch
        }
        return SyncRegularFileRead(
            data: data,
            device: UInt64(finalStatus.st_dev),
            inode: UInt64(finalStatus.st_ino),
            byteCount: byteCount,
            sha256: sha256
        )
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
    }

    private static func size(of status: stat) -> Int64? {
        guard status.st_size >= 0 else { return nil }
        return Int64(status.st_size)
    }

    private static func identity(of status: stat) -> SyncRegularFileIdentity {
        .init(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }
}
