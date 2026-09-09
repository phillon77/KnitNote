import Foundation

/// Constructed only after the complete native committed inventory succeeds.
/// Retains no storage owner: every use reacquires and validates native ownership.
final class SyncBootstrapOwnedHandoffEvidence {
    let manifest: BootstrapManifestV3
    let checkpoint: SyncBootstrapCheckpoint
    let liveRoot: URL
    let liveRootIdentity: SyncRegularFileIdentity
    private let storage: SyncAccountStorage
    private let paths: SyncAccountStorage.Paths
    private let account: SyncAccountIdentity
    private let maximumBytes: Int
    private let validateContext: () throws -> Void
    private let retained: [SyncAccountRecoveryInventory.Entry]
    private let control: SyncAccountControlObservation

    private init(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths, account: SyncAccountIdentity,
        maximumBytes: Int, validateContext: @escaping () throws -> Void,
        manifest: BootstrapManifestV3, checkpoint: SyncBootstrapCheckpoint,
        root: SyncAccountRecoveryInventory.Entry, retained: [SyncAccountRecoveryInventory.Entry],
        control: SyncAccountControlObservation) {
        self.storage = storage; self.paths = paths; self.account = account; self.maximumBytes = maximumBytes
        self.validateContext = validateContext; self.manifest = manifest; self.checkpoint = checkpoint
        liveRoot = paths.workingSet; liveRootIdentity = .init(device: root.device, inode: root.inode)
        self.retained = retained
        self.control = control
    }

    static func capture(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths, account: SyncAccountIdentity,
        maximumBytes: Int, validateContext: @escaping () throws -> Void) throws -> Self {
        try validateContext()
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            let observer = SyncAccountRecoveryControlFile(synchronize: { _ in })
            let control = try observer.observe(access: access)
            let inventory = try SyncAccountRecoveryInventory.capture(access: access, paths: paths, account: account,
                journal: .init(url: paths.mutationJournalURL), archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"),
                control: control, maximumBytes: maximumBytes)
            guard let selected = inventory.bootstrapEvidence,
                  let root = inventory.entries.first(where: { $0.relativePath == "working-set" && $0.isDirectory }) else {
                throw SyncBootstrapError.invalidPhase
            }
            let manifest = try BootstrapManifestV3.decodeEnvelope(selected.activeEnvelope, maximumBytes: maximumBytes)
            guard case let .committed(body) = manifest.body,
                  root.device == body.stagedRoot.device, root.inode == body.stagedRoot.inode else { throw SyncBootstrapError.invalidPhase }
            let path = "working-set/SyncMetadata/bootstrap-canonical.json"
            guard let entry = inventory.entries.first(where: { $0.relativePath == path }),
                  body.installed["SyncMetadata/bootstrap-canonical.json"] == .init(bytes: entry.byteCount, digest: entry.sha256) else {
                throw SyncBootstrapError.corrupt
            }
            let checkpoint = try JSONDecoder().decode(SyncBootstrapCheckpoint.self,
                from: read(entry, paths: paths, maximumBytes: maximumBytes).data)
            guard checkpoint.archiveSHA256 == body.installed["projects-v1.json"]?.digest else { throw SyncBootstrapError.corrupt }
            _ = try SyncRecordValidator().validate(checkpoint.records)
            try validateContext(); try access.validate()
            guard try access.entries() == inventory.entries, try observer.observe(access: access) == control else {
                throw SyncBootstrapError.sourceChanged
            }
            return Self(storage: storage, paths: paths, account: account, maximumBytes: maximumBytes,
                validateContext: validateContext, manifest: manifest, checkpoint: checkpoint, root: root,
                retained: inventory.entries.filter(isRetained), control: control)
        }
    }

    func revalidate() throws { try withValidated { _ in () } }

    func stagedAttachmentSource(_ version: SyncAttachmentVersion) throws -> SyncAttachmentSource? {
        try withValidated { entries in
            guard checkpoint.records.contains(where: { $0.id == .init(kind: .attachment, uuid: version.versionID)
                && $0.payload.attachment == version }), (0...Int64(maximumBytes)).contains(version.byteCount) else {
                throw SyncBootstrapError.corrupt
            }
            let path = manifest.transactionRelativePath + "/Attachments/" + version.versionID.uuidString
            guard let entry = entries.first(where: { $0.relativePath == path }) else { return nil }
            guard !entry.isDirectory, entry.byteCount == version.byteCount, entry.sha256 == version.contentSHA256 else {
                throw SyncBootstrapError.sourceChanged
            }
            _ = try Self.read(entry, paths: paths, maximumBytes: maximumBytes)
            return try .init(fileURL: paths.accountRoot.appendingPathComponent(path),
                contentSHA256: version.contentSHA256, byteCount: version.byteCount)
        }
    }

    private func withValidated<T>(_ body: ([SyncAccountRecoveryInventory.Entry]) throws -> T) throws -> T {
        try validateContext()
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            let observer = SyncAccountRecoveryControlFile(synchronize: { _ in })
            let entries = try access.entries()
            guard entries.filter(Self.isRetained) == retained, try observer.observe(access: access) == control else {
                throw SyncBootstrapError.sourceChanged
            }
            let value = try body(entries)
            try validateContext(); try access.validate()
            guard try access.entries().filter(Self.isRetained) == retained, try observer.observe(access: access) == control else {
                throw SyncBootstrapError.sourceChanged
            }
            return value
        }
    }

    // Same post-adoption authority as the legacy handoff, plus immutable owned
    // control, history, Original and staged outputs. The daily canonical file
    // and journal may advance; the bootstrap capability cannot bless their edits.
    private static func isRetained(_ entry: SyncAccountRecoveryInventory.Entry) -> Bool {
        let path = entry.relativePath
        if path == ".KnitNote-SyncBootstrap" || path.hasPrefix(".KnitNote-SyncBootstrap/") { return true }
        if ["working-set", "working-set/projects-v1.json", "working-set/SyncMetadata/bootstrap-canonical.json",
            "working-set/SyncMetadata/bootstrap-receipt.json"].contains(path) { return true }
        return ["attachment-versions.", "attachment-manifest.", "revision-ledger."].contains {
            path.hasPrefix("working-set/SyncMetadata/" + $0)
        }
    }

    private static func read(_ entry: SyncAccountRecoveryInventory.Entry, paths: SyncAccountStorage.Paths,
        maximumBytes: Int) throws -> SyncRegularFileRead {
        guard !entry.isDirectory else { throw SyncBootstrapError.sourceChanged }
        let value = try SyncRegularFileReader().read(paths.accountRoot.appendingPathComponent(entry.relativePath),
            maximumBytes: maximumBytes, expected: .init(byteCount: entry.byteCount, sha256: entry.sha256))
        guard value.device == entry.device, value.inode == entry.inode else { throw SyncBootstrapError.sourceChanged }
        return value
    }
}
