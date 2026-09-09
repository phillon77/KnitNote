import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

/// Shared real-storage fixture for the syscall matrix and its built-bundle workers.
/// The root constructor is identical in parent and child; no inode evidence is copied.
struct OwnedMatrixFixture {
    let root: URL
    let account = try! SyncAccountIdentity(containerIdentifier: "test", userRecordName: "owned-matrix")
    let storage: SyncAccountStorage
    let paths: SyncAccountStorage.Paths
    let archive: ProjectArchive
    let local: SyncExportPackage?
    let context: SyncBootstrapContext
    let missing: Bool

    init(root: URL? = nil, missing: Bool = false, legacyJournal: Bool = false, media: Bool = true) throws {
        self.root = root ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("owned-matrix-fixture-" + UUID().uuidString)
        guard !FileManager.default.fileExists(atPath: self.root.path) else { throw OwnedFixtureFailure.injected }
        self.missing = missing
        storage = SyncAccountStorage(baseURL: self.root.appendingPathComponent("store"))
        paths = try missing ? storage.openForVerifiedAccount(identity: account, validateAccount: {}) : storage.open(identity: account)
        context = .init(accountIDHash: account.accountIDHash, epoch: UUID(), freezeID: UUID())
        if missing {
            archive = .init(version: ProjectArchive.currentVersion, projects: [])
            local = nil
        } else {
            if media { _ = try BackupFixture.writeCompleteArchive(to: paths.workingSet) }
            else {
                let simple = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "Matrix source")])
                try JSONEncoder().encode(simple).write(to: paths.workingSet.appendingPathComponent("projects-v1.json"))
            }
            archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: paths.workingSet.appendingPathComponent("projects-v1.json")))
            local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: paths.workingSet, deviceID: "matrix")
        }
        if legacyJournal {
            try FileManager.default.createDirectory(at: paths.mutationJournalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            struct Envelope: Encodable { let version = 1; let checkpoint: Data; let checksum: Data }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let mutations = [Self.mutation(1), Self.mutation(2)]
            let data = try encoder.encode(SyncJournalCheckpoint(version: 1, throughSequence: 0, pending: mutations))
            try encoder.encode(Envelope(checkpoint: data, checksum: OwnedBootstrapCodec.hash(data)))
                .write(to: paths.mutationJournalURL.appendingPathExtension("checkpoint"))
            try Data().write(to: paths.mutationJournalURL.appendingPathExtension("segment"))
        }
    }

    static func mutation(_ index: Int) -> SyncMutation {
        .delete(.init(kind: .project, uuid: UUID(uuidString: String(format: "c0000000-0000-0000-0000-%012d", index))!),
            mutationID: UUID(uuidString: String(format: "d0000000-0000-0000-0000-%012d", index))!)
    }
    var journal: FileSyncMutationJournal { .init(url: paths.mutationJournalURL) }
    var namespace: URL { Self.namespace(paths, account: account) }
    static func namespace(_ paths: SyncAccountStorage.Paths, account: SyncAccountIdentity) -> URL {
        paths.accountRoot.appendingPathComponent(".KnitNote-SyncBootstrap/" + account.accountIDHash + "/"
            + OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(paths.workingSet.standardizedFileURL.path.utf8))))
    }
    func input(context: SyncBootstrapContext? = nil) throws -> SyncBootstrapOwnedInput {
        let selected = context ?? self.context
        let pending = try journal.recoverySnapshot().mutations
        let ordinary = try SyncBootstrapTransaction(liveRoot: paths.workingSet, context: selected, validateContext: { _ in })
        return try .init(local: local, sourceArchive: archive,
            remote: .init(context: selected, records: [], attachments: [:], isComplete: true),
            pending: pending.isEmpty ? nil : .init(mutations: pending, sourceTreeFingerprint: ordinary.sourceFingerprint()),
            counterReminderContext: .init())
    }
    func transaction(context: SyncBootstrapContext? = nil, boundary: @escaping (SyncBootstrapOwnedBoundary) throws -> Void = { _ in },
        io: SyncBootstrapOwnedIO = .init()) throws -> SyncBootstrapOwnedTransaction {
        let selected = context ?? self.context
        return try .init(storage: storage, paths: paths, account: account, context: selected,
            validateContext: { guard $0 == selected else { throw SyncBootstrapError.contextChanged } }, boundary: boundary, io: io)
    }
    func remove() { try? storage.close(); try? FileManager.default.removeItem(at: root) }
    static func descriptorPath(_ fd: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { throw OwnedFixtureFailure.injected }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    static func files(_ root: URL) throws -> [String: Data] {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            let url = url.standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { throw OwnedFixtureFailure.injected }
            var info = stat(); guard lstat(url.path, &info) == 0 else { throw OwnedFixtureFailure.injected }
            if info.st_mode & S_IFMT == S_IFREG { result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url) }
        }
        return result
    }
    static func manifest(_ paths: SyncAccountStorage.Paths, account: SyncAccountIdentity) throws -> BootstrapManifestV3 {
        try .decodeEnvelope(Data(contentsOf: namespace(paths, account: account).appendingPathComponent("active.json")))
    }
    struct CrashCut: Codable {
        let relativePath: String
        let bytes: Data
        let device: UInt64
        let inode: UInt64
        let active: Data
        let control: Data?
    }
    func recordCut(_ fd: Int32) throws {
        let path = try Self.descriptorPath(fd)
        guard path.hasPrefix(paths.workingSet.path + "/") else { throw OwnedFixtureFailure.injected }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw OwnedFixtureFailure.injected }
        let evidence = try CrashCut(relativePath: String(path.dropFirst(paths.workingSet.path.count + 1)),
            bytes: Data(contentsOf: URL(fileURLWithPath: path)), device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
            active: Data(contentsOf: namespace.appendingPathComponent("active.json")),
            control: try? Data(contentsOf: paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")))
        try JSONEncoder().encode(evidence).write(to: root.appendingPathComponent("cut.json"))
    }
    static func authenticate(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths, account: SyncAccountIdentity) throws {
        let journal = FileSyncMutationJournal(url: paths.mutationJournalURL)
        let before = try journal.recoverySnapshot().mutations
        let inventory = try SyncAccountRecoveryInventory.capture(storage: storage, paths: paths, account: account,
            journal: journal, archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"))
        let vault = SyncRecoveryVault(directory: paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: storage, paths: paths, account: account, vault: vault, journal: journal)
        let now = Date(), sealed = try recovery.seal(recovery.prepare(now: now), now: now)
        try recovery.cleanup(sealed); try recovery.restore(vaultID: sealed.vaultID, now: now)
        #expect(try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: now))
        let after = try FileSyncMutationJournal(url: paths.mutationJournalURL).recoverySnapshot().mutations
        #expect(after.map(\.mutationID) == before.map(\.mutationID))
        #expect(after.map(\.savedRecordVersion) == before.map(\.savedRecordVersion))
        let restored = try SyncAccountRecoveryInventory.capture(storage: storage, paths: paths, account: account,
            journal: FileSyncMutationJournal(url: paths.mutationJournalURL), archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"))
        #expect(restored.packet.files.map(\.bytes) == inventory.packet.files.map(\.bytes))
        #expect(restored.deletionFiles.map(\.bytes) == inventory.deletionFiles.map(\.bytes))
    }
}
