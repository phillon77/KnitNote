import CryptoKit
import Darwin
import Foundation

/// Implementations must durably insert a new key without replacing an existing
/// UUID. Returning success means the key survives process termination. Production
/// integration supplies Keychain storage; this module never opens live Keychain.
public protocol SyncRecoveryVaultKeychain: Sendable {
    func insert(_ key: Data, for vaultID: UUID) throws
    func key(for vaultID: UUID) throws -> Data?
    func remove(for vaultID: UUID) throws
}

public enum SyncRecoveryVaultError: Error, Equatable {
    case invalidPayload
    case unsafePath
    case unavailable
    case authenticationFailed
    case expired
}

/// Encrypts an already frozen, bounded unsent recovery packet. This is not an
/// account archive or a source inventory: callers own capture and restore policy.
/// A returned ID proves file + directory synchronization and authenticated reopen.
/// It does not authorize deleting plaintext without a matching capture inventory.
public final class SyncRecoveryVault: @unchecked Sendable {
    private let directory: URL
    private let keychain: any SyncRecoveryVaultKeychain
    private let maximumPayloadBytes: Int
    private let synchronize: @Sendable (Int32) throws -> Void
    private let mutex = NSLock()
    private static let lifetime: TimeInterval = 2_592_000
    var recoveryDirectory: URL { directory }

