import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncBootstrapOwnedSelectorRecoveryTests {
    // Removing post-preparing selector lineage validation must expose a write
    // to conflicting evidence, including on a fresh owner of the same root.
    @Test(arguments: ["prepared", "installed"], ["context", "history", "prepared", "transaction", "source", "phase", "garbage"])
    func conflictingCompleteSelectorRejectsRecoveryUnchanged(phase: String, conflict: String) throws {
        let f = try OwnedMatrixFixture(missing: true, media: false); defer { f.remove() }
        let tx = try f.transaction(), token = try tx.prepare(f.input())
        if phase == "installed" { try tx.install(token) }
        try conflicting(try OwnedMatrixFixture.manifest(f.paths, account: f.account), kind: conflict)
            .write(to: f.namespace.appendingPathComponent("active-next.json"))
        try f.storage.close()
        let storage = SyncAccountStorage(baseURL: f.root.appendingPathComponent("store"))
        let paths = try storage.openExistingAccount(identity: f.account, validateAccount: {})
        defer { try? storage.close() }
        let before = try OwnedMatrixFixture.files(paths.accountRoot)
        let physical = try entries(storage, paths: paths, account: f.account)
        let recovery = try SyncBootstrapOwnedTransaction(storage: storage, paths: paths, account: f.account,
            context: f.context, validateContext: { _ in })
        #expect(throws: (any Error).self) { try recovery.recover() }
        #expect(try OwnedMatrixFixture.files(paths.accountRoot) == before)
        #expect(try entries(storage, paths: paths, account: f.account) == physical)
    }

    @Test(arguments: [false, true])
    func conflictingSelectorBlocksForwardEffects(commit: Bool) throws {
        let f = try OwnedMatrixFixture(missing: true, media: false); defer { f.remove() }
        let tx = try f.transaction(), token = try tx.prepare(f.input())
        if commit { try tx.install(token) }
        try conflicting(try OwnedMatrixFixture.manifest(f.paths, account: f.account), kind: "context")
            .write(to: f.namespace.appendingPathComponent("active-next.json"))
        let before = try OwnedMatrixFixture.files(f.paths.accountRoot)
        let physical = try entries(f.storage, paths: f.paths, account: f.account)
        if commit { #expect(throws: (any Error).self) { try tx.commit(token) } }
        else { #expect(throws: (any Error).self) { try tx.install(token) } }
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == before)
        #expect(try entries(f.storage, paths: f.paths, account: f.account) == physical)
    }

    @Test func canonicallyEquivalentButByteDifferentLivePathRejectsUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("owned-selector-café-" + UUID().uuidString)
        let f = try OwnedMatrixFixture(root: root, missing: true, media: false); defer { f.remove() }
        _ = try f.transaction().prepare(f.input())
        let main = try OwnedMatrixFixture.manifest(f.paths, account: f.account)
        let decomposed = main.livePath.decomposedStringWithCanonicalMapping
        let alternate = Data(decomposed.utf8) != Data(main.livePath.utf8)
            ? decomposed : main.livePath.precomposedStringWithCanonicalMapping
        #expect(alternate == main.livePath)
        #expect(Data(alternate.utf8) != Data(main.livePath.utf8))
        let candidate = BootstrapManifestV3(id: main.id, context: main.context, livePath: alternate,
            journalPath: main.journalPath, sourceProof: main.sourceProof, original: main.original,
            historyHead: main.historyHead, body: main.body)
        try candidate.encoded().write(to: f.namespace.appendingPathComponent("active-next.json"))
        let before = try OwnedMatrixFixture.files(f.paths.accountRoot)
        #expect(throws: (any Error).self) { try f.transaction().recover() }
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == before)
    }

    @Test func conflictingSelectorAppearingAfterAdmissionIsPreserved() throws {
        let f = try OwnedMatrixFixture(missing: true, media: false); defer { f.remove() }
        _ = try f.transaction().prepare(f.input())
        let conflict = try conflicting(OwnedMatrixFixture.manifest(f.paths, account: f.account), kind: "context")
        var snapshot: [String: Data]?
        let tx = try f.transaction(boundary: { point in
            if point == .afterRollbackIntent {
                try conflict.write(to: f.namespace.appendingPathComponent("active-next.json"))
                snapshot = try OwnedMatrixFixture.files(f.paths.accountRoot)
            }
        })
        #expect(throws: (any Error).self) { try tx.recover() }
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == #require(snapshot))
    }

    @Test(arguments: [SyncBootstrapOwnedSelectorPoint.afterNextCreation, .beforeRename], [false, true])
    func selectorChangedAtLastWriteOrRenameBoundaryRejectsUnchanged(point: SyncBootstrapOwnedSelectorPoint,
                                                                  replaceInode: Bool) throws {
        let f = try OwnedMatrixFixture(missing: true, media: false); defer { f.remove() }
        _ = try f.transaction().prepare(f.input())
        let conflict = try conflicting(OwnedMatrixFixture.manifest(f.paths, account: f.account), kind: "context")
        let next = f.namespace.appendingPathComponent("active-next.json")
        var snapshot: [String: Data]?, laterWrites = 0
        let tx = try f.transaction(boundary: { boundary in
            if snapshot == nil, boundary == .selector(point) {
                if replaceInode { try Data(contentsOf: next).write(to: next, options: .atomic) }
                else { try conflict.write(to: next) }
                snapshot = try OwnedMatrixFixture.files(f.paths.accountRoot)
            }
        }, io: .init(write: { fd, bytes in
            if snapshot != nil { laterWrites += 1 }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        }))
        #expect(throws: (any Error).self) { try tx.recover() }
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == #require(snapshot))
        #expect(laterWrites == 0)
    }

    // Actual writer cuts, including partial envelopes, must remain recoverable.
    @Test(arguments: [false, true], ["partial", "complete", "terminal-partial", "terminal-complete"])
    func interruptedRollbackDerivativeRecoversRepeatedly(installed: Bool, cut: String) throws {
        let f = try OwnedMatrixFixture(missing: true, media: false); defer { f.remove() }
        let tx = try f.transaction(), token = try tx.prepare(f.input())
        if installed { try tx.install(token) }
        var hit = false
        let io = SyncBootstrapOwnedIO(write: { fd, bytes in
            if try OwnedMatrixFixture.descriptorPath(fd).hasSuffix("/active-next.json") {
                let body = try BootstrapManifestV3.decodeEnvelope(bytes).body
                let targeted: Bool
                switch body {
                case .rollingBack: targeted = !cut.hasPrefix("terminal-")
                case .rolledBack: targeted = cut.hasPrefix("terminal-")
                default: targeted = false
                }
                if targeted {
                    hit = true
                    try SyncBootstrapOwnedPOSIX.write(fd, cut.hasSuffix("partial") ? Data(bytes.prefix(79)) : bytes)
                    throw OwnedFixtureFailure.injected
                }
            }
            try SyncBootstrapOwnedPOSIX.write(fd, bytes)
        })
        #expect(throws: OwnedFixtureFailure.self) { try f.transaction(io: io).recover() }
        #expect(hit)
        try f.storage.close()
        let storage = SyncAccountStorage(baseURL: f.root.appendingPathComponent("store"))
        let paths = try storage.openExistingAccount(identity: f.account, validateAccount: {})
        defer { try? storage.close() }
        let recovery = try SyncBootstrapOwnedTransaction(storage: storage, paths: paths, account: f.account,
            context: f.context, validateContext: { _ in })
        _ = try recovery.recover()
        guard case .rolledBack = try OwnedMatrixFixture.manifest(paths, account: f.account).body else {
            Issue.record("expected recovered rollback"); return
        }
        let terminal = try OwnedMatrixFixture.files(paths.accountRoot)
        _ = try recovery.recover()
        #expect(try OwnedMatrixFixture.files(paths.accountRoot) == terminal)
    }

    @Test(arguments: ["clean", "partial", "complete"])
    func legacyArchiveTerminalRecoveryIsIdempotent(cut: String) throws {
        let f = try OwnedMatrixFixture(media: false); defer { f.remove() }
        let input = try f.input()
        let ordinary = try SyncBootstrapTransaction(liveRoot: f.paths.workingSet, context: f.context, validateContext: { _ in })
        let token = try ordinary.prepare(local: #require(input.local), sourceArchive: input.sourceArchive, remote: input.remote)
        try ordinary.install(token); try ordinary.rollback(token)
        let original = try OwnedMatrixFixture.files(f.paths.accountRoot)
        if cut != "clean" {
            let io = SyncBootstrapOwnedIO(write: { fd, bytes in
                if try OwnedMatrixFixture.descriptorPath(fd).hasSuffix("/active-next.json") {
                    try SyncBootstrapOwnedPOSIX.write(fd, cut == "partial" ? Data(bytes.prefix(79)) : bytes)
                    throw OwnedFixtureFailure.injected
                }
                try SyncBootstrapOwnedPOSIX.write(fd, bytes)
            })
            #expect(throws: OwnedFixtureFailure.self) { try f.transaction(io: io).prepare(input) }
        }
        try f.storage.close()
        let storage = SyncAccountStorage(baseURL: f.root.appendingPathComponent("store"))
        let paths = try storage.openExistingAccount(identity: f.account, validateAccount: {})
        defer { try? storage.close() }
        let current = SyncBootstrapContext(accountIDHash: f.account.accountIDHash, epoch: UUID(), freezeID: UUID())
        var synchronized: [String] = []
        let recovery = try SyncBootstrapOwnedTransaction(storage: storage, paths: paths, account: f.account,
            context: current, validateContext: { _ in }, io: .init(synchronize: { fd in
                synchronized.append(try OwnedMatrixFixture.descriptorPath(fd))
                try SyncBootstrapOwnedPOSIX.synchronize(fd)
            }))
        _ = try recovery.recover()
        #expect(try OwnedMatrixFixture.files(paths.accountRoot) == original)
        let physical = try entries(storage, paths: paths, account: f.account)
        _ = try recovery.recover()
        #expect(try OwnedMatrixFixture.files(paths.accountRoot) == original)
        #expect(try entries(storage, paths: paths, account: f.account) == physical)
        #expect(synchronized.contains(f.namespace.appendingPathComponent("active.json").path))
        try Data("corrupted archive".utf8).write(to: paths.workingSet.appendingPathComponent("projects-v1.json"))
        let corrupt = try OwnedMatrixFixture.files(paths.accountRoot)
        #expect(throws: (any Error).self) { try recovery.recover() }
        #expect(try OwnedMatrixFixture.files(paths.accountRoot) == corrupt)
    }

    private func entries(_ storage: SyncAccountStorage, paths: SyncAccountStorage.Paths,
                         account: SyncAccountIdentity) throws -> [SyncAccountRecoveryInventory.Entry] {
        try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: 100_000_000) { try $0.entries() }
    }

    private func conflicting(_ main: BootstrapManifestV3, kind: String) throws -> Data {
        if kind == "garbage" { return Data("unowned incomplete bytes".utf8) }
        if kind == "transaction" {
            let other = try OwnedMatrixFixture(missing: true, media: false); defer { other.remove() }
            _ = try other.transaction().prepare(other.input())
            return try Data(contentsOf: other.namespace.appendingPathComponent("active.json"))
        }
        let body = try #require(main.body.preparedBody)
        var payload = try #require(JSONSerialization.jsonObject(with: OwnedBootstrapCodec.encode(main)) as? [String: Any])
        switch kind {
        case "context":
            var context = try #require(payload["context"] as? [String: Any]); context["epoch"] = UUID().uuidString
            payload["context"] = context
        case "history": payload["historyHead"] = ["sha256": Data(repeating: 0x37, count: 32).base64EncodedString(),
            "byteCount": 1, "recordCount": 1, "chainByteCount": 1]
        case "prepared", "source":
            var value = try #require(JSONSerialization.jsonObject(with: OwnedBootstrapCodec.encode(body)) as? [String: Any])
            value[kind == "source" ? "formerSourceSHA256" : "preparationSHA256"] = Data(repeating: 0x29, count: 32).base64EncodedString()
            payload["body"] = ["phase": "rollingBack", "rollingBack": value]
        case "phase":
            let value = try JSONSerialization.jsonObject(with: OwnedBootstrapCodec.encode(body))
            let phase: String
            if case .prepared = main.body { phase = "committed" } else { phase = "prepared" }
            payload["body"] = ["phase": phase, phase: value]
        default: throw OwnedFixtureFailure.injected
        }
        let candidate = try JSONDecoder().decode(BootstrapManifestV3.self,
            from: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let encoded = try candidate.encoded()
        _ = try BootstrapManifestV3.decodeEnvelope(encoded)
        return encoded
    }
}
