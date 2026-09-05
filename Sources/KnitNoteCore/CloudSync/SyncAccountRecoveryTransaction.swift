import CryptoKit
import Darwin
import Foundation

/// Caller holds the domain/journal freeze from prepare through cleanup and close.
/// This type owns neither runtime freezing nor restore/replay. All filesystem
/// operations below also hold the storage owner's mutex and account lock.
public final class SyncAccountRecoveryTransaction: @unchecked Sendable {
    public enum Error: Swift.Error, Equatable { case invalidAuthority, changedInventory, unavailable, tooLarge }
    public struct Prepared: Sendable {
        fileprivate let bytes: Data
        fileprivate init(bytes: Data) { self.bytes = bytes }
    }
    public struct Sealed: Equatable, Sendable {
        public let vaultID: UUID
        public let captureID: UUID
        public let packetSHA256: Data
        public let inventoryFingerprint: Data
        fileprivate let envelopeSHA256: Data
        fileprivate init(vaultID: UUID, envelope: Envelope, inventory: SyncAccountRecoveryInventory, bytes: Data) throws {
            self.vaultID = vaultID; captureID = envelope.captureID
            packetSHA256 = envelope.packetSHA256; inventoryFingerprint = inventory.fingerprint
            envelopeSHA256 = Data(SHA256.hash(data: bytes))
        }
    }
    enum Phase: String, Codable { case sealed, cleanupStarted, cleanupComplete }
    struct Selection {
        let receipt: Sealed
        let phase: Phase
        let inventory: SyncAccountRecoveryInventory
    }
    fileprivate struct Envelope: Codable {
        let formatVersion: Int
        let captureID: UUID
        let accountDevice: UInt64
        let accountInode: UInt64
        let temporarySession: String
        let packetSHA256: Data
        let inventory: Data
    }
    private struct Intent: Codable, Equatable {
        let formatVersion: Int
        let accountIDHash: String
        let accountRoot: URL
        let archiveURL: URL
        let journalURL: URL
        let vaultID: UUID
        let captureID: UUID
        let envelopeSHA256: Data
        let packetSHA256: Data
        let inventoryFingerprint: Data
        var phase: Phase
    }
    private struct Authorized {
        let intent: Intent
        let envelope: Envelope
        let inventory: SyncAccountRecoveryInventory
        let receipt: Sealed
    }
    private let storage: SyncAccountStorage
    private let paths: SyncAccountStorage.Paths
    private let account: SyncAccountIdentity
    private let vault: SyncRecoveryVault
    private let journal: FileSyncMutationJournal
    private let maximumBytes: Int
    private let synchronize: @Sendable (Int32) throws -> Void
    private let mutex = NSLock()
    private static let main = "intent.json"
    private static let next = "intent-next.json"

    public convenience init(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths, account: SyncAccountIdentity,
                            vault: SyncRecoveryVault, journal: FileSyncMutationJournal, maximumBytes: Int = 100_000_000) {
        self.init(storage: storage, paths: paths, account: account, vault: vault, journal: journal,
            maximumBytes: maximumBytes, synchronize: { guard fsync($0) == 0 else { throw Error.unavailable } })
    }
    init(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths, account: SyncAccountIdentity,
         vault: SyncRecoveryVault, journal: FileSyncMutationJournal, maximumBytes: Int = 100_000_000,
         synchronize: @escaping @Sendable (Int32) throws -> Void) {
        self.storage = storage; self.paths = paths; self.account = account; self.vault = vault
        self.journal = journal; self.maximumBytes = maximumBytes; self.synchronize = synchronize
    }

    public func prepare(now: Date) throws -> Prepared {
        mutex.lock(); defer { mutex.unlock() }
        try validateConfiguration(now: now)
        // No previous selected recovery can be superseded by another capture.
        // Task 4 must settle its explicit restoration authority first.
        let root = try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes,
            createControl: true) { access -> (UInt64, UInt64) in
            guard let control = access.controlDescriptor, try read(Self.main, at: control) == nil,
                  try read(Self.next, at: control) == nil else { throw Error.invalidAuthority }
            return try identity(access.accountDescriptor)
        }
        let inventory = try SyncAccountRecoveryInventory.capture(storage: storage, paths: paths, account: account,
            journal: journal, archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"), maximumBytes: maximumBytes)
        let envelope = Envelope(formatVersion: 1, captureID: UUID(), accountDevice: root.0, accountInode: root.1,
            temporarySession: ".decrypted-temporary/" + paths.decryptedTemporary.lastPathComponent,
            packetSHA256: Data(SHA256.hash(data: try inventory.packet.encoded(maximumBytes: maximumBytes))),
            inventory: try inventory.encoded(maximumBytes: maximumBytes))
        let bytes = try Self.encode(envelope)
        guard bytes.count <= maximumBytes else { throw Error.tooLarge }
        _ = try decode(bytes)
        return Prepared(bytes: bytes)
    }

