import Foundation
import Darwin
import Testing
@testable import KnitNoteCore

struct SyncBootstrapOwnedTransactionTests {
    @Test(arguments: [false, true], ["epoch", "freeze"])
    func staleForwardTokenRejectsBeforeEffectsButHistoricalRecoveryRemainsAllowed(installed: Bool, change: String) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let prior = try f.transaction(), token = try prior.prepare(f.input())
        if installed { try prior.install(token) }
        let selected = try f.manifest(), before = try f.source.diskBytes()
        let current = SyncBootstrapContext(accountIDHash: f.context.accountIDHash,
            epoch: change == "epoch" ? UUID() : f.context.epoch,
            freezeID: change == "freeze" ? UUID() : f.context.freezeID)
        var validations = 0, effects = 0
        let owner = try SyncBootstrapOwnedTransaction(storage: f.source.storage, paths: f.source.paths,
            account: f.source.account, context: current, validateContext: { value in
                #expect(value == current); validations += 1
            }, boundary: { _ in effects += 1 }, io: .init(write: { fd, bytes in
                effects += 1; try SyncBootstrapOwnedPOSIX.write(fd, bytes)
            }, synchronize: { fd in effects += 1; try SyncBootstrapOwnedPOSIX.synchronize(fd) }))
        if installed { #expect(throws: (any Error).self) { _ = try owner.commit(token) } }
        else { #expect(throws: (any Error).self) { try owner.install(token) } }
        #expect(validations == 1)
        #expect(effects == 0)
        #expect(try f.source.diskBytes() == before)
        #expect(try f.manifest() == selected)
        _ = try owner.recover()
        guard case .rolledBack = try f.manifest().body else { Issue.record("historical recovery did not roll back"); return }
        #expect(try f.manifest().context == selected.context)
        #expect(!FileManager.default.fileExists(atPath: f.source.archiveURL.path))
        _ = try f.source.capture()
    }

    @Test(arguments: ["attachment-change", "attachment-remove", "validation-change", "validation-remove"])
    func restartedPreparedRejectsChangedOrMissingAuxiliaryBytes(change: String) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let id = UUID(), bytes = Data("unreferenced remote attachment".utf8)
        let sourceURL = f.source.paths.staging.appendingPathComponent("unused-source")
        try bytes.write(to: sourceURL)
        let source = try SyncAttachmentSource(fileURL: sourceURL, contentSHA256: OwnedBootstrapCodec.hash(bytes), byteCount: Int64(bytes.count))
        let input = SyncBootstrapOwnedInput(local: nil, sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
            remote: .init(context: f.context, records: [], attachments: [id: source], isComplete: true),
            pending: nil, counterReminderContext: .init())
        let token = try f.transaction().prepare(input), manifest = try f.manifest()
        let root = f.source.paths.accountRoot.appendingPathComponent(manifest.transactionRelativePath)
        let selected: URL
        if change.hasPrefix("attachment") { selected = root.appendingPathComponent("Attachments/" + id.uuidString) }
        else {
            let paths = try #require(FileManager.default.enumerator(at: root.appendingPathComponent("ValidationMerged"), includingPropertiesForKeys: [.isRegularFileKey]))
            var regular: URL?
            for case let url as URL in paths where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { regular = url; break }
            selected = try #require(regular)
        }
        if change.hasSuffix("remove") { try FileManager.default.removeItem(at: selected) }
        else { try Data("different immutable bytes".utf8).write(to: selected) }
        let before = try f.source.diskBytes()
        #expect(throws: (any Error).self) { try f.transaction().install(token) }
        #expect(try f.source.diskBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: f.source.archiveURL.path))
    }

    @Test func emptyRootAbortCompletesVaultRecoveryAndRejectsFormerlyAbsentHistoryRoot() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let failing = try f.transaction(boundary: { if $0 == .beforeTransactionRootCreation { throw OwnedFixtureFailure.injected } })
        #expect(throws: (any Error).self) { _ = try failing.prepare(f.input()) }
        _ = try f.transaction().recover()
        let old = try f.manifest()
        let second = try f.transaction(boundary: { if $0 == .beforeTransactionRootCreation { throw OwnedFixtureFailure.injected } })
        #expect(throws: (any Error).self) { _ = try second.prepare(f.input()) }
        _ = try f.transaction().recover()
        let captured = try f.source.capture()
        #expect(captured.bootstrapEvidence?.historyRecords.count == 1)
        let unexpected = f.source.paths.accountRoot.appendingPathComponent(old.transactionRelativePath)
        try FileManager.default.createDirectory(at: unexpected, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { _ = try f.source.capture() }
        try FileManager.default.removeItem(at: unexpected)
        let vault = SyncRecoveryVault(directory: f.source.paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.source.storage, paths: f.source.paths,
            account: f.source.account, vault: vault, journal: f.source.journal)
        let now = Date(), sealed = try recovery.seal(recovery.prepare(now: now), now: now)
        try recovery.cleanup(sealed); try recovery.restore(vaultID: sealed.vaultID, now: now)
        #expect(try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: now))
        _ = try f.transaction().prepare(f.input())
    }

