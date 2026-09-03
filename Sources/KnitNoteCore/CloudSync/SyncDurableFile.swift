import Darwin
import Foundation

enum SyncDurableFileError: Error, Equatable {
    case corrupt
    case unsafeFile
    case unavailable
}

enum SyncDurableFileWriteBoundary: CaseIterable, Equatable, Sendable {
    case beforeFileSync
    case beforeRename
    case beforeDirectorySync
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

    static func write(
        _ data: Data,
        to url: URL,
        beforeBoundary: (SyncDurableFileWriteBoundary) throws -> Void = { _ in }
    ) throws {
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
        try beforeBoundary(.beforeFileSync)
        guard Darwin.fsync(descriptor) == 0 else { throw SyncDurableFileError.unavailable }
        try beforeBoundary(.beforeRename)
        guard temporaryURL.path.withCString({ temporaryPath in
            url.path.withCString { destinationPath in
                Darwin.rename(temporaryPath, destinationPath)
            }
        }) == 0 else {
            throw SyncDurableFileError.unavailable
        }
        shouldRemoveTemporary = false
        try synchronizeParentDirectory(of: url, beforeBoundary: beforeBoundary)
    }

    static func createNoClobber(
        _ data: Data,
        at url: URL,
        beforeBoundary: (SyncDurableFileWriteBoundary) throws -> Void = { _ in },
        afterRename: () throws -> Void = {}
    ) throws -> Bool {
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
        try beforeBoundary(.beforeFileSync)
        guard Darwin.fsync(descriptor) == 0 else { throw SyncDurableFileError.unavailable }
        try beforeBoundary(.beforeRename)
        let didRename = temporaryURL.path.withCString { temporaryPath in
            url.path.withCString { destinationPath in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    temporaryPath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if didRename != 0 {
            guard errno == EEXIST else { throw SyncDurableFileError.unavailable }
            try synchronizeParentDirectory(of: url, beforeBoundary: beforeBoundary)
            return false
        }
        shouldRemoveTemporary = false
        try afterRename()
        try synchronizeParentDirectory(of: url, beforeBoundary: beforeBoundary)
        return true
    }

    static func synchronizeParentDirectory(
        of url: URL,
        beforeBoundary: (SyncDurableFileWriteBoundary) throws -> Void = { _ in }
    ) throws {
        try beforeBoundary(.beforeDirectorySync)
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func removeRegularFile(at url: URL) throws {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        if result != 0 {
            guard errno == ENOENT else { throw SyncDurableFileError.unavailable }
            return
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw SyncDurableFileError.unsafeFile
        }
        guard url.path.withCString({ Darwin.unlink($0) }) == 0 else {
            throw SyncDurableFileError.unavailable
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func withExclusiveFileLock<T>(
        for protectedURL: URL,
        _ body: () throws -> T
    ) throws -> T {
        let parent = protectedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let lockURL = parent.appendingPathComponent(
            ".\(protectedURL.lastPathComponent).lock",
            isDirectory: false
        )
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw SyncDurableFileError.unavailable }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            throw SyncDurableFileError.unsafeFile
        }
        guard try setFileLock(descriptor, type: Int16(F_WRLCK)) else {
            throw SyncDurableFileError.unavailable
        }
        defer { _ = try? setFileLock(descriptor, type: Int16(F_UNLCK)) }
        return try body()
    }

    private static func setFileLock(_ descriptor: Int32, type: Int16) throws -> Bool {
        var lock = flock()
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        while true {
            let result = Darwin.fcntl(descriptor, F_SETLKW, &lock)
            if result == 0 { return true }
            if errno == EINTR { continue }
            return false
        }
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

    static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw SyncDurableFileError.unavailable }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw SyncDurableFileError.unsafeFile
        }
        guard Darwin.fsync(descriptor) == 0 else { throw SyncDurableFileError.unavailable }
    }
}