    /// A readable ciphertext left by failed synchronization is not durable proof.
    /// Reestablish file and parent durability before account plaintext cleanup.
    func synchronizedRecoveryPayload(_ id: UUID, account: SyncAccountIdentity, now: Date) throws -> Data {
        mutex.lock(); defer { mutex.unlock() }
        let root = try openDirectory()
        defer { Darwin.close(root) }
        let result = try authenticatedPayload(id, account: account, root: root)
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= result.metadata.createdAt,
              now.timeIntervalSince1970 < result.metadata.expiresAt else { throw SyncRecoveryVaultError.expired }
        let fd = openat(root, Self.name(id), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SyncRecoveryVaultError.unsafePath }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
              opened.st_size >= 0, opened.st_size <= maximumCiphertextBytes else { throw SyncRecoveryVaultError.unsafePath }
        try synchronize(fd)
        try synchronize(root)
        var named = stat()
        guard fstatat(root, Self.name(id), &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino, named.st_nlink == 1 else {
            throw SyncRecoveryVaultError.unsafePath
        }
        guard try authenticatedPayload(id, account: account, root: root).payload == result.payload else {
            throw SyncRecoveryVaultError.authenticationFailed
        }
        return result.payload
    }

    public convenience init(directory: URL, keychain: any SyncRecoveryVaultKeychain,
                maximumPayloadBytes: Int = 100_000_000) {
        self.init(directory: directory, keychain: keychain, maximumPayloadBytes: maximumPayloadBytes,
            synchronize: { descriptor in
                guard fsync(descriptor) == 0 else { throw SyncRecoveryVaultError.unavailable }
            })
    }

    init(directory: URL, keychain: any SyncRecoveryVaultKeychain, maximumPayloadBytes: Int,
         synchronize: @escaping @Sendable (Int32) throws -> Void) {
        self.directory = directory
        self.keychain = keychain
        self.maximumPayloadBytes = maximumPayloadBytes
        self.synchronize = synchronize
    }

    @discardableResult
    public func seal(_ payload: Data, account: SyncAccountIdentity, now: Date) throws -> UUID {
        mutex.lock(); defer { mutex.unlock() }
        guard maximumPayloadBytes >= 0, maximumPayloadBytes <= 100_000_000,
              payload.count <= maximumPayloadBytes, now.timeIntervalSince1970.isFinite,
              now.addingTimeInterval(Self.lifetime).timeIntervalSince1970.isFinite else {
            throw SyncRecoveryVaultError.invalidPayload
        }
        let root = try openDirectory()
        defer { Darwin.close(root) }
        let id = UUID()
        let key = SymmetricKey(size: .bits256)
        let keyBytes = key.withUnsafeBytes { Data($0) }
        let metadata = Metadata(formatVersion: 1, vaultID: id, accountIDHash: account.accountIDHash,
            createdAt: now.timeIntervalSince1970,
            expiresAt: now.timeIntervalSince1970 + Self.lifetime,
            payloadHash: Data(SHA256.hash(data: payload)))
        let authenticated = try Self.encoder().encode(metadata)
        let sealed = try AES.GCM.seal(payload, using: key, authenticating: authenticated)
        guard let ciphertext = sealed.combined else { throw SyncRecoveryVaultError.unavailable }
        let bytes = try Self.encoder().encode(Envelope(metadata: authenticated, ciphertext: ciphertext))
        try keychain.insert(keyBytes, for: id)
        guard try keychain.key(for: id) == keyBytes else { throw SyncRecoveryVaultError.unavailable }
        // A failure may leave encrypted bytes and their key. Never remove either
        // during error recovery: the caller retains plaintext and can retry safely.
        try writeExclusive(bytes, name: Self.name(id), root: root)
        let verified = try authenticatedPayload(id, account: account, root: root)
        guard verified.payload == payload else { throw SyncRecoveryVaultError.authenticationFailed }
        return id
    }

    public func restore(_ id: UUID, account: SyncAccountIdentity, now: Date) throws -> Data {
        mutex.lock(); defer { mutex.unlock() }
        let root = try openDirectory()
        defer { Darwin.close(root) }
        let result = try authenticatedPayload(id, account: account, root: root)
        guard now.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970 >= result.metadata.createdAt,
              now.timeIntervalSince1970 < result.metadata.expiresAt else {
            throw SyncRecoveryVaultError.expired
        }
        return result.payload
    }

    /// Fails closed on foreign, malformed, or unauthenticated vaults. Expiry is
    /// trusted only after authentication; forged dates cannot erase a valid key.
    /// A bounded durable intent makes file/key cleanup retryable. Missing-key
    /// recovery can remove only an intact terminal intent whose ciphertext is
    /// already absent; it never authorizes another ciphertext/key deletion.
    @discardableResult
    public func purgeExpired(account: SyncAccountIdentity, now: Date) throws -> [UUID] {
        mutex.lock(); defer { mutex.unlock() }
        guard now.timeIntervalSince1970.isFinite else { throw SyncRecoveryVaultError.invalidPayload }
        let root = try openDirectory()
        defer { Darwin.close(root) }
        let copy = dup(root)
        guard copy >= 0 else { throw SyncRecoveryVaultError.unavailable }
        guard let stream = fdopendir(copy) else {
            Darwin.close(copy); throw SyncRecoveryVaultError.unavailable
        }
        defer { closedir(stream) }
        var candidates = Set<UUID>()
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw SyncRecoveryVaultError.unavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard let suffix = [".vault", ".purge", ".purge-next"].first(where: { name.hasSuffix($0) }),
                  let id = UUID(uuidString: String(name.dropLast(suffix.count))),
                  name == id.uuidString.lowercased() + suffix else { throw SyncRecoveryVaultError.unsafePath }
            candidates.insert(id)
        }
        // Authenticate the entire inventory before deleting any candidate.
        var expired: [UUID] = []
        for id in candidates.sorted(by: { $0.uuidString < $1.uuidString }) {
            if try purgeCandidate(id, account: account, now: now, root: root) != nil { expired.append(id) }
        }
        for id in expired {
            guard var intent = try purgeCandidate(id, account: account, now: now, root: root) else {
                throw SyncRecoveryVaultError.authenticationFailed
            }
            let intentName = Self.purgeName(id)
            if try !exists(intentName, root: root) {
                try writeExclusive(try Self.encoder().encode(intent), name: intentName, root: root)
            }
            if try exists(Self.name(id), root: root) {
                // An existing readable intent may be left by a failed fsync.
                // Reestablish its durability before removing the sole original.
                try synchronizeIntent(named: intentName, root: root)
                guard unlinkat(root, Self.name(id), 0) == 0 else { throw SyncRecoveryVaultError.unavailable }
                try synchronize(root)
            }
            if intent.phase != .ciphertextRemoved {
                intent = try PurgeIntent(id: id, account: account, ciphertext: intent.ciphertext, phase: .ciphertextRemoved)
                let next = intentName + "-next"
                // This derivative is disposable only after its main intent has
                // authenticated and its exact original ciphertext is removed.
                if try exists(next, root: root) {
                    _ = try readBounded(name: next, root: root, maximumBytes: maximumIntentBytes)
                    guard unlinkat(root, next, 0) == 0 else { throw SyncRecoveryVaultError.unavailable }
                    try synchronize(root)
                }
                try writeExclusive(try Self.encoder().encode(intent), name: next, root: root)
                guard renameat(root, next, root, intentName) == 0 else { throw SyncRecoveryVaultError.unavailable }
                try synchronize(root)
            }
            // A visible terminal rename is not proof that its parent fsync
            // succeeded. This barrier also runs on every terminal-phase retry.
            try synchronizeIntent(named: intentName, root: root)
            if try keychain.key(for: id) != nil { try keychain.remove(for: id) }
            guard try keychain.key(for: id) == nil else { throw SyncRecoveryVaultError.unavailable }
            guard unlinkat(root, intentName, 0) == 0 else { throw SyncRecoveryVaultError.unavailable }
            try synchronize(root)
        }
        return expired
    }

