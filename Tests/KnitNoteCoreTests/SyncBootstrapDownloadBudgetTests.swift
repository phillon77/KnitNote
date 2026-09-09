import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncBootstrapDownloadBudgetTests {
    // Break caught: the admitted owned budget omits full native media, pending
    // data, or the nested retained-output envelope at a recoverable crash cut.
    @Test(arguments: ["after-preparing", "prepared", "installed", "committed"])
    func fullRepresentativeMediaCrashPrefixesFitAdmittedNativeEnvelope(cut: String) throws {
        let f = try OwnedMatrixFixture(legacyJournal: true, media: true); defer { f.remove() }
        let initial = try OwnedMatrixFixture.files(f.paths.workingSet)
        let pending = try f.journal.recoverySnapshot().mutations
        var reached = false
        let tx = try f.transaction(boundary: { point in
            let matches = (cut == "after-preparing" && point == .afterPreparingPublication)
                || (cut == "prepared" && point == .afterPreparedPublication)
                || (cut == "installed" && point == .afterInstalled)
                || (cut == "committed" && point == .selector(.afterSelectedSynchronize)
                    && { if case .committed? = try? OwnedMatrixFixture.manifest(f.paths, account: f.account).body { return true }; return false }())
            if !reached && matches { reached = true; throw OwnedFixtureFailure.injected }
        })
        let input = try f.input(), plan = try tx.plan(input)
        #expect(plan.maximumRecoveryEnvelopeBytes <= 100_000_000)
        #expect(throws: (any Error).self) {
            let prepared = try tx.prepare(input)
            try tx.install(prepared); _ = try tx.commit(prepared)
        }
        try #require(reached)
        // Native recovery freezes an interrupted prefix before the inventory
        // codec can admit it; nonterminal output is never counted as authority.
        _ = try f.transaction().recover()
        let inventory = try SyncAccountRecoveryInventory.capture(storage: f.storage, paths: f.paths, account: f.account,
            journal: f.journal, archiveURL: f.paths.workingSet.appendingPathComponent("projects-v1.json"))
        let actualInventory = try inventory.encoded()
        let projectedInventory = try inventory.projectedEncodedByteCount(entries: inventory.entries,
            packetByteCount: inventory.packet.encoded().count, deletionFiles: inventory.deletionFiles,
            sourceAuthority: inventory.sourceAuthority, bootstrapEvidence: inventory.bootstrapEvidence)
        #expect(projectedInventory == actualInventory.count)
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: f.journal, maximumBytes: plan.maximumRecoveryEnvelopeBytes)
        let now = Date(), sealed = try recovery.seal(recovery.prepare(now: now), now: now)
        let payload = try vault.synchronizedRecoveryPayload(sealed.vaultID, account: f.account, now: now)
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let encodedInventory = try #require(object["inventory"] as? String)
        #expect(Data(base64Encoded: encodedInventory) == actualInventory)
        #expect(payload.count <= plan.maximumRecoveryEnvelopeBytes)
        #expect(Array(try f.journal.recoverySnapshot().mutations.prefix(pending.count)).map(\.mutationID) == pending.map(\.mutationID))
        if cut != "committed" { #expect(try OwnedMatrixFixture.files(f.paths.workingSet) == initial) }
        print("APP-BRIDGE-CAP fullMedia=project,yarn,journalFull,journalThumb,pdf,markup cut=\(cut) sourceFiles=\(initial.count) sourceBytes=\(initial.values.reduce(0) { $0 + $1.count }) inventory=\(actualInventory.count) envelope=\(payload.count) admitted=\(plan.maximumRecoveryEnvelopeBytes)")
    }

    @Test(arguments: [false, true])
    func emptyFootprintMatchesActualSealingWithInclusiveCap(missing: Bool) throws {
        let f = try OwnedMatrixFixture(missing: missing, legacyJournal: !missing, media: false); defer { f.remove() }
        let footprint = SyncBootstrapDownloadFootprint(directoryPaths: [], files: [:])
        let cap = try minimumBudget(f, footprint)
        let before = try OwnedMatrixFixture.files(f.paths.accountRoot)
        try requireFits(f, footprint, cap)
        #expect(throws: (any Error).self) { try requireFits(f, footprint, cap - 1) }
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == before)
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: f.journal, maximumBytes: cap)
        let now = Date(), receipt = try recovery.seal(recovery.prepare(now: now), now: now)
        let bytes = try vault.synchronizedRecoveryPayload(receipt.vaultID, account: f.account, now: now)
        #expect(bytes.count == cap)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["formatVersion"] as? Int == (missing ? 2 : 1))
    }

    @Test func prospectiveNativePathsAccountForAncestorsLocksTempsAndUnknownDigests() throws {
        let f = try OwnedMatrixFixture(media: false); defer { f.remove() }
        let directory = "staging/" + String(repeating: "毛線", count: 35) + "/Assets"
        let files: [String: Int64] = [directory + "/.lock": 0, directory + "/.tmp-00000000-0000-0000-0000-000000000001": 513,
            directory + "/blob.asset": 513, directory + "/publication.json": 177]
        let footprint = SyncBootstrapDownloadFootprint(directoryPaths: [directory], files: files)
        let cap = try minimumBudget(f, footprint)
        let before = try OwnedMatrixFixture.files(f.paths.accountRoot)
        #expect(throws: (any Error).self) { try requireFits(f, footprint, cap - 1) }
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == before)
        try FileManager.default.createDirectory(at: f.paths.accountRoot.appendingPathComponent(directory), withIntermediateDirectories: true)
        for (path, count) in files { try Data(repeating: 255, count: Int(count)).write(to: f.paths.accountRoot.appendingPathComponent(path)) }
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: f.journal, maximumBytes: cap)
        let now = Date(), receipt = try recovery.seal(recovery.prepare(now: now), now: now)
        #expect(try vault.synchronizedRecoveryPayload(receipt.vaultID, account: f.account, now: now).count <= cap)
    }

    @Test func peakRawBytesAndOverflowRejectBeforeWriting() throws {
        let f = try OwnedMatrixFixture(media: false); defer { f.remove() }
        let before = try OwnedMatrixFixture.files(f.paths.accountRoot)
        for files: [String: Int64] in [["staging/a": Int64.max], ["staging/a": -1],
            ["staging/a": 60_000_000, "staging/b": 60_000_000]] {
            #expect(throws: (any Error).self) {
                try requireFits(f, .init(directoryPaths: [], files: files), 100_000_000)
            }
        }
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == before)
    }

    @Test func samePathAccountsForLargerPeakWithoutGrantingOverwrite() throws {
        let f = try OwnedMatrixFixture(media: false); defer { f.remove() }
        try Data(repeating: 1, count: 20_000).write(to: f.paths.staging.appendingPathComponent("existing"))
        let before = try OwnedMatrixFixture.files(f.paths.accountRoot)
        let large = try minimumBudget(f, .init(directoryPaths: [], files: ["staging/existing": 30_000]))
        let small = try minimumBudget(f, .init(directoryPaths: [], files: ["staging/existing": 1]))
        #expect(large > small)
        #expect(small >= 20_000)
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == before)
    }

    @Test func futureFootprintCannotCreateSourceAuthorityOrReplaceControl() throws {
        let f = try OwnedMatrixFixture(media: false); defer { f.remove() }
        try FileManager.default.removeItem(at: f.paths.workingSet.appendingPathComponent("projects-v1.json"))
        let before = try OwnedMatrixFixture.files(f.paths.accountRoot)
        #expect(throws: (any Error).self) {
            try requireFits(f, .init(directoryPaths: [], files: ["working-set/projects-v1.json": 100]), 100_000_000)
        }
        #expect(try OwnedMatrixFixture.files(f.paths.accountRoot) == before)
    }

    @Test(arguments: ["../escape", "staging/../escape", "/absolute", "staging//empty", ".sealed-recovery-v1/intent.json", "vault/key",
        ".decrypted-temporary/.owner-v1", "staging/unresolved.tmp"])
    func invalidOrExcludedPathsCannotDisappearFromAccounting(path: String) throws {
        let f = try OwnedMatrixFixture(media: false); defer { f.remove() }
        #expect(throws: (any Error).self) {
            try requireFits(f, .init(directoryPaths: [], files: [path: 1]), 100_000_000)
        }
    }

    @Test func existingPendingAndOwnedHistoryRemainInsideEveryEnvelopeLayer() throws {
        let f = try OwnedMatrixFixture(legacyJournal: true, media: false); defer { f.remove() }
        for _ in 0..<2 {
            let tx = try f.transaction(boundary: { point in
                if point == .afterTransactionRootCreation { throw OwnedFixtureFailure.injected }
            })
            #expect(throws: (any Error).self) { try tx.prepare(f.input()) }
            _ = try f.transaction().recover()
        }
        #expect(try OwnedMatrixFixture.manifest(f.paths, account: f.account).historyHead?.recordCount == 1)
        let cap = try minimumBudget(f, .init(directoryPaths: [], files: [:]))
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: OwnedBootstrapTestKeys())
        let recovery = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: f.journal, maximumBytes: cap)
        let now = Date(), receipt = try recovery.seal(recovery.prepare(now: now), now: now)
        #expect(try vault.synchronizedRecoveryPayload(receipt.vaultID, account: f.account, now: now).count == cap)
    }

    @Test func exactControlDerivativeAndDeletionPacketBytesMatchSealing() throws {
        let f = try RecoveryInventoryFixture(); defer { f.remove() }
        let ledger = try SyncDeletionLedger(root: f.ledgerRoot)
        let deletion = try f.addDeletion(ledger: ledger, name: "Budget retained media", attachment: true)
        let journal = FileSyncMutationJournal(url: f.paths.mutationJournalURL)
        try journal.enqueue(deletion.versions.map { try SyncMutation.save(recordVersion: $0, mutationID: UUID()) })
        _ = try f.makeMissingArchiveRollback(withMedia: true)
        let vault = SyncRecoveryVault(directory: f.paths.vault, keychain: OwnedBootstrapTestKeys())
        let original = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: journal)
        let now = Date(), old = try original.seal(original.prepare(now: now), now: now)
        try original.cleanup(old); try original.restore(vaultID: old.vaultID, now: now)
        #expect(try original.consumeRestoredSelection(vaultID: old.vaultID, now: now))
        let mainURL = f.paths.accountRoot.appendingPathComponent(".sealed-recovery-v1/intent.json")
        let main = try Data(contentsOf: mainURL)
        let next = try SyncAccountRecoveryControlFile.encode(SyncAccountRecoveryControlFile.decode(main),
            predecessorSHA256: OwnedBootstrapCodec.hash(main))
        try next.write(to: mainURL.deletingLastPathComponent().appendingPathComponent("intent-next.json"))
        func check(_ cap: Int) throws {
            try SyncBootstrapDownloadBudget.requireFits(storage: f.storage, paths: f.paths, account: f.account,
                footprint: .init(directoryPaths: [], files: [:]), maximumBytes: cap)
        }
        let before = try f.diskBytes()
        try check(100_000_000)
        var low = 0, high = 100_000_000
        while low < high {
            let middle = low + (high - low) / 2
            do { try check(middle); high = middle } catch { low = middle + 1 }
        }
        try check(low)
        #expect(throws: (any Error).self) { try check(low - 1) }
        #expect(try f.diskBytes() == before)
        let recovery = SyncAccountRecoveryTransaction(storage: f.storage, paths: f.paths, account: f.account,
            vault: vault, journal: journal, maximumBytes: low)
        let receipt = try recovery.seal(recovery.prepare(now: now), now: now)
        #expect(try vault.synchronizedRecoveryPayload(receipt.vaultID, account: f.account, now: now).count == low)
    }

    private func requireFits(_ f: OwnedMatrixFixture, _ footprint: SyncBootstrapDownloadFootprint, _ cap: Int) throws {
        try SyncBootstrapDownloadBudget.requireFits(storage: f.storage, paths: f.paths,
            account: f.account, footprint: footprint, maximumBytes: cap)
    }

    private func minimumBudget(_ f: OwnedMatrixFixture, _ footprint: SyncBootstrapDownloadFootprint) throws -> Int {
        try requireFits(f, footprint, 100_000_000)
        var low = 0, high = 100_000_000
        while low < high {
            let middle = low + (high - low) / 2
            do { try requireFits(f, footprint, middle); high = middle }
            catch { low = middle + 1 }
        }
        return low
    }
}
