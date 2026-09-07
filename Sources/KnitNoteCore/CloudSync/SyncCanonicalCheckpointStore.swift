import Darwin
import Foundation

/// Account ownership and a writer freeze must be retained by the caller across
/// these calls. This object pins filesystem ancestry; it does not acquire locks.
/// Like SyncAccountStorage, the model is cooperative sandbox actors, not hostile
/// same-user syscall swaps. Every injected boundary is followed by revalidation.
public final class SyncCanonicalCheckpointStore {
    private static let name = "canonical.json"
    private static let temporaryName = ".canonical-next.json"
    private let parentURL: URL
    private let account: SyncAccountIdentity
    private let ancestry: [Handle]
    private let components: [String]
    private let validateOwnership: () throws -> Void
    private let beforeBoundary: (SyncDurableFileWriteBoundary) throws -> Void
    private var parent: Handle { ancestry[ancestry.count - 1] }

    public convenience init(liveRoot: URL, account: SyncAccountIdentity,
                            validateOwnership: @escaping () throws -> Void) throws {
        try self.init(liveRoot: liveRoot, account: account, validateOwnership: validateOwnership, beforeBoundary: { _ in })
    }

    init(liveRoot: URL, account: SyncAccountIdentity, validateOwnership: @escaping () throws -> Void,
         beforeBoundary: @escaping (SyncDurableFileWriteBoundary) throws -> Void) throws {
        try validateOwnership()
        let rootURL = try Self.normalized(liveRoot)
        self.parentURL = rootURL.appendingPathComponent("SyncMetadata", isDirectory: true)
        self.account = account
        self.validateOwnership = validateOwnership
        self.beforeBoundary = beforeBoundary
        let names = rootURL.path.split(separator: "/").map(String.init)
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw SyncAccountStorageError.unavailable }
        var handles = [Handle(root)]
        for name in names { handles.append(try Self.openDirectory(name, parent: handles.last!)) }
        try Self.validateAncestry(handles, names: names)
        try validateOwnership()
        var metadata = stat()
        if fstatat(handles.last!.fd, "SyncMetadata", &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw SyncAccountStorageError.unsafePath }
            guard mkdirat(handles.last!.fd, "SyncMetadata", S_IRWXU) == 0 else {
                throw SyncAccountStorageError.unavailable
            }
        }
        handles.append(try Self.openDirectory("SyncMetadata", parent: handles.last!))
        components = names + ["SyncMetadata"]
        ancestry = handles
        try validateBindings()
        // Also repair initialization interrupted after mkdir, using the same
        // descriptor fsync barrier as account storage's directory operations.
        guard fsync(handles[handles.count - 2].fd) == 0 else { throw SyncAccountStorageError.unavailable }
        try validateBindings()
    }

    public func load() throws -> SyncCanonicalCheckpoint? {
        try validateBindings()
        return try read(Self.name)?.value
    }

    /// Read-only routing before construction: a missing canonical must not
    /// create SyncMetadata and change the Original tree of a rolled-back
    /// bootstrap. This is not activation or permission to publish a domain.
    static func loadIfPresent(liveRoot: URL, account: SyncAccountIdentity,
                              validateOwnership: () throws -> Void) throws -> SyncCanonicalCheckpoint? {
        try validateOwnership()
        let rootURL = try normalized(liveRoot)
        var names = rootURL.path.split(separator: "/").map(String.init)
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw SyncAccountStorageError.unavailable }
        var handles = [Handle(root)]
        for name in names { handles.append(try openDirectory(name, parent: handles.last!)) }
        func validate() throws {
            try validateOwnership()
            try validateAncestry(handles, names: names)
        }
        try validate()
        var metadata = stat()
        if fstatat(handles.last!.fd, "SyncMetadata", &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw SyncAccountStorageError.unsafePath }
            try validate()
            return nil
        }
        handles.append(try openDirectory("SyncMetadata", parent: handles.last!))
        names.append("SyncMetadata")
        try validate()
        func readExisting(_ name: String) throws -> SyncCanonicalCheckpoint? {
            var before = stat()
            if fstatat(handles.last!.fd, name, &before, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw SyncAccountStorageError.unsafePath }
                try validate(); return nil
            }
            guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else { throw SyncAccountStorageError.unsafePath }
            let result = try SyncRegularFileReader().read(rootURL.appendingPathComponent("SyncMetadata/" + name),
                maximumBytes: SyncCanonicalCheckpoint.maximumBytes)
            try validate()
            var after = stat()
            guard fstatat(handles.last!.fd, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                  identity(before) == result.identity, identity(after) == result.identity,
                  after.st_mode & S_IFMT == S_IFREG, after.st_nlink == 1 else { throw SyncAccountStorageError.unsafePath }
            let value = try JSONDecoder().decode(SyncCanonicalCheckpoint.self, from: result.data).validated()
            guard value.accountIDHash == account.accountIDHash else { throw SyncPublicationError.corruptTransaction }
            return value
        }
        let current = try readExisting(name)
        _ = try readExisting(temporaryName)
        try validate()
        return current
    }

    /// Verifies the consumer's named live root is this pinned account store.
    func validateBinding(liveRoot: URL, accountIDHash: String? = nil) throws {
        try validateBindings()
        guard try Self.normalized(liveRoot) == parentURL.deletingLastPathComponent(),
              accountIDHash == nil || accountIDHash == account.accountIDHash else {
            throw SyncPublicationError.corruptTransaction
        }
    }

    /// nil is verified absence, never a wildcard. Exact candidate retries repair
    /// both durability barriers and preserve the original commit ID.
    public func install(_ candidate: SyncCanonicalCheckpoint, replacing predecessorSHA256: Data?) throws {
        try validateBindings()
        guard candidate.accountIDHash == account.accountIDHash,
              predecessorSHA256 == nil || predecessorSHA256?.count == 32 else {
            throw SyncPublicationError.corruptTransaction
        }
        let bytes = try candidate.encoded()
        let current = try read(Self.name)
        let alreadyInstalled = current?.bytes == bytes
        guard alreadyInstalled || current?.sha256 == predecessorSHA256 else {
            throw SyncPublicationError.corruptTransaction
        }
        // One fixed slot bounds crash remnants. Only this exact complete
        // candidate is recoverable; partial, foreign or unrelated bytes remain.
        let abandoned = try read(Self.temporaryName)
        guard abandoned == nil || abandoned?.bytes == bytes else { throw SyncPublicationError.corruptTransaction }

        if alreadyInstalled, let current {
            let installed = try openFile(Self.name, snapshot: current)
            try boundary(.beforeFileSync, current: current)
            try requireFile(installed, name: Self.name, snapshot: current)
            guard fsync(installed.fd) == 0 else { throw SyncAccountStorageError.unavailable }
            if let abandoned {
                try validateBindings()
                try requireSnapshot(current, name: Self.name)
                try requireSnapshot(abandoned, name: Self.temporaryName)
                guard unlinkat(parent.fd, Self.temporaryName, 0) == 0 else { throw SyncAccountStorageError.unavailable }
            }
            try synchronizeParent(candidate: current)
            return
        }

        let temporary: Handle
        var created = false
        if let abandoned {
            temporary = try openFile(Self.temporaryName, snapshot: abandoned)
        } else {
            try validateBindings()
            try requireSnapshot(current, name: Self.name)
            let fd = openat(parent.fd, Self.temporaryName,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw SyncAccountStorageError.unsafePath }
            temporary = Handle(fd)
            created = true
        }
        var renamed = false
        defer {
            // A replaced name, revoked owner or moved parent invalidates our
            // cleanup authority. Abandoned files are retained on failure.
            if created && !renamed { try? removeOwnedTemporary(temporary) }
        }
        if created { try Self.writeAll(bytes, descriptor: temporary.fd) }
        let staged = try read(Self.temporaryName)
        guard let staged, staged.bytes == bytes else { throw SyncPublicationError.corruptTransaction }
        try requireFile(temporary, name: Self.temporaryName, snapshot: staged)
        try boundary(.beforeFileSync, current: current)
        try requireFile(temporary, name: Self.temporaryName, snapshot: staged)
        guard fsync(temporary.fd) == 0 else { throw SyncAccountStorageError.unavailable }
        try boundary(.beforeRename, current: current)
        try requireFile(temporary, name: Self.temporaryName, snapshot: staged)
        guard renameat(parent.fd, Self.temporaryName, parent.fd, Self.name) == 0 else {
            throw SyncAccountStorageError.unavailable
        }
        renamed = true
        try synchronizeParent(candidate: staged)
    }

    private struct Snapshot {
        let value: SyncCanonicalCheckpoint
        let bytes: Data
        let sha256: Data
        let identity: SyncRegularFileIdentity
    }

    private func read(_ name: String) throws -> Snapshot? {
        try validateBindings()
        var status = stat()
        if fstatat(parent.fd, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw SyncAccountStorageError.unsafePath }
            try validateBindings()
            return nil
        }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else { throw SyncAccountStorageError.unsafePath }
        let result = try SyncRegularFileReader().read(parentURL.appendingPathComponent(name),
            maximumBytes: SyncCanonicalCheckpoint.maximumBytes)
        try validateBindings()
        var after = stat()
        guard fstatat(parent.fd, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
              after.st_mode & S_IFMT == S_IFREG, after.st_nlink == 1,
              Self.identity(status) == result.identity, Self.identity(after) == result.identity else {
            throw SyncAccountStorageError.unsafePath
        }
        let value = try JSONDecoder().decode(SyncCanonicalCheckpoint.self, from: result.data).validated()
        guard value.accountIDHash == account.accountIDHash else { throw SyncPublicationError.corruptTransaction }
        try validateBindings()
        return Snapshot(value: value, bytes: result.data, sha256: result.sha256, identity: result.identity)
    }

    private func requireSnapshot(_ expected: Snapshot?, name: String) throws {
        let actual = try read(name)
        guard actual?.identity == expected?.identity, actual?.bytes == expected?.bytes else {
            throw SyncAccountStorageError.unsafePath
        }
    }

    private func openFile(_ name: String, snapshot: Snapshot) throws -> Handle {
        let fd = openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SyncAccountStorageError.unsafePath }
        let handle = Handle(fd)
        try requireFile(handle, name: name, snapshot: snapshot)
        return handle
    }

    private func requireFile(_ handle: Handle, name: String, snapshot: Snapshot) throws {
        var status = stat()
        guard fstat(handle.fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1, Self.identity(status) == snapshot.identity else {
            throw SyncAccountStorageError.unsafePath
        }
        try requireSnapshot(snapshot, name: name)
    }

    private func boundary(_ boundary: SyncDurableFileWriteBoundary, current: Snapshot?) throws {
        try beforeBoundary(boundary)
        try validateBindings()
        try requireSnapshot(current, name: Self.name)
    }

    private func synchronizeParent(candidate: Snapshot) throws {
        try boundary(.beforeDirectorySync, current: candidate)
        guard fsync(parent.fd) == 0 else { throw SyncAccountStorageError.unavailable }
        try requireSnapshot(candidate, name: Self.name)
    }

    private func removeOwnedTemporary(_ handle: Handle) throws {
        try validateBindings()
        var named = stat(), opened = stat()
        guard fstat(handle.fd, &opened) == 0,
              fstatat(parent.fd, Self.temporaryName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1,
              Self.identity(named) == Self.identity(opened) else { throw SyncAccountStorageError.unsafePath }
        guard unlinkat(parent.fd, Self.temporaryName, 0) == 0 else { throw SyncAccountStorageError.unavailable }
        try validateBindings()
        guard fsync(parent.fd) == 0 else { throw SyncAccountStorageError.unavailable }
    }

    private func validateBindings() throws {
        try validateOwnership()
        try Self.validateAncestry(ancestry, names: components)
    }

    private static func validateAncestry(_ handles: [Handle], names: [String]) throws {
        for (offset, name) in names.enumerated() {
            var named = stat(), opened = stat()
            guard fstatat(handles[offset].fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  fstat(handles[offset + 1].fd, &opened) == 0,
                  named.st_mode & S_IFMT == S_IFDIR, opened.st_mode & S_IFMT == S_IFDIR,
                  identity(named) == identity(opened) else { throw SyncAccountStorageError.unsafePath }
        }
    }

    private static func openDirectory(_ name: String, parent: Handle) throws -> Handle {
        let fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SyncAccountStorageError.unsafePath }
        let child = Handle(fd)
        try validateAncestry([parent, child], names: [name])
        return child
    }

    private static func normalized(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), url.query == nil, url.fragment == nil,
              url.host == nil || url.host == "", !url.path.utf8.contains(0),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw SyncAccountStorageError.unsafePath
        }
        var path = url.path
        // Only macOS's system aliases are normalized, as in account storage.
        if path == "/tmp" || path.hasPrefix("/tmp/") || path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        guard path != "/", path.split(separator: "/").count < 128 else { throw SyncAccountStorageError.unsafePath }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func identity(_ status: stat) -> SyncRegularFileIdentity {
        .init(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SyncAccountStorageError.unavailable }
                offset += count
            }
        }
    }

    private final class Handle {
        let fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        deinit { Darwin.close(fd) }
    }
}
