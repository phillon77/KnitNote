import CryptoKit
import Darwin
import Foundation

public enum SyncAccountStorageError: Error, Equatable {
    case invalidIdentity
    case alreadyOpen
    case accountInUse
    case unsafePath
    case unavailable
}

/// One storage owner per account; consumers share its Paths, not separate opens.
/// Operations are descriptor-relative and never follow user-created symlinks.
/// The model is cooperative sandbox actors, not hostile same-user syscall swaps.
public final class SyncAccountStorage: @unchecked Sendable {
    public struct Paths: Equatable, Sendable {
        public let accountRoot: URL
        public let workingSet: URL
        public let journal: URL
        public var mutationJournalURL: URL {
            workingSet.appendingPathComponent(SyncBootstrapTransaction.defaultJournalRelativePath)
        }
        public let engineState: URL
        /// Persistent upload sources: never removed by open/close.
        public let staging: URL
        public let quarantine: URL
        public let vault: URL
        /// Only reconstructible decrypted copies belong here, never sole unsent
        /// sources. close() removes this session unless the authenticated
        /// recovery owner has retained it for a pending selection publication.
        public let decryptedTemporary: URL
        /// Six standard roots, NOT a complete plaintext inventory. For example,
        /// SyncBootstrapTransaction(liveRoot: workingSet) also owns the sibling
        /// accountRoot/.KnitNote-SyncBootstrap original/staged/backup trees.
        /// Account-transition sealing must inventory these and other account-owned
        /// artifacts before destructive cleanup, including working-set deletions.
        public var persistentRoots: [URL] { [workingSet, journal, engineState, staging, quarantine, vault] }
    }

    private let baseURL: URL
    private let synchronize: @Sendable (Int32) throws -> Void
    private let mutex = NSLock()
    private var session: Session?
    private static let temporaryName = ".decrypted-temporary"
    private static let ownerName = ".owner-v1"
    private static let lockName = ".storage-lock"
    static let recoveryControlName = ".sealed-recovery-v1"

    public convenience init(baseURL: URL) {
        self.init(baseURL: baseURL, synchronize: { guard fsync($0) == 0 else { throw SyncAccountStorageError.unavailable } })
    }

    init(baseURL: URL, synchronize: @escaping @Sendable (Int32) throws -> Void) {
        self.baseURL = baseURL; self.synchronize = synchronize
    }

    // Normal ARC release uses the same validated close path. This is not crash
    // recovery: failure leaves evidence, and a retained capture is never removed.
    deinit { try? close() }

    /// Compatibility gate only: never relocate a journal or reinterpret its
    /// absolute attachment URLs. Bootstrap terminal proofs are checked after
    /// selected recovery has finished, since cleanup may have removed only part
    /// of the original bootstrap tree at an interruption.
    public func validateRuntimeJournalNamespace(paths: Paths, account: SyncAccountIdentity,
                                               validateBootstrap: Bool) throws {
        try withRecoveryInventory(paths: paths, account: account, maximumBytes: 100_000_000) { entries in
            let oldBootstrapJournal = "working-set/SyncMetadata/bootstrap-journal"
            guard !entries.contains(where: {
                let path = $0.relativePath
                return path.hasPrefix("journal/") || path == oldBootstrapJournal
                    || path.hasPrefix(oldBootstrapJournal + ".")
                    || path.hasPrefix("working-set/SyncMetadata/.bootstrap-journal")
            }) else {
                throw SyncAccountStorageError.unsafePath
            }
            if validateBootstrap {
                try SyncBootstrapTransaction.validateTerminalRecovery(account: account, accountRoot: paths.accountRoot,
                    liveRoot: paths.workingSet, journalURL: paths.mutationJournalURL, entries: entries)
            }
        }
    }

    /// Opens an account and recovers abandoned, positively owned temporary copies.
    /// Missing/corrupt ownership markers fail closed without deleting their tree.
    /// Existing legacy global storage is not migrated by this API.
    @discardableResult
    public func open(identity: SyncAccountIdentity) throws -> Paths {
        try open(identity: identity, mode: .legacy)
    }

    /// The callback validates a freshly queried account generation, outside our
    /// mutex. Directory creation, provenance and account ownership are internal.
    public func openForVerifiedAccount(identity: SyncAccountIdentity, validateAccount: () throws -> Void) throws -> Paths {
        try verifiedOpen(identity: identity, mode: .verified, validateAccount: validateAccount)
    }

    /// Never creates the account namespace or infers freshness from its contents.
    public func openExistingAccount(identity: SyncAccountIdentity, validateAccount: () throws -> Void) throws -> Paths {
        try verifiedOpen(identity: identity, mode: .existing, validateAccount: validateAccount)
    }

    private enum OpenMode { case legacy, verified, existing }

