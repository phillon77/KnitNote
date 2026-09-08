import CryptoKit
import Darwin
import Foundation

/// Caller holds the domain/journal freeze from prepare through cleanup and close.
/// This type does not own runtime freezing. All filesystem
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
    public enum Phase: String, Codable, Sendable { case sealed, cleanupStarted, cleanupComplete, restoreStarted, replayComplete }
    struct Selection {
        let receipt: Sealed
        let phase: Phase
        let inventory: SyncAccountRecoveryInventory
    }
    /// Authenticated observation for runtime lifecycle routing. This value does
    /// not authorize deletion or replay; those methods always reauthenticate.
    public struct LifecycleSnapshot: Sendable {
        public let receipt: Sealed
        public let phase: Phase
        public let account: SyncAccountIdentity
        public let accountRoot: URL
        fileprivate init(selection: Selection, account: SyncAccountIdentity, root: URL) {
            receipt = selection.receipt; phase = selection.phase
            self.account = account; accountRoot = root
        }
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
    private struct SourceControlSnapshot: Codable {
        let mainBytes: Data?
        let nextBytes: Data?
        enum CodingKeys: String, CodingKey { case mainBytes, nextBytes }
        init(_ observation: SyncAccountControlObservation) {
            mainBytes = observation.mainBytes; nextBytes = observation.nextBytes
        }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(mainBytes, forKey: .mainBytes)
            try c.encode(nextBytes, forKey: .nextBytes)
        }
        func observation() throws -> SyncAccountControlObservation {
            try SyncAccountRecoveryControlFile.observation(mainBytes: mainBytes, nextBytes: nextBytes)
        }
    }
    /// Flatten the additional witness without changing the legacy envelope wire.
    private struct EnvelopeV2: Codable {
        let legacy: Envelope
        let sourceControl: SourceControlSnapshot
        enum CodingKeys: String, CodingKey { case sourceControl }
        init(_ legacy: Envelope, sourceControl: SourceControlSnapshot) {
            self.legacy = legacy; self.sourceControl = sourceControl
        }
        init(from decoder: any Decoder) throws {
            legacy = try Envelope(from: decoder)
            sourceControl = try decoder.container(keyedBy: CodingKeys.self).decode(SourceControlSnapshot.self, forKey: .sourceControl)
        }
        func encode(to encoder: any Encoder) throws {
            try legacy.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(sourceControl, forKey: .sourceControl)
        }
    }

    /// Future lifetime accounting through the actual EnvelopeV2 codec. It emits
    /// a size only, never a prepared recovery envelope or root authority.
    static func projectedEnvelopeByteCount(inventoryByteCount: Int, captureID: UUID,
        accountDevice: UInt64, accountInode: UInt64, temporarySession: String,
        control: SyncAccountControlObservation) throws -> Int {
        let empty = Envelope(formatVersion: 2, captureID: captureID, accountDevice: accountDevice,
            accountInode: accountInode, temporarySession: temporarySession,
            packetSHA256: Data(repeating: 0, count: 32), inventory: Data())
        let overhead = try encode(EnvelopeV2(empty, sourceControl: SourceControlSnapshot(control))).count
        return try SyncBootstrapRecoveryBudget.add(overhead,
            SyncBootstrapRecoveryBudget.base64Bytes(inventoryByteCount))
    }
    private typealias Intent = SyncAccountRecoveryIntent
    private struct Authorized {
        let intent: Intent
        let envelope: Envelope
        let inventory: SyncAccountRecoveryInventory
        let receipt: Sealed
        let observation: SyncAccountControlObservation
        let now: Date
    }
    private let storage: SyncAccountStorage
    private let paths: SyncAccountStorage.Paths
    private let account: SyncAccountIdentity
    private let vault: SyncRecoveryVault
    private let journal: FileSyncMutationJournal
    private let maximumBytes: Int
    private let synchronize: @Sendable (Int32) throws -> Void
    private let controlFile: SyncAccountRecoveryControlFile
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
         synchronize: @escaping @Sendable (Int32) throws -> Void,
         controlBoundary: @escaping @Sendable (SyncAccountRecoveryControlFile.Boundary) throws -> Void = { _ in }) {
        self.storage = storage; self.paths = paths; self.account = account; self.vault = vault
        self.journal = journal; self.maximumBytes = maximumBytes; self.synchronize = synchronize
        controlFile = SyncAccountRecoveryControlFile(synchronize: synchronize, boundary: controlBoundary)
    }

    public func prepare(now: Date) throws -> Prepared {
        mutex.lock(); defer { mutex.unlock() }
        try validateConfiguration(now: now)
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes,
            createControl: true) { access in
            let observation = try controlFile.observe(access: access)
            switch observation.state {
            case nil, .absentSource: break
            default: throw Error.invalidAuthority
            }
            try controlFile.synchronize(observation, access: access)
            let root = try identity(access.accountDescriptor)
            let entries = try access.entries()
            let legacy = observation.state == nil && entries.contains {
                $0.relativePath == "working-set/projects-v1.json" && !$0.isDirectory
            }
            let captureID = UUID()
            let session = ".decrypted-temporary/" + paths.decryptedTemporary.lastPathComponent
            let empty = Envelope(formatVersion: legacy ? 1 : 2, captureID: captureID, accountDevice: root.0,
                accountInode: root.1, temporarySession: session, packetSHA256: Data(repeating: 0, count: 32), inventory: Data())
            let snapshot = SourceControlSnapshot(observation)
            let budget: Int
            if legacy { budget = maximumBytes }
            else {
                let overhead = try Self.encode(EnvelopeV2(empty, sourceControl: snapshot)).count
                budget = try SyncBootstrapRecoveryBudget.inventoryAllowance(
                    maximumEnvelopeBytes: maximumBytes, fixedOverheadBytes: overhead)
            }
            let inventory = try SyncAccountRecoveryInventory.capture(access: access, paths: paths, account: account,
                journal: journal, archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"),
                control: observation, maximumBytes: budget)
            guard try controlFile.observe(access: access) == observation else { throw Error.changedInventory }
            let envelope = Envelope(formatVersion: empty.formatVersion, captureID: captureID, accountDevice: root.0,
                accountInode: root.1, temporarySession: session,
                packetSHA256: Data(SHA256.hash(data: try inventory.packet.encoded(maximumBytes: maximumBytes))),
                inventory: try inventory.encoded(maximumBytes: budget))
            let bytes = try legacy ? Self.encode(envelope) : Self.encode(EnvelopeV2(envelope, sourceControl: snapshot))
            _ = try decode(bytes)
            try validateRoot(envelope, access: access)
            guard try access.entries() == inventory.entries, try controlFile.observe(access: access) == observation else { throw Error.changedInventory }
            return Prepared(bytes: bytes)
        }
    }

    public func seal(_ prepared: Prepared, now: Date) throws -> Sealed {
        mutex.lock(); defer { mutex.unlock() }
        try validateConfiguration(now: now)
        let (envelope, inventory, snapshot) = try decode(prepared.bytes)
        let captured = try snapshot?.observation() ?? .init(mainBytes: nil, nextBytes: nil, state: nil)
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            guard let control = access.controlDescriptor, try controlFile.observe(access: access) == captured else { throw Error.changedInventory }
            try validateRoot(envelope, access: access)
            guard try access.entries() == inventory.entries, try controlFile.observe(access: access) == captured else { throw Error.changedInventory }
            let id = try vault.seal(prepared.bytes, account: account, now: now)
            guard try vault.synchronizedRecoveryPayload(id, account: account, now: now) == prepared.bytes else { throw Error.invalidAuthority }
            try access.validate()
            guard try access.entries() == inventory.entries else { throw Error.changedInventory }
            let receipt = try Sealed(vaultID: id, envelope: envelope, inventory: inventory, bytes: prepared.bytes)
            let intent = Intent(formatVersion: 1, accountIDHash: account.accountIDHash, accountRoot: paths.accountRoot,
                archiveURL: inventory.archiveURL, journalURL: inventory.journalURL, vaultID: id,
                captureID: receipt.captureID, envelopeSHA256: receipt.envelopeSHA256, packetSHA256: receipt.packetSHA256,
                inventoryFingerprint: receipt.inventoryFingerprint, phase: .sealed)
            let validateSource = {
                try self.validateRoot(envelope, access: access)
                guard try access.entries() == inventory.entries,
                      try self.vault.synchronizedRecoveryPayload(id, account: self.account, now: now) == prepared.bytes else { throw Error.changedInventory }
                guard try access.entries() == inventory.entries else { throw Error.changedInventory }
            }
            try validateSource()
            guard try controlFile.observe(access: access) == captured else { throw Error.changedInventory }
            try access.retainCurrentTemporary(for: receipt, capturedPath: envelope.temporarySession, inventory: inventory)
            if let main = captured.mainBytes {
                let predecessor = Data(SHA256.hash(data: main))
                _ = try controlFile.replace(captured, with: .selectedRecovery(intent, predecessorSHA256: predecessor),
                    access: access, validateSource: validateSource)
            } else {
                try write(try Self.encode(intent), name: Self.main, at: control)
                try legacyBarrier(intent, access: access)
            }
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
            guard let value = try authorize(access: access, now: now) else { return nil as Sealed? }
            guard value.intent.phase == .sealed || value.intent.phase == .cleanupStarted || value.intent.phase == .cleanupComplete else { throw Error.invalidAuthority }
            return value.receipt
        }
        guard let current else { return nil }
        try cleanupLocked(expected: current, now: now)
        return current
    }

    /// Read-only runtime handoff. Install/replay must still enter restore(),
    /// which establishes its durable phase under account ownership.
    func authenticatedSelection(now: Date) throws -> Selection? {
        mutex.lock(); defer { mutex.unlock() }
        try validateConfiguration(now: now)
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            guard let value = try authorize(access: access, now: now) else { return nil }
            if value.intent.phase == .restoreStarted || value.intent.phase == .replayComplete {
                try validateRestored(value, access: access, complete: value.intent.phase == .replayComplete)
            } else {
                let remaining = try remainingEntries(value, access: access)
                guard value.intent.phase != .cleanupComplete || remaining.isEmpty else { throw Error.changedInventory }
            }
            return Selection(receipt: value.receipt, phase: value.intent.phase, inventory: value.inventory)
        }
    }

    public func lifecycleSnapshot(now: Date) throws -> LifecycleSnapshot? {
        try authenticatedSelection(now: now).map { LifecycleSnapshot(selection: $0, account: account, root: paths.accountRoot) }
    }

    func sourceState(now: Date) throws -> SyncAccountSourceState? {
        mutex.lock(); defer { mutex.unlock() }
        try validateConfiguration(now: now)
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            let observation = try controlFile.observe(access: access)
            switch observation.state {
            case .absentSource:
                let source = try validateSourceState(observation, access: access)
                try controlFile.synchronize(observation, access: access)
                guard try validateSourceState(observation, access: access) == source else { throw Error.changedInventory }
                return source
            case nil, .legacySelection, .selectedRecovery, .sourceSpent: return nil
            }
        }
    }

    private func validateSourceState(_ observation: SyncAccountControlObservation,
                                     access: SyncAccountStorage.RecoveryAccess) throws -> SyncAccountSourceState {
        guard case .absentSource(let source) = observation.state else { throw Error.invalidAuthority }
        let inventory = try SyncAccountRecoveryInventory.capture(access: access, paths: paths, account: account,
            journal: journal, archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"),
            control: observation, maximumBytes: maximumBytes)
        guard case .absent(let evidence) = inventory.sourceAuthority, evidence.state == source else { throw Error.invalidAuthority }
        return source
    }

    /// Durable absence only. It proves neither replay nor journal acknowledgement.
    public func synchronizeSelectionAbsence(now: Date) throws {
        mutex.lock(); defer { mutex.unlock() }
        try validateConfiguration(now: now)
        try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) {
            try synchronizeAbsence($0)
        }
    }

    private func synchronizeAbsence(_ access: SyncAccountStorage.RecoveryAccess) throws {
        let observation = try controlFile.observe(access: access)
        switch observation.state {
        case .absentSource(let source), .sourceSpent(let source, _, _):
            try validateSourceBinding(source, access: access)
            try controlFile.synchronize(observation, access: access)
            try validateSourceBinding(source, access: access)
        case nil:
            try controlFile.synchronize(observation, access: access)
        case .legacySelection, .selectedRecovery: throw Error.invalidAuthority
        }
    }

    private func validateSourceBinding(_ source: SyncAccountSourceState,
                                       access: SyncAccountStorage.RecoveryAccess) throws {
        try access.validate()
        try SyncAccountRecoveryControlFile.validate(source)
        let root = try identity(access.accountDescriptor)
        guard source.accountIDHash == account.accountIDHash, source.accountRoot == paths.accountRoot,
              source.accountDevice == root.0, source.accountInode == root.1,
              source.archiveURL == paths.workingSet.appendingPathComponent("projects-v1.json"),
              source.journalURL == journal.recoveryLocation, source.journalURL == paths.mutationJournalURL else { throw Error.invalidAuthority }
    }

    /// Restores only the current authenticated selection into its original owned
    /// account. The caller keeps all domain/journal consumers frozen until it
    /// consumes the completed selection. Repeating completion only verifies it.
    public func restore(vaultID: UUID, now: Date) throws {
        mutex.lock(); defer { mutex.unlock() }
        try validateConfiguration(now: now)
        try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            guard var value = try authorize(access: access, now: now), value.receipt.vaultID == vaultID else { throw Error.invalidAuthority }
            if value.intent.phase == .cleanupComplete {
                guard try remainingEntries(value, access: access).isEmpty else { throw Error.changedInventory }
                guard try vault.synchronizedRecoveryPayload(vaultID, account: account, now: now).sha256 == value.receipt.envelopeSHA256 else { throw Error.invalidAuthority }
                value = try transition(value, to: .restoreStarted, access: access)
            }
            guard value.intent.phase == .restoreStarted || value.intent.phase == .replayComplete else { throw Error.invalidAuthority }
            try validateRestored(value, access: access, complete: value.intent.phase == .replayComplete)
            try barrier(value, access: access)
            if value.intent.phase == .replayComplete {
                if value.observation.nextBytes != nil { _ = try transition(value, to: .replayComplete, access: access) }
                return
            }
            let files = try restoredFiles(value.inventory)
            // Dependencies are validated with the authenticated packet before
            // the first file is installed. The manifest is installed last.
            let manifest = "working-set/.sync-deletions/ledger.json"
            for file in files where file.relativePath != manifest {
                try barrier(value, access: access)
                try install(file, access: access)
            }
            try validateRestored(value, access: access, complete: false)
            try barrier(value, access: access)
            _ = try journal.validateRecoveryReplay(value.inventory.packet.mutations, maximumBytes: maximumBytes)
            try journal.enqueue(value.inventory.packet.mutations)
            for file in files where file.relativePath == manifest {
                try barrier(value, access: access)
                try install(file, access: access)
            }
            try validateRestored(value, access: access, complete: true)
            // Reestablish every restored file/directory, including artifacts
            // readable after a failed journal append or install fsync.
            for entry in try access.entries() {
                if entry.isDirectory {
                    let fd = try openDirectory(entry.relativePath, root: access.accountDescriptor)
                    defer { Darwin.close(fd) }; try synchronize(fd)
                } else { try synchronizeRestoredFile(entry.relativePath, access: access) }
            }
            try synchronize(access.accountDescriptor)
            try validateRestored(value, access: access, complete: true)
            _ = try transition(value, to: .replayComplete, access: access)
        }
    }

    /// true means this exact completed selection was verified and consumed.
    /// false means there is durably no selection; it is NOT proof of replay or
    /// acknowledgement. A matching published source is resynchronized on retry.
    /// Call under freeze before allowing new account data or a later capture.
    @discardableResult
    public func consumeRestoredSelection(vaultID: UUID, now: Date) throws -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        try validateConfiguration(now: now)
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            let observation = try controlFile.observe(access: access)
            switch observation.state {
            case .absentSource(let source):
                guard case .restoredSelection(let recordedVault, _, _, _, _) = source.origin,
                      recordedVault == vaultID else { throw Error.invalidAuthority }
                // Origin is immutable current-local provenance. The old vault
                // may have expired or lost its key after the durable handoff.
                guard try validateSourceState(observation, access: access) == source else { throw Error.changedInventory }
                try controlFile.synchronize(observation, access: access)
                guard try validateSourceState(observation, access: access) == source else { throw Error.changedInventory }
                return true
            case .sourceSpent: throw Error.invalidAuthority
            case nil:
                try synchronizeAbsence(access)
                return false
            case .legacySelection, .selectedRecovery: break
            }
            guard var value = try authorize(access: access, now: now),
                  value.receipt.vaultID == vaultID, value.intent.phase == .replayComplete else { throw Error.invalidAuthority }
            try validateRestored(value, access: access, complete: true)
            try barrier(value, access: access)
            if case .legacySelection = value.observation.state, value.observation.nextBytes != nil {
                value = try transition(value, to: .replayComplete, access: access)
            }
            let entries = try access.entries()
            for entry in entries {
                if entry.isDirectory {
                    let fd = try openDirectory(entry.relativePath, root: access.accountDescriptor)
                    defer { Darwin.close(fd) }; try synchronize(fd)
                } else { try synchronizeRestoredFile(entry.relativePath, access: access) }
            }
            try synchronize(access.accountDescriptor)
            try validateRestored(value, access: access, complete: true)
            try barrier(value, access: access)
            let root = try identity(access.accountDescriptor)
            let baseline = try restoredSourceBaseline(value, entries: entries, access: access)
            let source = SyncAccountSourceState(authorityID: UUID(), generation: UUID(),
                accountIDHash: account.accountIDHash, accountRoot: paths.accountRoot,
                accountDevice: root.0, accountInode: root.1, archiveURL: value.inventory.archiveURL,
                journalURL: value.inventory.journalURL, baselineSHA256: baseline,
                origin: .restoredSelection(vaultID: value.receipt.vaultID, captureID: value.receipt.captureID,
                    envelopeSHA256: value.receipt.envelopeSHA256, packetSHA256: value.receipt.packetSHA256,
                    deletionSHA256: value.inventory.deletionLedger.map { Data(SHA256.hash(data: $0)) }))
            try validateSourceBinding(source, access: access)
            let selected = value
            _ = try controlFile.replace(value.observation, with: .absentSource(source), access: access) {
                try self.validateSourceBinding(source, access: access)
                try self.validateSelectedPayload(selected, access: access)
                try self.validateRestored(selected, access: access, complete: true)
                guard try self.restoredSourceBaseline(selected, entries: entries, access: access) == baseline else { throw Error.changedInventory }
            }
            return true
        }
    }

    private func restoredSourceBaseline(_ value: Authorized, entries: [SyncAccountRecoveryInventory.Entry],
                                         access: SyncAccountStorage.RecoveryAccess) throws -> Data {
        guard try access.entries() == entries else { throw Error.changedInventory }
        let snapshot = try journal.recoverySnapshot(accountRoot: paths.accountRoot, inventoryEntries: entries, maximumBytes: maximumBytes)
        guard snapshot.url == value.inventory.journalURL, snapshot.mutations == value.inventory.packet.mutations else { throw Error.changedInventory }
        let export: SyncDeletionLedger.RecoveryExport?
        if entries.contains(where: { $0.relativePath == "working-set/.sync-deletions" && $0.isDirectory }) {
            export = try SyncDeletionLedger.recoveryExport(archiveURL: value.inventory.archiveURL,
                pending: snapshot.mutations, maximumBytes: maximumBytes)
        } else { export = nil }
        let baseline = try SyncAccountSourceBaseline.digest(entries: entries, accountRoot: paths.accountRoot,
            journalURL: snapshot.url, mutations: snapshot.mutations,
            selectedFiles: value.inventory.packet.files + value.inventory.deletionFiles,
            deletionLedger: export?.manifest, pendingMarkerVersions: export?.pendingMarkerVersions ?? [])
        guard try access.entries() == entries else { throw Error.changedInventory }
        return baseline
    }

    private func restoredFiles(_ inventory: SyncAccountRecoveryInventory) throws -> [SyncPendingRecoveryPacket.File] {
        var files: [String: SyncPendingRecoveryPacket.File] = [:]
        var selected = inventory.packet.files + inventory.deletionFiles
        if let manifest = inventory.deletionLedger {
            selected.append(try SyncDeletionLedger.recoveryManifestFile(manifest, archiveURL: inventory.archiveURL,
                pending: inventory.packet.mutations, files: inventory.deletionFiles, markers: inventory.pendingMarkerVersions))
        }
        for file in selected {
            if let prior = files[file.relativePath] { guard prior == file else { throw Error.invalidAuthority } }
            files[file.relativePath] = file
        }
        return files.values.sorted { $0.relativePath < $1.relativePath }
    }

    private func validateRestored(_ value: Authorized, access: SyncAccountStorage.RecoveryAccess, complete: Bool) throws {
        try access.validate()
        let files = Dictionary(uniqueKeysWithValues: try restoredFiles(value.inventory).map { ($0.relativePath, $0) })
        let replay = try journal.validateRecoveryReplay(value.inventory.packet.mutations, maximumBytes: maximumBytes)
        let segment = value.inventory.journalURL.appendingPathExtension("segment")
        let segmentPath = String(segment.path.dropFirst(paths.accountRoot.path.count + 1))
        guard paths.accountRoot.appendingPathComponent(segmentPath) == segment, files[segmentPath] == nil else { throw Error.invalidAuthority }
        let session = ".decrypted-temporary/" + paths.decryptedTemporary.lastPathComponent
        let retained = Set(["working-set", "journal", "engine-state", "staging", "quarantine", ".decrypted-temporary", session])
        let original = Dictionary(uniqueKeysWithValues: value.inventory.entries.map { ($0.relativePath, $0) })
        var directories = retained
        for path in Array(files.keys) + [segmentPath] {
            var parts = path.split(separator: "/"); parts.removeLast()
            while !parts.isEmpty { directories.insert(parts.joined(separator: "/")); parts.removeLast() }
        }
        let current = try access.entries()
        let inert = Set(try inertTemporaryEntries(value, current: current, access: access).map(\.relativePath))
        for entry in current {
            if inert.contains(entry.relativePath) { continue }
            if entry.isDirectory {
                guard directories.contains(entry.relativePath) else { throw Error.changedInventory }
                if retained.contains(entry.relativePath), entry.relativePath != session || session == value.envelope.temporarySession {
                    guard original[entry.relativePath] == entry else { throw Error.changedInventory }
                }
            } else if let file = files[entry.relativePath] {
                guard entry.byteCount == file.byteCount, entry.sha256 == file.sha256 else { throw Error.changedInventory }
            } else {
                guard entry.relativePath == segmentPath, replay.segment == segment else { throw Error.changedInventory }
            }
        }
        guard retained.allSatisfy({ name in current.contains { $0.relativePath == name && $0.isDirectory } }),
              !current.contains(where: { $0.relativePath.hasPrefix(session + "/") }) else { throw Error.changedInventory }
        if complete {
            guard replay.complete, files.keys.allSatisfy({ name in current.contains { $0.relativePath == name && !$0.isDirectory } }) else { throw Error.changedInventory }
        }
    }

    private func install(_ file: SyncPendingRecoveryPacket.File, access: SyncAccountStorage.RecoveryAccess) throws {
        var parent = openat(access.accountDescriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Error.unavailable }
        defer { Darwin.close(parent) }
        let parts = file.relativePath.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            if mkdirat(parent, part, S_IRWXU) != 0, errno != EEXIST { throw Error.unavailable }
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Error.invalidAuthority }
            do { try synchronize(parent) } catch { Darwin.close(next); throw error }
            Darwin.close(parent); parent = next
        }
        let name = parts.last!
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        if fd < 0 {
            guard errno == EEXIST else { throw Error.unavailable }
            let result = try SyncRegularFileReader().read(paths.accountRoot.appendingPathComponent(file.relativePath),
                maximumBytes: file.bytes.count, expected: .init(byteCount: file.byteCount, sha256: file.sha256))
            guard result.data == file.bytes else { throw Error.changedInventory }
        } else {
            defer { Darwin.close(fd) }
            try file.bytes.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Error.unavailable }; offset += count
                }
            }
            try synchronize(fd)
        }
        try synchronizeRestoredFile(file.relativePath, access: access)
        try synchronize(parent)
    }

    private func synchronizeRestoredFile(_ path: String, access: SyncAccountStorage.RecoveryAccess) throws {
        let parent = try openParent(path, root: access.accountDescriptor); defer { Darwin.close(parent) }
        let name = String(path.split(separator: "/").last!)
        let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Error.unavailable }; defer { Darwin.close(fd) }
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1 else { throw Error.changedInventory }
        try synchronize(fd); try synchronize(parent)
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino, named.st_nlink == 1 else { throw Error.changedInventory }
        try access.validate()
    }

    private func cleanupLocked(expected: Sealed, now: Date) throws {
        try validateConfiguration(now: now)
        try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            guard var authorized = try authorize(access: access, now: now), authorized.receipt == expected,
                  let control = access.controlDescriptor else { throw Error.invalidAuthority }
            guard authorized.intent.phase == .sealed || authorized.intent.phase == .cleanupStarted || authorized.intent.phase == .cleanupComplete else { throw Error.invalidAuthority }
            let remaining = try remainingEntries(authorized, access: access)
            guard authorized.intent.phase != .cleanupComplete || remaining.isEmpty else { throw Error.changedInventory }
            // Both readable original ciphertext and intent are resynchronized on
            // every entry/retry, including a previously visible terminal rename.
            guard try vault.synchronizedRecoveryPayload(expected.vaultID, account: account, now: now).sha256 == expected.envelopeSHA256 else {
                throw Error.invalidAuthority
            }
            try barrier(authorized, access: access)
            if authorized.intent.phase == .sealed {
                authorized = try transition(authorized, to: .cleanupStarted, access: access)
            }
            try access.releaseCurrentTemporary(for: authorized.receipt)
            for entry in remaining.sorted(by: { $0.relativePath.split(separator: "/").count > $1.relativePath.split(separator: "/").count
                || ($0.relativePath.split(separator: "/").count == $1.relativePath.split(separator: "/").count && $0.relativePath < $1.relativePath) }) {
                // No stale receipt may replace a newer durable intent. A readable
                // prior write is reestablished before each destructive boundary.
                try barrier(authorized, access: access)
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
                _ = try transition(authorized, to: .cleanupComplete, access: access)
            } else {
                guard try read(Self.next, at: control) == nil else { throw Error.invalidAuthority }
                try barrier(authorized, access: access)
            }
        }
    }

    private func transition(_ value: Authorized, to phase: Phase, access: SyncAccountStorage.RecoveryAccess) throws -> Authorized {
        // Keep one identity snapshot for the complete publication, not just the
        // first barrier: replace/legacyTransition perform further synchronizations.
        let inert = try inertTemporaryEntries(value, current: access.entries(), access: access)
        try barrier(value, access: access)
        let validateSource = {
            guard try self.inertTemporaryEntries(value, current: access.entries(), access: access) == inert else { throw Error.changedInventory }
            try self.validateSelectedPayload(value, access: access)
            if value.intent.phase == .restoreStarted || value.intent.phase == .replayComplete {
                try self.validateRestored(value, access: access, complete: phase == .replayComplete)
            } else {
                let remaining = try self.remainingEntries(value, access: access)
                guard (phase != .cleanupComplete && phase != .restoreStarted) || remaining.isEmpty else { throw Error.changedInventory }
            }
            guard try self.inertTemporaryEntries(value, current: access.entries(), access: access) == inert else { throw Error.changedInventory }
        }
        try validateSource()
        switch value.observation.state {
        case .legacySelection:
            _ = try legacyTransition(value.intent, to: phase, access: access, validateSource: validateSource)
        case .selectedRecovery:
            guard let main = value.observation.mainBytes else { throw Error.invalidAuthority }
            var next = value.intent; next.phase = phase
            let predecessor = Data(SHA256.hash(data: main))
            _ = try controlFile.replace(value.observation, with: .selectedRecovery(next, predecessorSHA256: predecessor),
                access: access, validateSource: validateSource)
        default: throw Error.invalidAuthority
        }
        try validateSource()
        guard let refreshed = try authorize(access: access, now: value.now), refreshed.receipt == value.receipt,
              refreshed.intent.phase == phase else { throw Error.invalidAuthority }
        return refreshed
    }

    private func legacyTransition(_ intent: Intent, to phase: Phase, access: SyncAccountStorage.RecoveryAccess,
        validateSource: () throws -> Void) throws -> Intent {
        guard let control = access.controlDescriptor else { throw Error.invalidAuthority }
        try legacyBarrier(intent, access: access)
        try validateSource()
        if try read(Self.next, at: control) != nil {
            // A bounded derivative has no authority of its own. Only the
            // authenticated, synchronized main selection permits rebuilding it.
            guard unlinkat(control, Self.next, 0) == 0 else { throw Error.unavailable }
            try synchronize(control)
            try validateSource()
        }
        var next = intent; next.phase = phase
        try write(try Self.encode(next), name: Self.next, at: control)
        try validateSource()
        try legacyBarrier(intent, access: access)
        try validateSource()
        guard renameat(control, Self.next, control, Self.main) == 0 else { throw Error.unavailable }
        try synchronize(control)
        try legacyBarrier(next, access: access)
        try validateSource()
        return next
    }

    private func authorize(access: SyncAccountStorage.RecoveryAccess, now: Date) throws -> Authorized? {
        let observation = try controlFile.observe(access: access)
        let intent: Intent
        switch observation.state {
        case .legacySelection(let selected), .selectedRecovery(let selected, _): intent = selected
        case nil, .absentSource, .sourceSpent: return nil
        }
        guard intent.formatVersion == 1, intent.accountIDHash == account.accountIDHash, intent.accountRoot == paths.accountRoot,
              intent.archiveURL == paths.workingSet.appendingPathComponent("projects-v1.json"),
              intent.journalURL == journal.recoveryLocation else { throw Error.invalidAuthority }
        let payload = try vault.restore(intent.vaultID, account: account, now: now)
        let (envelope, inventory, snapshot) = try decode(payload)
        switch observation.state {
        case .selectedRecovery(_, let predecessor):
            guard envelope.formatVersion == 2, case .absentSource = try snapshot?.observation().state else { throw Error.invalidAuthority }
            if intent.phase == .sealed {
                guard let sourceMain = snapshot?.mainBytes, predecessor == Data(SHA256.hash(data: sourceMain)) else { throw Error.invalidAuthority }
            }
        case .legacySelection:
            guard snapshot?.mainBytes == nil, snapshot?.nextBytes == nil else { throw Error.invalidAuthority }
        default: throw Error.invalidAuthority
        }
        let receipt = try Sealed(vaultID: intent.vaultID, envelope: envelope, inventory: inventory, bytes: payload)
        guard receipt.captureID == intent.captureID, receipt.packetSHA256 == intent.packetSHA256,
              receipt.envelopeSHA256 == intent.envelopeSHA256, receipt.inventoryFingerprint == intent.inventoryFingerprint else { throw Error.invalidAuthority }
        try validateRoot(envelope, access: access)
        guard try controlFile.observe(access: access) == observation else { throw Error.changedInventory }
        return Authorized(intent: intent, envelope: envelope, inventory: inventory, receipt: receipt, observation: observation, now: now)
    }

    private func remainingEntries(_ value: Authorized, access: SyncAccountStorage.RecoveryAccess) throws -> [SyncAccountRecoveryInventory.Entry] {
        try access.validate()
        let expected = Dictionary(uniqueKeysWithValues: value.inventory.entries.map { ($0.relativePath, $0) })
        let current = try access.entries()
        let inert = Set(try inertTemporaryEntries(value, current: current, access: access).map(\.relativePath))
        let session = ".decrypted-temporary/" + paths.decryptedTemporary.lastPathComponent
        let newSession = session != value.envelope.temporarySession
        let retained = Set(["working-set", "journal", "engine-state", "staging", "quarantine", ".decrypted-temporary", session])
        for entry in current {
            if inert.contains(entry.relativePath) { continue }
            if newSession, entry.relativePath == session {
                guard entry.isDirectory else { throw Error.changedInventory }
            } else {
                guard expected[entry.relativePath] == entry else { throw Error.changedInventory }
            }
        }
        // Legacy v1 permits its old session to have been reclaimed. Captured
        // v2 sessions retain their exact rules independently of uncaptured inert
        // directories; the current reopened session must still be empty.
        guard !newSession || !current.contains(where: { $0.relativePath.hasPrefix(session + "/") }),
              retained.allSatisfy({ name in current.contains(where: { $0.relativePath == name && $0.isDirectory }) }) else { throw Error.changedInventory }
        if value.intent.phase == .sealed {
            let actualNames = Set(current.map(\.relativePath))
            guard expected.keys.allSatisfy({ name in
                actualNames.contains(name) || (value.envelope.formatVersion == 1 && newSession && (name == value.envelope.temporarySession
                    || name.hasPrefix(value.envelope.temporarySession + "/")))
            }) else { throw Error.changedInventory }
        }
        return current.filter { !retained.contains($0.relativePath) && !inert.contains($0.relativePath) }
    }

    /// Authenticated capture exclusions are inert observations, never ownership
    /// receipts or cleanup authority. Captured names cannot use this exception.
    private func inertTemporaryEntries(_ value: Authorized, current: [SyncAccountRecoveryInventory.Entry],
        access: SyncAccountStorage.RecoveryAccess) throws -> [SyncAccountRecoveryInventory.Entry] {
        let prefix = ".decrypted-temporary/"
        let captured = Set(value.inventory.entries.map(\.relativePath))
        var result: [SyncAccountRecoveryInventory.Entry] = []
        for entry in current where entry.relativePath.hasPrefix(prefix) && !captured.contains(entry.relativePath) {
            let name = String(entry.relativePath.dropFirst(prefix.count))
            // Descendants can never independently become inert; their parent
            // must prove exact emptiness, or ordinary inventory validation fails.
            if name.contains("/") { continue }
            guard entry.isDirectory, let id = UUID(uuidString: name), id.uuidString.lowercased() == name,
                  !captured.contains(where: { $0.hasPrefix(entry.relativePath + "/") }),
                  !current.contains(where: { $0.relativePath.hasPrefix(entry.relativePath + "/") }) else { throw Error.changedInventory }
            let parent = try openDirectory(".decrypted-temporary", root: access.accountDescriptor)
            defer { Darwin.close(parent) }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Error.changedInventory }
            guard let stream = fdopendir(fd) else { Darwin.close(fd); throw Error.unavailable }
            defer { closedir(stream) }
            func validateIdentity() throws {
                var opened = stat(), named = stat()
                guard fstat(fd, &opened) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      opened.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
                      UInt64(opened.st_dev) == entry.device, UInt64(opened.st_ino) == entry.inode,
                      opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { throw Error.changedInventory }
            }
            try validateIdentity()
            while true {
                errno = 0
                guard let child = readdir(stream) else {
                    guard errno == 0 else { throw Error.unavailable }; break
                }
                let childName = withUnsafePointer(to: &child.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(child.pointee.d_namlen) + 1) { String(validatingCString: $0) }
                }
                guard childName == "." || childName == ".." else { throw Error.changedInventory }
            }
            try validateIdentity()
            try access.validate()
            result.append(entry)
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func decode(_ bytes: Data) throws -> (Envelope, SyncAccountRecoveryInventory, SourceControlSnapshot?) {
        guard bytes.count <= maximumBytes else { throw Error.tooLarge }
        let value = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard value.formatVersion == 1 || value.formatVersion == 2, value.accountDevice > 0, value.accountInode > 0,
              value.temporarySession.hasPrefix(".decrypted-temporary/"),
              let id = UUID(uuidString: String(value.temporarySession.dropFirst(".decrypted-temporary/".count))),
              value.temporarySession == ".decrypted-temporary/" + id.uuidString.lowercased() else { throw Error.invalidAuthority }
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        let snapshot: SourceControlSnapshot?
        if value.formatVersion == 2 {
            let v2 = try JSONDecoder().decode(EnvelopeV2.self, from: bytes)
            // Normalized full topology enforces required nullable witness keys
            // and rejects unknown fields at both envelope and snapshot levels.
            guard try JSONSerialization.data(withJSONObject: object as Any, options: [.sortedKeys]) ==
                JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: Self.encode(v2)), options: [.sortedKeys]) else { throw Error.invalidAuthority }
            snapshot = v2.sourceControl
        } else {
            guard object?["sourceControl"] == nil else { throw Error.invalidAuthority }
            snapshot = nil
        }
        let inventory = try SyncAccountRecoveryInventory.decodeRecovery(value.inventory, account: account,
            paths: paths, journalURL: journal.recoveryLocation, maximumBytes: maximumBytes)
        if let snapshot {
            guard case .absent(let evidence) = inventory.sourceAuthority,
                  evidence.state.accountDevice == value.accountDevice, evidence.state.accountInode == value.accountInode else { throw Error.invalidAuthority }
            let observation = try snapshot.observation()
            if case .absentSource(let source) = observation.state {
                guard source == evidence.state else { throw Error.invalidAuthority }
            } else {
                guard observation.mainBytes == nil, observation.nextBytes == nil,
                      case .bootstrapRollback = evidence.state.origin else { throw Error.invalidAuthority }
            }
        } else if inventory.sourceAuthority != nil { throw Error.invalidAuthority }
        // All prepare/seal/cleanup/restore authorization decodes pass the same
        // native enqueue gate before cleanup can destroy original plaintext.
        try journal.preflightRecoveryReplay(inventory.packet.mutations, maximumBytes: maximumBytes)
        guard value.packetSHA256 == Data(SHA256.hash(data: try inventory.packet.encoded(maximumBytes: maximumBytes))),
              inventory.entries.contains(where: { $0.relativePath == value.temporarySession && $0.isDirectory }),
              (value.formatVersion == 2 || inventory.entries.filter({ $0.relativePath.hasPrefix(".decrypted-temporary/") }).allSatisfy({
                  $0.relativePath == value.temporarySession || $0.relativePath.hasPrefix(value.temporarySession + "/")
              })) else { throw Error.invalidAuthority }
        return (value, inventory, snapshot)
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
    private func validateSelectedPayload(_ value: Authorized, access: SyncAccountStorage.RecoveryAccess) throws {
        try validateRoot(value.envelope, access: access)
        guard try vault.synchronizedRecoveryPayload(value.receipt.vaultID, account: account, now: value.now).sha256 == value.receipt.envelopeSHA256 else { throw Error.invalidAuthority }
    }
    private func barrier(_ value: Authorized, access: SyncAccountStorage.RecoveryAccess) throws {
        guard try controlFile.observe(access: access) == value.observation else { throw Error.changedInventory }
        let inert = try inertTemporaryEntries(value, current: access.entries(), access: access)
        try validateSelectedPayload(value, access: access)
        switch value.observation.state {
        case .legacySelection: try legacyBarrier(value.intent, access: access)
        case .selectedRecovery: try controlFile.synchronize(value.observation, access: access)
        default: throw Error.invalidAuthority
        }
        guard try controlFile.observe(access: access) == value.observation else { throw Error.changedInventory }
        guard try inertTemporaryEntries(value, current: access.entries(), access: access) == inert else { throw Error.changedInventory }
    }
    private func legacyBarrier(_ intent: Intent, access: SyncAccountStorage.RecoveryAccess) throws {
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
