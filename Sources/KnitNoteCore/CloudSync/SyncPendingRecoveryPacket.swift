import CryptoKit
import Darwin
import Foundation

public enum SyncPendingRecoveryPacketError: Error, Equatable {
    case invalidPacket
    case unsafeSource
    case tooLarge
}

/// Journal-only recovery data, never authority for account cleanup. The caller
/// must stop publishers and freeze domain/journal consumers for the entire capture.
/// Selected non-journal recovery dependencies require the recovery transaction.
public struct SyncPendingRecoveryPacket: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let relativePath: String
        public let byteCount: Int64
        public let sha256: Data
        public let bytes: Data
    }

    public let accountIDHash: String
    public let accountRoot: URL
    public let mutations: [SyncMutation]
    public let files: [File]
    public static let maximumBytes = 100_000_000

    public static func capture(account: SyncAccountIdentity, accountRoot: URL,
                               journal: any SyncMutationJournalProtocol,
                               maximumBytes: Int = Self.maximumBytes) throws -> Self {
        try checkLimit(maximumBytes)
        try validateRoot(accountRoot, hash: account.accountIDHash)
        let root = try openDirectory(accountRoot)
        defer { Darwin.close(root) }
        let mutations = try journal.pending()
        try validateMutations(mutations)
        var sources: [String: SyncAttachmentSource] = [:]
        for source in mutations.compactMap(\.attachmentSource) {
            let relative = try relativePath(source.fileURL, root: accountRoot)
            if let previous = sources[relative] {
                guard previous == source else { throw SyncPendingRecoveryPacketError.invalidPacket }
            }
            sources[relative] = source
        }
        let paths = sources.keys.sorted()
        let placeholders = paths.map { path in
            let source = sources[path]!
            return File(relativePath: path, byteCount: source.byteCount, sha256: source.contentSHA256, bytes: Data())
        }
        let draft = Wire(formatVersion: 1, accountIDHash: account.accountIDHash, accountRoot: accountRoot,
            mutations: mutations, files: placeholders)
        // Preflight all metadata/mutations plus exact base64 expansion before
        // reading even one source. Canonical encoding never escapes base64 '/'.
        var encodedCount = try encoder().encode(draft).count
        guard encodedCount <= maximumBytes else { throw SyncPendingRecoveryPacketError.tooLarge }
        for file in placeholders {
            guard file.byteCount >= 0, file.byteCount <= Int64(maximumBytes) else {
                throw SyncPendingRecoveryPacketError.tooLarge
            }
            let expansion = (Int(file.byteCount) + 2) / 3 * 4
            guard expansion <= maximumBytes - encodedCount else { throw SyncPendingRecoveryPacketError.tooLarge }
            encodedCount += expansion
        }
        var files: [File] = []
        for path in paths {
            let source = sources[path]!
            let parent = try openParent(path, root: root)
            defer { Darwin.close(parent) }
            let read = try SyncRegularFileReader().read(source.fileURL, maximumBytes: Int(source.byteCount),
                expected: .init(byteCount: source.byteCount, sha256: source.contentSHA256))
            var named = stat()
            guard fstatat(parent, source.fileURL.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1,
                  UInt64(named.st_dev) == read.device, UInt64(named.st_ino) == read.inode else {
                throw SyncPendingRecoveryPacketError.unsafeSource
            }
            files.append(.init(relativePath: path, byteCount: read.byteCount, sha256: read.sha256, bytes: read.data))
        }
        let packet = Self(accountIDHash: account.accountIDHash, accountRoot: accountRoot, mutations: mutations, files: files)
        _ = try packet.encoded(maximumBytes: maximumBytes)
        return packet
    }

    public func encoded(maximumBytes: Int = Self.maximumBytes) throws -> Data {
        try Self.checkLimit(maximumBytes)
        try validate()
        let data = try Self.encoder().encode(wire)
        guard data.count <= maximumBytes else { throw SyncPendingRecoveryPacketError.tooLarge }
        return data
    }

    /// Use this boundary for untrusted bytes: Decoder alone cannot inspect the
    /// original byte length (including insignificant whitespace or unknown keys).
    public static func decode(_ data: Data, account: SyncAccountIdentity, accountRoot: URL,
                              maximumBytes: Int = Self.maximumBytes) throws -> Self {
        try checkLimit(maximumBytes)
        guard data.count <= maximumBytes else { throw SyncPendingRecoveryPacketError.tooLarge }
        let packet = try JSONDecoder().decode(Self.self, from: data)
        guard packet.accountIDHash == account.accountIDHash, packet.accountRoot == accountRoot else {
            throw SyncPendingRecoveryPacketError.invalidPacket
        }
        _ = try packet.encoded(maximumBytes: maximumBytes)
        return packet
    }

    public init(from decoder: any Decoder) throws {
        let wire = try Wire(from: decoder)
        guard wire.formatVersion == 1 else { throw SyncPendingRecoveryPacketError.invalidPacket }
        self.init(accountIDHash: wire.accountIDHash, accountRoot: wire.accountRoot,
            mutations: wire.mutations, files: wire.files)
        _ = try encoded()
    }

    public func encode(to encoder: any Encoder) throws {
        _ = try encoded()
        try wire.encode(to: encoder)
    }

    private init(accountIDHash: String, accountRoot: URL, mutations: [SyncMutation], files: [File]) {
        self.accountIDHash = accountIDHash; self.accountRoot = accountRoot
        self.mutations = mutations; self.files = files
    }

    private struct Wire: Codable {
        let formatVersion: Int
        let accountIDHash: String
        let accountRoot: URL
        let mutations: [SyncMutation]
        let files: [File]
    }

    private var wire: Wire {
        .init(formatVersion: 1, accountIDHash: accountIDHash, accountRoot: accountRoot, mutations: mutations, files: files)
    }

    private func validate() throws {
        try Self.validateRoot(accountRoot, hash: accountIDHash)
        try Self.validateMutations(mutations)
        var indexed: [String: File] = [:]
        for file in files {
            try Self.validateRelative(file.relativePath)
            guard indexed[file.relativePath] == nil, file.byteCount == Int64(file.bytes.count),
                  file.sha256.count == 32, file.sha256 == Data(SHA256.hash(data: file.bytes)) else {
                throw SyncPendingRecoveryPacketError.invalidPacket
            }
            indexed[file.relativePath] = file
        }
        var referenced = Set<String>()
        for source in mutations.compactMap(\.attachmentSource) {
            let relative = try Self.relativePath(source.fileURL, root: accountRoot)
            guard let file = indexed[relative], file.byteCount == source.byteCount,
                  file.sha256 == source.contentSHA256 else { throw SyncPendingRecoveryPacketError.invalidPacket }
            referenced.insert(relative)
        }
        guard referenced == Set(indexed.keys) else { throw SyncPendingRecoveryPacketError.invalidPacket }
    }

    private static func validateMutations(_ mutations: [SyncMutation]) throws {
        var ids = Set<UUID>()
        var sources: [URL: (SyncRecordVersion, SyncAttachmentSource)] = [:]
        for mutation in mutations {
            _ = try mutation.validatedForJournalLoad()
            guard ids.insert(mutation.mutationID).inserted else { throw SyncPendingRecoveryPacketError.invalidPacket }
            if let source = mutation.attachmentSource, let version = mutation.savedRecordVersion {
                if let previous = sources[source.fileURL] {
                    guard previous.0 == version, previous.1 == source else { throw SyncPendingRecoveryPacketError.invalidPacket }
                }
                sources[source.fileURL] = (version, source)
            }
        }
    }

    private static func checkLimit(_ count: Int) throws {
        guard count >= 0, count <= maximumBytes else { throw SyncPendingRecoveryPacketError.tooLarge }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }

    private static func validateRoot(_ root: URL, hash: String) throws {
        guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              root.isFileURL, root.path.hasPrefix("/"), root.lastPathComponent == hash,
              root.query == nil, root.fragment == nil, root.host == nil || root.host == "",
              !root.path.utf8.contains(0), root.standardizedFileURL.path == root.path else {
            throw SyncPendingRecoveryPacketError.unsafeSource
        }
        try validateRelative(String(root.path.dropFirst()))
    }

    private static func relativePath(_ url: URL, root: URL) throws -> String {
        guard url.isFileURL, url.path.hasPrefix(root.path + "/"), url.query == nil, url.fragment == nil else {
            throw SyncPendingRecoveryPacketError.unsafeSource
        }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        try validateRelative(relative)
        guard root.appendingPathComponent(relative) == url else { throw SyncPendingRecoveryPacketError.unsafeSource }
        return relative
    }

    private static func validateRelative(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.utf8.contains(0), !parts.isEmpty, parts.count <= 128,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SyncPendingRecoveryPacketError.unsafeSource
        }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw SyncPendingRecoveryPacketError.unsafeSource }
        defer { Darwin.close(root) }
        var path = url.path
        // Descriptor walking recognizes the same macOS system aliases as account
        // storage. Packet and immutable mutation URLs remain exactly unchanged.
        if path == "/tmp" || path.hasPrefix("/tmp/") || path == "/var" || path.hasPrefix("/var/") {
            path = "/private" + path
        }
        return try walk(Array(path.split(separator: "/")).map(String.init), root: root)
    }

    private static func openParent(_ path: String, root: Int32) throws -> Int32 {
        try walk(path.split(separator: "/").dropLast().map(String.init), root: root)
    }

    private static func walk(_ parts: [String], root: Int32) throws -> Int32 {
        var fd = dup(root)
        guard fd >= 0 else { throw SyncPendingRecoveryPacketError.unsafeSource }
        for part in parts {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw SyncPendingRecoveryPacketError.unsafeSource }
            fd = next
        }
        return fd
    }
}