    private func verifiedOpen(identity: SyncAccountIdentity, mode: OpenMode, validateAccount: () throws -> Void) throws -> Paths {
        try validateAccount()
        let paths = try open(identity: identity, mode: mode)
        do {
            try withRecoveryOwnership(paths: paths, account: identity, maximumBytes: 100_000_000) { access in
                try validateSourceOpen(paths: paths, identity: identity, access: access)
            }
            try validateAccount()
            return paths
        } catch {
            mutex.lock()
            if session?.paths == paths { session = nil }
            mutex.unlock()
            throw error
        }
    }

    private func open(identity: SyncAccountIdentity, mode: OpenMode) throws -> Paths {
        mutex.lock(); defer { mutex.unlock() }
        guard session == nil else { throw SyncAccountStorageError.alreadyOpen }
        let normalized = try Self.normalized(baseURL)
        let base = try Self.openPath(normalized, create: mode != .existing)
        let allocation = try Self.directory(identity.accountIDHash, in: base, create: mode != .existing)
        let account = allocation.handle
        let root = normalized.appendingPathComponent(identity.accountIDHash, isDirectory: true)
        let preflightRollback: [SyncAccountRecoveryInventory.Entry]?
        if mode != .legacy && !allocation.created {
            // Read-only preflight precedes even creation of a lock or scaffold.
            preflightRollback = try requireExistingEvidence(account, identity: identity, root: root)
        } else { preflightRollback = nil }
        let lock = try Self.accountLock(in: account)
        let names = ["working-set", "journal", "engine-state", "staging", "quarantine", "vault"]
        var workingStatus = stat()
        let workingExists = fstatat(account.fd, "working-set", &workingStatus, AT_SYMLINK_NOFOLLOW) == 0
        guard workingExists || errno == ENOENT else { throw SyncAccountStorageError.unsafePath }
        let missingExistingWorkingSet = !allocation.created && !workingExists
        // Legacy admission cannot reconstruct or authorize an interrupted owned
        // placement. In particular it must not manufacture an empty live root.
        if missingExistingWorkingSet, mode == .legacy,
           try Self.preserveOwnedMissingWorkingSet(account, identity: identity, root: root) {
            throw SyncAccountStorageError.unsafePath
        }
        let missingWorkingSet = missingExistingWorkingSet && mode != .legacy
        for name in names {
            if missingWorkingSet, name == "working-set" { continue }
            _ = try Self.directory(name, in: account, create: mode == .legacy || allocation.created)
        }
        let temporary = try Self.directory(Self.temporaryName, in: account, create: mode == .legacy || allocation.created)
        let marker = Data("KnitNote.SyncAccountStorage.decrypted-temporary.v1\n\(identity.accountIDHash)\n".utf8)
        if temporary.created { try Self.writeOwner(marker, in: temporary.handle) }
        try Self.validateOwner(marker, in: temporary.handle)
        // Metadata-only scan includes bootstrap siblings and other existing
        // account descendants. It does not read persistent file contents.
        try Self.validateTree(account)
        let control: Handle?
        if mode != .legacy {
            var status = stat()
            let exists = fstatat(account.fd, Self.recoveryControlName, &status, AT_SYMLINK_NOFOLLOW) == 0
            guard exists || errno == ENOENT else { throw SyncAccountStorageError.unsafePath }
            control = exists || allocation.created
                ? try Self.directory(Self.recoveryControlName, in: account, create: allocation.created).handle : nil
        } else { control = nil }
        func validateBindings() throws {
            try Self.sameDirectory(Self.openPath(normalized, create: false), base)
            try Self.validateEntry(account, named: identity.accountIDHash, in: base)
            try Self.validateEntry(lock, named: Self.lockName, in: account, regular: true)
            try Self.validateEntry(temporary.handle, named: Self.temporaryName, in: account)
            try Self.validateOwner(marker, in: temporary.handle)
            if let control {
                try Self.validateEntry(control, named: Self.recoveryControlName, in: account)
                try Self.validateRecoveryControl(control)
            }
        }
        let access = RecoveryAccess(accountDescriptor: account.fd, controlDescriptor: control?.fd, entries: {
            var remaining = 100_000_000
            return try Self.recoveryEntries(account, prefix: "", remaining: &remaining)
        }, validate: validateBindings)
        let urls = names.map { root.appendingPathComponent($0, isDirectory: true) }
        // Validate before abandoned temporary copies can be removed.
        let provisional = Paths(accountRoot: root, workingSet: urls[0], journal: urls[1], engineState: urls[2],
            staging: urls[3], quarantine: urls[4], vault: urls[5], decryptedTemporary: root.appendingPathComponent(Self.temporaryName))
        if missingWorkingSet {
            try SyncBootstrapOwnedTransaction.validateMissingWorkingSetRecovery(storage: self, paths: provisional,
                account: identity, access: access, maximumBytes: 100_000_000)
        }
        if mode != .legacy {
            try validateBindings()
            if let preflightRollback {
                // A valid replacement proof is still not the preflight proof.
                // Check after taking ownership and before creating a session.
                guard try !Self.hasRecoveryControlEvidence(in: account),
                      try access.entries() == preflightRollback else { throw SyncAccountStorageError.unsafePath }
            }
            if allocation.created {
                let expected = Set(names + [Self.lockName, Self.temporaryName, Self.recoveryControlName])
                func validateScaffold() throws {
                    try validateBindings()
                    guard Set(try Self.names(in: account)) == expected,
                          try Self.names(in: temporary.handle) == [Self.ownerName] else { throw SyncAccountStorageError.unsafePath }
                    for name in names {
                        guard try Self.names(in: Self.directory(name, in: account, create: false).handle).isEmpty else { throw SyncAccountStorageError.unsafePath }
                    }
                }
                try validateScaffold()
                guard let control, try Self.names(in: control).isEmpty else { throw SyncAccountStorageError.unsafePath }
                let originalEntries = try access.entries()
                var status = stat()
                guard fstat(account.fd, &status) == 0 else { throw SyncAccountStorageError.unsafePath }
                let source = SyncAccountSourceState(authorityID: UUID(), generation: UUID(), accountIDHash: identity.accountIDHash,
                    accountRoot: root, accountDevice: UInt64(status.st_dev), accountInode: UInt64(status.st_ino),
                    archiveURL: urls[0].appendingPathComponent("projects-v1.json"), journalURL: provisional.mutationJournalURL,
                    baselineSHA256: try SyncAccountSourceBaseline.digest(entries: [], accountRoot: root,
                        journalURL: provisional.mutationJournalURL, mutations: [], selectedFiles: [], deletionLedger: nil,
                        pendingMarkerVersions: []), origin: .freshAllocation(allocationID: UUID()))
                // An account sync fault before main exists leaves an ambiguous
                // existing namespace, which every subsequent verified open blocks.
                try synchronize(account.fd)
                try validateScaffold()
                guard try access.entries() == originalEntries else { throw SyncAccountStorageError.unsafePath }
                try SyncAccountRecoveryControlFile(synchronize: synchronize).initializeFresh(source, access: access)
                try synchronize(base.fd)
                try validateScaffold()
                guard try access.entries() == originalEntries else { throw SyncAccountStorageError.unsafePath }
            }
            try validateSourceOpen(paths: provisional, identity: identity, access: access)
        }
        // Exclusive account ownership and the format/hash marker authorize only
        // this dedicated temporary namespace, never persistentRoots.
        // Verified opens preserve abandoned sessions until authenticated account
        // cleanup. A later generation-validation failure cannot authorize deletion.
        if mode == .legacy, try !Self.hasRecoveryControlEvidence(in: account) {
            try Self.removeContents(temporary.handle, excluding: Self.ownerName)
        }
        let name = UUID().uuidString.lowercased()
        let decrypted = try Self.directory(name, in: temporary.handle, create: true).handle
        let paths = Paths(accountRoot: root, workingSet: urls[0], journal: urls[1], engineState: urls[2],
            staging: urls[3], quarantine: urls[4], vault: urls[5],
            decryptedTemporary: root.appendingPathComponent(Self.temporaryName, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true))
        session = Session(base: base, account: account, lock: lock, temporary: temporary.handle,
            decrypted: decrypted, name: name, identity: identity, marker: marker, paths: paths)
        return paths
    }