    public func seal(_ prepared: Prepared, now: Date) throws -> Sealed {
        mutex.lock(); defer { mutex.unlock() }
        try validateConfiguration(now: now)
        let (envelope, inventory) = try decode(prepared.bytes)
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            guard let control = access.controlDescriptor, try read(Self.main, at: control) == nil,
                  try read(Self.next, at: control) == nil else { throw Error.invalidAuthority }
            try validateRoot(envelope, access: access)
            guard try access.entries() == inventory.entries else { throw Error.changedInventory }
            let id = try vault.seal(prepared.bytes, account: account, now: now)
            guard try vault.synchronizedRecoveryPayload(id, account: account, now: now) == prepared.bytes else { throw Error.invalidAuthority }
            try access.validate()
            guard try access.entries() == inventory.entries else { throw Error.changedInventory }
            let receipt = try Sealed(vaultID: id, envelope: envelope, inventory: inventory, bytes: prepared.bytes)
            let intent = Intent(formatVersion: 1, accountIDHash: account.accountIDHash, accountRoot: paths.accountRoot,
                archiveURL: inventory.archiveURL, journalURL: inventory.journalURL, vaultID: id,
                captureID: receipt.captureID, envelopeSHA256: receipt.envelopeSHA256, packetSHA256: receipt.packetSHA256,
                inventoryFingerprint: receipt.inventoryFingerprint, phase: .sealed)
            try write(try Self.encode(intent), name: Self.main, at: control)
            try barrier(intent, access: access)
            return receipt
        }
    }

    public func cleanup(_ sealed: Sealed) throws {
        mutex.lock(); defer { mutex.unlock() }
        try cleanupLocked(expected: sealed, now: .now)
    }

    /// Returns nil only when no selected intent or derivative exists. Otherwise
    /// authenticate the currently selected capture and finish its cleanup.
    @discardableResult
    public func recoverInterruptedTransition(now: Date) throws -> Sealed? {
        mutex.lock(); defer { mutex.unlock() }
        try validateConfiguration(now: now)
        let current = try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            try authorize(access: access, now: now)?.receipt
        }
        guard let current else { return nil }
        try cleanupLocked(expected: current, now: now)
        return current
    }

    /// Read-only handoff for Task 4. It is an authenticated current selection,
    /// not install/replay authority; Task 4 must establish its own durable phase.
    func authenticatedSelection(now: Date) throws -> Selection? {
        mutex.lock(); defer { mutex.unlock() }
        try validateConfiguration(now: now)
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            guard let value = try authorize(access: access, now: now) else { return nil }
            let remaining = try remainingEntries(value, access: access)
            guard value.intent.phase != .cleanupComplete || remaining.isEmpty else { throw Error.changedInventory }
            return Selection(receipt: value.receipt, phase: value.intent.phase, inventory: value.inventory)
        }
    }

    private func cleanupLocked(expected: Sealed, now: Date) throws {
        try validateConfiguration(now: now)
        try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            guard var authorized = try authorize(access: access, now: now), authorized.receipt == expected,
                  let control = access.controlDescriptor else { throw Error.invalidAuthority }
            let remaining = try remainingEntries(authorized, access: access)
            guard authorized.intent.phase != .cleanupComplete || remaining.isEmpty else { throw Error.changedInventory }
            // Both readable original ciphertext and intent are resynchronized on
            // every entry/retry, including a previously visible terminal rename.
            guard try vault.synchronizedRecoveryPayload(expected.vaultID, account: account, now: now).sha256 == expected.envelopeSHA256 else {
                throw Error.invalidAuthority
            }
            try barrier(authorized.intent, access: access)
            if authorized.intent.phase == .sealed {
                let started = try transition(authorized.intent, to: .cleanupStarted, access: access)
                authorized = Authorized(intent: started, envelope: authorized.envelope,
                    inventory: authorized.inventory, receipt: authorized.receipt)
            }
            for entry in remaining.sorted(by: { $0.relativePath.split(separator: "/").count > $1.relativePath.split(separator: "/").count
                || ($0.relativePath.split(separator: "/").count == $1.relativePath.split(separator: "/").count && $0.relativePath < $1.relativePath) }) {
                // No stale receipt may replace a newer durable intent. A readable
                // prior write is reestablished before each destructive boundary.
                try barrier(authorized.intent, access: access)
                let parent = try openParent(entry.relativePath, root: access.accountDescriptor)
                defer { Darwin.close(parent) }
                let name = String(entry.relativePath.split(separator: "/").last!)
                var status = stat()
                guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
                      UInt64(status.st_dev) == entry.device, UInt64(status.st_ino) == entry.inode,
                      status.st_mode & S_IFMT == (entry.isDirectory ? S_IFDIR : S_IFREG),
                      entry.isDirectory || (status.st_nlink == 1 && status.st_size == entry.byteCount) else { throw Error.changedInventory }
                guard unlinkat(parent, name, entry.isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw Error.unavailable }
                try synchronize(parent)
            }
            guard try remainingEntries(authorized, access: access).isEmpty else { throw Error.changedInventory }
            // A retry can arrive after an unlink but before its parent's fsync.
            // Synchronize all surviving retained directories before completion.
            for entry in try access.entries() where entry.isDirectory {
                let fd = try openDirectory(entry.relativePath, root: access.accountDescriptor)
                defer { Darwin.close(fd) }
                try synchronize(fd)
            }
            try synchronize(access.accountDescriptor)
            if authorized.intent.phase == .cleanupStarted {
                _ = try transition(authorized.intent, to: .cleanupComplete, access: access)
            } else {
                guard try read(Self.next, at: control) == nil else { throw Error.invalidAuthority }
                try barrier(authorized.intent, access: access)
            }
        }
    }

    private func transition(_ intent: Intent, to phase: Phase, access: SyncAccountStorage.RecoveryAccess) throws -> Intent {
        guard let control = access.controlDescriptor else { throw Error.invalidAuthority }
        try barrier(intent, access: access)
        if try read(Self.next, at: control) != nil {
            // A bounded derivative has no authority of its own. Only the
            // authenticated, synchronized main selection permits rebuilding it.
            guard unlinkat(control, Self.next, 0) == 0 else { throw Error.unavailable }
            try synchronize(control)
        }
        var next = intent; next.phase = phase
        try write(try Self.encode(next), name: Self.next, at: control)
        try barrier(intent, access: access)
        guard renameat(control, Self.next, control, Self.main) == 0 else { throw Error.unavailable }
        try synchronize(control)
        try barrier(next, access: access)
        return next
    }

    private func authorize(access: SyncAccountStorage.RecoveryAccess, now: Date) throws -> Authorized? {
        guard let control = access.controlDescriptor else { return nil }
        guard let bytes = try read(Self.main, at: control) else {
            guard try read(Self.next, at: control) == nil else { throw Error.invalidAuthority }
            return nil
        }
        let intent = try JSONDecoder().decode(Intent.self, from: bytes)
        guard intent.formatVersion == 1, intent.accountIDHash == account.accountIDHash, intent.accountRoot == paths.accountRoot,
              intent.archiveURL == paths.workingSet.appendingPathComponent("projects-v1.json"),
              intent.journalURL == journal.recoveryLocation else { throw Error.invalidAuthority }
        let payload = try vault.restore(intent.vaultID, account: account, now: now)
        let (envelope, inventory) = try decode(payload)
        let receipt = try Sealed(vaultID: intent.vaultID, envelope: envelope, inventory: inventory, bytes: payload)
        guard receipt.captureID == intent.captureID, receipt.packetSHA256 == intent.packetSHA256,
              receipt.envelopeSHA256 == intent.envelopeSHA256, receipt.inventoryFingerprint == intent.inventoryFingerprint else { throw Error.invalidAuthority }
        try validateRoot(envelope, access: access)
        return Authorized(intent: intent, envelope: envelope, inventory: inventory, receipt: receipt)
    }

    private func remainingEntries(_ value: Authorized, access: SyncAccountStorage.RecoveryAccess) throws -> [SyncAccountRecoveryInventory.Entry] {
        try access.validate()
        let expected = Dictionary(uniqueKeysWithValues: value.inventory.entries.map { ($0.relativePath, $0) })
        let current = try access.entries()
        let session = ".decrypted-temporary/" + paths.decryptedTemporary.lastPathComponent
        let newSession = session != value.envelope.temporarySession
        let retained = Set(["working-set", "journal", "engine-state", "staging", "quarantine", ".decrypted-temporary", session])
        for entry in current {
            if newSession, entry.relativePath == session {
                guard entry.isDirectory else { throw Error.changedInventory }
            } else {
                guard expected[entry.relativePath] == entry else { throw Error.changedInventory }
            }
        }
        // Storage.open positively reclaims its owned prior session. Only the
        // current empty UUID session can differ; no descendants are exempted.
        guard !newSession || !current.contains(where: { $0.relativePath.hasPrefix(session + "/") }),
              retained.allSatisfy({ name in current.contains(where: { $0.relativePath == name && $0.isDirectory }) }) else { throw Error.changedInventory }
        if value.intent.phase == .sealed {
            let actualNames = Set(current.map(\.relativePath))
            guard expected.keys.allSatisfy({ name in
                actualNames.contains(name) || (newSession && (name == value.envelope.temporarySession
                    || name.hasPrefix(value.envelope.temporarySession + "/")))
            }) else { throw Error.changedInventory }
        }
        return current.filter { !retained.contains($0.relativePath) }
    }

    private func decode(_ bytes: Data) throws -> (Envelope, SyncAccountRecoveryInventory) {
        guard bytes.count <= maximumBytes else { throw Error.tooLarge }
        let value = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard value.formatVersion == 1, value.accountDevice > 0, value.accountInode > 0,
              value.temporarySession.hasPrefix(".decrypted-temporary/"),
              let id = UUID(uuidString: String(value.temporarySession.dropFirst(".decrypted-temporary/".count))),
              value.temporarySession == ".decrypted-temporary/" + id.uuidString.lowercased() else { throw Error.invalidAuthority }
        let inventory = try SyncAccountRecoveryInventory.decodeRecovery(value.inventory, account: account,
            paths: paths, journalURL: journal.recoveryLocation, maximumBytes: maximumBytes)
        guard value.packetSHA256 == Data(SHA256.hash(data: try inventory.packet.encoded(maximumBytes: maximumBytes))),
              inventory.entries.contains(where: { $0.relativePath == value.temporarySession && $0.isDirectory }),
              inventory.entries.filter({ $0.relativePath.hasPrefix(".decrypted-temporary/") }).allSatisfy({
                  $0.relativePath == value.temporarySession || $0.relativePath.hasPrefix(value.temporarySession + "/")
              }) else { throw Error.invalidAuthority }
        return (value, inventory)
    }

    private func validateConfiguration(now: Date) throws {
        guard maximumBytes >= 0, maximumBytes <= 100_000_000 else { throw Error.tooLarge }
        guard now.timeIntervalSince1970.isFinite, vault.recoveryDirectory == paths.vault else { throw Error.invalidAuthority }
    }
    private func validateRoot(_ envelope: Envelope, access: SyncAccountStorage.RecoveryAccess) throws {
        try access.validate()
        let value = try identity(access.accountDescriptor)
        guard value.0 == envelope.accountDevice, value.1 == envelope.accountInode else { throw Error.invalidAuthority }
    }
    private func identity(_ fd: Int32) throws -> (UInt64, UInt64) {
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { throw Error.invalidAuthority }
        return (UInt64(status.st_dev), UInt64(status.st_ino))
    }
    private func barrier(_ intent: Intent, access: SyncAccountStorage.RecoveryAccess) throws {
        guard let control = access.controlDescriptor, let bytes = try read(Self.main, at: control),
              try JSONDecoder().decode(Intent.self, from: bytes) == intent else { throw Error.invalidAuthority }
        let fd = openat(control, Self.main, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Error.unavailable }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1 else { throw Error.invalidAuthority }
        try synchronize(fd)
        try synchronize(control)
        try synchronize(access.accountDescriptor)
        try access.validate()
        var named = stat()
        guard fstatat(control, Self.main, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino, named.st_nlink == 1 else { throw Error.invalidAuthority }
        guard try read(Self.main, at: control) == bytes else { throw Error.invalidAuthority }
    }
    private func read(_ name: String, at root: Int32) throws -> Data? {
        let fd = openat(root, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { guard errno == ENOENT else { throw Error.invalidAuthority }; return nil }
        defer { Darwin.close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
              status.st_size >= 0, status.st_size <= 8192 else { throw Error.invalidAuthority }
        var bytes = Data(count: Int(status.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Error.unavailable }; offset += count
            }
        }
        var named = stat(), after = stat()
        guard fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0, fstat(fd, &after) == 0,
              status.st_dev == named.st_dev, status.st_ino == named.st_ino, after.st_nlink == 1,
              status.st_size == after.st_size, status.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              status.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Error.invalidAuthority }
        return bytes
    }
    private func write(_ bytes: Data, name: String, at root: Int32) throws {
        guard bytes.count <= 8192 else { throw Error.tooLarge }
        let fd = openat(root, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Error.unavailable }
        defer { Darwin.close(fd) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Error.unavailable }; offset += count
            }
        }
        try synchronize(fd); try synchronize(root)
    }
    private func openParent(_ path: String, root: Int32) throws -> Int32 {
        try openDirectory(path.split(separator: "/").dropLast().joined(separator: "/"), root: root)
    }
    private func openDirectory(_ path: String, root: Int32) throws -> Int32 {
        var fd = openat(root, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Error.invalidAuthority }
        for part in path.split(separator: "/") {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw Error.invalidAuthority }; fd = next
        }
        return fd
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private extension Data { var sha256: Data { Data(SHA256.hash(data: self)) } }
