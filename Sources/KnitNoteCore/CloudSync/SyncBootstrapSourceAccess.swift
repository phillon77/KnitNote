import Foundation

struct SyncBootstrapSourceSnapshot {
    let archive: ProjectArchive
    let local: SyncExportPackage?
    let pending: SyncBootstrapPendingSnapshot?
    let counterReminderContext: SyncCounterReminderMergeContext
}

/// Read-only native source observation. The caller owns the producer freeze;
/// this value neither installs a store nor grants subsequent write authority.
final class SyncBootstrapSourceAccess {
    private let storage: SyncAccountStorage
    private let paths: SyncAccountStorage.Paths
    private let account: SyncAccountIdentity
    private let maximumBytes: Int

    init(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths,
         account: SyncAccountIdentity, maximumBytes: Int) {
        self.storage = storage; self.paths = paths; self.account = account; self.maximumBytes = maximumBytes
    }

    func requireBinding(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths, account: SyncAccountIdentity) throws {
        guard self.storage === storage, self.paths == paths, self.account == account else { throw SyncBootstrapError.contextChanged }
    }

    func capture(deviceID: String) throws -> SyncBootstrapSourceSnapshot {
        guard (0...100_000_000).contains(maximumBytes) else { throw SyncAccountRecoveryInventory.Error.tooLarge }
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            let observer = SyncAccountRecoveryControlFile(synchronize: { _ in })
            let control = try observer.observe(access: access)
            guard control.nextBytes == nil else { throw SyncBootstrapError.sourceChanged }
            switch control.state {
            case nil, .absentSource: break
            default: throw SyncBootstrapError.sourceChanged
            }
            let journal = FileSyncMutationJournal(url: paths.mutationJournalURL)
            let archiveURL = paths.workingSet.appendingPathComponent("projects-v1.json")
            let inventory = try SyncAccountRecoveryInventory.capture(access: access, paths: paths,
                account: account, journal: journal, archiveURL: archiveURL, control: control, maximumBytes: maximumBytes)
            let archive: ProjectArchive
            let hasArchive: Bool
            if let bytes = try read(archiveURL, inventory: inventory) {
                archive = try JSONDecoder().decode(ProjectArchive.self, from: bytes)
                hasArchive = true
            } else {
                // Ephemeral no-control rollback observations are insufficient:
                // owned planning requires the durable source handoff first.
                guard control.mainBytes != nil, case .absent = inventory.sourceAuthority else {
                    throw SyncBootstrapError.sourceChanged
                }
                archive = .init(version: ProjectArchive.currentVersion, projects: [])
                hasArchive = false
            }
            let prepared = try read(WatchSyncPaths.preparedCommand(in: paths.workingSet), inventory: inventory)
                .map { try WatchSyncCodec.decode(PreparedWatchCommand.self, from: $0) }
            let ledger = try read(WatchSyncPaths.processedLedger(in: paths.workingSet), inventory: inventory)
                .map { try WatchSyncCodec.decode(ProcessedWatchCommandLedger.self, from: $0) }
                ?? ProcessedWatchCommandLedger()
            let context = SyncCounterReminderMergeContext(preparedCommands: prepared.map { [$0] } ?? [], processedLedger: ledger)
            let local: SyncExportPackage?
            if hasArchive {
                let head = paths.workingSet.appendingPathComponent("SyncMetadata/attachment-versions.json")
                _ = try entry(head, inventory: inventory)
                for ext in ["attachment-records", "attachment-tombstones", "watch-proofs"] {
                    _ = try entry(head.deletingPathExtension().appendingPathExtension(ext), inventory: inventory)
                }
                let evidence = try SyncAttachmentPublicationEvidenceFile(url: head).loadFrozenSource()
                local = try ProjectArchiveSyncMapper.exportFrozenSource(archive: archive,
                    liveRoot: paths.workingSet, deviceID: deviceID, preparedWatchCommand: prepared,
                    processedWatchLedger: ledger, evidence: evidence)
            } else { local = nil }
            let pending = try SyncBootstrapOwnedTransaction.hasSourceJournal(inventory.entries,
                journalRelativePath: SyncBootstrapTransaction.defaultJournalRelativePath) || !inventory.packet.mutations.isEmpty
                ? SyncBootstrapPendingSnapshot(mutations: inventory.packet.mutations,
                    sourceTreeFingerprint: SyncBootstrapOwnedTransaction.sourceTreeFingerprint(inventory.entries)) : nil
            try access.validate()
            guard try access.entries() == inventory.entries, try observer.observe(access: access) == control else {
                throw SyncBootstrapError.sourceChanged
            }
            return .init(archive: archive, local: local, pending: pending, counterReminderContext: context)
        }
    }

    private func read(_ url: URL, inventory: SyncAccountRecoveryInventory) throws -> Data? {
        guard let entry = try entry(url, inventory: inventory) else { return nil }
        guard !entry.isDirectory else { throw SyncBootstrapError.sourceChanged }
        let value = try SyncRegularFileReader().read(url, maximumBytes: min(maximumBytes, Int(entry.byteCount)),
            expected: .init(byteCount: entry.byteCount, sha256: entry.sha256))
        guard value.device == entry.device, value.inode == entry.inode else { throw SyncBootstrapError.sourceChanged }
        return value.data
    }

    private func entry(_ url: URL, inventory: SyncAccountRecoveryInventory) throws -> SyncAccountRecoveryInventory.Entry? {
        let path = try SyncAccountRecoveryInventory.relative(url, root: paths.accountRoot)
        guard inventory.entries.filter({ OwnedBootstrapCodec.alias($0.relativePath) == OwnedBootstrapCodec.alias(path) })
            .allSatisfy({ OwnedBootstrapCodec.samePath($0.relativePath, path) }) else { throw SyncBootstrapError.unsafePath }
        return inventory.entries.first { OwnedBootstrapCodec.samePath($0.relativePath, path) }
    }
}
