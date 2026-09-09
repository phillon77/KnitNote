import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncBootstrapOwnedInterruptionMatrixTests {
    // Break caught: any helper may advance after failed descriptor IO, omit an
    // allocated role from exact abort freeze, or lose that evidence on restart.
    @Test(arguments: ["Original", "Staged", "Attachments", "ValidationOriginal", "ValidationMerged"],
        ["before-write", "partial-write", "after-write", "before-file-sync", "after-file-sync", "before-parent-sync", "after-parent-sync"])
    func everyRoleRetainsActualWriteAndDurabilityCut(role: String, cut: String) throws {
        // A real small archive exercises the same native role output program;
        // Attachments and the separate complete helper trace retain full media.
        let f = try OwnedMatrixFixture(media: role == "Attachments"); defer { f.remove() }
        let before = try OwnedMatrixFixture.files(f.paths.workingSet)
        var temporary: String?, destination: String?, hit = false, laterWrites = 0
        var expected = Data()
        func fail() throws { hit = true; throw OwnedFixtureFailure.injected }
        let io = SyncBootstrapOwnedIO(write: { fd, bytes in
            let path = try OwnedMatrixFixture.descriptorPath(fd)
            if hit, !path.hasSuffix("/active-next.json") { laterWrites += 1 }
            if hit, path.hasSuffix("/active-next.json") {
                guard case .abortedPreparation = try BootstrapManifestV3.decodeEnvelope(bytes).body else {
                    Issue.record("forward selector after failed preparation output"); throw OwnedFixtureFailure.injected
                }
            }
            if temporary == nil, path.contains("/" + role + "/"), bytes.count > 7 {
                temporary = path; expected = bytes
                let url = URL(fileURLWithPath: path)
                destination = url.deletingLastPathComponent().appendingPathComponent(String(url.lastPathComponent.dropFirst().dropLast(41))).path
                if cut == "before-write" { expected = Data(); try fail() }
                if cut == "partial-write" { expected = Data(bytes.prefix(7)); try SyncBootstrapOwnedPOSIX.write(fd, expected); try fail() }
                try SyncBootstrapOwnedPOSIX.write(fd, bytes)
                if cut == "after-write" { try fail() }
                return
            }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        }, synchronize: { fd in
            let path = try OwnedMatrixFixture.descriptorPath(fd)
            if !hit, let temporary {
                if path == temporary {
                    if cut == "before-file-sync" { try fail() }
                    try SyncBootstrapOwnedPOSIX.synchronize(fd)
                    if cut == "after-file-sync" { try fail() }
                    return
                }
                if path == URL(fileURLWithPath: temporary).deletingLastPathComponent().path,
                   !FileManager.default.fileExists(atPath: temporary) {
                    #expect(FileManager.default.fileExists(atPath: try #require(destination)))
                    if cut == "before-parent-sync" { try fail() }
                    try SyncBootstrapOwnedPOSIX.synchronize(fd)
                    if cut == "after-parent-sync" { try fail() }
                    return
                }
            }
            try SyncBootstrapOwnedPOSIX.synchronize(fd)
        })
        #expect(throws: OwnedFixtureFailure.self) { try f.transaction(io: io).prepare(f.input()) }
        #expect(hit && laterWrites == 0)
        let selected = try OwnedMatrixFixture.manifest(f.paths, account: f.account)
        guard case let .abortedPreparation(abort) = selected.body else { Issue.record("expected exact abort"); return }
        let retained = try #require(cut.contains("parent-sync") ? destination : temporary)
        #expect(try Data(contentsOf: URL(fileURLWithPath: retained)) == expected)
        let frozen = try #require(abort.frozenOutputEntries.first { f.paths.accountRoot.appendingPathComponent($0.relativePath).path == retained })
        #expect(frozen.byteCount == expected.count && frozen.sha256 == OwnedBootstrapCodec.hash(expected))
        #expect(try OwnedMatrixFixture.files(f.paths.workingSet) == before)
        #expect(!FileManager.default.fileExists(atPath: f.namespace.appendingPathComponent("active-next.json").path))
        #expect(!FileManager.default.fileExists(atPath: f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json").path))
        try f.storage.close()
        let reopened = SyncAccountStorage(baseURL: f.root.appendingPathComponent("store"))
        let paths = try reopened.openExistingAccount(identity: f.account, validateAccount: {})
        defer { try? reopened.close() }
        let context = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        _ = try SyncBootstrapOwnedTransaction(storage: reopened, paths: paths, account: f.account, context: context,
            validateContext: { _ in }).recover()
        #expect(try OwnedMatrixFixture.manifest(paths, account: f.account) == selected)
        #expect(try Data(contentsOf: URL(fileURLWithPath: retained)) == expected)
        try OwnedMatrixFixture.authenticate(storage: reopened, paths: paths, account: f.account)
        print("OWNED-MATRIX role=\(role) cut=\(cut) bytes=\(expected.count) frozen=\(frozen.inode) authenticated=yes")
    }

    // Break caught: failed live journal bytes are repaired by an ordinary loader
    // before owned rollback, or the exact legal partial prefix cannot be sealed.
    @Test(arguments: ["before-root", "journal-append", "journal-shard", "journal-checkpoint", "journal-shard-published", "journal-checkpoint-published", "journal-segment", "journal-attachment", "receipt-write", "receipt-sync", "rollback-intent", "original-restored"], ["ordinary", "authenticated"])
    func abruptNativeCutReopensForIndependentRecoveryRoutes(cut: String, route: String) throws {
        guard ProcessInfo.processInfo.environment["KNITNOTE_OWNED_MATRIX_CHILD"] == nil else { return }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("owned-matrix-crash-" + UUID().uuidString)
        var retainFailureRoot = false
        defer { if !retainFailureRoot { try? FileManager.default.removeItem(at: root) } }
        let child = Process(), executable = try #require(Bundle.main.executableURL)
        #expect(executable.lastPathComponent == "swiftpm-testing-helper")
        child.executableURL = executable
        var arguments: [String] = [], skip = false
        for argument in CommandLine.arguments.dropFirst() {
            if skip { skip = false; continue }
            if argument == "--filter" { skip = true; continue }
            arguments.append(argument)
        }
        child.arguments = arguments + ["--filter", "SyncBootstrapOwnedInterruptionMatrixTests/nativeCrashWorker"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "KNITNOTE_RUN_CLOUDKIT_INTEGRATION")
        environment["KNITNOTE_OWNED_MATRIX_CHILD"] = cut
        environment["KNITNOTE_OWNED_MATRIX_ROOT"] = root.path
        child.environment = environment
        let childLog = FileManager.default.temporaryDirectory.appendingPathComponent("owned-matrix-child-" + cut + "-" + UUID().uuidString + ".log")
        #expect(FileManager.default.createFile(atPath: childLog.path, contents: nil))
        let output = try FileHandle(forWritingTo: childLog)
        defer { try? output.close() }
        child.standardOutput = output; child.standardError = output
        print("OWNED-MATRIX childLog=\(childLog.path)")
        try child.run()
        let deadline = Date().addingTimeInterval(60)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning {
            retainFailureRoot = true
            child.terminate()
            let grace = Date().addingTimeInterval(2)
            while child.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            print("OWNED-MATRIX incompleteRoot=\(root.path) childExit=\(child.terminationStatus)")
            Issue.record("matrix child timeout: \(cut); interruption evidence incomplete"); return
        }
        child.waitUntilExit()
        guard child.terminationReason == .exit, child.terminationStatus == 86 else {
            retainFailureRoot = true
            print("OWNED-MATRIX incompleteRoot=\(root.path)")
            Issue.record("matrix child did not reach \(cut), exit \(child.terminationStatus)"); return
        }
        let before = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: root.appendingPathComponent("before.json")))
        let account = try SyncAccountIdentity(containerIdentifier: "test", userRecordName: "owned-matrix")
        let storage = SyncAccountStorage(baseURL: root.appendingPathComponent("store"))
        let paths = try storage.openExistingAccount(identity: account, validateAccount: {})
        defer { try? storage.close() }
        let active = try OwnedMatrixFixture.manifest(paths, account: account)
        let evidence = try (try? Data(contentsOf: root.appendingPathComponent("cut.json"))).map {
            try JSONDecoder().decode(OwnedMatrixFixture.CrashCut.self, from: $0)
        }
        let publicationBaseline = try (try? Data(contentsOf: root.appendingPathComponent("installed.json"))).map {
            try JSONDecoder().decode(NativePublicationBaseline.self, from: $0)
        }
        if let evidence {
            #expect(try Data(contentsOf: OwnedMatrixFixture.namespace(paths, account: account).appendingPathComponent("active.json")) == evidence.active)
            #expect((try? Data(contentsOf: paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json"))) == evidence.control)
        }
        if cut == "before-root" {
            guard case .preparing = active.body else { Issue.record("expected durable preparing"); return }
            #expect(!FileManager.default.fileExists(atPath: paths.accountRoot.appendingPathComponent(active.transactionRelativePath).path))
            #expect(try OwnedMatrixFixture.files(paths.workingSet) == before)
        }
        if cut.hasSuffix("-published") {
            let baseline = try #require(publicationBaseline), evidence = try #require(evidence)
            guard case let .installed(prepared) = active.body else { Issue.record("publication cut advanced selector"); return }
            let index = try #require(prepared.commitProgram.operations.firstIndex {
                guard case let .replace(path, _, _, _) = $0 else { return false }
                return cut == "journal-shard-published" ? path.contains("pending.json.proofs.") : path.hasSuffix("pending.json.checkpoint")
            })
            guard case let .replace(path, old, published, temporaryID) = prepared.commitProgram.operations[index] else { return }
            let live = try OwnedMatrixFixture.files(paths.workingSet)
            #expect(evidence.relativePath == path && evidence.bytes == published)
            #expect(live[path] == published && baseline.files[path] != published)
            #expect(old?.value == baseline.files[path].map(SyncBootstrapOwnedPOSIX.proof))
            #expect(live[Self.temporaryPath(path, id: temporaryID)] == nil)
            #expect(evidence.control == nil) // These two real fixtures retain archive provenance.
            #expect(index + 1 < prepared.commitProgram.operations.count)
            // No later replacement has run: notably checkpoint is old after
            // shard publication, and the original segment remains after checkpoint.
            for later in prepared.commitProgram.operations.dropFirst(index + 1) {
                if case let .replace(laterPath, _, _, id) = later {
                    #expect(live[laterPath] == baseline.files[laterPath])
                    #expect(live[Self.temporaryPath(laterPath, id: id)] == nil)
                }
            }
            let segmentPath = prepared.commitProgram.journalRelativePath + ".segment"
            #expect(live[segmentPath] == baseline.files[segmentPath])
            #expect(baseline.files[segmentPath] == before[segmentPath])
            #expect(live[segmentPath] != nil)
            var segment = stat(); #expect(lstat(paths.workingSet.appendingPathComponent(segmentPath).path, &segment) == 0)
            #expect(UInt64(segment.st_dev) == baseline.segmentDevice && segment.st_ino == baseline.segmentInode)
            if cut == "journal-shard-published" {
                let checkpoint = prepared.commitProgram.journalRelativePath + ".checkpoint"
                #expect(live[checkpoint] == before[checkpoint])
            }
        }
        let context = SyncBootstrapContext(accountIDHash: account.accountIDHash, epoch: UUID(), freezeID: UUID())
        _ = try SyncBootstrapOwnedTransaction(storage: storage, paths: paths, account: account,
            context: context, validateContext: { _ in }).recover()
        #expect(try OwnedMatrixFixture.files(paths.workingSet) == before)
        let terminal = try OwnedMatrixFixture.manifest(paths, account: account)
        switch terminal.body {
        case let .abortedPreparation(body):
            #expect(cut == "before-root" && body.frozenOutputEntries.isEmpty && terminal.historyHead == nil)
            #expect(!FileManager.default.fileExists(atPath: paths.accountRoot.appendingPathComponent(terminal.transactionRelativePath).path))
        case let .rolledBack(body):
            #expect(cut != "before-root")
            #expect(body.frozenTransactionEntries.contains { $0.relativePath.contains("/Failed/") })
            if !["rollback-intent", "original-restored"].contains(cut) {
                let evidence = try #require(evidence)
                let failedPath = terminal.transactionRelativePath + "/Failed/" + evidence.relativePath
                let entry = try #require(body.frozenTransactionEntries.first { $0.relativePath == failedPath })
                let bytes = try Data(contentsOf: paths.accountRoot.appendingPathComponent(failedPath))
                #expect(bytes == evidence.bytes)
                #expect(entry.byteCount == evidence.bytes.count && entry.sha256 == OwnedBootstrapCodec.hash(evidence.bytes))
                #expect(entry.device == evidence.device && entry.inode == evidence.inode)
            }
            if let baseline = publicationBaseline {
                let path = terminal.transactionRelativePath + "/Failed/" + body.prepared.commitProgram.journalRelativePath + ".segment"
                let retained = try #require(body.frozenTransactionEntries.first { $0.relativePath == path })
                #expect(retained.device == baseline.segmentDevice && retained.inode == baseline.segmentInode)
                #expect(try Data(contentsOf: paths.accountRoot.appendingPathComponent(path))
                    == baseline.files[body.prepared.commitProgram.journalRelativePath + ".segment"])
            }
        default: Issue.record("unexpected recovered phase for \(cut)"); return
        }
        // Every route starts a separate equivalent real child/storage fixture.
        // The oracle copies only initial journal input, never ownership evidence.
        let expectedRoot = root.appendingPathComponent("ordinary")
        for (path, bytes) in before where path.hasPrefix("SyncMetadata/pending.json") || path.hasPrefix("SyncMetadata/.pending.json") {
            let url = expectedRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let native = FileSyncMutationJournal(url: paths.mutationJournalURL)
        let expected = FileSyncMutationJournal(url: expectedRoot.appendingPathComponent("SyncMetadata/pending.json"))
        let originalPending = try expected.recoverySnapshot().mutations
        #expect(try native.recoverySnapshot().mutations == originalPending)
        if route == "authenticated" {
            // No ordinary loader/migration precedes seal on this independent root.
            try OwnedMatrixFixture.authenticate(storage: storage, paths: paths, account: account)
        } else {
            // A fresh ordinary loader runs directly on exact owned rollback,
            // before any vault reconstruction can hide a native-format failure.
            #expect(try native.pending() == originalPending)
            #expect(try expected.pending() == originalPending)
            func journalBytes(_ live: URL) throws -> [String: Data] {
                try OwnedMatrixFixture.files(live).filter {
                    $0.key.hasPrefix("SyncMetadata/pending.json") || $0.key.hasPrefix("SyncMetadata/.pending.json")
                }
            }
            #expect(try journalBytes(paths.workingSet) == journalBytes(expectedRoot))
            let next = OwnedMatrixFixture.mutation(909)
            try native.enqueue(next); try native.enqueue(next)
            try expected.enqueue(next); try expected.enqueue(next)
            #expect(try native.pending() == expected.pending())
            #expect(try journalBytes(paths.workingSet) == journalBytes(expectedRoot))
            try native.acknowledge([next.identity]); try expected.acknowledge([next.identity])
            #expect(try FileSyncMutationJournal(url: paths.mutationJournalURL).pending() == expected.pending())
            #expect(try journalBytes(paths.workingSet) == journalBytes(expectedRoot))
        }
        print("OWNED-MATRIX crash=\(cut) childExit=86 sameRoot=yes rollbackExact=yes recoveryRoute=\(route)")
    }

    @Test func nativeCrashWorker() throws {
        guard let cut = ProcessInfo.processInfo.environment["KNITNOTE_OWNED_MATRIX_CHILD"],
              let path = ProcessInfo.processInfo.environment["KNITNOTE_OWNED_MATRIX_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        guard root.lastPathComponent.hasPrefix("owned-matrix-crash-") else { throw OwnedFixtureFailure.injected }
        let began = ProcessInfo.processInfo.systemUptime
        func mark(_ phase: String) {
            let line = "OWNED-CHILD cut=\(cut) elapsed=\(ProcessInfo.processInfo.systemUptime - began) phase=\(phase) root=\(root.path)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        mark("fixture-begin")
        let migration = ["journal-shard", "journal-checkpoint", "journal-shard-published", "journal-checkpoint-published", "journal-segment"].contains(cut)
        let f = try OwnedMatrixFixture(root: root, missing: cut == "before-root", legacyJournal: migration,
            media: cut == "journal-attachment")
        mark("fixture-ready")
        let input = try f.input(), before = try OwnedMatrixFixture.files(f.paths.workingSet)
        mark("input-ready")
        try JSONEncoder().encode(before).write(to: root.appendingPathComponent("before.json"))
        var committing = false, publishedIndex: Int?, publishedPath: String?
        let tx = try f.transaction(boundary: { boundary in
            switch boundary {
            case .afterPreparingPublication: mark("preparing-selected")
            case .afterPreparedPublication: mark("prepared-selected")
            case .afterInstalled: mark("installed-selected")
            case let .afterJournalOperation(index): mark("journal-operation-\(index)-complete")
            default: break
            }
            if cut == "before-root", boundary == .afterPreparingPublication { Darwin._exit(86) }
            if ["rollback-intent", "original-restored"].contains(cut), boundary == .afterInstalled { throw OwnedFixtureFailure.injected }
            if cut == "rollback-intent", boundary == .afterRollbackIntent { Darwin._exit(86) }
            if cut == "original-restored", boundary == .afterOriginalRestore { Darwin._exit(86) }
            if committing, let publishedIndex, let publishedPath,
               boundary == .afterJournalOperation(index: publishedIndex) {
                let fd = Darwin.open(f.paths.workingSet.appendingPathComponent(publishedPath).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw OwnedFixtureFailure.injected }; defer { Darwin.close(fd) }
                mark("published-cut-record-begin"); try f.recordCut(fd); mark("published-cut-record-ready"); Darwin._exit(86)
            }
        }, io: .init(write: { fd, bytes in
            let p = try OwnedMatrixFixture.descriptorPath(fd)
            if committing {
                let match = (cut == "journal-append" && p.hasSuffix("pending.json.segment"))
                    || (cut == "journal-shard" && p.contains("/.pending.json.proofs."))
                    || (cut == "journal-checkpoint" && p.contains("/.pending.json.checkpoint."))
                    || (cut == "journal-attachment" && p.contains("/.pending.json.attachments/."))
                    || (cut == "receipt-write" && p.contains("/.bootstrap-receipt.json."))
                if match && bytes.count > 7 {
                    mark("partial-cut-write-begin")
                    try SyncBootstrapOwnedPOSIX.write(fd, Data(bytes.prefix(7)))
                    mark("partial-cut-record-begin"); try f.recordCut(fd); mark("partial-cut-record-ready"); Darwin._exit(86)
                }
            }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        }, synchronize: { fd in
            let p = try OwnedMatrixFixture.descriptorPath(fd)
            try SyncBootstrapOwnedPOSIX.synchronize(fd)
            if committing, cut == "receipt-sync", p.contains("/.bootstrap-receipt.json.") { try f.recordCut(fd); Darwin._exit(86) }
        }))
        if cut == "journal-segment" || cut.hasSuffix("-published") {
            let operations = try tx.plan(input).commitProgram.operations
            let index = try #require(operations.firstIndex {
                guard case let .replace(path, _, _, _) = $0 else { return false }
                if cut == "journal-shard-published" { return path.contains("pending.json.proofs.") }
                return path.hasSuffix(cut == "journal-segment" ? "pending.json.segment" : "pending.json.checkpoint")
            })
            guard case let .replace(path, _, _, _) = operations[index] else { return }
            publishedIndex = index; publishedPath = path
        }
        mark("prepare-begin")
        let token = try tx.prepare(input); mark("prepare-returned")
        try tx.install(token); mark("install-returned")
        if cut.hasSuffix("-published") {
            var segment = stat(); #expect(lstat(f.paths.mutationJournalURL.appendingPathExtension("segment").path, &segment) == 0)
            let baseline = try NativePublicationBaseline(files: OwnedMatrixFixture.files(f.paths.workingSet),
                segmentDevice: UInt64(segment.st_dev), segmentInode: segment.st_ino)
            try JSONEncoder().encode(baseline).write(to: root.appendingPathComponent("installed.json"))
        }
        committing = true
        mark("commit-begin")
        _ = try tx.commit(token)
        Issue.record("worker did not reach \(cut)")
    }

    private struct NativePublicationBaseline: Codable {
        let files: [String: Data]
        let segmentDevice: UInt64
        let segmentInode: UInt64
    }

    private static func temporaryPath(_ path: String, id: UUID) -> String {
        let url = URL(fileURLWithPath: path), parent = OwnedBootstrapCodec.parent(path)
        return (parent.isEmpty ? "" : parent + "/") + "." + url.lastPathComponent + "." + id.uuidString + ".tmp"
    }
}
