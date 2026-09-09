import Darwin
import Foundation

struct SyncBootstrapDownloadFootprint {
    /// Accounting inputs only. The native producer separately admits all writes.
    let directoryPaths: [String]
    let files: [String: Int64]
}

enum SyncBootstrapDownloadBudget {
    static func requireFits(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths,
        account: SyncAccountIdentity, footprint: SyncBootstrapDownloadFootprint, maximumBytes: Int) throws {
        guard (0...100_000_000).contains(maximumBytes) else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
        try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            try requireFits(access: access, paths: paths, account: account, footprint: footprint, maximumBytes: maximumBytes)
        }
    }

    /// Retained synchronously by the native download producer. Checking capacity
    /// and writing must share this owner; callers must not retain it across await.
    static func requireFits(access: SyncAccountStorage.RecoveryAccess, paths: SyncAccountStorage.Paths,
        account: SyncAccountIdentity, footprint: SyncBootstrapDownloadFootprint, maximumBytes: Int) throws {
        guard (0...100_000_000).contains(maximumBytes) else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
        let observer = SyncAccountRecoveryControlFile(synchronize: { _ in })
        let control = try observer.observe(access: access)
        let inventory = try SyncAccountRecoveryInventory.capture(access: access, paths: paths, account: account,
            journal: FileSyncMutationJournal(url: paths.mutationJournalURL),
            archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"),
            control: control, maximumBytes: maximumBytes)
        let future = try prospectiveEntries(inventory.entries, footprint: footprint)
        var rawBytes = 0
        for entry in future where !entry.isDirectory {
            guard entry.byteCount >= 0, entry.byteCount <= Int64(maximumBytes) else {
                throw SyncAccountRecoveryTransaction.Error.tooLarge
            }
            rawBytes = try SyncBootstrapRecoveryBudget.add(rawBytes, Int(entry.byteCount))
        }
        guard rawBytes <= maximumBytes else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
        // These Entries are never fed to native capture, decode or restore.
        // The real packet, deletion bytes, authority and complete owned history
        // are embedded by the existing inventory codec at every Base64 layer.
        let count = try inventory.projectedEncodedByteCount(entries: future,
            packetByteCount: inventory.packet.encoded(maximumBytes: maximumBytes).count,
            deletionFiles: inventory.deletionFiles, sourceAuthority: inventory.sourceAuthority,
            bootstrapEvidence: inventory.bootstrapEvidence)
        var status = stat()
        guard fstat(access.accountDescriptor, &status) == 0 else { throw SyncAccountRecoveryTransaction.Error.unavailable }
        let envelope = try SyncAccountRecoveryTransaction.projectedEnvelopeByteCount(inventoryByteCount: count,
            captureID: UUID(), accountDevice: UInt64(status.st_dev), accountInode: UInt64(status.st_ino),
            temporarySession: ".decrypted-temporary/" + paths.decryptedTemporary.lastPathComponent, control: control,
            legacy: inventory.sourceAuthority == nil && inventory.bootstrapEvidence == nil)
        guard envelope <= maximumBytes else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
        try access.validate()
        guard try access.entries() == inventory.entries, try observer.observe(access: access) == control else {
            throw SyncAccountRecoveryTransaction.Error.changedInventory
        }
    }

    private static func prospectiveEntries(_ existing: [SyncAccountRecoveryInventory.Entry],
        footprint: SyncBootstrapDownloadFootprint) throws -> [SyncAccountRecoveryInventory.Entry] {
        typealias Entry = SyncAccountRecoveryInventory.Entry
        var entries = Dictionary(uniqueKeysWithValues: existing.map { ($0.relativePath, $0) })
        var aliases = Dictionary(existing.map { (OwnedBootstrapCodec.alias($0.relativePath), $0.relativePath) },
            uniquingKeysWith: { first, _ in first })
        func admit(_ path: String) throws {
            guard OwnedBootstrapCodec.relative(path),
                  !["vault", ".sealed-recovery-v1", ".storage-lock"].contains(OwnedBootstrapCodec.alias(String(path.split(separator: "/").first!))),
                  OwnedBootstrapCodec.alias(path) != ".decrypted-temporary/.owner-v1" else { throw SyncBootstrapError.unsafePath }
            let alias = OwnedBootstrapCodec.alias(path)
            if let old = aliases[alias], !OwnedBootstrapCodec.samePath(old, path) { throw SyncBootstrapError.unsafePath }
            aliases[alias] = path
        }
        func directory(_ path: String) throws {
            try admit(path)
            if let old = entries[path] {
                guard old.isDirectory else { throw SyncBootstrapError.unsafePath }
            } else {
                entries[path] = Entry(relativePath: path, isDirectory: true, byteCount: 0,
                    sha256: Data(), device: UInt64.max, inode: UInt64.max)
            }
        }
        func ancestors(_ path: String) throws {
            let parts = path.split(separator: "/")
            for count in 1..<parts.count { try directory(parts.prefix(count).joined(separator: "/")) }
        }
        for path in footprint.directoryPaths {
            try admit(path); try ancestors(path); try directory(path)
        }
        for (path, bytes) in footprint.files {
            try admit(path); try ancestors(path)
            guard (0...100_000_000).contains(bytes) else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
            let old = entries[path]
            guard old?.isDirectory != true else { throw SyncBootstrapError.unsafePath }
            // Future content and inode are unknown. All-ones SHA bytes bind the
            // native codec's maximum digest width; numeric widths are maximal.
            let future = Entry(relativePath: path, isDirectory: false, byteCount: max(bytes, old?.byteCount ?? 0),
                sha256: Data(repeating: 255, count: 32), device: UInt64.max, inode: UInt64.max)
            try SyncAccountRecoveryInventory.compatibilityGate([future])
            entries[path] = future
        }
        return entries.values.sorted { OwnedBootstrapCodec.pathOrder($0.relativePath, $1.relativePath) }
    }
}