    private struct Metadata: Codable {
        let formatVersion: Int
        let vaultID: UUID
        let accountIDHash: String
        let createdAt: TimeInterval
        let expiresAt: TimeInterval
        let payloadHash: Data
    }

    private struct Envelope: Codable {
        let metadata: Data
        let ciphertext: Data
    }

    private struct PurgeIntent: Codable {
        enum Phase: String, Codable { case prepared, ciphertextRemoved }
        let formatVersion: Int
        let vaultID: UUID
        let accountIDHash: String
        let phase: Phase
        let ciphertext: Data
        let checksum: Data

        init(id: UUID, account: SyncAccountIdentity, ciphertext: Data, phase: Phase) throws {
            formatVersion = 1; vaultID = id; accountIDHash = account.accountIDHash
            self.phase = phase; self.ciphertext = ciphertext
            checksum = Self.digest(id: id, account: account.accountIDHash, ciphertext: ciphertext, phase: phase)
        }

        static func digest(id: UUID, account: String, ciphertext: Data, phase: Phase) -> Data {
            var bytes = Data("KnitNote.VaultPurge.v1\n\(id.uuidString)\n\(account)\n\(phase.rawValue)\n".utf8)
            bytes.append(ciphertext)
            return Data(SHA256.hash(data: bytes))
        }
    }

    private var maximumCiphertextBytes: Int { (min(max(0, maximumPayloadBytes), 100_000_000) + 2) / 3 * 4 + 8192 }
    private var maximumIntentBytes: Int { (maximumCiphertextBytes + 2) / 3 * 4 + 8192 }
    private static func purgeName(_ id: UUID) -> String { id.uuidString.lowercased() + ".purge" }

    private func purgeCandidate(_ id: UUID, account: SyncAccountIdentity, now: Date, root: Int32) throws -> PurgeIntent? {
        let hasCiphertext = try exists(Self.name(id), root: root)
        let hasIntent = try exists(Self.purgeName(id), root: root)
        let hasNext = try exists(Self.purgeName(id) + "-next", root: root)
        if hasIntent {
            let bytes = try readBounded(name: Self.purgeName(id), root: root, maximumBytes: maximumIntentBytes)
            let intent = try JSONDecoder().decode(PurgeIntent.self, from: bytes)
            guard intent.formatVersion == 1, intent.vaultID == id, intent.accountIDHash == account.accountIDHash,
                  intent.ciphertext.count <= maximumCiphertextBytes,
                  intent.checksum == PurgeIntent.digest(id: id, account: account.accountIDHash,
                      ciphertext: intent.ciphertext, phase: intent.phase) else { throw SyncRecoveryVaultError.authenticationFailed }
            if try keychain.key(for: id) == nil {
                guard intent.phase == .ciphertextRemoved, !hasCiphertext, !hasNext else {
                    throw SyncRecoveryVaultError.authenticationFailed
                }
                return intent // Terminal artifact cleanup only, no file/key authority.
            }
            let authenticated = try authenticate(intent.ciphertext, id: id, account: account)
            guard now.timeIntervalSince1970 >= authenticated.metadata.expiresAt,
                  intent.phase != .ciphertextRemoved || !hasCiphertext else { throw SyncRecoveryVaultError.authenticationFailed }
            if hasCiphertext {
                guard try readBounded(name: Self.name(id), root: root, maximumBytes: maximumCiphertextBytes) == intent.ciphertext else {
                    throw SyncRecoveryVaultError.authenticationFailed
                }
            }
            if hasNext {
                guard intent.phase == .prepared else { throw SyncRecoveryVaultError.authenticationFailed }
                _ = try readBounded(name: Self.purgeName(id) + "-next", root: root, maximumBytes: maximumIntentBytes)
            }
            return intent
        }
        guard hasCiphertext, !hasNext else { throw SyncRecoveryVaultError.authenticationFailed }
        let bytes = try readBounded(name: Self.name(id), root: root, maximumBytes: maximumCiphertextBytes)
        let result = try authenticate(bytes, id: id, account: account)
        guard now.timeIntervalSince1970 >= result.metadata.expiresAt else { return nil }
        return try PurgeIntent(id: id, account: account, ciphertext: bytes, phase: .prepared)
    }

