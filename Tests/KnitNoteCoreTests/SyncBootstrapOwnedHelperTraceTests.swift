import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncBootstrapOwnedHelperTraceTests {
    @Test(arguments: ["backup", "deletion"], [false, true])
    @MainActor func actualValidationCutsFreezeOnlyIssuedOutputs(helper: String, after: Bool) throws {
        let f = try OwnedMatrixFixture(media: false); defer { f.remove() }
        let deleted = try SyncDeletionCaptureProgramTests.request(root: f.root)
        let input = SyncBootstrapOwnedInput(local: f.local, sourceArchive: f.archive,
            remote: .init(context: f.context, records: deleted.currentRecords, attachments: [:], isComplete: true),
            pending: nil, counterReminderContext: .init())
        let source = try OwnedMatrixFixture.files(f.paths.workingSet)
        var hit = false, laterOutputs = 0
        let tx = try f.transaction(boundary: { point in
            if hit { if case .afterPreparationOutput = point { laterOutputs += 1 }; return }
            let value: SyncBootstrapOwnedValidation
            switch point {
            case let .beforeValidation(v) where !after: value = v
            case let .afterValidation(v) where after: value = v
            default: return
            }
            let matches: Bool
            switch value {
            case .backupInspection: matches = helper == "backup"
            case .deletion: matches = helper == "deletion"
            default: matches = false
            }
            if matches { hit = true; throw OwnedFixtureFailure.injected }
        })
        #expect(throws: (any Error).self) { try tx.prepare(input) }
        #expect(hit && laterOutputs == 0)
        let terminal = try OwnedMatrixFixture.manifest(f.paths, account: f.account)
        guard case let .abortedPreparation(abort) = terminal.body else { Issue.record("not frozen abort"); return }
        #expect(!abort.frozenOutputEntries.isEmpty)
        #expect(try OwnedMatrixFixture.files(f.paths.workingSet) == source)
        let frozen = try OwnedMatrixFixture.files(f.paths.accountRoot)
        _ = try f.transaction().recover()
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == frozen)
        try OwnedMatrixFixture.authenticate(storage: f.storage, paths: f.paths, account: f.account)
    }

    // Break caught: helper validation is skipped or publication drops its native
    // lock before an immutable/head write and its parent durability barrier.
    @Test @MainActor func completePhysicalHelpersKeepValidationAndNativeLockOrder() throws {
        let f = try OwnedMatrixFixture(); defer { f.remove() }
        let deleted = try SyncDeletionCaptureProgramTests.request(root: f.root)
        let input = SyncBootstrapOwnedInput(local: f.local, sourceArchive: f.archive,
            remote: .init(context: f.context, records: deleted.currentRecords, attachments: [:], isComplete: true),
            pending: nil, counterReminderContext: .init())
        var validations: [SyncBootstrapOwnedValidation] = [], completed: [SyncBootstrapOwnedValidation] = []
        var openValidation: SyncBootstrapOwnedValidation?, lockPath: String?, probes = 0
        var trace: [String] = [], preparedSelector = false
        func probe(locked: Bool) throws {
            let fd = Darwin.open(try #require(lockPath), O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw OwnedFixtureFailure.injected }; defer { Darwin.close(fd) }
            let acquired = flock(fd, LOCK_EX | LOCK_NB) == 0
            let lockError = errno
            if acquired { #expect(flock(fd, LOCK_UN) == 0) }
            #expect(acquired == !locked)
            if locked { #expect(lockError == EWOULDBLOCK) }
            probes += 1
        }
        let tx = try f.transaction(boundary: { point in
            switch point {
            case let .beforeValidation(value):
                #expect(openValidation == nil); openValidation = value; validations.append(value)
                trace.append("validate-start:\(value)")
            case let .afterValidation(value):
                #expect(openValidation == value); openValidation = nil; completed.append(value)
                trace.append("validate-end:\(value)")
            case .afterPreparedPublication:
                #expect(openValidation == nil); try probe(locked: false)
            default: break
            }
        }, io: .init(write: { fd, bytes in
            let path = try OwnedMatrixFixture.descriptorPath(fd)
            trace.append("write:" + path)
            if lockPath != nil, path.contains("/Staged/SyncMetadata/") { try probe(locked: true) }
            if path.hasSuffix("/active-next.json"), case .prepared = try BootstrapManifestV3.decodeEnvelope(bytes).body {
                preparedSelector = true; try probe(locked: false)
            }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        }, synchronize: { fd in
            let path = try OwnedMatrixFixture.descriptorPath(fd)
            try SyncBootstrapOwnedPOSIX.synchronize(fd)
            trace.append("sync:" + path)
            if path.hasSuffix("/Staged/SyncMetadata/.attachment-versions.json.lock") { lockPath = path }
            if lockPath != nil, !preparedSelector,
               path.contains("/Staged/SyncMetadata/") || path.hasSuffix("/Staged/SyncMetadata") {
                try probe(locked: true)
            }
        }))
        let plan = try tx.plan(input)
        _ = try tx.prepare(input)
        #expect(validations == completed && openValidation == nil)
        #expect(validations.contains(.localMaterialization))
        #expect(validations.contains(.mergedMaterialization))
        #expect(plan.backupPackages.count == 2)
        for index in plan.backupPackages.indices {
            #expect(validations.contains(.backupSource(index: index, final: false)))
            #expect(validations.contains(.backupSource(index: index, final: true)))
            #expect(validations.contains(.backupInspection(index: index)))
        }
        let deletionSteps = plan.deletion.steps.indices.filter { if case .validate = plan.deletion.steps[$0] { true } else { false } }
        #expect(deletionSteps.count == 2)
        #expect(validations.filter { if case .deletion = $0 { true } else { false } }.count == 2)
        for index in deletionSteps { #expect(validations.contains(.deletion(step: index))) }
        #expect(probes > 5 && preparedSelector)
        for (index, event) in trace.enumerated() where event.hasPrefix("write:") && !event.hasSuffix("/active-next.json") {
            let path = String(event.dropFirst(6)), parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            let fileSync = try #require(trace.indices.first { $0 > index && trace[$0] == "sync:" + path })
            _ = try #require(trace.indices.first { $0 > fileSync && trace[$0] == "sync:" + parent })
        }
        print("OWNED-MATRIX helper-validations=\(completed.count) actualNativeLockProbes=\(probes) writeAndFsyncEvents=\(trace.count)")
    }
}