    @Test(arguments: ["manifest", "spent", "scaffold", "symlink", "placement", "legacy"])
    func missingLiveAdmissionRejectsUnprovedOrLegacyState(change: String) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let tx = try f.transaction(boundary: { point in
            if point == .afterLiveMove || point == .afterRollbackIntent { throw OwnedFixtureFailure.injected }
        })
        let token = try tx.prepare(f.input())
        #expect(throws: (any Error).self) { try tx.install(token) }
        let manifest = try f.manifest(), root = f.source.paths.accountRoot.appendingPathComponent(try f.manifest().transactionRelativePath)
        #expect(!FileManager.default.fileExists(atPath: f.source.paths.workingSet.path))
        try f.source.storage.close()
        switch change {
        case "manifest": try FileManager.default.removeItem(at: f.namespace.appendingPathComponent("active.json"))
        case "spent":
            let url = f.source.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
            let bytes = try Data(contentsOf: url)
            guard case let .sourceSpent(source, _, digest) = try SyncAccountRecoveryControlFile.decode(bytes) else { throw OwnedFixtureFailure.injected }
            try SyncAccountRecoveryControlFile.encode(.sourceSpent(source, transactionID: UUID(), preparedManifestSHA256: digest),
                predecessorSHA256: SyncAccountRecoveryControlFile.sourceSpentPredecessor(bytes)).write(to: url)
        case "scaffold": try FileManager.default.removeItem(at: f.source.paths.staging)
        case "symlink": try FileManager.default.createSymbolicLink(at: f.source.paths.workingSet, withDestinationURL: root.appendingPathComponent("Displaced"))
        case "placement": try FileManager.default.moveItem(at: root.appendingPathComponent("Staged"), to: root.appendingPathComponent("Unexplained"))
        case "legacy": break
        default: throw OwnedFixtureFailure.injected
        }
        let before = try f.source.diskBytes()
        let storage = SyncAccountStorage(baseURL: f.source.base)
        #expect(throws: (any Error).self) {
            if change == "legacy" { _ = try storage.open(identity: f.source.account) }
            else { _ = try storage.openExistingAccount(identity: f.source.account, validateAccount: {}) }
        }
        #expect(try f.source.diskBytes() == before)
        if change != "symlink" { #expect(!FileManager.default.fileExists(atPath: f.source.paths.workingSet.path)) }
        #expect(manifest.body.preparedBody != nil)
    }

    @Test(arguments: [false, true], ["main", "next", "archiveHash", "original", "rootIdentity", "placement", "extra", "legacy"])
    func archiveMissingLiveRejectsWrongEvidenceWithoutRecreationOrCleanup(existingOnly: Bool, damage: String) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
        try JSONEncoder().encode(archive).write(to: f.archiveURL)
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "fixture")
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let tx = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, validateContext: { _ in }, boundary: { point in
                if point == .afterLiveMove || point == .afterRollbackIntent { throw OwnedFixtureFailure.injected }
            })
        let token = try tx.prepare(.init(local: local, sourceArchive: archive,
            remote: .init(context: context, records: [], attachments: [:], isComplete: true),
            pending: nil, counterReminderContext: .init()))
        #expect(throws: (any Error).self) { try tx.install(token) }
        let active = URL(fileURLWithPath: try #require(f.diskBytes().keys.first { $0.hasSuffix("/active.json") }))
        let manifest = try BootstrapManifestV3.decodeEnvelope(Data(contentsOf: active))
        let root = f.paths.accountRoot.appendingPathComponent(manifest.transactionRelativePath)
        let retained = f.paths.accountRoot.appendingPathComponent(".decrypted-temporary/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: false)
        try Data("must remain before authenticated cleanup".utf8).write(to: retained.appendingPathComponent("retained.bin"))
        try f.storage.close()
        switch damage {
        case "main", "next":
            let directory = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("mismatched control evidence".utf8).write(to: directory.appendingPathComponent(
                damage == "main" ? "intent.json" : "intent-next.json"))
        case "archiveHash":
            var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: active)) as! [String: Any]
            var payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"] as! String)!) as! [String: Any]
            payload["sourceProof"] = ["kind": "archive", "sha256": Data(repeating: 9, count: 32).base64EncodedString()]
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            envelope["payload"] = bytes.base64EncodedString(); envelope["digest"] = OwnedBootstrapCodec.hash(bytes).base64EncodedString()
            try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: active)
        case "original": try Data("changed original archive".utf8).write(to: root.appendingPathComponent("Original/projects-v1.json"))
        case "rootIdentity":
            let saved = f.base.appendingPathComponent("retained-staged-root")
            try FileManager.default.moveItem(at: root.appendingPathComponent("Staged"), to: saved)
            try FileManager.default.copyItem(at: saved, to: root.appendingPathComponent("Staged"))
        case "placement": try FileManager.default.moveItem(at: root.appendingPathComponent("Staged"), to: root.appendingPathComponent("Unexplained"))
        case "extra": try Data("unowned extra entry".utf8).write(to: root.appendingPathComponent("extra.bin"))
        case "legacy": break
        default: throw OwnedFixtureFailure.injected
        }
        let before = try f.diskBytes()
        let storage = SyncAccountStorage(baseURL: f.base); defer { try? storage.close() }
        #expect(throws: (any Error).self) {
            if damage == "legacy" { _ = try storage.open(identity: f.account) }
            else if existingOnly { _ = try storage.openExistingAccount(identity: f.account, validateAccount: {}) }
            else { _ = try storage.openForVerifiedAccount(identity: f.account, validateAccount: {}) }
        }
        #expect(try f.diskBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: f.paths.workingSet.path))
    }

    @Test func legacyNoEvidenceRetainsOrdinaryMissingScaffoldBehavior() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        try f.storage.close()
        try FileManager.default.removeItem(at: f.paths.workingSet)
        let storage = SyncAccountStorage(baseURL: f.base)
        let paths = try storage.open(identity: f.account)
        defer { try? storage.close() }
        #expect(FileManager.default.fileExists(atPath: paths.workingSet.path))
    }

    @Test func sameScopeOriginalDirectoryReplacementFailsBeforeLiveMove() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        var replaced = false
        let tx = try f.transaction(boundary: { point in
            if point == .afterSourceSpend, !replaced {
                replaced = true
                let original = f.source.paths.accountRoot.appendingPathComponent(try f.manifest().transactionRelativePath + "/Original")
                let retained = f.source.base.appendingPathComponent("same-scope-original")
                try FileManager.default.moveItem(at: original, to: retained)
                try FileManager.default.copyItem(at: retained, to: original)
            }
        })
        let token = try tx.prepare(f.input())
        #expect(throws: (any Error).self) { try tx.install(token) }
        #expect(replaced)
        #expect(!FileManager.default.fileExists(atPath: f.source.archiveURL.path))
        #expect(!FileManager.default.fileExists(atPath: f.source.paths.accountRoot.appendingPathComponent(try f.manifest().transactionRelativePath + "/Displaced").path))
    }

    @Test func actualTornCommitOutputIsFrozenThenAuthenticallyRecovered() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        var committing = false, fired = false
        let tx = try f.transaction(io: .init(write: { fd, bytes in
            if committing, !fired, bytes.count > 7 {
                fired = true
                try SyncBootstrapOwnedPOSIX.write(fd, Data(bytes.prefix(7)))
                throw OwnedFixtureFailure.injected
            }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        }))
        let token = try tx.prepare(f.input())
        try tx.install(token); committing = true
        #expect(throws: (any Error).self) { _ = try tx.commit(token) }
        #expect(fired)
        _ = try f.transaction().recover()
        let captured = try f.source.capture()
        let retained = try #require(captured.entries.first { $0.relativePath.contains("/Failed/") && $0.relativePath.hasSuffix(".tmp") })
        #expect(retained.byteCount == 7)
        let url = f.source.paths.accountRoot.appendingPathComponent(retained.relativePath), bytes = try Data(contentsOf: f.source.paths.accountRoot.appendingPathComponent(retained.relativePath))
        try Data("changed".utf8).write(to: url)
        #expect(throws: (any Error).self) { _ = try f.source.capture() }
        try bytes.write(to: url)
        let vault = SyncRecoveryVault(directory: f.source.paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.source.storage, paths: f.source.paths,
            account: f.source.account, vault: vault, journal: f.source.journal)
        let now = Date(), sealed = try recovery.seal(recovery.prepare(now: now), now: now)
        try recovery.cleanup(sealed); try recovery.restore(vaultID: sealed.vaultID, now: now)
        #expect(try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: now))
        #expect(try f.source.journal.pending().isEmpty)
    }

    @Test func ownedCiphertextCannotBeReplacedByPlainInventoryOrWrongKeys() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let tx = try f.transaction(), token = try tx.prepare(f.input())
        try tx.install(token); _ = try tx.commit(token)
        let captured = try f.source.capture()
        let vault = SyncRecoveryVault(directory: f.source.paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.source.storage, paths: f.source.paths,
            account: f.source.account, vault: vault, journal: f.source.journal)
        let sealed = try recovery.seal(recovery.prepare(now: .now), now: .now)
        let wrongVault = SyncRecoveryVault(directory: f.source.paths.vault, keychain: OwnedBootstrapTestKeys())
        let wrong = SyncAccountRecoveryTransaction(storage: f.source.storage, paths: f.source.paths,
            account: f.source.account, vault: wrongVault, journal: f.source.journal)
        let before = try f.source.diskBytes()
        #expect(throws: (any Error).self) { try wrong.cleanup(sealed) }
        #expect(try f.source.diskBytes() == before)
        let location = f.source.paths.vault.appendingPathComponent(sealed.vaultID.uuidString.lowercased() + ".vault")
        let encrypted = try Data(contentsOf: location)
        try captured.encoded().write(to: location)
        let plaintextBefore = try f.source.diskBytes()
        #expect(throws: (any Error).self) { try recovery.cleanup(sealed) }
        #expect(try f.source.diskBytes() == plaintextBefore)
        try encrypted.write(to: location)
        #expect(throws: (any Error).self) { _ = try vault.restore(UUID(), account: f.source.account, now: .now) }
        #expect(throws: (any Error).self) { _ = try vault.restore(sealed.vaultID,
            account: SyncAccountIdentity(containerIdentifier: "test", userRecordName: "wrong-owned-account"), now: .now) }
        try recovery.cleanup(sealed); try recovery.restore(vaultID: sealed.vaultID, now: .now)
        #expect(try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: .now))
    }

    @Test(arguments: ["Attachments/unreferenced.asset", "ValidationMerged/unplanned.bin"])
    func restartedPreparedRejectsExtraImmutableOutput(path: String) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let token = try f.transaction().prepare(f.input())
        let manifest = try f.manifest()
        let output = f.source.paths.accountRoot.appendingPathComponent(manifest.transactionRelativePath + "/" + path)
        try Data("unplanned immutable output".utf8).write(to: output)
        let before = try f.source.diskBytes()
        #expect(throws: (any Error).self) { try f.transaction().install(token) }
        #expect(try f.source.diskBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: f.source.archiveURL.path))
    }
    @Test func nonemptyOriginalJournalRetainsLogicalReplayAndCommitCoordination() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let journal = try f.makeMissingArchiveRollback(withMedia: false)
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let tx = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, validateContext: { _ in })
        _ = try tx.recover()
        let ordinary = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context, validateContext: { _ in })
        let pending = try journal.pending()
        let token = try tx.prepare(.init(local: nil, sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
            remote: .init(context: context, records: [], attachments: [:], isComplete: true),
            pending: .init(mutations: pending, sourceTreeFingerprint: ordinary.sourceFingerprint()), counterReminderContext: .init()))
        try tx.install(token)
        _ = try tx.commit(token)
        #expect(Array(try journal.pending().prefix(pending.count)) == pending)
    }

    @Test(arguments: [false, true], [(false, false), (false, true), (true, false), (true, true)])
    func abruptMoveGapReopensForOwnedRecovery(rollbackGap: Bool, route: (Bool, Bool)) throws {
        let (archiveOrigin, existingOnly) = route
        guard ProcessInfo.processInfo.environment["KNITNOTE_OWNED_MOVE_CHILD"] == nil else { return }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("owned-move-crash-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "KNITNOTE_RUN_CLOUDKIT_INTEGRATION")
        environment["KNITNOTE_OWNED_MOVE_CHILD"] = rollbackGap ? "failed" : "live"
        environment["KNITNOTE_OWNED_MOVE_ROOT"] = root.path
        environment["KNITNOTE_OWNED_MOVE_ARCHIVE"] = archiveOrigin ? "1" : "0"
        let child = Process(), executable = try #require(Bundle.main.executableURL)
        #expect(executable.lastPathComponent == "swiftpm-testing-helper")
        child.executableURL = executable
        var arguments: [String] = [], skipNext = false
        for argument in CommandLine.arguments.dropFirst() {
            if skipNext { skipNext = false; continue }
            if argument == "--filter" { skipNext = true; continue }
            arguments.append(argument)
        }
        arguments += ["--filter", "SyncBootstrapOwnedTransactionTests/abruptMoveWorker"]
        child.arguments = arguments; child.environment = environment
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        let deadline = Date().addingTimeInterval(60)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning {
            child.terminate()
            let grace = Date().addingTimeInterval(2)
            while child.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            Issue.record("owned move worker timeout"); return
        }
        guard child.terminationReason == .exit, child.terminationStatus == 86 else {
            Issue.record("owned move worker did not reach abrupt boundary: \(child.terminationStatus)"); return
        }
        let account = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "owned-move-crash")
        let accountRoot = root.appendingPathComponent(account.accountIDHash)
        #expect(!FileManager.default.fileExists(atPath: accountRoot.appendingPathComponent("working-set").path))
        let storage = SyncAccountStorage(baseURL: root)
        let control = accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        if archiveOrigin { #expect(!FileManager.default.fileExists(atPath: control.path)) }
        let paths = try existingOnly ? storage.openExistingAccount(identity: account, validateAccount: {})
            : storage.openForVerifiedAccount(identity: account, validateAccount: {})
        defer { try? storage.close() }
        #expect(!FileManager.default.fileExists(atPath: paths.workingSet.path))
        #expect(throws: (any Error).self) {
            try storage.validateRuntimeJournalNamespace(paths: paths, account: account, validateBootstrap: true)
        }
        let context = SyncBootstrapContext(accountIDHash: account.accountIDHash, epoch: UUID(), freezeID: UUID())
        _ = try SyncBootstrapOwnedTransaction(storage: storage, paths: paths, account: account,
            context: context, validateContext: { _ in }).recover()
        #expect(FileManager.default.fileExists(atPath: paths.workingSet.path))
        let captured = try SyncAccountRecoveryInventory.capture(storage: storage, paths: paths, account: account,
            journal: FileSyncMutationJournal(url: paths.mutationJournalURL), archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"))
        #expect(captured.sourceAuthority != nil)
        if archiveOrigin {
            guard case .archive = captured.sourceAuthority else { Issue.record("archive origin changed"); return }
            #expect(!FileManager.default.fileExists(atPath: control.path))
        }
    }

    @Test func abruptMoveWorker() throws {
        guard let point = ProcessInfo.processInfo.environment["KNITNOTE_OWNED_MOVE_CHILD"],
              let selected = ProcessInfo.processInfo.environment["KNITNOTE_OWNED_MOVE_ROOT"] else { return }
        let root = URL(fileURLWithPath: selected)
        guard ["live", "failed"].contains(point), root.lastPathComponent.hasPrefix("owned-move-crash-"),
              !FileManager.default.fileExists(atPath: root.path) else { throw OwnedFixtureFailure.injected }
        let account = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "owned-move-crash")
        let storage = SyncAccountStorage(baseURL: root)
        let archiveOrigin = ProcessInfo.processInfo.environment["KNITNOTE_OWNED_MOVE_ARCHIVE"] == "1"
        let paths = try archiveOrigin ? storage.open(identity: account)
            : storage.openForVerifiedAccount(identity: account, validateAccount: {})
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
        if archiveOrigin { try JSONEncoder().encode(archive).write(to: paths.workingSet.appendingPathComponent("projects-v1.json")) }
        let local = try archiveOrigin ? ProjectArchiveSyncMapper.export(archive: archive, liveRoot: paths.workingSet, deviceID: "fixture") : nil
        let context = SyncBootstrapContext(accountIDHash: account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let tx = try SyncBootstrapOwnedTransaction(storage: storage, paths: paths, account: account,
            context: context, validateContext: { _ in }, boundary: { boundary in
                if point == "live", boundary == .afterLiveMove { Darwin._exit(86) }
                if point == "failed", boundary == .afterInstalled { throw OwnedFixtureFailure.injected }
                if point == "failed", boundary == .afterFailedMove { Darwin._exit(86) }
            })
        let token = try tx.prepare(.init(local: local, sourceArchive: archive,
            remote: .init(context: context, records: [], attachments: [:], isComplete: true), pending: nil, counterReminderContext: .init()))
        try tx.install(token)
        Issue.record("owned move worker did not reach actual move")
    }

    @Test(arguments: [false, true]) @MainActor func mediaDeletionFIFOCompletesOwnedAndAuthenticatedRecovery(restoredOrigin: Bool) throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let deleted = try f.addDeletion(ledger: ledger, name: "retained before owned installation", attachment: true)
        let journal = FileSyncMutationJournal(url: f.paths.mutationJournalURL)
        try journal.enqueue(deleted.versions.map { try SyncMutation.save(recordVersion: $0, mutationID: UUID()) })
        _ = try f.makeMissingArchiveRollback(withMedia: true)
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account, vault: vault, journal: journal)
        let now = Date()
        if restoredOrigin {
            let sealed = try recovery.seal(recovery.prepare(now: now), now: now)
            try recovery.cleanup(sealed); try recovery.restore(vaultID: sealed.vaultID, now: now)
            #expect(try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: now))
        }
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let tx = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, validateContext: { _ in })
        if !restoredOrigin { _ = try tx.recover() }
        let ordinary = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context, validateContext: { _ in })
        let pending = try journal.pending()
        let input = try SyncBootstrapOwnedInput(local: nil, sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
            remote: .init(context: context, records: [], attachments: [:], isComplete: true),
            pending: .init(mutations: pending, sourceTreeFingerprint: ordinary.sourceFingerprint()), counterReminderContext: .init())
        let program = try tx.plan(input)
        let prepared = try tx.prepare(input)
        try tx.install(prepared)
        _ = try tx.commit(prepared)
        let expected = try FileSyncMutationJournal(url: f.paths.mutationJournalURL).pending()
        #expect(Array(expected.prefix(pending.count)) == pending)
        let captured = try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
            journal: journal, archiveURL: f.archiveURL)
        #expect(!captured.packet.files.isEmpty)
        #expect(!captured.deletionFiles.isEmpty)
        let sealed = try recovery.seal(recovery.prepare(now: now), now: now)
        let capturedByteCount = try vault.restore(sealed.vaultID, account: f.account, now: now).count
        print("OWNED-CAPTURE origin=\(restoredOrigin ? "restoredSelection" : "legacyRollback") bytes=\(capturedByteCount) bound=\(program.maximumRecoveryEnvelopeBytes)")
        #expect(capturedByteCount <= program.maximumRecoveryEnvelopeBytes)
        try recovery.cleanup(sealed); try recovery.restore(vaultID: sealed.vaultID, now: now)
        #expect(try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: now))
        let actual = try FileSyncMutationJournal(url: f.paths.mutationJournalURL).pending()
        #expect(actual.map(\.mutationID) == expected.map(\.mutationID))
        #expect(actual.map(\.savedRecordVersion) == expected.map(\.savedRecordVersion))
        let restored = try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
            journal: journal, archiveURL: f.archiveURL)
        #expect(restored.packet.files.map(\.bytes) == captured.packet.files.map(\.bytes))
        #expect(restored.deletionLedger == captured.deletionLedger)
        #expect(restored.deletionFiles.map(\.bytes) == captured.deletionFiles.map(\.bytes))
    }

    @Test(arguments: [SyncBootstrapOwnedBoundary.afterSourceSpend, .afterLiveMove, .afterStagedMove, .afterInstalled])
    func installFaultRestoresOriginalAndReissuesExactTerminalOrigin(point: SyncBootstrapOwnedBoundary) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        var fired = false
        let tx = try f.transaction(boundary: { current in
            if current == point, !fired { fired = true; throw OwnedFixtureFailure.injected }
        })
        let prepared = try tx.prepare(f.input())
        #expect(throws: (any Error).self) { try tx.install(prepared) }
        #expect(fired)
        _ = try f.transaction().recover()
        let terminal = try f.manifest()
        guard case .rolledBack = terminal.body else { Issue.record("rollback was not completed"); return }
        let main = try Data(contentsOf: f.source.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json"))
        guard case let .absentSource(source) = try SyncAccountRecoveryControlFile.decode(main),
              case let .bootstrapRollback(id, path, digest) = source.origin else { Issue.record("missing terminal handoff"); return }
        #expect(id == prepared.transactionID)
        #expect(try OwnedBootstrapCodec.hash(Data(contentsOf: f.source.paths.accountRoot.appendingPathComponent(path))) == digest)
        #expect(!FileManager.default.fileExists(atPath: f.source.archiveURL.path))
        #expect(try f.source.journal.pending().isEmpty)
    }

    @Test(arguments: [false, true]) func lostCommittedArchiveNeverRevivesAbsence(remove: Bool) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let tx = try f.transaction(), prepared = try tx.prepare(f.input())
        try tx.install(prepared); _ = try tx.commit(prepared)
        let control = f.source.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let bytes = try Data(contentsOf: control)
        if remove { try FileManager.default.removeItem(at: f.source.archiveURL) }
        else { try Data("corrupt archive".utf8).write(to: f.source.archiveURL) }
        let before = try f.source.diskBytes()
        #expect(throws: (any Error).self) { _ = try f.source.capture() }
        let recovery = SyncAccountRecoveryTransaction(storage: f.source.storage, paths: f.source.paths,
            account: f.source.account, vault: SyncRecoveryVault(directory: f.source.paths.vault, keychain: OwnedBootstrapTestKeys()),
            journal: f.source.journal)
        #expect(try recovery.sourceState(now: .now) == nil)
        #expect(throws: (any Error).self) { _ = try recovery.prepare(now: .now) }
        #expect(try Data(contentsOf: control) == bytes)
        #expect(try f.source.diskBytes() == before)
    }

    @Test(arguments: [false, true], ["generation", "authorityID", "origin"])
    func spentPayloadMustRetainExactFormerSourceIdentity(committed: Bool, damage: String) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let tx = try f.transaction(), prepared = try tx.prepare(f.input())
        try tx.install(prepared)
        if committed { _ = try tx.commit(prepared) }
        let control = f.source.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let bytes = try Data(contentsOf: control)
        guard case let .sourceSpent(source, id, digest) = try SyncAccountRecoveryControlFile.decode(bytes) else {
            Issue.record("expected actual spent control"); return
        }
        let changed = SyncAccountSourceState(authorityID: damage == "authorityID" ? UUID() : source.authorityID,
            generation: damage == "generation" ? UUID() : source.generation,
            accountIDHash: source.accountIDHash, accountRoot: source.accountRoot,
            accountDevice: source.accountDevice, accountInode: source.accountInode,
            archiveURL: source.archiveURL, journalURL: source.journalURL, baselineSHA256: source.baselineSHA256,
            origin: damage == "origin" ? .bootstrapRollback(transactionID: UUID(),
                activeRelativePath: ".KnitNote-SyncBootstrap/changed/active.json", activeEnvelopeSHA256: Data(repeating: 8, count: 32)) : source.origin)
        let replaced = try SyncAccountRecoveryControlFile.encode(.sourceSpent(changed, transactionID: id,
            preparedManifestSHA256: digest), predecessorSHA256: SyncAccountRecoveryControlFile.sourceSpentPredecessor(bytes))
        try replaced.write(to: control)
        let before = try f.source.diskBytes()
        if committed { #expect(throws: (any Error).self) { _ = try f.source.capture() } }
        else { #expect(throws: (any Error).self) { _ = try tx.commit(prepared) } }
        #expect(try f.source.diskBytes() == before)
    }

    @Test func originalControlRaceDuringPreparationCannotPublishFormerSourceWitness() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let control = f.source.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        var changedSnapshot: [String: Data]?
        let tx = try f.transaction(boundary: { point in
            if case .afterPreparationOutput = point, changedSnapshot == nil {
                guard case let .absentSource(source) = try SyncAccountRecoveryControlFile.decode(Data(contentsOf: control)) else {
                    throw OwnedFixtureFailure.injected
                }
                let changed = SyncAccountSourceState(authorityID: source.authorityID, generation: UUID(),
                    accountIDHash: source.accountIDHash, accountRoot: source.accountRoot,
                    accountDevice: source.accountDevice, accountInode: source.accountInode,
                    archiveURL: source.archiveURL, journalURL: source.journalURL,
                    baselineSHA256: source.baselineSHA256, origin: source.origin)
                try SyncAccountRecoveryControlFile.encode(.absentSource(changed), predecessorSHA256: nil).write(to: control)
                changedSnapshot = try f.source.diskBytes()
            }
        })
        #expect(throws: (any Error).self) { _ = try tx.prepare(f.input()) }
        #expect(try f.source.diskBytes() == #require(changedSnapshot))
        guard case .preparing = try f.manifest().body else { Issue.record("race published a terminal or prepared witness"); return }
    }

    @Test func sourceSpentIsDurableBeforeFirstLiveMove() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let oldControl = try SyncAccountRecoveryControlFile.decode(Data(contentsOf:
            f.source.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")))
        let formerSource = try BootstrapManifestV3.formerSourceDigest(oldControl)
        var observed = false
        let tx = try f.transaction(boundary: { point in
            if point == .afterSourceSpend {
                observed = true
                let manifest = try f.manifest()
                let data = try Data(contentsOf: f.source.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json"))
                guard case let .sourceSpent(_, id, digest) = try SyncAccountRecoveryControlFile.decode(data) else {
                    Issue.record("source was not durably spent"); throw OwnedFixtureFailure.injected
                }
                #expect(id == manifest.id)
                #expect(digest == (try SyncBootstrapOwnedManifestCodec.preparedSHA256(manifest)))
                #expect(manifest.body.preparedBody?.formerSourceSHA256 == formerSource)
                #expect(!FileManager.default.fileExists(atPath: f.source.archiveURL.path))
                let root = f.source.paths.accountRoot.appendingPathComponent(manifest.transactionRelativePath)
                #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Staged").path))
                #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Displaced").path))
            }
        })
        let prepared = try tx.prepare(f.input())
        try tx.install(prepared)
        #expect(observed)
        guard case .installed = try f.manifest().body else { Issue.record("installation did not finish"); return }
    }

    @Test func committedSpentCanCompleteAuthenticatedRecovery() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let tx = try f.transaction()
        let program = try tx.plan(f.input())
        let prepared = try tx.prepare(f.input())
        try tx.install(prepared)
        let receipt = try tx.commit(prepared)
        #expect(receipt.transactionID == prepared.transactionID)
        let expected = try FileSyncMutationJournal(url: f.source.paths.mutationJournalURL).pending()
        let vault = SyncRecoveryVault(directory: f.source.paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.source.storage, paths: f.source.paths,
            account: f.source.account, vault: vault, journal: f.source.journal)
        let now = Date()
        let recoveryPrepared = try recovery.prepare(now: now)
        let sealed = try recovery.seal(recoveryPrepared, now: now)
        let capturedByteCount = try vault.restore(sealed.vaultID, account: f.source.account, now: now).count
        print("OWNED-CAPTURE origin=fresh bytes=\(capturedByteCount) bound=\(program.maximumRecoveryEnvelopeBytes)")
        #expect(capturedByteCount <= program.maximumRecoveryEnvelopeBytes)
        try recovery.cleanup(sealed)
        try recovery.restore(vaultID: sealed.vaultID, now: now)
        #expect(try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: now))
        #expect(try f.source.journal.pending() == expected)
    }

    @Test func archiveOriginRetainsNilControlThroughCommitAndAuthenticatedRecovery() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let archive = ProjectArchive(version: ProjectArchive.currentVersion,
            projects: [try StoredProject(name: "Archive source provenance")])
        try JSONEncoder().encode(archive).write(to: f.archiveURL)
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "fixture")
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let tx = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, validateContext: { _ in })
        let input = SyncBootstrapOwnedInput(local: local, sourceArchive: archive,
            remote: .init(context: context, records: [], attachments: [:], isComplete: true),
            pending: nil, counterReminderContext: .init())
        let program = try tx.plan(input), token = try tx.prepare(input)
        try tx.install(token); _ = try tx.commit(token)
        let control = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        #expect(!FileManager.default.fileExists(atPath: control.path))
        let journal = FileSyncMutationJournal(url: f.paths.mutationJournalURL)
        let expected = try journal.pending()
        #expect(!expected.isEmpty)
        let inventory = try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths,
            account: f.account, journal: journal, archiveURL: f.archiveURL)
        guard case .archive = inventory.sourceAuthority else { Issue.record("archive origin changed"); return }
        let evidence = try #require(inventory.bootstrapEvidence)
        let committed = try BootstrapManifestV3.decodeEnvelope(evidence.activeEnvelope)
        guard case let .committed(body) = committed.body else { Issue.record("not committed"); return }
        #expect(body.sourceControlSHA256 == nil)
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: journal)
        let now = Date()
        let sealed = try recovery.seal(recovery.prepare(now: now), now: now)
        let capturedByteCount = try vault.restore(sealed.vaultID, account: f.account, now: now).count
        print("OWNED-CAPTURE origin=archive bytes=\(capturedByteCount) bound=\(program.maximumRecoveryEnvelopeBytes)")
        #expect(capturedByteCount <= program.maximumRecoveryEnvelopeBytes)
        try recovery.cleanup(sealed); try recovery.restore(vaultID: sealed.vaultID, now: now)
        #expect(try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: now))
        #expect(try FileSyncMutationJournal(url: f.paths.mutationJournalURL).pending() == expected)
    }

    @Test func legacyMissingRollbackReceivesDurableSourceBeforeOwnedPlan() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let journal = try f.makeMissingArchiveRollback(withMedia: false)
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let tx = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, validateContext: { _ in })
        let original = try f.diskBytes()
        _ = try tx.recover()
        let controlURL = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let bytes = try Data(contentsOf: controlURL)
        guard case let .absentSource(source) = try SyncAccountRecoveryControlFile.decode(bytes),
              case .bootstrapRollback = source.origin else { Issue.record("missing durable legacy origin"); return }
        _ = try tx.recover()
        #expect(try Data(contentsOf: controlURL) == bytes)
        let after = try f.diskBytes()
        for (path, value) in original { #expect(after[path] == value) }
        let ordinary = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context, validateContext: { _ in })
        let program = try tx.plan(.init(local: nil, sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
            remote: .init(context: context, records: [], attachments: [:], isComplete: true),
            pending: .init(mutations: journal.pending(), sourceTreeFingerprint: ordinary.sourceFingerprint()),
            counterReminderContext: .init()))
        guard case let .preparing(preparing) = try BootstrapManifestV3.decodeEnvelope(program.preparingEnvelope).body else { return }
        #expect(preparing.sourceControlSHA256 == OwnedBootstrapCodec.hash(bytes))
    }

    @Test func emptyRootAbortHandoffCanRetryWithoutChangingHistoricalEnvelope() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let failing = try f.transaction(boundary: { point in
            if point == .beforeTransactionRootCreation { throw OwnedFixtureFailure.injected }
        })
        #expect(throws: (any Error).self) { _ = try failing.prepare(f.input()) }
        let old = try Data(contentsOf: f.namespace.appendingPathComponent("active.json"))
        _ = try f.transaction().recover()
        let retry = try f.transaction()
        let next = try retry.prepare(f.input())
        #expect(next.transactionID != (try BootstrapManifestV3.decodeEnvelope(old)).id)
        let head = try #require(try f.manifest().historyHead)
        let record = try Data(contentsOf: f.namespace.appendingPathComponent("History/" + OwnedBootstrapCodec.hex(head.sha256) + ".json"))
        #expect(try BootstrapHistoryRecordV1.decodeEnvelope(record).terminalEnvelope == old)
    }

    @Test func preparedRestartRejectsSameBaselineDifferentSourceGeneration() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        _ = try f.transaction().prepare(f.input())
        try f.source.storage.withRecoveryOwnership(paths: f.source.paths, account: f.source.account,
            maximumBytes: 100_000_000) { access in
            let file = SyncAccountRecoveryControlFile(synchronize: SyncBootstrapOwnedPOSIX.synchronize)
            let observed = try file.observe(access: access)
            guard case let .absentSource(source) = observed.state else { throw OwnedFixtureFailure.injected }
            let changed = SyncAccountSourceState(authorityID: source.authorityID, generation: UUID(),
                accountIDHash: source.accountIDHash, accountRoot: source.accountRoot,
                accountDevice: source.accountDevice, accountInode: source.accountInode,
                archiveURL: source.archiveURL, journalURL: source.journalURL,
                baselineSHA256: source.baselineSHA256, origin: source.origin)
            _ = try file.replace(observed, with: .absentSource(changed), access: access, validateSource: {})
        }
        let before = try f.source.diskBytes()
        #expect(throws: (any Error).self) { _ = try f.transaction().recover() }
        #expect(try f.source.diskBytes() == before)
    }

    @Test func unspentRollbackCanCompleteAuthenticatedRecovery() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        _ = try f.transaction().prepare(f.input())
        _ = try f.transaction().recover()
        let keys = OwnedBootstrapTestKeys()
        let vault = SyncRecoveryVault(directory: f.source.paths.vault, keychain: keys)
        let recovery = SyncAccountRecoveryTransaction(storage: f.source.storage, paths: f.source.paths,
            account: f.source.account, vault: vault, journal: f.source.journal)
        let now = Date()
        let recoveryPrepared = try recovery.prepare(now: now)
        let sealed = try recovery.seal(recoveryPrepared, now: now)
        try recovery.cleanup(sealed)
        try recovery.restore(vaultID: sealed.vaultID, now: now)
        #expect(try recovery.consumeRestoredSelection(vaultID: sealed.vaultID, now: now))
        #expect(try f.source.journal.pending().isEmpty)
    }

    @Test func preparedBeforeSpendRecoveryRestoresOriginalWithoutSpending() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let tx = try f.transaction()
        let prepared = try tx.prepare(f.input())
        let main = f.source.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let beforeControl = try Data(contentsOf: main)
        let beforeEntries = try f.source.storage.withRecoveryOwnership(paths: f.source.paths,
            account: f.source.account, maximumBytes: 100_000_000) { try $0.entries() }
        #expect(try tx.recover() == nil)
        let terminal = try f.manifest()
        #expect(terminal.id == prepared.transactionID)
        guard case .rolledBack = terminal.body else { Issue.record("prepared must complete rollback"); return }
        let afterEntries = try f.source.storage.withRecoveryOwnership(paths: f.source.paths,
            account: f.source.account, maximumBytes: 100_000_000) { try $0.entries() }
        #expect(afterEntries.filter { $0.relativePath == "working-set" || $0.relativePath.hasPrefix("working-set/") }
            == beforeEntries.filter { $0.relativePath == "working-set" || $0.relativePath.hasPrefix("working-set/") })
        if case .sourceSpent = try SyncAccountRecoveryControlFile.decode(Data(contentsOf: main)) {
            Issue.record("before-spend rollback must never spend source")
        }
        #expect(!beforeControl.isEmpty)
    }

    @Test(arguments: [false, true]) func unresolvedControlDerivativeRejectsWithoutChangingEitherSlot(removeMain: Bool) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let main = f.source.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let next = main.deletingLastPathComponent().appendingPathComponent("intent-next.json")
        let bytes = try Data(contentsOf: main)
        let state = try SyncAccountRecoveryControlFile.decode(bytes)
        let derivative = try SyncAccountRecoveryControlFile.encode(state, predecessorSHA256: OwnedBootstrapCodec.hash(bytes))
        try derivative.write(to: next)
        if removeMain { try FileManager.default.removeItem(at: main) }
        let before = try f.source.diskBytes()
        #expect(throws: (any Error).self) { _ = try f.transaction().plan(f.input()) }
        #expect(try f.source.diskBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: f.namespace.path))
    }

    @Test func unexplainedRawSpellingSiblingNamespaceRejectsEvenWhenEmpty() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
        try JSONEncoder().encode(archive).write(to: f.archiveURL)
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "fixture")
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let raw = OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(f.paths.workingSet.path.utf8)))
        let normalized = OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(f.paths.workingSet.standardizedFileURL.path.utf8)))
        #expect(raw != normalized)
        let sibling = f.paths.accountRoot.appendingPathComponent(".KnitNote-SyncBootstrap/" + f.account.accountIDHash + "/" + raw)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let before = try f.diskBytes()
        #expect(throws: (any Error).self) {
            _ = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
                context: context, validateContext: { _ in }).plan(.init(local: local, sourceArchive: archive,
                    remote: .init(context: context, records: [], attachments: [:], isComplete: true),
                    pending: nil, counterReminderContext: .init()))
        }
        #expect(try f.diskBytes() == before)
        #expect(FileManager.default.fileExists(atPath: sibling.path))
        #expect(!FileManager.default.fileExists(atPath: sibling.deletingLastPathComponent().appendingPathComponent(normalized).path))
    }

    @Test @MainActor func incomingMediaFreeDeletionRetainsSupportingMediaAndLocalValidationIndexes() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let remoteRoot = f.source.base.appendingPathComponent("remote-package")
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        _ = try BackupFixture.writeCompleteArchive(to: remoteRoot)
        let archive = try JSONDecoder().decode(ProjectArchive.self,
            from: Data(contentsOf: remoteRoot.appendingPathComponent("projects-v1.json")))
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: remoteRoot, deviceID: "remote")
        let deleted = try SyncDeletionCaptureProgramTests.request(root: remoteRoot)
        let before = try f.source.diskBytes()
        let p = try f.transaction().plan(.init(local: nil,
            sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
            remote: .init(context: f.context, records: package.records + deleted.currentRecords,
                attachments: package.attachments, isComplete: true),
            pending: nil, counterReminderContext: .init()))
        #expect(p.deletionRequests.count == 1)
        #expect(p.deletionRequests[0].supportingAttachments == package.attachments.mapValues {
            SyncBootstrapOutputProof(byteCount: $0.byteCount, sha256: $0.contentSHA256)
        })
        #expect(p.deletionRequests[0].attachments.isEmpty)
        let validations = p.deletion.steps.enumerated().compactMap { index, step -> (Int, SyncDeletionCaptureProgram.Validation)? in
            if case let .validate(value) = step { return (index, value) }; return nil
        }
        #expect(validations.count == 2)
        for (index, validation) in validations {
            #expect(!validation.sources.isEmpty)
            for stepIndex in validation.sources.values {
                #expect(stepIndex < index)
                guard case .output = p.deletion.steps[stepIndex] else { Issue.record("invalid local output index"); continue }
            }
        }
        let finalLedger = try #require(p.deletion.finalManifestBytes)
        let ledgerAtPublication = try #require(p.publication.expectedInitialTree.files.first { $0.path == ".sync-deletions/ledger.json" })
        #expect(ledgerAtPublication.proof == SyncBootstrapOwnedProgramBuilder.proof(finalLedger))
        let merged = try #require(p.steps.compactMap { step -> KnitNoteBackupFrozenTree? in
            if case let .backup(index, initial, _) = step, p.backupPackages[index].role == .validationMerged { return initial }
            return nil
        }.last)
        for file in p.publication.finalFiles { #expect(merged.files[file.path] == file.proof) }
        #expect(try f.source.diskBytes() == before)
    }

    @Test func actualLegacyArchiveRollbackBecomesExactPendingHistoryWithoutWrites() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "original")])
        try JSONEncoder().encode(archive).write(to: f.archiveURL)
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "legacy")
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let ordinary = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context, validateContext: { _ in })
        let remote = SyncBootstrapRemoteSnapshot(context: context, records: [], attachments: [:], isComplete: true)
        let prior = try ordinary.prepare(local: local, sourceArchive: archive, remote: remote)
        try ordinary.install(prior); try ordinary.rollback(prior)
        let before = try f.diskBytes()
        let p = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, validateContext: { _ in }).plan(.init(local: local, sourceArchive: archive,
                remote: remote, pending: nil, counterReminderContext: .init()))
        let manifest = try BootstrapManifestV3.decodeEnvelope(p.preparingEnvelope)
        guard case let .preparing(body) = manifest.body else { Issue.record("expected preparing"); return }
        #expect(manifest.livePath == f.paths.workingSet.standardizedFileURL.path)
        let pending = try #require(body.predecessor)
        let record = try BootstrapHistoryRecordV1.decodeEnvelope(pending.record)
        #expect(record.transactionID == prior.transactionID)
        #expect(record.previous == nil)
        #expect(!record.treeEntries.isEmpty)
        let active = OwnedBootstrapCodec.parent(manifest.transactionRelativePath) + "/active.json"
        #expect(record.terminalEnvelope == before[f.paths.accountRoot.appendingPathComponent(active).path])
        #expect(try f.diskBytes() == before)
    }

    @Test func selectedRecoveryRejectsAndRealConsumedRestoreAdmitsWithoutOwnedWrites() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let tx = try f.transaction()
        _ = try tx.plan(f.input())
        let vault = SyncRecoveryVault(directory: f.source.paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.source.storage, paths: f.source.paths,
            account: f.source.account, vault: vault, journal: f.source.journal)
        let now = Date()
        let receipt = try recovery.seal(recovery.prepare(now: now), now: now)
        let selected = try f.source.diskBytes()
        #expect(throws: SyncBootstrapError.sourceChanged) { _ = try tx.plan(f.input()) }
        #expect(try f.source.diskBytes() == selected)
        try recovery.cleanup(receipt)
        try recovery.restore(vaultID: receipt.vaultID, now: now)
        #expect(try recovery.consumeRestoredSelection(vaultID: receipt.vaultID, now: now))
        let source = try #require(try recovery.sourceState(now: now))
        guard case let .restoredSelection(vaultID, captureID, _, _, _) = source.origin else {
            Issue.record("expected actual authenticated restored provenance"); return
        }
        #expect(vaultID == receipt.vaultID && captureID == receipt.captureID)
        let ordinary = try SyncBootstrapTransaction(liveRoot: f.source.paths.workingSet,
            context: f.context, validateContext: { _ in })
        let restoredInventory = try f.source.capture()
        let pending = SyncBootstrapPendingSnapshot(mutations: restoredInventory.packet.mutations,
            sourceTreeFingerprint: try ordinary.sourceFingerprint())
        let before = try f.source.diskBytes(), input = f.input()
        let p = try tx.plan(.init(local: nil, sourceArchive: input.sourceArchive, remote: input.remote,
            pending: pending, counterReminderContext: .init()))
        #expect(p.initialControl.state == .absentSource(source))
        #expect(try f.source.diskBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: f.namespace.path))
    }

    @Test func fullLifetimeCapIsInclusiveAndAllocationAloneDoesNotAdmitAttempt() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let id = UUID(), now = Date(timeIntervalSince1970: 100)
        let before = try f.source.diskBytes()
        let full = try f.transaction(transactionID: id, now: now).plan(f.input())
        let cap = full.maximumRecoveryEnvelopeBytes
        let exact = try f.transaction(maximumBytes: cap, transactionID: id, now: now).plan(f.input())
        #expect(exact.preparingEnvelope == full.preparingEnvelope)
        #expect(exact.maximumRecoveryEnvelopeBytes == cap)
        #expect(throws: (any Error).self) {
            _ = try f.transaction(maximumBytes: cap - 1, transactionID: id, now: now).plan(f.input())
        }
        #expect(full.reservation.reservedEncodedEntryBytes < cap - 1)
        #expect(full.preparingEnvelope.count < cap - 1)
        #expect(full.lifetimeScenarios.map(\.name) == ["abortedPreparing", "abortedPreparingNextRetry",
            "preparedRolledBack", "preparedRolledBackNextRetry", "journalFailedRolledBack",
            "journalFailedRolledBackNextRetry", "committed"])
        #expect(full.lifetimeScenarios.map(\.recoveryEnvelopeBytes).max() == cap)
        print("OWNED-BUDGET fresh preparing=\(full.preparingEnvelope.count) entryAllocation=\(full.reservation.reservedEncodedEntryBytes) maxRecovery=\(cap)")
        for scenario in full.lifetimeScenarios {
            print("OWNED-BUDGET \(scenario.name) inventory=\(scenario.inventoryBytes) envelope=\(scenario.recoveryEnvelopeBytes) retryPreparing=\(scenario.nextRetryPreparingBytes.map(String.init) ?? "none")")
        }
        let committed = try #require(full.lifetimeScenarios.first { $0.name == "committed" })
        #expect(full.preparingEnvelope.count < committed.recoveryEnvelopeBytes - 1)
        #expect(throws: (any Error).self) {
            _ = try f.transaction(maximumBytes: committed.recoveryEnvelopeBytes - 1,
                transactionID: id, now: now).plan(f.input())
        }
        #expect(try f.source.diskBytes() == before)
    }

    @Test func journalSuffixUsesNativeTraceAndExactReceiptBinding() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        _ = try BackupFixture.writeCompleteArchive(to: f.paths.workingSet)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: f.archiveURL))
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "owned")
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let p = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, validateContext: { _ in }).plan(.init(local: local, sourceArchive: archive,
                remote: .init(context: context, records: [], attachments: [:], isComplete: true),
                pending: nil, counterReminderContext: .init()))
        let prefix = Array(p.commitProgram.operations.dropLast(2))
        var ids = prefix.compactMap { operation -> UUID? in
            switch operation {
            case let .replace(_, _, _, id), let .copyAttachment(_, _, _, id): return id
            default: return nil
            }
        }
        let native = try FileSyncMutationJournal(url: f.paths.mutationJournalURL).planOwnedEnqueueProjection(
            p.mutations, accountRoot: f.paths.accountRoot, inventoryEntries: p.initialInventory.entries,
            preflightSources: p.attachmentSources.filter { id, _ in p.mutations.contains { $0.recordID.uuid == id && $0.attachmentSource != nil } },
            temporaryID: { ids.removeFirst() })
        #expect(native.commitProgram.operations == prefix)
        #expect(native.commitProgram.initialJournalFiles == p.commitProgram.initialJournalFiles)
        #expect(native.commitProgram.initialJournalDirectories == p.commitProgram.initialJournalDirectories)
        #expect(ids.isEmpty)
        guard case let .replace(path, old, bytes, _) = p.commitProgram.operations[prefix.count] else {
            Issue.record("receipt must use the native replace grammar"); return
        }
        #expect(path == "SyncMetadata/bootstrap-receipt.json")
        #expect(old == nil)
        let receipt = try JSONDecoder().decode(SyncBootstrapReceipt.self, from: bytes)
        #expect(receipt.transactionID == p.transactionID)
        #expect(receipt.accountIDHash == f.account.accountIDHash)
        let expectedArchive = try Data(contentsOf: f.archiveURL)
        #expect(receipt.sourceProof == .archive(sha256: OwnedBootstrapCodec.hash(expectedArchive)))
        #expect(p.commitProgram.operations.last == .synchronize(path: "SyncMetadata"))
        #expect(p.attachmentIdentities.count == p.attachmentSources.count)
    }

    @Test func changedSourceAndStalePendingFingerprintRejectUnchanged() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let before = try f.source.diskBytes()
        let input = f.input()
        let wrong = ProjectArchive(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "not admitted")])
        #expect(throws: (any Error).self) {
            _ = try f.transaction().plan(.init(local: nil, sourceArchive: wrong, remote: input.remote,
                pending: nil, counterReminderContext: .init()))
        }
        let stale = SyncBootstrapPendingSnapshot(mutations: [], sourceTreeFingerprint: Data(repeating: 1, count: 32))
        #expect(throws: SyncBootstrapError.sourceChanged) {
            _ = try f.transaction().plan(.init(local: nil, sourceArchive: input.sourceArchive, remote: input.remote,
                pending: stale, counterReminderContext: .init()))
        }
        #expect(try f.source.diskBytes() == before)
    }

    @Test func originalCopyPreservesOrdinaryLexicalInterleavingAndEarlierOrigins() throws {
        let proof = SyncBootstrapOutputProof(byteCount: 1, sha256: Data(repeating: 1, count: 32))
        var tree = SyncBootstrapOwnedProgramBuilder.Tree()
        tree.directories.formUnion(["a", "z"])
        for path in ["a/child", "m-file", "z/child"] {
            tree.files[path] = .init(proof: proof, origin: .live(path: "working-set/" + path, proof: proof))
        }
        var builder = SyncBootstrapOwnedProgramBuilder()
        try builder.copy(tree, to: .original)
        let copied = builder.actions.map { action -> String in
            switch action {
            case let .directory(_, path): return path + "/"
            case let .write(_, path, _, _): return path
            default: return "unexpected"
            }
        }
        #expect(copied == ["/", "a/", "a/child", "m-file", "z/", "z/child"])
        try builder.copy(builder.trees[.original]!, to: .staged)
        let source = try #require(builder.trees[.staged]?.files["m-file"])
        guard case let .output(index, _) = source.origin,
              case let .output(output) = builder.steps[index],
              case let .copy(.output(originalIndex, _))? = output.content else {
            Issue.record("initial Staged copy must retain the earlier Original output identity"); return
        }
        #expect(originalIndex < index)
    }

    @Test func replanningOneAttemptKeepsEveryGeneratedOutputIdentityAndExactEnvelope() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let tx = try f.transaction()
        let first = try tx.plan(f.input())
        let second = try tx.plan(f.input())
        #expect(first.transactionID == second.transactionID)
        #expect(first.actions == second.actions)
        #expect(first.preparingEnvelope == second.preparingEnvelope)
        #expect(first.maximumRecoveryEnvelopeBytes == second.maximumRecoveryEnvelopeBytes)
    }

    @Test func archiveMediaPlanRetainsBackupAndValidationOrderWithoutWriting() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        _ = try BackupFixture.writeCompleteArchive(to: f.paths.workingSet)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: f.archiveURL))
        let local = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: f.paths.workingSet, deviceID: "owned-fixture")
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let id = UUID(), now = Date(timeIntervalSince1970: 100)
        let tx = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, transactionID: id, now: now, validateContext: { candidate in
                guard candidate == context else { throw SyncBootstrapError.contextChanged }
            })
        let before = try f.diskBytes()
        let p = try tx.plan(.init(local: local, sourceArchive: archive,
            remote: .init(context: context, records: [], attachments: [:], isComplete: true),
            pending: nil, counterReminderContext: .init()))
        #expect(p.backupPackages.map(\.role) == [.validationOriginal, .validationMerged])
        let significant = p.steps.compactMap { step -> String? in
            switch step {
            case let .backup(index, _, _): return p.backupPackages[index].role == .validationOriginal ? "originalBackup" : "mergedBackup"
            case .validateLocal: return "localRoundtrip"
            case .validateMaterialization: return "materialization"
            case .deletion: return "deletion"
            case .publication: return "publication"
            case .output: return nil
            }
        }
        #expect(significant == ["originalBackup", "localRoundtrip", "materialization", "deletion", "publication", "mergedBackup"])
        #expect(!p.projection.files.isEmpty)
        #expect(p.publication.expectedInitialTree.files.contains { $0.path == "SyncMetadata/bootstrap-canonical.json" })
        #expect(p.reservation.reservations.count == 5)
        let abortRetry = try #require(p.lifetimeScenarios.first { $0.name == "abortedPreparingNextRetry" })
        #expect(p.reservation.reservedEncodedEntryBytes < abortRetry.recoveryEnvelopeBytes - 1)
        #expect(throws: (any Error).self) {
            let bounded = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
                context: context, maximumBytes: abortRetry.recoveryEnvelopeBytes - 1,
                transactionID: id, now: now, validateContext: { _ in })
            _ = try bounded.plan(.init(local: local, sourceArchive: archive,
                remote: .init(context: context, records: [], attachments: [:], isComplete: true),
                pending: nil, counterReminderContext: .init()))
        }
        #expect(try f.diskBytes() == before)
    }

    @Test func legacyMissingRollbackWithoutDurableSourceControlRejectsUnchanged() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let journal = try f.makeMissingArchiveRollback()
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let ordinary = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: context, validateContext: { _ in })
        let pending = try SyncBootstrapPendingSnapshot(mutations: journal.pending(), sourceTreeFingerprint: ordinary.sourceFingerprint())
        let before = try f.diskBytes()
        let tx = try SyncBootstrapOwnedTransaction(storage: f.storage, paths: f.paths, account: f.account,
            context: context, validateContext: { _ in })
        #expect(throws: SyncBootstrapError.sourceChanged) {
            _ = try tx.plan(.init(local: nil, sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
                remote: .init(context: context, records: [], attachments: [:], isComplete: true),
                pending: pending, counterReminderContext: .init()))
        }
        #expect(try f.diskBytes() == before)
    }

    @Test func selectedRemoteSymlinkAncestorRejectsBeforeAnyOwnedOutput() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let remoteRoot = f.source.base.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        _ = try BackupFixture.writeCompleteArchive(to: remoteRoot)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: remoteRoot.appendingPathComponent("projects-v1.json")))
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: remoteRoot, deviceID: "remote")
        let alias = f.source.base.appendingPathComponent("remote-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: remoteRoot)
        var sources = package.attachments
        let id = try #require(sources.keys.first)
        let source = try #require(sources[id])
        let relative = String(source.fileURL.path.dropFirst(remoteRoot.path.count + 1))
        sources[id] = try .init(fileURL: alias.appendingPathComponent(relative),
            contentSHA256: source.contentSHA256, byteCount: source.byteCount)
        let before = try f.source.diskBytes()
        #expect(throws: (any Error).self) {
            _ = try f.transaction().plan(.init(local: nil,
                sourceArchive: .init(version: ProjectArchive.currentVersion, projects: []),
                remote: .init(context: f.context, records: package.records, attachments: sources, isComplete: true),
                pending: nil, counterReminderContext: .init()))
        }
        #expect(try f.source.diskBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: f.namespace.path))
    }

    @Test func freshMissingSourcePlanLeavesCompleteDiskAndControlUntouched() throws {
        let fixture = try OwnedBootstrapFixture()
        defer { fixture.remove() }
        let before = try fixture.source.capture()
        let disk = try fixture.source.diskBytes()
        let program = try fixture.transaction().plan(fixture.input())
        #expect(program.maximumRecoveryEnvelopeBytes > program.reservation.reservedEncodedEntryBytes)
        #expect(program.maximumRecoveryEnvelopeBytes <= 100_000_000)
        #expect(program.backupPackages.count == 1)
        #expect(program.backupPackages.first?.role == .validationMerged)
        #expect(!program.preparingEnvelope.isEmpty)
        #expect(try fixture.source.capture().entries == before.entries)
        #expect(try fixture.source.diskBytes() == disk)
        #expect(!FileManager.default.fileExists(atPath: fixture.namespace.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.source.archiveURL.path))
    }

    @Test func unaffordablePlanCreatesNoSelectorHistoryOrTransactionTree() throws {
        let fixture = try OwnedBootstrapFixture()
        defer { fixture.remove() }
        let before = try fixture.source.capture()
        let disk = try fixture.source.diskBytes()
        #expect(throws: (any Error).self) {
            _ = try fixture.transaction(maximumBytes: 1).plan(fixture.input())
        }
        #expect(try fixture.source.capture().entries == before.entries)
        #expect(try fixture.source.diskBytes() == disk)
        #expect(!FileManager.default.fileExists(atPath: fixture.namespace.path))
    }
}