    private func requireExistingEvidence(_ account: Handle, identity: SyncAccountIdentity,
        root: URL) throws -> [SyncAccountRecoveryInventory.Entry]? {
        func regular(_ path: String, parent: Handle) throws -> Bool {
            var status = stat()
            if fstatat(parent.fd, path, &status, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw SyncAccountStorageError.unsafePath }; return false
            }
            guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else { throw SyncAccountStorageError.unsafePath }
            return true
        }
        // Each path component is opened separately with O_NOFOLLOW.
        for (directory, file) in [("working-set", "projects-v1.json"), (Self.recoveryControlName, "intent.json")] {
            var status = stat()
            if fstatat(account.fd, directory, &status, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw SyncAccountStorageError.unsafePath }; continue
            }
            let parent = try Self.directory(directory, in: account, create: false).handle
            if try regular(file, parent: parent) { return nil }
        }
        // No-control evidence remains distinct: a missing owned live root needs
        // the same exact placement/source proof used again under account lock.
        // Otherwise only the established legacy terminal rollback may admit it.
        guard try !Self.hasRecoveryControlEvidence(in: account) else { throw SyncAccountStorageError.unsafePath }
        var remaining = 100_000_000
        let entries = try Self.recoveryEntries(account, prefix: "", remaining: &remaining)
        let live = root.appendingPathComponent("working-set", isDirectory: true)
        if !entries.contains(where: { $0.relativePath == "working-set" }) {
            let paths = Paths(accountRoot: root, workingSet: live, journal: root.appendingPathComponent("journal"),
                engineState: root.appendingPathComponent("engine-state"), staging: root.appendingPathComponent("staging"),
                quarantine: root.appendingPathComponent("quarantine"), vault: root.appendingPathComponent("vault"),
                decryptedTemporary: root.appendingPathComponent(Self.temporaryName))
            let access = RecoveryAccess(accountDescriptor: account.fd, controlDescriptor: nil, entries: {
                var remaining = 100_000_000
                return try Self.recoveryEntries(account, prefix: "", remaining: &remaining)
            }, validate: {
                try Self.sameDirectory(Self.openPath(root, create: false), account)
                guard try !Self.hasRecoveryControlEvidence(in: account) else { throw SyncAccountStorageError.unsafePath }
            })
            try SyncBootstrapOwnedTransaction.validateMissingWorkingSetRecovery(storage: self, paths: paths,
                account: identity, access: access, maximumBytes: 100_000_000)
        } else {
            guard let evidence = try SyncBootstrapTransaction.terminalRecoveryEvidence(account: identity,
                accountRoot: root, liveRoot: live,
                journalURL: live.appendingPathComponent(SyncBootstrapTransaction.defaultJournalRelativePath), entries: entries),
                  evidence.phase == .rolledBack, case .missingArchive = evidence.sourceProof else {
                throw SyncAccountStorageError.unsafePath
            }
        }
        remaining = 100_000_000
        guard try !Self.hasRecoveryControlEvidence(in: account),
              try Self.recoveryEntries(account, prefix: "", remaining: &remaining) == entries else {
            throw SyncAccountStorageError.unsafePath
        }
        return entries
    }

    /// Negative preservation only, never recovery admission. Keep legacy's
    /// ordinary no-evidence scaffold behavior, but do not create a live root
    /// over a source-control or selected owned-v3 interruption.
    private static func preserveOwnedMissingWorkingSet(_ account: Handle, identity: SyncAccountIdentity,
        root: URL) throws -> Bool {
        if try hasRecoveryControlEvidence(in: account) { return true }
        let live = root.standardizedFileURL.appendingPathComponent("working-set", isDirectory: true)
        let components = [".KnitNote-SyncBootstrap", identity.accountIDHash,
            OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(live.path.utf8)))]
        var parent = account
        for name in components {
            var status = stat()
            if fstatat(parent.fd, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw SyncAccountStorageError.unsafePath }; return false
            }
            parent = try directory(name, in: parent, create: false).handle
        }
        struct Version: Decodable { let version: Int }
        for name in ["active.json", "active-next.json"] {
            guard let bytes = try SyncBootstrapOwnedPOSIX.read(name, parent: parent.fd, maximumBytes: 100_000_000) else { continue }
            let version = try JSONDecoder().decode(Version.self, from: OwnedBootstrapCodec.envelopePayload(bytes)).version
            guard [1, 2, 3].contains(version) else { throw SyncAccountStorageError.unsafePath }
            if version == 3 { return true }
        }
        return false
    }

    private func validateSourceOpen(paths: Paths, identity: SyncAccountIdentity, access: RecoveryAccess) throws {
        let control = SyncAccountRecoveryControlFile(synchronize: synchronize)
        let observation = try control.observe(access: access)
        let originalEntries = try access.entries()
        if !originalEntries.contains(where: { $0.relativePath == "working-set" }) {
            try SyncBootstrapOwnedTransaction.validateMissingWorkingSetRecovery(storage: self, paths: paths,
                account: identity, access: access, maximumBytes: 100_000_000)
        }
        switch observation.state {
        case .absentSource(let source), .sourceSpent(let source, _, _):
            var status = stat()
            guard fstat(access.accountDescriptor, &status) == 0,
                  source.accountIDHash == identity.accountIDHash, source.accountRoot == paths.accountRoot,
                  source.accountDevice == UInt64(status.st_dev), source.accountInode == UInt64(status.st_ino),
                  source.archiveURL == paths.workingSet.appendingPathComponent("projects-v1.json"),
                  source.journalURL == paths.mutationJournalURL else { throw SyncAccountStorageError.unsafePath }
            if case .absentSource = observation.state {
                // Only fresh origin can be validated completely without the
                // later authenticated inventory/dependency integration.
                if case .freshAllocation = source.origin {
                    let entries = try access.entries()
                    let snapshot = try FileSyncMutationJournal(url: paths.mutationJournalURL).recoverySnapshot()
                    guard snapshot.mutations.isEmpty,
                          try access.entries() == entries,
                          try SyncAccountSourceBaseline.digest(entries: entries, accountRoot: paths.accountRoot,
                            journalURL: paths.mutationJournalURL, mutations: [], selectedFiles: [], deletionLedger: nil,
                            pendingMarkerVersions: []) == source.baselineSHA256 else { throw SyncAccountStorageError.unsafePath }
                }
            }
        case .legacySelection(let intent), .selectedRecovery(let intent, _):
            guard intent.accountIDHash == identity.accountIDHash, intent.accountRoot == paths.accountRoot,
                  intent.archiveURL == paths.workingSet.appendingPathComponent("projects-v1.json"),
                  intent.journalURL == paths.mutationJournalURL else { throw SyncAccountStorageError.unsafePath }
        case nil:
            _ = try requireExistingEvidence(Handle(try Self.duplicate(access.accountDescriptor)),
                identity: identity, root: paths.accountRoot)
        }
        try control.synchronize(observation, access: access)
        guard try access.entries() == originalEntries else { throw SyncAccountStorageError.unsafePath }
    }

    private static func duplicate(_ descriptor: Int32) throws -> Int32 {
        let result = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard result >= 0 else { throw SyncAccountStorageError.unavailable }; return result
    }

    /// The coordinator must stop/freeze consumers and durably seal unsent data
    /// BEFORE destroying any persistent decrypted account roots. This API neither
    /// stops runtime stores nor deletes journal/staging/bootstrap/deletion evidence.
    /// A cleanup error retains the session and account lock so close can be retried.
    public func close() throws {
        mutex.lock(); defer { mutex.unlock() }
        guard let session else { return }
        let currentBase = try Self.openPath(Self.normalized(baseURL), create: false)
        try Self.sameDirectory(currentBase, session.base)
        try Self.validateEntry(session.account, named: session.identity.accountIDHash, in: session.base)
        try Self.validateEntry(session.lock, named: Self.lockName, in: session.account, regular: true)
        try Self.validateEntry(session.temporary, named: Self.temporaryName, in: session.account)
        try Self.validateOwner(session.marker, in: session.temporary)
        try Self.validateEntry(session.decrypted, named: session.name, in: session.temporary)
        try Self.validateTree(session.decrypted)
        if session.retainedCapture != nil {
            // Registration precedes any selector publication. Release ownership
            // without destroying a captured tree, including uncertain writes.
            self.session = nil
            return
        }
        try Self.removeContents(session.decrypted)
        guard unlinkat(session.temporary.fd, session.name, AT_REMOVEDIR) == 0 else {
            throw SyncAccountStorageError.unavailable
        }
        // removeContents already fsyncs all plaintext removals. No fallible work
        // follows removal of the now-empty session directory, so an error always
        // leaves a retryable session name and retained ownership lock.
        self.session = nil
    }

    /// Read-only inventory under this owner's mutex and retained account lock.
    /// The caller must also freeze domain/journal writers for the whole call.
    /// These entries are observations, never authorization to remove anything.
    func withRecoveryInventory<T>(paths: Paths, account: SyncAccountIdentity, maximumBytes: Int,
                                  _ body: ([SyncAccountRecoveryInventory.Entry]) throws -> T) throws -> T {
        try withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            let entries = try access.entries()
            let result = try body(entries)
            try access.validate()
            guard try access.entries() == entries else { throw SyncAccountStorageError.unsafePath }
            return result
        }
    }

    /// Internal descriptor scope for the authenticated recovery transaction. The
    /// descriptors and callbacks must not escape this synchronous ownership body.
    struct RecoveryAccess {
        let accountDescriptor: Int32
        let controlDescriptor: Int32?
        let entries: () throws -> [SyncAccountRecoveryInventory.Entry]
        let validate: () throws -> Void
        private let retain: ((SyncAccountRecoveryTransaction.Sealed, String, SyncAccountRecoveryInventory) throws -> Void)?
        private let release: ((SyncAccountRecoveryTransaction.Sealed) throws -> Void)?

        init(accountDescriptor: Int32, controlDescriptor: Int32?,
             entries: @escaping () throws -> [SyncAccountRecoveryInventory.Entry], validate: @escaping () throws -> Void,
             retain: ((SyncAccountRecoveryTransaction.Sealed, String, SyncAccountRecoveryInventory) throws -> Void)? = nil,
             release: ((SyncAccountRecoveryTransaction.Sealed) throws -> Void)? = nil) {
            self.accountDescriptor = accountDescriptor; self.controlDescriptor = controlDescriptor
            self.entries = entries; self.validate = validate; self.retain = retain; self.release = release
        }

        func retainCurrentTemporary(for receipt: SyncAccountRecoveryTransaction.Sealed, capturedPath: String,
                                    inventory: SyncAccountRecoveryInventory) throws {
            guard let retain else { throw SyncAccountStorageError.invalidIdentity }
            try retain(receipt, capturedPath, inventory)
        }

        /// Only the authenticated transaction calls this after its cleanup phase
        /// has been durably established. A reopened, uncaptured session has no pin.
        func releaseCurrentTemporary(for receipt: SyncAccountRecoveryTransaction.Sealed) throws {
            guard let release else { throw SyncAccountStorageError.invalidIdentity }
            try release(receipt)
        }
    }

    func withRecoveryOwnership<T>(paths: Paths, account: SyncAccountIdentity, maximumBytes: Int,
                                   createControl: Bool = false, _ body: (RecoveryAccess) throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        guard let session, session.paths == paths, session.identity == account else {
            throw SyncAccountStorageError.invalidIdentity
        }
        let vault = try Self.directory("vault", in: session.account, create: false).handle
        let ownerDescriptor = openat(session.temporary.fd, Self.ownerName, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard ownerDescriptor >= 0 else { throw SyncAccountStorageError.unsafePath }
        let owner = Handle(ownerDescriptor)
        var controlStatus = stat()
        let controlExists = fstatat(session.account.fd, Self.recoveryControlName, &controlStatus, AT_SYMLINK_NOFOLLOW) == 0
        guard controlExists || errno == ENOENT else { throw SyncAccountStorageError.unsafePath }
        let control = controlExists || createControl
            ? try Self.directory(Self.recoveryControlName, in: session.account, create: createControl).handle : nil
        func validateBindings() throws {
            let currentBase = try Self.openPath(Self.normalized(baseURL), create: false)
            try Self.sameDirectory(currentBase, session.base)
            try Self.validateEntry(session.account, named: account.accountIDHash, in: session.base)
            try Self.validateEntry(session.lock, named: Self.lockName, in: session.account, regular: true)
            try Self.validateEntry(session.temporary, named: Self.temporaryName, in: session.account)
            try Self.validateEntry(owner, named: Self.ownerName, in: session.temporary, regular: true)
            try Self.validateOwner(session.marker, in: session.temporary)
            try Self.validateEntry(session.decrypted, named: session.name, in: session.temporary)
            try Self.validateEntry(vault, named: "vault", in: session.account)
            try Self.validateTree(vault)
            if let control {
                try Self.validateEntry(control, named: Self.recoveryControlName, in: session.account)
                try Self.validateRecoveryControl(control)
            } else {
                var status = stat()
                guard fstatat(session.account.fd, Self.recoveryControlName, &status, AT_SYMLINK_NOFOLLOW) != 0,
                      errno == ENOENT else { throw SyncAccountStorageError.unsafePath }
            }
        }
        try validateBindings()
        let result = try body(.init(accountDescriptor: session.account.fd, controlDescriptor: control?.fd,
            entries: {
                var remaining = maximumBytes
                return try Self.recoveryEntries(session.account, prefix: "", remaining: &remaining)
            }, validate: validateBindings, retain: { receipt, capturedPath, inventory in
                try validateBindings()
                let path = Self.temporaryName + "/" + session.name
                guard capturedPath == path, inventory.account == account, inventory.accountRoot == paths.accountRoot,
                      inventory.fingerprint == receipt.inventoryFingerprint else { throw SyncAccountStorageError.invalidIdentity }
                var status = stat()
                guard fstat(session.decrypted.fd, &status) == 0 else { throw SyncAccountStorageError.unsafePath }
                var remaining = maximumBytes
                let actual = [SyncAccountRecoveryInventory.Entry(relativePath: path, isDirectory: true,
                    byteCount: 0, sha256: Data(), device: UInt64(status.st_dev), inode: UInt64(status.st_ino))]
                    + (try Self.recoveryEntries(session.decrypted, prefix: path + "/", remaining: &remaining))
                let captured = inventory.entries.filter { $0.relativePath == path || $0.relativePath.hasPrefix(path + "/") }
                guard actual.sorted(by: { $0.relativePath < $1.relativePath }) == captured.sorted(by: { $0.relativePath < $1.relativePath }) else {
                    throw SyncAccountStorageError.unsafePath
                }
                try validateBindings()
                self.session?.retainedCapture = receipt
            }, release: { receipt in
                try validateBindings()
                if let retained = self.session?.retainedCapture {
                    guard retained == receipt else { throw SyncAccountStorageError.invalidIdentity }
                    self.session?.retainedCapture = nil
                }
            }))
        // Rewalking a retained descriptor alone cannot prove accountRoot still
        // names it, nor that excluded control/vault paths retain their bindings.
        try validateBindings()
        return result
    }

    private static func validateRecoveryControl(_ control: Handle) throws {
        for name in try names(in: control) {
            guard ["intent.json", "intent-next.json"].contains(name) else { throw SyncAccountStorageError.unsafePath }
            var status = stat()
            guard fstatat(control.fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
                  status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
                  status.st_size >= 0, status.st_size <= 8192 else { throw SyncAccountStorageError.unsafePath }
        }
    }

    /// Local control presence is only a reason to preserve bytes. It grants no
    /// cleanup authority and cannot reveal the encrypted envelope's version.
    private static func hasRecoveryControlEvidence(in account: Handle) throws -> Bool {
        var status = stat()
        if fstatat(account.fd, recoveryControlName, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw SyncAccountStorageError.unsafePath }
            return false
        }
        let control = try directory(recoveryControlName, in: account, create: false).handle
        try validateRecoveryControl(control)
        let present = try !names(in: control).isEmpty
        try validateEntry(control, named: recoveryControlName, in: account)
        return present
    }

    private static func recoveryEntries(_ parent: Handle, prefix: String, remaining: inout Int,
                                        depth: Int = 0) throws -> [SyncAccountRecoveryInventory.Entry] {
        guard depth < 128 else { throw SyncAccountStorageError.unsafePath }
        var result: [SyncAccountRecoveryInventory.Entry] = []
        for name in try names(in: parent).sorted() {
            let path = prefix + name
            // Only format-owned controls and the entire encrypted namespace are
            // excluded. Decrypted session contents and bootstrap siblings remain.
            if path == "vault" || path == lockName || path == recoveryControlName || path == temporaryName + "/" + ownerName { continue }
            var status = stat()
            guard fstatat(parent.fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw SyncAccountStorageError.unsafePath }
            let isDirectory = status.st_mode & S_IFMT == S_IFDIR
            let digest: Data
            if isDirectory {
                digest = Data()
            } else {
                guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else { throw SyncAccountStorageError.unsafePath }
                let descriptor = openat(parent.fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw SyncAccountStorageError.unsafePath }
                let handle = Handle(descriptor)
                try validateEntry(handle, named: name, in: parent, regular: true)
                var hasher = SHA256(), count: Int64 = 0
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let readCount = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if readCount < 0, errno == EINTR { continue }
                    guard readCount >= 0 else { throw SyncAccountStorageError.unavailable }
                    if readCount == 0 { break }
                    count += Int64(readCount)
                    guard count <= status.st_size else { throw SyncAccountStorageError.unsafePath }
                    hasher.update(data: Data(buffer.prefix(readCount)))
                }
                var after = stat()
                guard fstat(descriptor, &after) == 0, count == status.st_size,
                      after.st_size == status.st_size, after.st_dev == status.st_dev, after.st_ino == status.st_ino,
                      after.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
                      after.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec,
                      after.st_ctimespec.tv_sec == status.st_ctimespec.tv_sec,
                      after.st_ctimespec.tv_nsec == status.st_ctimespec.tv_nsec else { throw SyncAccountStorageError.unsafePath }
                try validateEntry(handle, named: name, in: parent, regular: true)
                digest = Data(hasher.finalize())
            }
            let entry = SyncAccountRecoveryInventory.Entry(relativePath: path, isDirectory: isDirectory,
                byteCount: isDirectory ? 0 : Int64(status.st_size), sha256: digest,
                device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
            let cost = try JSONEncoder().encode(entry).count + 1
            guard cost <= remaining else { throw SyncAccountRecoveryInventory.Error.tooLarge }
            remaining -= cost
            result.append(entry)
            if isDirectory {
                result += try recoveryEntries(directory(name, in: parent, create: false).handle,
                    prefix: path + "/", remaining: &remaining, depth: depth + 1)
            }
        }
        return result
    }

    // Captured-session retention is local to the currently held owner. Reopened
    // UUID sessions did not exist in earlier captures and start unregistered.
    private struct Session {
        let base: Handle
        let account: Handle
        let lock: Handle
        let temporary: Handle
        let decrypted: Handle
        let name: String
        let identity: SyncAccountIdentity
        let marker: Data
        let paths: Paths
        var retainedCapture: SyncAccountRecoveryTransaction.Sealed?
    }

    private final class Handle {
        let fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        deinit { Darwin.close(fd) }
    }

    private static func normalized(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw SyncAccountStorageError.unsafePath
        }
        var path = url.standardizedFileURL.path
        // macOS system aliases only; never resolve arbitrary user symlinks.
        if path == "/tmp" || path.hasPrefix("/tmp/") || path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        guard path != "/" else { throw SyncAccountStorageError.unsafePath }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func openPath(_ url: URL, create: Bool) throws -> Handle {
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw SyncAccountStorageError.unavailable }
        var current = Handle(root)
        for component in url.path.split(separator: "/") {
            current = try directory(String(component), in: current, create: create).handle
        }
        return current
    }

    private static func directory(_ name: String, in parent: Handle, create: Bool) throws -> (handle: Handle, created: Bool) {
        var created = false
        var status = stat()
        if fstatat(parent.fd, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT, create else { throw SyncAccountStorageError.unsafePath }
            if mkdirat(parent.fd, name, S_IRWXU) == 0 { created = true }
            else if errno != EEXIST { throw SyncAccountStorageError.unavailable }
            guard fstatat(parent.fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw SyncAccountStorageError.unsafePath }
        }
        guard status.st_mode & S_IFMT == S_IFDIR else { throw SyncAccountStorageError.unsafePath }
        let fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SyncAccountStorageError.unsafePath }
        let handle = Handle(fd)
        try validateEntry(handle, named: name, in: parent)
        if created, fsync(parent.fd) != 0 { throw SyncAccountStorageError.unavailable }
        return (handle, created)
    }

    private static func accountLock(in account: Handle) throws -> Handle {
        let fd = openat(account.fd, lockName, O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SyncAccountStorageError.unsafePath }
        let handle = Handle(fd)
        try validateEntry(handle, named: lockName, in: account, regular: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw SyncAccountStorageError.accountInUse }
            throw SyncAccountStorageError.unavailable
        }
        return handle
    }

    private static func validateEntry(_ handle: Handle, named name: String, in parent: Handle, regular: Bool = false) throws {
        var named = stat(), opened = stat()
        guard fstatat(parent.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(handle.fd, &opened) == 0,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino,
              named.st_mode & S_IFMT == (regular ? S_IFREG : S_IFDIR),
              !regular || named.st_nlink == 1 else { throw SyncAccountStorageError.unsafePath }
    }

    private static func sameDirectory(_ lhs: Handle, _ rhs: Handle) throws {
        var a = stat(), b = stat()
        guard fstat(lhs.fd, &a) == 0, fstat(rhs.fd, &b) == 0,
              a.st_dev == b.st_dev, a.st_ino == b.st_ino else { throw SyncAccountStorageError.unsafePath }
    }

    private static func writeOwner(_ bytes: Data, in parent: Handle) throws {
        let fd = openat(parent.fd, ownerName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SyncAccountStorageError.unsafePath }
        let handle = Handle(fd)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(handle.fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SyncAccountStorageError.unavailable }
                offset += count
            }
        }
        guard fsync(fd) == 0, fsync(parent.fd) == 0 else { throw SyncAccountStorageError.unavailable }
    }

    private static func validateOwner(_ expected: Data, in parent: Handle) throws {
        let fd = openat(parent.fd, ownerName, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SyncAccountStorageError.unsafePath }
        let handle = Handle(fd)
        try validateEntry(handle, named: ownerName, in: parent, regular: true)
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_size == expected.count else { throw SyncAccountStorageError.unsafePath }
        var actual = Data(count: expected.count)
        try actual.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SyncAccountStorageError.unsafePath }
                offset += count
            }
        }
        guard actual == expected else { throw SyncAccountStorageError.unsafePath }
    }

    private static func names(in parent: Handle) throws -> [String] {
        // A fresh open file description avoids sharing readdir offsets with the
        // retained descriptor across validation, deletion, and close retries.
        let fd = openat(parent.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SyncAccountStorageError.unsafePath }
        guard let stream = fdopendir(fd) else { Darwin.close(fd); throw SyncAccountStorageError.unavailable }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw SyncAccountStorageError.unavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw SyncAccountStorageError.unsafePath }
            if name != ".", name != ".." { result.append(name) }
        }
        return result
    }

    private static func validateTree(_ parent: Handle, depth: Int = 0) throws {
        guard depth < 128 else { throw SyncAccountStorageError.unsafePath }
        for name in try names(in: parent) {
            var status = stat()
            guard fstatat(parent.fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw SyncAccountStorageError.unsafePath }
            switch status.st_mode & S_IFMT {
            case S_IFDIR: try validateTree(directory(name, in: parent, create: false).handle, depth: depth + 1)
            case S_IFREG: guard status.st_nlink == 1 else { throw SyncAccountStorageError.unsafePath }
            default: throw SyncAccountStorageError.unsafePath
            }
        }
    }

    private static func removeContents(_ parent: Handle, excluding: String? = nil) throws {
        for name in try names(in: parent) where name != excluding {
            var status = stat()
            guard fstatat(parent.fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw SyncAccountStorageError.unsafePath }
            let isDirectory = status.st_mode & S_IFMT == S_IFDIR
            if isDirectory {
                try removeContents(directory(name, in: parent, create: false).handle)
            } else {
                guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else { throw SyncAccountStorageError.unsafePath }
            }
            guard unlinkat(parent.fd, name, isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw SyncAccountStorageError.unavailable }
        }
        guard fsync(parent.fd) == 0 else { throw SyncAccountStorageError.unavailable }
    }
}
