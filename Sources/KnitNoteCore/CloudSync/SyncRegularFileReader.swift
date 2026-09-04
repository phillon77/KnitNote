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

public protocol SyncRegularFileReading: Sendable {
    func read(
        _ url: URL,
        maximumBytes: Int,
        expected: SyncRegularFileExpectation?
    ) throws -> SyncRegularFileRead
    /// Reads at most `maximumBytes`, which must be exactly one greater than
    /// `declaredByteCount`, and retains at most the declared number of bytes.
    /// There is intentionally no default: every conformer must implement the
    /// bounded diagnostic read rather than falling back to a wider `read`.
    func observe(
        _ url: URL,
        declaredByteCount: Int64,
        maximumBytes: Int
    ) throws -> SyncRegularFileObservation
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
    public let modificationNanoseconds: Int64
    public let sha256: Data

    public var identity: SyncRegularFileIdentity {
        .init(device: device, inode: inode)
    }

    public init(
        data: Data,
        device: UInt64,
        inode: UInt64,
        byteCount: Int64,
        modificationNanoseconds: Int64 = 0,
        sha256: Data
    ) {
        self.data = data
        self.device = device
        self.inode = inode
        self.byteCount = byteCount
        self.modificationNanoseconds = modificationNanoseconds
        self.sha256 = sha256
    }
}

/// A descriptor-bound diagnostic observation. `data` never contains the
/// overrun probe byte, so callers can retain at most `declaredByteCount` bytes
/// while `hasSizeMismatch` still records a larger or changing source.
public struct SyncRegularFileObservation: Sendable {
    public let data: Data
    public let device: UInt64
    public let inode: UInt64
    public let sha256: Data
    public let hasSizeMismatch: Bool

    public init(
        data: Data,
        device: UInt64,
        inode: UInt64,
        sha256: Data,
        hasSizeMismatch: Bool
    ) {
        self.data = data
        self.device = device
        self.inode = inode
        self.sha256 = sha256
        self.hasSizeMismatch = hasSizeMismatch
    }
}

struct SyncRegularFileReaderIOCounters: Sendable {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var bytesRead = 0
    }

    private let storage = Storage()

    var bytesRead: Int {
        storage.lock.withLock { storage.bytesRead }
    }

    fileprivate func record(bytesRead: Int) {
        storage.lock.withLock { storage.bytesRead += bytesRead }
    }
}

public struct SyncRegularFileReader: SyncRegularFileReading, Sendable {
    private let beforeOpen: (@Sendable () throws -> Void)?
    private let beforeRead: (@Sendable () throws -> Void)?
    private let ioCounters: SyncRegularFileReaderIOCounters?

    public init() {
        beforeOpen = nil
        beforeRead = nil
        ioCounters = nil
    }

