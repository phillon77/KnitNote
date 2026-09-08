import CryptoKit
import Darwin
import Foundation

/// Fault seams act on the real descriptor. They never return ownership.
struct SyncBootstrapOwnedIO {
    var write: (Int32, Data) throws -> Void = SyncBootstrapOwnedPOSIX.write
    var synchronize: (Int32) throws -> Void = SyncBootstrapOwnedPOSIX.synchronize
}

/// Checked descriptor operations. Authorization remains in the private issuer;
/// these primitives neither select an account nor issue an output capability.
enum SyncBootstrapOwnedPOSIX {
    final class Descriptor {
        let value: Int32
        init(_ value: Int32) throws {
            guard value >= 0 else { throw SyncAccountStorageError.unavailable }
            self.value = value
        }
        deinit { Darwin.close(value) }
    }

    static func write(_ fd: Int32, _ bytes: Data) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SyncAccountStorageError.unavailable }
                offset += count
            }
        }
    }
    static func synchronize(_ fd: Int32) throws {
        var result: Int32
        repeat { result = fsync(fd) } while result != 0 && errno == EINTR
        guard result == 0 else { throw SyncAccountStorageError.unavailable }
    }
    static func identity(_ fd: Int32) throws -> BootstrapManifestV3.InstallRootIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw SyncBootstrapError.unsafePath }
        return .init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
    static func directory(_ path: String, from root: Int32) throws -> Descriptor {
        guard path.isEmpty || OwnedBootstrapCodec.relative(path) else { throw SyncBootstrapError.unsafePath }
        var descriptor = try Descriptor(fcntl(root, F_DUPFD_CLOEXEC, 0))
        for name in path.split(separator: "/").map(String.init) {
            let next = try Descriptor(openat(descriptor.value, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
            try match(next.value, name: name, parent: descriptor.value, directory: true)
            descriptor = next
        }
        return descriptor
    }
    static func match(_ fd: Int32, name: String, parent: Int32, directory: Bool) throws {
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              named.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || named.st_nlink == 1 else { throw SyncBootstrapError.unsafePath }
    }
    static func read(_ name: String, parent: Int32, maximumBytes: Int) throws -> Data? {
        var named = stat()
        if fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw SyncBootstrapError.unsafePath }; return nil
        }
        guard named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1,
              named.st_size >= 0, named.st_size <= maximumBytes else { throw SyncBootstrapError.unsafePath }
        let fd = try Descriptor(openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        try match(fd.value, name: name, parent: parent, directory: false)
        var bytes = Data(count: Int(named.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd.value, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SyncBootstrapError.sourceChanged }
                offset += count
            }
        }
        var extra: UInt8 = 0
        guard Darwin.read(fd.value, &extra, 1) == 0 else { throw SyncBootstrapError.sourceChanged }
        try match(fd.value, name: name, parent: parent, directory: false)
        return bytes
    }
    static func proof(_ bytes: Data) -> SyncBootstrapOutputProof {
        .init(byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)))
    }
}
