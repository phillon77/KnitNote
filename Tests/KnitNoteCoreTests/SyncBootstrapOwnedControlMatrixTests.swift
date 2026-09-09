import Foundation
import Synchronization
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncBootstrapOwnedControlMatrixTests {
    @Test(arguments: ["spend", "reissue"], Array(1...7))
    func sourceControlFsyncCutsNeverAdvanceUncertainSource(operation: String, failAt: Int) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let controlPath = f.source.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let nextPath = controlPath.deletingLastPathComponent().appendingPathComponent("intent-next.json")
        let originalControl = try Data(contentsOf: controlPath)
        guard case let .absentSource(originalSource) = try SyncAccountRecoveryControlFile.decode(originalControl) else {
            Issue.record("fixture missing exact original source"); return
        }
        func assertReissued(_ source: SyncAccountSourceState, terminal: BootstrapManifestV3, bytes: Data) {
            let expected = SyncAccountSourceState(authorityID: originalSource.authorityID, generation: source.generation,
                accountIDHash: originalSource.accountIDHash, accountRoot: originalSource.accountRoot,
                accountDevice: originalSource.accountDevice, accountInode: originalSource.accountInode,
                archiveURL: originalSource.archiveURL, journalURL: originalSource.journalURL,
                baselineSHA256: originalSource.baselineSHA256,
                origin: .bootstrapRollback(transactionID: terminal.id,
                    activeRelativePath: terminal.transactionRelativePath.components(separatedBy: "/").dropLast().joined(separator: "/") + "/active.json",
                    activeEnvelopeSHA256: OwnedBootstrapCodec.hash(bytes)))
            #expect(source == expected)
            #expect(source.generation != originalSource.generation)
        }
        struct State { var armed = false; var count = 0; var hit = false; var paths: [String] = [] }
        let state = Mutex(State())
        let io = SyncBootstrapOwnedIO(controlSynchronize: { fd in
            try state.withLock { value in
                if value.armed {
                    value.count += 1; value.paths.append(try OwnedMatrixFixture.descriptorPath(fd))
                    if value.count == failAt { value.hit = true; throw OwnedFixtureFailure.injected }
                }
                try SyncBootstrapOwnedPOSIX.synchronize(fd)
            }
        })
        let before = try OwnedMatrixFixture.files(f.source.paths.workingSet)
        var moved = false
        var expectedSpent: SyncAccountRecoveryControl?
        if operation == "spend" {
            let tx = try f.transaction(boundary: { point in
                if point == .beforeSourceSpend { state.withLock { $0.armed = true } }
                if point == .afterLiveMove { moved = true }
            }, io: io)
            let token = try tx.prepare(f.input())
            expectedSpent = try .sourceSpent(originalSource, transactionID: token.transactionID,
                preparedManifestSHA256: f.manifest().normalizedPreparedDigest())
            #expect(throws: (any Error).self) { try tx.install(token) }
        } else {
            #expect(throws: OwnedFixtureFailure.self) {
                try f.transaction(boundary: { if $0 == .afterPreparingPublication { throw OwnedFixtureFailure.injected } }).prepare(f.input())
            }
            state.withLock { $0.armed = true }
            #expect(throws: (any Error).self) { try f.transaction(io: io).recover() }
        }
        #expect(state.withLock { $0.hit })
        #expect(!moved)
        #expect(try OwnedMatrixFixture.files(f.source.paths.workingSet) == before)
        let cutFiles = try f.source.diskBytes()
        let mainBytes = try Data(contentsOf: controlPath), nextBytes = try? Data(contentsOf: nextPath)
        let terminalAtCut = try f.manifest(), activeAtCut = try Data(contentsOf: f.namespace.appendingPathComponent("active.json"))
        if failAt <= 3 {
            #expect(mainBytes == originalControl && nextBytes == nil)
            #expect(try SyncAccountRecoveryControlFile.decode(mainBytes) == .absentSource(originalSource))
        } else {
            let replacementBytes = try #require(failAt <= 5 ? nextBytes : mainBytes)
            let replacement = try SyncAccountRecoveryControlFile.decode(replacementBytes)
            if operation == "spend" { #expect(replacement == expectedSpent) }
            else {
                guard case let .absentSource(source) = replacement else { Issue.record("reissue did not retain source authority"); return }
                assertReissued(source, terminal: terminalAtCut, bytes: activeAtCut)
            }
            #expect(try SyncAccountRecoveryControlFile.encode(replacement,
                predecessorSHA256: OwnedBootstrapCodec.hash(originalControl)) == replacementBytes)
            if failAt <= 5 { #expect(mainBytes == originalControl && nextBytes != nil) }
            else { #expect(nextBytes == nil && mainBytes != originalControl) }
        }
        let recoverable = ![4, 5].contains(failAt)
        if !recoverable {
            #expect(throws: (any Error).self) { try f.transaction().recover() }
            #expect(try f.source.diskBytes() == cutFiles)
            #expect(throws: (any Error).self) { try f.source.capture() }
        } else {
            _ = try f.transaction().recover()
            let terminal = try f.manifest()
            switch (operation, terminal.body) {
            case ("spend", .rolledBack), ("reissue", .abortedPreparation): break
            default: Issue.record("source cut reached wrong terminal")
            }
            let recoveredBytes = try Data(contentsOf: controlPath)
            guard case let .absentSource(reissued) = try SyncAccountRecoveryControlFile.decode(recoveredBytes) else {
                Issue.record("recoverable cut did not reissue exact absent source"); return
            }
            assertReissued(reissued, terminal: terminal, bytes: try Data(contentsOf: f.namespace.appendingPathComponent("active.json")))
            #expect(!FileManager.default.fileExists(atPath: nextPath.path))
            #expect(try OwnedMatrixFixture.files(f.source.paths.workingSet) == before)
            if operation == "reissue", failAt >= 6 { #expect(recoveredBytes == mainBytes) }
            try OwnedMatrixFixture.authenticate(storage: f.source.storage, paths: f.source.paths, account: f.source.account)
        }
        print("OWNED-MATRIX source=\(operation) fsync=\(failAt) path=\(state.withLock { $0.paths.last ?? "" }) expectedRecovered=\(recoverable) exactSource=yes noLiveMove=yes")
    }

    @Test(arguments: ["preparing", "prepared", "aborted"],
        ["before-file", "after-file", "before-namespace", "after-namespace", "before-account", "after-account", "before-selected-file-sync", "after-selected-file-sync"])
    func selectedPhaseRealFsyncCutsRetainAuthority(phase: String, cut: String) throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let before = try OwnedMatrixFixture.files(f.source.paths.workingSet)
        var armed = false, hit = false, proposed: Data?, atCut: [String: Data]?
        let io = SyncBootstrapOwnedIO(write: { fd, bytes in
            if try OwnedMatrixFixture.descriptorPath(fd).hasSuffix("/active-next.json") {
                let value = try BootstrapManifestV3.decodeEnvelope(bytes)
                let label: String
                switch value.body { case .preparing: label = "preparing"; case .prepared: label = "prepared";
                case .abortedPreparation: label = "aborted"; default: label = "other" }
                armed = label == phase; if armed { proposed = bytes }
            }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        }, synchronize: { fd in
            let path = try OwnedMatrixFixture.descriptorPath(fd)
            let matched = cut.hasSuffix("-file") ? path == f.namespace.appendingPathComponent("active-next.json").path
                : cut.hasSuffix("-namespace") ? path == f.namespace.path
                : cut.hasSuffix("-account") ? path == f.source.paths.accountRoot.path
                : path == f.namespace.appendingPathComponent("active.json").path
            if armed && !hit && matched {
                if cut.hasPrefix("after-") { try SyncBootstrapOwnedPOSIX.synchronize(fd) }
                atCut = try f.source.diskBytes(); hit = true
                throw OwnedFixtureFailure.injected
            }
            try SyncBootstrapOwnedPOSIX.synchronize(fd)
        })
        let tx = try f.transaction(boundary: { point in
            if phase == "aborted", point == .afterTransactionRootCreation { throw OwnedFixtureFailure.injected }
        }, io: io)
        #expect(throws: (any Error).self) { try tx.prepare(f.input()) }
        #expect(hit)
        let cutSnapshot = try #require(atCut), proposedBytes = try #require(proposed)
        let selectedName = cut.hasSuffix("-file") ? "active-next.json" : "active.json"
        #expect(cutSnapshot[f.namespace.appendingPathComponent(selectedName).path] == proposedBytes)
        #expect(try OwnedMatrixFixture.files(f.source.paths.workingSet) == before)
        if phase == "preparing" {
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.namespace.path).allSatisfy { ["active.json", "active-next.json"].contains($0) })
        }
        let failed = try OwnedMatrixFixture.files(f.source.paths.accountRoot)
        try f.source.storage.close()
        let reopened = SyncAccountStorage(baseURL: f.source.base)
        let paths = try reopened.openExistingAccount(identity: f.source.account, validateAccount: {})
        defer { try? reopened.close() }
        let context = SyncBootstrapContext(accountIDHash: f.source.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        let recovery = try SyncBootstrapOwnedTransaction(storage: reopened, paths: paths, account: f.source.account,
            context: context, validateContext: { _ in })
        if phase == "preparing", cut.hasSuffix("-file") {
            #expect(throws: (any Error).self) { try recovery.recover() }
            #expect(try OwnedMatrixFixture.files(paths.accountRoot) == failed)
        } else {
            _ = try recovery.recover()
            let terminal = try OwnedMatrixFixture.manifest(paths, account: f.source.account)
            switch terminal.body { case .abortedPreparation, .rolledBack: break; default: Issue.record("unresolved selector phase") }
            #expect(try OwnedMatrixFixture.files(paths.workingSet) == before)
            try OwnedMatrixFixture.authenticate(storage: reopened, paths: paths, account: f.source.account)
        }
        print("OWNED-MATRIX selector=\(phase) cut=\(cut) actualBytes=\(proposedBytes.count) firstMainlessFailClosed=\(phase == "preparing" && cut.hasSuffix("-file"))")
    }

    // Break caught: selector durability bypasses the owner's real descriptor IO,
    // so a failed or torn publication could be mistaken for an observed barrier.
    @Test func selectorPartialWriteIsObservedBeforeAnyAllocation() throws {
        let f = try OwnedBootstrapFixture(); defer { f.remove() }
        let before = try f.source.diskBytes()
        var hit = false
        let io = SyncBootstrapOwnedIO(write: { fd, bytes in
            if try OwnedMatrixFixture.descriptorPath(fd).hasSuffix("/active-next.json") {
                hit = true; try SyncBootstrapOwnedPOSIX.write(fd, Data(bytes.prefix(7)))
                throw OwnedFixtureFailure.injected
            }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        })
        #expect(throws: OwnedFixtureFailure.self) { try f.transaction(io: io).prepare(f.input()) }
        #expect(hit)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.namespace.path) == ["active-next.json"])
        #expect(try Data(contentsOf: f.namespace.appendingPathComponent("active-next.json")).count == 7)
        let failed = try f.source.diskBytes()
        #expect(before.allSatisfy { failed[$0.key] == $0.value })
        #expect(throws: (any Error).self) { try f.transaction().recover() }
        #expect(try f.source.diskBytes() == failed)
    }
}