    private func exists(_ name: String, root: Int32) throws -> Bool {
        var status = stat()
        if fstatat(root, name, &status, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw SyncRecoveryVaultError.unavailable }
        return false
    }

    private func synchronizeIntent(named name: String, root: Int32) throws {
        let fd = openat(root, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SyncRecoveryVaultError.unsafePath }
        defer { Darwin.close(fd) }
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_nlink == 1, opened.st_size >= 0, opened.st_size <= maximumIntentBytes else {
            throw SyncRecoveryVaultError.unsafePath
        }
        try synchronize(fd)
        try synchronize(root)
        guard fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else {
            throw SyncRecoveryVaultError.unsafePath
        }
    }

    private func authenticatedPayload(_ id: UUID, account: SyncAccountIdentity, root: Int32)
        throws -> (payload: Data, metadata: Metadata) {
        let bytes = try readBounded(name: Self.name(id), root: root, maximumBytes: maximumCiphertextBytes)
        return try authenticate(bytes, id: id, account: account)
    }

    private func authenticate(_ bytes: Data, id: UUID, account: SyncAccountIdentity)
        throws -> (payload: Data, metadata: Metadata) {
        do {
            guard maximumPayloadBytes >= 0, maximumPayloadBytes <= 100_000_000 else {
                throw SyncRecoveryVaultError.invalidPayload
            }
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard envelope.metadata.count <= 4096 else { throw SyncRecoveryVaultError.authenticationFailed }
            let metadata = try JSONDecoder().decode(Metadata.self, from: envelope.metadata)
            guard metadata.formatVersion == 1, metadata.vaultID == id,
                  metadata.accountIDHash == account.accountIDHash,
                  metadata.createdAt.isFinite, metadata.expiresAt.isFinite,
                  metadata.expiresAt - metadata.createdAt == Self.lifetime,
                  metadata.payloadHash.count == 32,
                  let key = try keychain.key(for: id), key.count == 32 else {
                throw SyncRecoveryVaultError.authenticationFailed
            }
            let payload = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext),
                using: SymmetricKey(data: key), authenticating: envelope.metadata)
            guard payload.count <= maximumPayloadBytes,
                  Data(SHA256.hash(data: payload)) == metadata.payloadHash else {
                throw SyncRecoveryVaultError.authenticationFailed
            }
            return (payload, metadata)
        } catch {
            // Do not propagate errors containing payloads, key material, or paths.
            throw SyncRecoveryVaultError.authenticationFailed
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }

    private static func name(_ id: UUID) -> String { id.uuidString.lowercased() + ".vault" }

    /// Existing account-owned directory only. Walk every ancestor without
    /// following symlinks; recognize just macOS's two system path aliases.
    private func openDirectory() throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.path.utf8.contains(0),
              !directory.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw SyncRecoveryVaultError.unsafePath
        }
        var path = directory.path
        if path == "/tmp" || path.hasPrefix("/tmp/") || path == "/var" || path.hasPrefix("/var/") {
            path = "/private" + path
        }
        guard path != "/" else { throw SyncRecoveryVaultError.unsafePath }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SyncRecoveryVaultError.unavailable }
        for component in path.split(separator: "/") {
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            Darwin.close(descriptor)
            guard next >= 0 else { throw SyncRecoveryVaultError.unsafePath }
            descriptor = next
        }
        return descriptor
    }

    private func writeExclusive(_ data: Data, name: String, root: Int32) throws {
        let fd = openat(root, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SyncRecoveryVaultError.unavailable }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SyncRecoveryVaultError.unavailable }
                offset += count
            }
        }
        try synchronize(fd)
        try synchronize(root)
    }

    private func readBounded(name: String, root: Int32, maximumBytes: Int) throws -> Data {
        let fd = openat(root, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SyncRecoveryVaultError.unsafePath }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0, before.st_size <= maximumBytes else {
            throw SyncRecoveryVaultError.unsafePath
        }
        var result = Data(count: Int(before.st_size))
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SyncRecoveryVaultError.unavailable }
                offset += count
            }
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == named.st_dev, before.st_ino == named.st_ino,
              after.st_nlink == 1, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw SyncRecoveryVaultError.unsafePath
        }
        return result
    }
}
