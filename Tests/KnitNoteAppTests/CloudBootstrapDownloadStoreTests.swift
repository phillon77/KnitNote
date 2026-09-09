import CryptoKit
import Darwin
import Foundation
import Testing

@testable import KnitNote

@Suite(.serialized) @MainActor struct CloudBootstrapDownloadStoreTests {
    @Test func constructionCannotCreateAssetTree() throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let before = try f.entries()
        _ = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 0)
        #expect(!FileManager.default.fileExists(atPath: f.assetRoot.path))
        #expect(try f.entries() == before)
    }
    @Test func zeroBudgetRejectsBeforeAnyAssetWrite() throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let bytes = Data("safe".utf8), source = try f.source(bytes), version = try f.version(bytes)
        let before = try f.entries()
        let store = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 0)
        #expect(throws: (any Error).self) { _ = try store.accept(version: version, sourceURL: source) }
        #expect(try f.entries() == before)
    }
    @Test(arguments: [Data("evil".utf8), Data("bad".utf8), Data("too long".utf8)])
    func invalidBytesNeverQuarantineOrCreateTree(_ bad: Data) throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let version = try f.version(Data("safe".utf8)), source = try f.source(bad)
        let before = try f.entries()
        let store = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000)
        #expect(throws: (any Error).self) { _ = try store.accept(version: version, sourceURL: source) }
        #expect(try f.entries() == before)
        #expect(try Data(contentsOf: source) == bad)
    }
    @Test func invalidatedScopeRejectsWithoutEffects() throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let bytes = Data("safe".utf8), source = try f.source(bytes), version = try f.version(bytes)
        let store = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000)
        let before = try f.entries()
        f.scope.invalidate()
        #expect(throws: (any Error).self) { _ = try store.accept(version: version, sourceURL: source) }
        #expect(try f.entries() == before)
    }
    @Test func successfulDownloadIsBoundAndRevalidationRejectsReplacement() throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let bytes = try CloudBootstrapFixture.jpeg(), source = try f.source(bytes), version = try f.version(bytes)
        let store = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000)
        let accepted = try store.accept(version: version, sourceURL: source)
        try store.revalidate(version: version, source: accepted)
        #expect(try Data(contentsOf: accepted.fileURL) == bytes)
        let replacement = f.root.appendingPathComponent("replacement-with-binding")
        #expect(copyfile(accepted.fileURL.path, replacement.path, nil, copyfile_flags_t(COPYFILE_ALL)) == 0)
        #expect(rename(replacement.path, accepted.fileURL.path) == 0)
        // The replacement carries identical bytes AND native xattr binding.
        _ = try store.runtimeAssets.existingBootstrapDownload(version: version)
        #expect(throws: (any Error).self) { try store.revalidate(version: version, source: accepted) }
    }

    @Test func missingLocatorDoesNotRecreateTree() throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let cold = try CloudAssetStagingService.makeForBootstrap(rootURL: f.assetRoot,
            accountIdentifier: f.account.userRecordName, maximumAssetBytes: 100_000_000)
        let before = try f.entries(), version = try f.version(Data("safe".utf8))
        #expect(throws: (any Error).self) { _ = try cold.existingBootstrapDownload(version: version) }
        #expect(try f.entries() == before)
    }

    @Test(arguments: [false, true])
    func externalLinksRejectBeforeNativeWrites(hard: Bool) throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let bytes = Data("safe".utf8), original = try f.source(bytes), version = try f.version(bytes)
        let alias = f.root.appendingPathComponent("alias")
        if hard { #expect(link(original.path, alias.path) == 0) }
        else { #expect(symlink(original.path, alias.path) == 0) }
        let before = try f.entries()
        let store = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000)
        #expect(throws: (any Error).self) { _ = try store.accept(version: version, sourceURL: alias) }
        #expect(try f.entries() == before)
        #expect(try Data(contentsOf: original) == bytes)
    }

    @Test func sourceReplacementAfterBoundedReadRejectsBeforeTree() throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let bytes = Data("safe".utf8), source = try f.source(bytes), replacement = try f.source(bytes)
        let version = try f.version(bytes), before = try f.entries()
        let store = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000,
            beforeBoundary: { point in if point == .afterInputRead { _ = rename(replacement.path, source.path) } })
        #expect(throws: (any Error).self) { _ = try store.accept(version: version, sourceURL: source) }
        #expect(try f.entries() == before)
    }

    @Test(arguments: [CloudBootstrapDownloadBoundary.afterBudgetAdmission, .insideAssetLock])
    func invalidationAtAdmissionNeverPublishes(point: CloudBootstrapDownloadBoundary) throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let bytes = Data("safe".utf8), source = try f.source(bytes), version = try f.version(bytes), scope = f.scope
        let before = try f.entries()
        let store = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: scope, maximumBytes: 100_000_000,
            beforeBoundary: { if $0 == point { scope.invalidate() } })
        #expect(throws: (any Error).self) { _ = try store.accept(version: version, sourceURL: source) }
        let after = try f.entries()
        #expect(!after.contains { $0.relativePath.hasSuffix(".asset") || $0.relativePath.contains("/.tmp-") })
        if point == .afterBudgetAdmission { #expect(after == before) }
    }

    @Test(arguments: CloudAssetPublicationBoundary.allCases)
    func interruptedNativePublicationRemainsRecoverableWithinBound(point: CloudAssetPublicationBoundary) throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let bytes = try CloudBootstrapFixture.jpeg(), source = try f.source(bytes), version = try f.version(bytes)
        let cold = try CloudAssetStagingService.makeForBootstrap(rootURL: f.assetRoot,
            accountIdentifier: f.account.userRecordName, maximumAssetBytes: 100_000_000)
        let plan = try cold.planBootstrapDownload(version: version, sourceURL: source, accountRoot: f.paths.accountRoot)
        let cap = try minimumBudget(f, plan.footprint)
        let before = try f.entries()
        let store = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: cap,
            publicationFault: { if $0 == point { throw DownloadTestFailure.interrupted } })
        #expect(throws: DownloadTestFailure.interrupted) { _ = try store.accept(version: version, sourceURL: source) }
        let after = try f.entries(), added = after.filter { !before.contains($0) }
        let temps = added.filter { $0.relativePath.contains("/.tmp-") }
        let finals = added.filter { $0.relativePath.hasSuffix(".asset") }
        #expect(temps.count == (point == .afterTemporaryFileSync ? 1 : 0))
        #expect(finals.count == (point == .beforeDirectorySync ? 1 : 0))
        try SyncBootstrapDownloadBudget.requireFits(storage: f.storage, paths: f.paths, account: f.account.identity,
            footprint: .init(directoryPaths: [], files: [:]), maximumBytes: cap)
        #expect(try Data(contentsOf: source) == bytes)
        // A retry may need more capacity because a crash-retained temp is real
        // inventory. It never sweeps that evidence to make the retry fit.
        let retry = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000)
        let accepted = try retry.accept(version: version, sourceURL: source)
        try retry.revalidate(version: version, source: accepted)
        for temporary in temps { #expect(try f.entries().contains(temporary)) }
    }

    private func minimumBudget(_ f: CloudBootstrapFixture, _ footprint: SyncBootstrapDownloadFootprint) throws -> Int {
        var low = 0, high = 100_000_000
        while low < high {
            let middle = low + (high - low) / 2
            do {
                try SyncBootstrapDownloadBudget.requireFits(storage: f.storage, paths: f.paths, account: f.account.identity,
                    footprint: footprint, maximumBytes: middle)
                high = middle
            } catch { low = middle + 1 }
        }
        try SyncBootstrapDownloadBudget.requireFits(storage: f.storage, paths: f.paths, account: f.account.identity,
            footprint: footprint, maximumBytes: low)
        return low
    }

    @Test func coldReopenKeepsStoragePathAndInstalledInode() throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        #expect(f.paths.accountRoot.path.hasPrefix("/private/"))
        let bytes = Data("safe".utf8), source = try f.source(bytes), version = try f.version(bytes)
        let store = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000)
        let first = try store.accept(version: version, sourceURL: source), before = try f.entries()
        let reopened = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000)
        #expect(try reopened.accept(version: version, sourceURL: source) == first)
        #expect(try f.entries() == before)
        try store.revalidate(version: version, source: first)
    }

    @Test func pendingBackedInstalledAndAllSourceBytesSurviveRejectionAndReuse() throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        let bytes = try CloudBootstrapFixture.jpeg(), record = try f.attachment(bytes: bytes)
        let version = try #require(record.payload.attachment), input = try f.source(bytes)
        let original = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000)
        let installed = try original.accept(version: version, sourceURL: input)
        let pending = try f.pending(record, source: installed), incoming = try f.pendingIncoming(record)
        #expect(incoming.records == [record])
        #expect(!incoming.acknowledged)
        let before = try f.entries()
        let journal = FileSyncMutationJournal(url: f.paths.mutationJournalURL)
        #expect(try journal.recoverySnapshot().mutations == [pending])
        let cap = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 0)
        #expect(throws: (any Error).self) { _ = try cap.accept(version: version, sourceURL: input) }
        let reopened = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000)
        let bad = try f.source(Data(repeating: 0, count: bytes.count))
        #expect(throws: (any Error).self) { _ = try reopened.accept(version: version, sourceURL: bad) }
        #expect(try reopened.accept(version: version, sourceURL: input) == installed)
        #expect(try f.entries() == before)
        #expect(try journal.recoverySnapshot().mutations == [pending])
        try original.revalidate(version: version, source: installed)
        let otherBytes = Data("another valid attachment".utf8), otherInput = try f.source(otherBytes)
        let other = try f.version(otherBytes)
        _ = try reopened.accept(version: other, sourceURL: otherInput)
        let afterNew = try f.entries()
        #expect(before.allSatisfy(afterNew.contains))
        #expect(try reopened.accept(version: other, sourceURL: otherInput).byteCount == Int64(otherBytes.count))
        #expect(try f.entries() == afterNew)
        try original.revalidate(version: version, source: installed)
        #expect(try journal.recoverySnapshot().mutations == [pending])
    }

    @Test(arguments: [false, true])
    func realSealedInventoryFitsExactProspectiveBound(interrupted: Bool) throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let bytes = try CloudBootstrapFixture.jpeg(), input = try f.source(bytes), version = try f.version(bytes)
        let cold = try CloudAssetStagingService.makeForBootstrap(rootURL: f.assetRoot,
            accountIdentifier: f.account.userRecordName, maximumAssetBytes: 100_000_000)
        let plan = try cold.planBootstrapDownload(version: version, sourceURL: input, accountRoot: f.paths.accountRoot)
        let cap = try minimumBudget(f, plan.footprint)
        let rejected = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: cap - 1)
        let before = try f.entries()
        #expect(throws: (any Error).self) { _ = try rejected.accept(version: version, sourceURL: input) }
        #expect(try f.entries() == before)
        let store = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: cap,
            publicationFault: { if interrupted && $0 == .afterTemporaryFileSync { throw DownloadTestFailure.interrupted } })
        if interrupted { #expect(throws: DownloadTestFailure.interrupted) { _ = try store.accept(version: version, sourceURL: input) } }
        else { _ = try store.accept(version: version, sourceURL: input) }
        #expect(try f.sealedByteCount(maximumBytes: cap) <= cap)
    }

    @Test func nativePublicationUsesTheExactRetainedTemporaryInItsFootprint() throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let bytes = Data("safe".utf8), input = try f.source(bytes), version = try f.version(bytes)
        let cold = try CloudAssetStagingService.makeForBootstrap(rootURL: f.assetRoot,
            accountIdentifier: f.account.userRecordName, maximumAssetBytes: 100_000_000)
        let plan = try cold.planBootstrapDownload(version: version, sourceURL: input, accountRoot: f.paths.accountRoot)
        let before = try f.entries()
        try f.storage.withRecoveryOwnership(paths: f.paths, account: f.account.identity, maximumBytes: 100_000_000) { access in
            try SyncBootstrapDownloadBudget.requireFits(access: access, paths: f.paths, account: f.account.identity,
                footprint: plan.footprint, maximumBytes: 100_000_000)
            try cold.readBootstrapInput(plan)
            #expect(throws: DownloadTestFailure.interrupted) {
                _ = try cold.publishBootstrapDownload(plan, requireCurrent: f.scope.requireCurrent,
                    publicationFault: { if $0 == .afterTemporaryFileSync { throw DownloadTestFailure.interrupted } })
            }
        }
        let added = try f.entries().filter { !before.contains($0) }
        #expect(added.filter { $0.relativePath.contains("/.tmp-") }.count == 1)
        for entry in added {
            if entry.isDirectory { #expect(plan.footprint.directoryPaths.contains(entry.relativePath)) }
            else { #expect(plan.footprint.files[entry.relativePath] == entry.byteCount) }
        }
    }

    @Test func archiveChangesDuringReadRejectBeforeAssetTree() throws {
        let f = try CloudBootstrapFixture(withArchive: true); defer { f.remove() }
        let bytes = Data("safe".utf8), input = try f.source(bytes), version = try f.version(bytes)
        let archiveURL = f.paths.workingSet.appendingPathComponent("projects-v1.json")
        let changed = try JSONEncoder().encode(ProjectArchive(version: ProjectArchive.currentVersion,
            projects: [try StoredProject(id: f.projectID, name: "new edit")]))
        let store = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000,
            beforeBoundary: { if $0 == .afterInputRead { try changed.write(to: archiveURL) } })
        #expect(throws: SyncBootstrapError.sourceChanged) { _ = try store.accept(version: version, sourceURL: input) }
        #expect(!FileManager.default.fileExists(atPath: f.assetRoot.path))
        #expect(try Data(contentsOf: archiveURL) == changed)
    }

    @Test func conflictingInstalledBytesRejectUnchanged() throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let bytes = Data("safe".utf8), input = try f.source(bytes), version = try f.version(bytes)
        let store = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000)
        let accepted = try store.accept(version: version, sourceURL: input)
        try Data("evil".utf8).write(to: accepted.fileURL)
        let before = try f.entries()
        let reopened = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: f.scope, maximumBytes: 100_000_000)
        #expect(throws: (any Error).self) { _ = try reopened.accept(version: version, sourceURL: input) }
        #expect(try f.entries() == before)
        #expect(try Data(contentsOf: accepted.fileURL) == Data("evil".utf8))
    }

    @Test func revocationBeforeNativeRenameCannotPublish() throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let bytes = Data("safe".utf8), input = try f.source(bytes), version = try f.version(bytes), scope = f.scope
        let store = try CloudBootstrapDownloadStore(storage: f.storage, paths: f.paths, scope: scope, maximumBytes: 100_000_000,
            publicationFault: { if $0 == .beforeRename { scope.invalidate() } })
        #expect(throws: SyncBootstrapError.contextChanged) { _ = try store.accept(version: version, sourceURL: input) }
        #expect(try !f.entries().contains { $0.relativePath.hasSuffix(".asset") })
    }

    @Test func invalidationRevokesWhileAdmittedSynchronousWorkIsHeld() async throws {
        let f = try CloudBootstrapFixture(); defer { f.remove() }
        let scope = f.scope, entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let operation = Task.detached {
            do {
                try scope.withCurrent { entered.signal(); _ = release.wait(timeout: .now() + 5) }
                return false
            } catch { return true }
        }
        let didEnter = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 2) == .success)
            }
        }
        #expect(didEnter)
        scope.invalidate()
        #expect(throws: SyncBootstrapError.contextChanged) { try scope.requireCurrent() }
        release.signal()
        #expect(await operation.value)
    }
}

private enum DownloadTestFailure: Error { case interrupted }