    init(
        beforeOpen: (@Sendable () throws -> Void)? = nil,
        beforeRead: (@Sendable () throws -> Void)? = nil,
        ioCounters: SyncRegularFileReaderIOCounters? = nil
    ) {
        self.beforeOpen = beforeOpen
        self.beforeRead = beforeRead
        self.ioCounters = ioCounters
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
        guard Self.isSafeRegularFile(pathStatus) else {
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
        guard Self.isSafeRegularFile(openedStatus) else {
            throw SyncRegularFileReadError.unsafeFile
        }
        guard Self.identity(of: openedStatus) == Self.identity(of: pathStatus) else {
            throw SyncRegularFileReadError.replaced
        }
        guard let openedByteCount = Self.size(of: openedStatus) else {
            throw SyncRegularFileReadError.unsafeFile
        }
        guard let openedModificationNanoseconds = Self.modificationNanoseconds(
            of: openedStatus
        ) else {
            throw SyncRegularFileReadError.unsafeFile
        }
        guard openedByteCount <= maximumByteCount else {
            throw SyncRegularFileReadError.tooLarge
        }
        if let expectedByteCount = expected?.byteCount {
            guard expectedByteCount >= 0,
                expectedByteCount <= maximumByteCount,
                openedByteCount == expectedByteCount
            else {
                throw SyncRegularFileReadError.expectationMismatch
            }
        }

        do {
            try beforeRead?()
        } catch let error as SyncRegularFileReadError {
            throw error
        } catch {
            throw SyncRegularFileReadError.unavailable
        }

        let readLimit = expected?.byteCount ?? maximumByteCount
        var data = Data()
        data.reserveCapacity(Int(min(openedByteCount, readLimit)))
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let remaining = Int(readLimit) - data.count
            let requestedCount = remaining >= buffer.count ? buffer.count : remaining + 1
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requestedCount)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw SyncRegularFileReadError.unavailable }
            guard count > 0 else { break }
            ioCounters?.record(bytesRead: count)
            guard count <= remaining else {
                if expected?.byteCount != nil {
                    throw SyncRegularFileReadError.expectationMismatch
                }
                throw SyncRegularFileReadError.tooLarge
            }
            data.append(buffer, count: count)
            hasher.update(data: Data(buffer.prefix(count)))
        }

        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0 else {
            throw SyncRegularFileReadError.unavailable
        }
        guard Self.isSafeRegularFile(finalStatus) else {
            throw SyncRegularFileReadError.unsafeFile
        }
        guard Self.identity(of: finalStatus) == Self.identity(of: openedStatus) else {
            throw SyncRegularFileReadError.replaced
        }
        guard let finalByteCount = Self.size(of: finalStatus) else {
            throw SyncRegularFileReadError.unsafeFile
        }
        guard let finalModificationNanoseconds = Self.modificationNanoseconds(
            of: finalStatus
        ) else {
            throw SyncRegularFileReadError.unsafeFile
        }
        guard finalByteCount <= maximumByteCount else {
            throw SyncRegularFileReadError.tooLarge
        }
        guard finalByteCount == openedByteCount,
              finalModificationNanoseconds == openedModificationNanoseconds,
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
            modificationNanoseconds: finalModificationNanoseconds,
            sha256: sha256
        )
    }

    public func observe(
        _ url: URL,
        declaredByteCount: Int64,
        maximumBytes: Int
    ) throws -> SyncRegularFileObservation {
        guard declaredByteCount >= 0,
              let retainedByteLimit = Int(exactly: declaredByteCount)
        else { throw SyncRegularFileReadError.tooLarge }
        let (requiredReadLimit, didOverflow) = retainedByteLimit.addingReportingOverflow(1)
        guard !didOverflow,
              maximumBytes == requiredReadLimit
        else { throw SyncRegularFileReadError.tooLarge }

        var pathStatus = stat()
        guard url.path.withCString({ Darwin.lstat($0, &pathStatus) }) == 0 else {
            throw SyncRegularFileReadError.unavailable
        }
        guard Self.isSafeRegularFile(pathStatus), Self.size(of: pathStatus) != nil else {
            throw SyncRegularFileReadError.unsafeFile
        }
        do { try beforeOpen?() }
        catch let error as SyncRegularFileReadError { throw error }
        catch { throw SyncRegularFileReadError.unavailable }

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
        guard Self.isSafeRegularFile(openedStatus),
              Self.identity(of: openedStatus) == Self.identity(of: pathStatus),
              let openedByteCount = Self.size(of: openedStatus),
              let openedModificationNanoseconds = Self.modificationNanoseconds(of: openedStatus)
        else { throw SyncRegularFileReadError.unsafeFile }

        do { try beforeRead?() }
        catch let error as SyncRegularFileReadError { throw error }
        catch { throw SyncRegularFileReadError.unavailable }

        let readLimit = retainedByteLimit
        var data = Data()
        data.reserveCapacity(Int(min(openedByteCount, declaredByteCount)))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var hasOverrun = false
        while true {
            let remaining = readLimit - data.count
            let requestedCount = remaining >= buffer.count ? buffer.count : remaining + 1
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, requestedCount)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw SyncRegularFileReadError.unavailable }
            guard count > 0 else { break }
            ioCounters?.record(bytesRead: count)
            if count > remaining {
                if remaining > 0 { data.append(buffer, count: remaining) }
                hasOverrun = true
                break
            }
            data.append(buffer, count: count)
        }

        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0 else {
            throw SyncRegularFileReadError.unavailable
        }
        guard Self.isSafeRegularFile(finalStatus),
              Self.identity(of: finalStatus) == Self.identity(of: openedStatus),
              let finalByteCount = Self.size(of: finalStatus),
              let finalModificationNanoseconds = Self.modificationNanoseconds(of: finalStatus)
        else { throw SyncRegularFileReadError.unsafeFile }

        let hasSizeMismatch = hasOverrun
            || openedByteCount != declaredByteCount
            || finalByteCount != declaredByteCount
            || data.count != readLimit
        if !hasSizeMismatch {
            guard finalModificationNanoseconds == openedModificationNanoseconds else {
                throw SyncRegularFileReadError.changed
            }
        }
        let digest = Data(SHA256.hash(data: data))
        return SyncRegularFileObservation(
            data: data,
            device: UInt64(finalStatus.st_dev),
            inode: UInt64(finalStatus.st_ino),
            sha256: digest,
            hasSizeMismatch: hasSizeMismatch
        )
    }

    private static func isSafeRegularFile(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG && status.st_nlink == 1
    }

    private static func size(of status: stat) -> Int64? {
        guard status.st_size >= 0 else { return nil }
        return Int64(status.st_size)
    }

    private static func modificationNanoseconds(of status: stat) -> Int64? {
        let seconds = Int64(status.st_mtimespec.tv_sec)
        let nanoseconds = Int64(status.st_mtimespec.tv_nsec)
        let (scaledSeconds, didOverflowScale) = seconds.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        let (result, didOverflowAdd) = scaledSeconds.addingReportingOverflow(nanoseconds)
        guard !didOverflowScale, !didOverflowAdd else { return nil }
        return result
    }

    private static func identity(of status: stat) -> SyncRegularFileIdentity {
        .init(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }
}
