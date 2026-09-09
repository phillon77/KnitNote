import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncBootstrapOwnedCommitCrashTests {
    private static let childKey = "KNITNOTE_OWNED_COMMIT_CHILD"
    private static let rootKey = "KNITNOTE_OWNED_COMMIT_ROOT"
    private static let projectName = "Matrix source"
    private static let sourceMutation = OwnedMatrixFixture.mutation(707)

    // Break caught: receipt existence is confused with committed native state,
    // or recovering a committed transaction enqueues the same import again.
    @Test(arguments: ["after-receipt", "after-commit"])
    func receiptBoundaryReopensWithoutDuplicateImport(cut: String) throws {
        guard ProcessInfo.processInfo.environment[Self.childKey] == nil else { return }
        let fixture = try Self.launchCommittedChild(cut: cut)
        var succeeded = false
        defer { fixture.finish(success: succeeded) }

        let before = try Self.snapshot(named: "before", fixture: fixture)
        let installed = try Self.snapshot(named: "installed", fixture: fixture)
        try Self.requireNamedProject(in: before, context: "before snapshot")
        try Self.requireNamedProject(in: installed, context: "installed snapshot")

        let account = try Self.account()
        let storage = SyncAccountStorage(baseURL: fixture.storeRoot)
        let paths = try storage.openExistingAccount(identity: account, validateAccount: {})
        let manifest = try OwnedMatrixFixture.manifest(paths, account: account)
        try Self.requirePhase(manifest, expected: cut == "after-receipt" ? "installed" : "committed")
        try Self.requireInstalledSnapshot(installed, matches: manifest)

        let receiptBytes = try Data(contentsOf: paths.workingSet
            .appendingPathComponent("SyncMetadata/bootstrap-receipt.json"))
        let receipt = try JSONDecoder().decode(SyncBootstrapReceipt.self, from: receiptBytes)
        try Self.require(receipt.transactionID == manifest.id, "receipt transaction does not match selected manifest")
        try Self.require(receipt.accountIDHash == account.accountIDHash, "receipt account does not match reopened account")

        let context = SyncBootstrapContext(accountIDHash: account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let transaction = try SyncBootstrapOwnedTransaction(storage: storage, paths: paths, account: account,
            context: context, validateContext: { candidate in
                guard candidate == context else { throw SyncBootstrapError.contextChanged }
            })
        let nativeBeforeRecovery = try OwnedMatrixFixture.files(paths.accountRoot)
        let journalBeforeRecovery = try FileSyncMutationJournal(url: paths.mutationJournalURL).recoverySnapshot().mutations

        if cut == "after-receipt" {
            try Self.require(!journalBeforeRecovery.isEmpty, "after-receipt journal is unexpectedly empty")
            try Self.require(try transaction.recover() == nil, "installed receipt cut issued committed authority")
            guard case .rolledBack = try OwnedMatrixFixture.manifest(paths, account: account).body else {
                throw CommitCrashTestFailure.expectation("after-receipt recovery did not select rolledBack")
            }
            try Self.require(try OwnedMatrixFixture.files(paths.workingSet) == before,
                "after-receipt rollback did not restore exact source bytes")
            let restored = try FileSyncMutationJournal(url: paths.mutationJournalURL).recoverySnapshot().mutations
            try Self.require(restored.map(\.mutationID) == [Self.sourceMutation.mutationID],
                "rollback did not restore the one literal source mutation in order")
            try Self.requireNamedProject(at: paths.workingSet, context: "first rollback reopen")
        } else {
            try Self.require(!journalBeforeRecovery.isEmpty, "committed journal is unexpectedly empty")
            let handoff = try Self.requireValue(try transaction.recover(), "committed recovery returned nil")
            try Self.require(handoff.transactionID == manifest.id, "committed handoff changed transaction")
            try Self.require(handoff.checkpoint.records.contains {
                $0.payload.fields["name"]?.value == .string(Self.projectName)
            }, "committed handoff lost the literal project domain")
            try Self.requireNamedProject(at: paths.workingSet, context: "first committed reopen")
            try Self.require(try FileSyncMutationJournal(url: paths.mutationJournalURL).recoverySnapshot().mutations
                == journalBeforeRecovery, "first committed recovery changed journal mutations")
            try Self.require(try OwnedMatrixFixture.files(paths.accountRoot) == nativeBeforeRecovery,
                "first committed recovery changed retained account bytes")
        }

        try storage.close()
        let firstTerminalBytes = try Self.accountBytes(fixture: fixture, account: account)
        let secondStorage = SyncAccountStorage(baseURL: fixture.storeRoot)
        let secondPaths = try secondStorage.openExistingAccount(identity: account, validateAccount: {})
        let secondContext = SyncBootstrapContext(accountIDHash: account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let second = try SyncBootstrapOwnedTransaction(storage: secondStorage, paths: secondPaths, account: account,
            context: secondContext, validateContext: { candidate in
                guard candidate == secondContext else { throw SyncBootstrapError.contextChanged }
            })
        if cut == "after-receipt" {
            try Self.require(try second.recover() == nil, "rolled-back second recovery issued authority")
            try Self.require(try OwnedMatrixFixture.files(secondPaths.workingSet) == before,
                "second rollback reopen changed exact source bytes")
            let journal = try FileSyncMutationJournal(url: secondPaths.mutationJournalURL).recoverySnapshot().mutations
            try Self.require(journal.map(\.mutationID) == [Self.sourceMutation.mutationID],
                "second rollback reopen changed journal IDs or order")
        } else {
            let handoff = try Self.requireValue(try second.recover(), "second committed recovery returned nil")
            try Self.require(handoff.transactionID == manifest.id, "second committed recovery changed transaction")
            let journal = try FileSyncMutationJournal(url: secondPaths.mutationJournalURL).recoverySnapshot().mutations
            try Self.require(journal == journalBeforeRecovery, "second committed recovery duplicated or reordered journal")
        }
        try Self.requireNamedProject(at: secondPaths.workingSet, context: "second same-root reopen")
        try secondStorage.close()
        try Self.require(try Self.accountBytes(fixture: fixture, account: account) == firstTerminalBytes,
            "repeated same-root recovery changed retained account bytes")

        succeeded = true
        print("OWNED-COMMIT cut=\(cut) childExit=86 sameRootTwice=yes beforeFiles=\(before.count) installedFiles=\(installed.count)")
    }

    // Break caught: missing, malformed, or differently-bound committed receipts
    // are accepted, or rejection mutates the only retained recovery evidence.
    @Test(arguments: ["missing", "corrupt", "wrong-account", "wrong-transaction"])
    func invalidCommittedReceiptPreservesEvidence(damage: String) throws {
        guard ProcessInfo.processInfo.environment[Self.childKey] == nil else { return }
        let fixture = try Self.launchCommittedChild(cut: "after-commit")
        var succeeded = false
        defer { fixture.finish(success: succeeded) }

        let account = try Self.account()
        let before = try Self.snapshot(named: "before", fixture: fixture)
        let installed = try Self.snapshot(named: "installed", fixture: fixture)
        try Self.requireNamedProject(in: before, context: "damaged fixture before snapshot")
        try Self.requireNamedProject(in: installed, context: "damaged fixture installed snapshot")

        let paths = Self.directPaths(fixture: fixture, account: account)
        let selected = try BootstrapManifestV3.decodeEnvelope(Data(contentsOf: paths.manifest))
        guard case .committed = selected.body else {
            throw CommitCrashTestFailure.expectation("damage fixture is not committed before mutation")
        }
        try Self.requireInstalledSnapshot(installed, matches: selected)
        try Self.damageReceipt(paths.receipt, kind: damage, account: account)
        let damagedBytes = try OwnedMatrixFixture.files(paths.accountRoot)

        let storage = SyncAccountStorage(baseURL: fixture.storeRoot)
        var observed: Error?
        do {
            let opened = try storage.openExistingAccount(identity: account, validateAccount: {})
            let context = SyncBootstrapContext(accountIDHash: account.accountIDHash, epoch: UUID(), freezeID: UUID())
            let transaction = try SyncBootstrapOwnedTransaction(storage: storage, paths: opened, account: account,
                context: context, validateContext: { candidate in
                    guard candidate == context else { throw SyncBootstrapError.contextChanged }
                })
            _ = try transaction.recover()
        } catch {
            observed = error
        }
        try storage.close()
        let rejection = try Self.requireValue(observed, "damaged committed receipt was accepted: \(damage)")
        try Self.require((rejection as? SyncBootstrapError) == .corrupt,
            "unexpected receipt rejection for \(damage): \(String(reflecting: rejection))")
        try Self.require(try OwnedMatrixFixture.files(paths.accountRoot) == damagedBytes,
            "receipt rejection changed retained account bytes: \(damage)")

        succeeded = true
        print("OWNED-COMMIT damage=\(damage) rejected=\(String(reflecting: rejection)) evidenceUnchanged=yes")
    }

    @Test func nativeCommitCrashWorker() throws {
        guard let cut = ProcessInfo.processInfo.environment[Self.childKey],
              let rootPath = ProcessInfo.processInfo.environment[Self.rootKey] else { return }
        let root = URL(fileURLWithPath: rootPath)
        guard ["after-receipt", "after-commit"].contains(cut),
              root.lastPathComponent.hasPrefix("owned-commit-crash-"),
              !FileManager.default.fileExists(atPath: root.path) else {
            throw CommitCrashTestFailure.invalidChildConfiguration
        }

        func mark(_ phase: String) {
            let line = "OWNED-COMMIT-CHILD cut=\(cut) phase=\(phase) root=\(root.path)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }

        mark("fixture-begin")
        let fixture = try OwnedMatrixFixture(root: root, media: false)
        try fixture.journal.enqueue(Self.sourceMutation)
        let input = try fixture.input()
        let before = try OwnedMatrixFixture.files(fixture.paths.workingSet)
        try JSONEncoder().encode(before).write(to: root.appendingPathComponent("before.json"))
        try Self.require(!before.isEmpty, "child source snapshot is empty")
        try Self.requireNamedProject(in: before, context: "child source")
        try Self.require(try fixture.journal.recoverySnapshot().mutations.map(\.mutationID)
            == [Self.sourceMutation.mutationID], "child did not persist literal source mutation")

        let transaction = try fixture.transaction(boundary: { boundary in
            if cut == "after-receipt", boundary == .afterReceipt {
                mark("after-receipt")
                Darwin._exit(86)
            }
        })
        mark("prepare-begin")
        let token = try transaction.prepare(input)
        try transaction.install(token)
        let installed = try OwnedMatrixFixture.files(fixture.paths.workingSet)
        try JSONEncoder().encode(installed).write(to: root.appendingPathComponent("installed.json"))
        try Self.require(!installed.isEmpty, "child installed snapshot is empty")
        mark("installed-snapshot-ready")
        _ = try transaction.commit(token)
        if cut == "after-commit" {
            mark("after-commit")
            Darwin._exit(86)
        }
        throw CommitCrashTestFailure.expectation("child did not reach requested cut: \(cut)")
    }

    private static func launchCommittedChild(cut: String) throws -> ChildFixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("owned-commit-crash-" + UUID().uuidString)
        try require(!FileManager.default.fileExists(atPath: root.path), "child root already exists")
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("owned-commit-crash-\(cut)-\(UUID().uuidString).log")
        try require(FileManager.default.createFile(atPath: log.path, contents: nil), "could not create child log")
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }

        let child = Process()
        let executable = try requireValue(Bundle.main.executableURL, "test helper executable is unavailable")
        try require(executable.lastPathComponent == "swiftpm-testing-helper", "unexpected child executable")
        child.executableURL = executable
        var arguments: [String] = []
        let inherited = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < inherited.count {
            let argument = inherited[index]
            if argument == "--filter" {
                index += min(2, inherited.count - index)
            } else if argument.hasPrefix("--filter=") {
                index += 1
            } else {
                arguments.append(argument)
                index += 1
            }
        }
        child.arguments = arguments + ["--filter", "SyncBootstrapOwnedCommitCrashTests/nativeCommitCrashWorker"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "KNITNOTE_RUN_CLOUDKIT_INTEGRATION")
        environment[childKey] = cut
        environment[rootKey] = root.path
        child.environment = environment
        child.standardOutput = output
        child.standardError = output
        print("OWNED-COMMIT childLog=\(log.path) root=\(root.path)")
        do {
            try child.run()
        } catch {
            print("OWNED-COMMIT launchFailure root=\(root.path) log=\(log.path) error=\(String(reflecting: error))")
            throw error
        }

        let deadline = Date().addingTimeInterval(60)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning {
            child.terminate()
            let grace = Date().addingTimeInterval(2)
            while child.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            print("OWNED-COMMIT timeout root=\(root.path) log=\(log.path) exit=\(child.terminationStatus)")
            throw CommitCrashTestFailure.childTimeout
        }
        child.waitUntilExit()
        guard child.terminationReason == .exit, child.terminationStatus == 86 else {
            print("OWNED-COMMIT unexpectedExit root=\(root.path) log=\(log.path) exit=\(child.terminationStatus)")
            throw CommitCrashTestFailure.childExit(child.terminationStatus)
        }
        return .init(root: root, log: log)
    }

    private static func snapshot(named name: String, fixture: ChildFixture) throws -> [String: Data] {
        let url = fixture.root.appendingPathComponent(name + ".json")
        return try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: url))
    }

    private static func account() throws -> SyncAccountIdentity {
        try .init(containerIdentifier: "test", userRecordName: "owned-matrix")
    }

    private struct DirectPaths {
        let accountRoot: URL
        let receipt: URL
        let manifest: URL
    }

    private static func directPaths(fixture: ChildFixture, account: SyncAccountIdentity) -> DirectPaths {
        let accountRoot = fixture.storeRoot.appendingPathComponent(account.accountIDHash)
        let workingSet = accountRoot.appendingPathComponent("working-set")
        let namespace = accountRoot.appendingPathComponent(".KnitNote-SyncBootstrap/" + account.accountIDHash + "/"
            + OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(workingSet.standardizedFileURL.path.utf8))))
        return .init(accountRoot: accountRoot,
            receipt: workingSet.appendingPathComponent("SyncMetadata/bootstrap-receipt.json"),
            manifest: namespace.appendingPathComponent("active.json"))
    }

    private static func accountBytes(fixture: ChildFixture, account: SyncAccountIdentity) throws -> [String: Data] {
        try OwnedMatrixFixture.files(directPaths(fixture: fixture, account: account).accountRoot)
    }

    private static func requireInstalledSnapshot(_ snapshot: [String: Data], matches manifest: BootstrapManifestV3) throws {
        let prepared: BootstrapManifestV3.PreparedBody
        switch manifest.body {
        case let .installed(value), let .committed(value): prepared = value
        default: throw CommitCrashTestFailure.expectation("selected phase has no installed snapshot")
        }
        let actual = snapshot.mapValues {
            BootstrapManifestV3.FileProof(bytes: Int64($0.count), digest: OwnedBootstrapCodec.hash($0))
        }
        let expected = prepared.installed.filter { $0.value.bytes >= 0 }
        try require(actual == expected, "child installed snapshot does not match selected native manifest")
    }

    private static func requirePhase(_ manifest: BootstrapManifestV3, expected: String) throws {
        let actual: String
        switch manifest.body {
        case .preparing: actual = "preparing"
        case .prepared: actual = "prepared"
        case .installed: actual = "installed"
        case .committed: actual = "committed"
        case .rollingBack: actual = "rollingBack"
        case .rolledBack: actual = "rolledBack"
        case .abortedPreparation: actual = "abortedPreparation"
        }
        try require(actual == expected, "expected native phase \(expected), observed \(actual)")
    }

    private static func requireNamedProject(in files: [String: Data], context: String) throws {
        let bytes = try requireValue(files["projects-v1.json"], "\(context) has no project archive")
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: bytes)
        try require(archive.projects.map(\.name) == [projectName], "\(context) lost literal project domain")
    }

    private static func requireNamedProject(at workingSet: URL, context: String) throws {
        let archive = try JSONDecoder().decode(ProjectArchive.self,
            from: Data(contentsOf: workingSet.appendingPathComponent("projects-v1.json")))
        try require(archive.projects.map(\.name) == [projectName], "\(context) lost literal project domain")
    }

    private static func damageReceipt(_ url: URL, kind: String, account: SyncAccountIdentity) throws {
        if kind == "missing" {
            try FileManager.default.removeItem(at: url)
            return
        }
        if kind == "corrupt" {
            try Data("not a bootstrap receipt".utf8).write(to: url)
            return
        }
        let originalBytes = try Data(contentsOf: url)
        let original = try JSONDecoder().decode(SyncBootstrapReceipt.self, from: originalBytes)
        let changed: SyncBootstrapReceipt
        if kind == "wrong-account" {
            changed = .init(transactionID: original.transactionID,
                accountIDHash: account.accountIDHash + "-different", sourceProof: original.sourceProof)
        } else if kind == "wrong-transaction" {
            changed = .init(transactionID: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
                accountIDHash: original.accountIDHash, sourceProof: original.sourceProof)
        } else {
            throw CommitCrashTestFailure.expectation("unknown receipt damage: \(kind)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(changed)
        let decoded = try JSONDecoder().decode(SyncBootstrapReceipt.self, from: bytes)
        try require(decoded.sourceProof == original.sourceProof, "receipt damage changed source proof")
        if kind == "wrong-account" {
            try require(decoded.transactionID == original.transactionID, "wrong-account changed transaction")
        } else {
            try require(decoded.accountIDHash == original.accountIDHash, "wrong-transaction changed account")
        }
        try bytes.write(to: url)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CommitCrashTestFailure.expectation(message) }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw CommitCrashTestFailure.expectation(message) }
        return value
    }

    private struct ChildFixture {
        let root: URL
        let log: URL
        var storeRoot: URL { root.appendingPathComponent("store") }

        func finish(success: Bool) {
            if success {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: log)
            } else {
                print("OWNED-COMMIT retainedFailureRoot=\(root.path) retainedLog=\(log.path)")
            }
        }
    }
}

private enum CommitCrashTestFailure: Error {
    case invalidChildConfiguration
    case childTimeout
    case childExit(Int32)
    case expectation(String)
}
