# Store Background Write Drain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reject new store background writes after revocation and await accepted backup, pattern, journal-photo and thumbnail work through its actual native termination.

**Architecture:** Evolve the reviewed per-store backup tracker into one category-aware internal tracker, retaining backup-only waiting and error behavior. Wire each native producer's outer lifetime and post-await admission without replacing native transactions; expose the aggregate public wait only after all four categories are wired.

**Tech Stack:** Swift 6, MainActor, AsyncStream, Swift Testing, existing file-service hooks, SwiftPM, Xcode.

**Spec:** `docs/superpowers/specs/2026-09-06-store-background-write-drain-design.md`; parent `docs/superpowers/specs/2026-09-06-cloud-sync-app-session-lifecycle-design.md`.

## Global Constraints

- 不改資料／備份／同步 record／journal／publication 格式、購買規則、語言或開發故事；保留 100,000,000-byte 檔案／authority 與 64 MiB journal metadata 上限。所有測試只使用獨立 fixture。不得改綁 store 路徑、刪除原始匯入來源，或把舊操作移交新帳號。
- 新等待結果不是完整 store freeze、資料健康、inventory、seal、cleanup 或新帳號可開啟的 receipt。App 外部生產者、Watch、engine、UI generation、建構期 recovery 與真實 authority 驗證仍是獨立門檻。
- 本工作不啟用正式 CloudKit、Keychain、Watch 或 App factory，不產生跨帳號啟用、簽署、安裝、真實資料遷移或清理的授權。
- Version remains **1.7.0 (13)**. Keep the existing public `BackupSessionDrainError` nominal type and backup-only wait contract. No synchronous lock across await; cancellation never unregisters native work.
- Keep native rollback, publication, catch cleanup and final reconcile inside the accepted operation. Do not turn termination into durable-health evidence or run recovery merely to make a wait return.
- No production testing seam is needed: reuse existing service hooks and test fixture helpers. No sleep, arbitrary yield, elapsed-time assertion or unbounded child task used as correctness evidence. On assertion failure release native blockers and await owned tasks before fixture cleanup.
- No merge, push, signing, install, App/test-host execution, upload, submission or worktree/evidence cleanup in this plan. Preserve prior work and all RED/timeout evidence.

## Baseline, file ownership and execution

Observed clean baseline: `bedaea05ec660c9329910dcd6cb2564a87f4ad96`, branch `docs/cross-device-sync-design`, linked worktree `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`. Prior unchanged implementation passed full Core2493/183 and unsigned macOS/iOS; see backup drain verification report for its documentation-only HEAD caveat. These results are baseline context, not new-plan acceptance.

Task1 owns tracker migration, existing tracker tests, backup wiring and PBX. Tasks2/3 own their corresponding store methods and new suites appended to `JSONProjectStoreTests.swift`, reusing its private `StoreBackupFixture`, `StoreOperationBlocker`, `backupEvidenceBytes`, `makeStorePNG`, `makeStoreJPEG`, and `makeStorePatternPDF`. Task4 owns the public aggregate API, mixed-work acceptance and durable report. Keep one implementation task active at a time because they share the store/test file.

The controller reviews each complete precommit diff, commits after approval, then performs one full-plan review and one consolidated fix wave. Full validation belongs to the controller after all reviews. During final validation do not edit or commit **any tracked file, including documentation**; record progress only in this plan's ignored workspace. Update reports after the commands finish.

### Task 1: Category-aware tracker and unchanged backup contract

**Files:**
- Move/replace: `Sources/KnitNoteCore/Backup/BackupSessionWorkTracker.swift` → `Sources/KnitNoteCore/Projects/StoreSessionWorkTracker.swift`.
- Move/update: `Tests/KnitNoteCoreTests/BackupSessionWorkTrackerTests.swift` → `Tests/KnitNoteCoreTests/StoreSessionWorkTrackerTests.swift`.
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`, `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`, `KnitNote.xcodeproj/project.pbxproj`.

**Interfaces:**
- Produces internal MainActor `StoreSessionWorkTracker`, nested `Kind: CaseIterable, Hashable, Sendable` with `.backup`, `.pattern`, `.journalPhoto`, `.thumbnail`; nested instance-bound `Token`.
- `begin(kind: Kind, protecting root: URL? = nil) throws -> Token`; `close()`; `finish(_ token: Token)`; `protects(_ artifact: URL, kind: Kind) -> Bool`; `waitUntilClosedAndIdle(for kinds: Set<Kind>) async throws`.
- Produces public `StoreSessionDrainError.sessionStillActive`, retains public `BackupSessionDrainError.sessionStillActive`.
- Store property becomes `private let sessionWork = StoreSessionWorkTracker()`; internal `waitForTrackedBackgroundWritesAfterRevocation() async throws` is testable but **not public yet**. Task4 promotes it only after all producers are covered.

- [ ] Write failing category and public-error tests before migrating source. Preserve every existing tracker assertion, updating direct tracker calls to explicit `.backup` and direct open-wait expectation to `StoreSessionDrainError`; keep store backup API expectation on `BackupSessionDrainError`.

```swift
@Test func backupWaitDoesNotWaitForUnrelatedCategory() async throws {
    let tracker = StoreSessionWorkTracker()
    let backup = try tracker.begin(kind: .backup)
    let pattern = try tracker.begin(kind: .pattern)
    tracker.close()
    tracker.finish(backup)
    try await tracker.waitUntilClosedAndIdle(for: [.backup])
    let ready = AsyncStream<Void>.makeStream()
    var ended = false
    let all = Task { @MainActor in
        ready.continuation.yield(())
        try await tracker.waitUntilClosedAndIdle(for: Set(StoreSessionWorkTracker.Kind.allCases))
        ended = true
    }
    var iterator = ready.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(!ended)
    tracker.finish(pattern)
    try await all.value
    #expect(ended)
}
```

Also test two simultaneously registered waiters with overlapping/different scopes, foreign/duplicate finishes, cancellation isolation, cancellation-before-entry, empty scope after closure, and protection scoped to backup roots. In the existing store test file add:

```swift
@MainActor @Test func backupWaitRetainsItsPublicOpenSessionError() async throws {
    let fixture = try StoreBackupFixture.make()
    defer { fixture.cleanup() }
    await #expect(throws: BackupSessionDrainError.sessionStillActive) {
        try await fixture.store.waitForBackupOperationsAfterRevocation()
    }
    await #expect(throws: StoreSessionDrainError.sessionStillActive) {
        try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
    }
}
```

- [ ] Run `swift test --filter 'StoreSessionWorkTrackerTests|backupWaitRetainsItsPublicOpenSessionError'`; record intended missing-type/API RED separately from any environment error.
- [ ] Implement the tracker by retaining the existing token and stream model. Replace operation values with `(kind: Kind, root: URL?)`; replace waiter values with `(kinds: Set<Kind>, continuation: AsyncStream<Void>.Continuation)`. Store standardized optional roots. The completion algorithm is:

```swift
private func hasWork(in kinds: Set<Kind>) -> Bool {
    operations.values.contains { kinds.contains($0.kind) }
}

func finish(_ token: Token) {
    guard token.owner == owner,
          operations.removeValue(forKey: token) != nil,
          closed else { return }
    let ready = waiters.filter { !hasWork(in: $0.value.kinds) }
    for (id, waiter) in ready {
        waiters.removeValue(forKey: id)
        waiter.continuation.yield(())
        waiter.continuation.finish()
    }
}
```

`waitUntilClosedAndIdle(for:)` checks Task cancellation, closed admission, then `hasWork(in:)`; if work remains, register a uniquely identified stream with that immutable scope, defer removing/finishing only that stream, then await a value and recheck cancellation. A finished stream without a value still throws `CancellationError`. `protects` checks only matching kind records with non-nil roots and path-component prefix matching. No filter changes or work removal occur from waiter cancellation.

- [ ] Update only the existing backup tracker references, adding `kind: .backup` to registration/protection and mapping open-session errors at the store API:

```swift
public func waitForBackupOperationsAfterRevocation() async throws {
    do {
        try await sessionWork.waitUntilClosedAndIdle(for: [.backup])
    } catch StoreSessionDrainError.sessionStillActive {
        throw BackupSessionDrainError.sessionStillActive
    }
}

// Internal until the producer inventory is wired in Tasks 2 and 3.
func waitForTrackedBackgroundWritesAfterRevocation() async throws {
    try await sessionWork.waitUntilClosedAndIdle(for: Set(StoreSessionWorkTracker.Kind.allCases))
}
```

Retain outer defer placement of export/prepare/restore exactly. Update the PBX file reference/path and App/Watch source memberships without duplicating IDs or regenerating unrelated settings. Preserve the public backup error in the module when removing its old file.
- [ ] Run `swift test --filter 'StoreSessionWorkTrackerTests|StoreBackup|backupWaitRetainsItsPublicOpenSessionError'`, PBX lint and diff check. Mutate aggregate scope filtering to ignore a live pattern token; `!ended` must fail and the test must still finish all tokens/tasks. Do not use a deliberately non-returning backup wait as RED evidence. Mutate broadcast/cancel isolation only if new scope coverage is not established by those cases; do not repeat prior unrelated mutations. Restore exactly and rerun covering GREEN.
- [ ] Write task report with actual diffs/logs, then independent review and controller commit `refactor(sync): share scoped store session work tracking`.

### Task 2: Pattern and inbox native lifetime

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`.
- Test: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`, new `@Suite @MainActor struct StorePatternSessionDrainTests`.

**Interfaces:**
- Consumes `sessionWork.begin(kind: .pattern)`, `finish`, internal aggregate wait from Task1.
- Existing public import/process/pending/discard/addYouTube signatures remain unchanged. Private `withActivePatternTransaction` becomes `async throws`, not `rethrows`, because admission can throw independently.

- [ ] Add entry tests proving revoked direct import, library/project import, process inbox, pending inbox, discard and addYouTube reject without source/evidence changes. Reuse full-root `backupEvidenceBytes`; preserve enumeration failures as thrown errors. Use fixture's original project UUID and a PNG under its private root.
- [ ] Add controlled tests for direct import, inbox enqueue/prepare, accepted discard/recovery termination and native failure evidence. The direct-import fixture already supports `patternBlocker`; the inbox fixture supports `patternInboxBlocker` and `failPatternInboxMove`:

```swift
@Test func directImportRemainsTrackedUntilNativeCopyEnds() async throws {
    let blocker = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(patternBlocker: blocker)
    defer { fixture.cleanup() }
    let source = fixture.root.appendingPathComponent("source.png")
    try makeStorePNG(at: source, red: 0.5)
    let original = try Data(contentsOf: source)
    let projectID = try #require(fixture.store.projects.first?.id)
    let operation = Task { @MainActor in
        blocker.startObservingOperation()
        defer { blocker.finishObservation(reachedBlock: false) }
        return try await fixture.store.importPattern(from: source, projectID: projectID)
    }
    do { try #require(await blocker.waitForObservedBlock()) }
    catch { blocker.resume(); _ = try? await operation.value; throw error }
    fixture.store.revokeSessionWrites()
    let ready = AsyncStream<Void>.makeStream()
    var ended = false
    let drain = Task { @MainActor in
        ready.continuation.yield(())
        try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
        ended = true
    }
    var iterator = ready.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(!ended)
    blocker.resume()
    await #expect(throws: StoreSessionAccessError.revoked) { try await operation.value }
    try await drain.value
    #expect(try Data(contentsOf: source) == original)
    #expect(fixture.store.projects.first?.patterns.isEmpty == true)
}
```

For inbox tests add **test-fixture-only** optional service closures when the existing move blocker is not the needed boundary: `PatternInboxFileService` already injects copy/move/remove/write; `PatternFileService` already injects copy/move/write; receipt recovery uses existing service APIs. Block a real native operation and preserve its own error, not a sleep. Exercise each continuation boundary separately: enqueue→process, reconcile→prepare, prepare→publish, pending reconciliation→items result. Accepted native discard completes with its real success/error and no invented post-result revoked error. Snapshot a second independent fixture root before A work and after A drain; B remains unchanged and can then be edited normally.
- [ ] Run `swift test --filter StorePatternSessionDrainTests`; capture behavioral RED against Task1. Do not claim the internal aggregate wait already covers the not-yet-wired photo/thumbnail categories.
- [ ] Wire direct import with an outer token before any background side effect, outside the existing counter defer. Wire helper as:

```swift
private func withActivePatternTransaction<Result>(
    _ operation: () async throws -> Result
) async throws -> Result {
    try requireSessionWriteAccess()
    let work = try sessionWork.begin(kind: .pattern)
    defer { sessionWork.finish(work) }
    activePatternTransactions += 1
    defer { activePatternTransactions -= 1 }
    return try await operation()
}
```

Add `try requireSessionWriteAccess()` after successful await and **before starting the next native phase** in `enqueuePatternImport` and `processPatternInboxItemWithoutTransaction`. In `pendingPatternInboxItems`, check entry before reconciliation, recheck after reconciliation, await items into a value, recheck before returning it. In direct `importPattern`, recheck inside its existing `do` before publication so its existing owned-file catch cleanup remains in scope. Do not rewrite native service transaction or cleanup bodies. Do not add a post-discard revocation error after native discard succeeded.
- [ ] Run `swift test --filter 'StorePatternSessionDrainTests|StoreSessionWorkTrackerTests|StoreBackup|PatternImport|PatternInbox|PatternLibrary|YouTubePattern'`. Temporarily omit direct-import tracking and one post-enqueue/reconcile admission check, separately; targeted lifetime/evidence tests must fail for the intended behavior. Restore and rerun covering GREEN. Keep errors and cancellation separate.
- [ ] Report and precommit review; controller commit `feat(sync): drain pattern work after store revocation`.

### Task 3: Journal photos and thumbnail producers

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`.
- Test: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`, new `@Suite @MainActor struct StoreMediaSessionDrainTests` and scoped fixture additions.

**Interfaces:**
- Consumes tracker `.journalPhoto` and `.thumbnail`, internal aggregate wait.
- Retains all public media signatures. No tracking of pure `yarnLabelPhotoStorageBytes` is added; no App/UI generation claim.
- Fixture gains `thumbnailRenderBlocker` and `thumbnailStageBlocker` optional arguments and a `thumbnailService: PatternThumbnailFileService` field for native-lock tests. Default behavior stays equivalent to existing tests.

- [ ] Create revoked-entry and late-native-result tests for `addJournalEntry`, `cacheYouTubeThumbnail`, `patternThumbnailURL`, `patternPDFPageThumbnailURL`, and both cover branches. Use `journalBlocker` already in `StoreBackupFixture` to stop after a real full-image write; require drain to remain pending, preserve native save errors, then ensure no revoked domain entry is published and native catch/reconcile output matches existing behavior.
- [ ] Configure fixture-only thumbnail hooks, using existing production APIs:

```swift
let thumbnailService = PatternThumbnailFileService(
    directory: root.appendingPathComponent("ThumbnailCache"),
    afterPageRender: { thumbnailRenderBlocker?.blockOnce() }
)
// Pass thumbnailService to JSONProjectStore, and this existing async hook:
afterYouTubeThumbnailStage: {
    if let thumbnailStageBlocker {
        await Task.detached { thumbnailStageBlocker.blockOnce() }.value
    }
}
```

For PDF page generation, the real `afterPageRender` callback holds the native service lock until released. For ordinary pattern/cover generation (no direct hook), first run a direct service PDF-page render on the **same fixture service instance** and block its after-render hook. Start the store's ordinary thumbnail/cover request using a same-MainActor readiness event; it reaches its detached await with native generation serialized behind that held lock. Revoke, observe aggregate wait still pending, release the lock holder, await every task, and require late store URL to be nil. The test's direct lock-holder task is also explicitly awaited before cleanup; it is not presented as store-tracked work.

Create PDF source with existing `makeStorePatternPDF` (one page) and import via `importPatternFromProject(source, projectID: fixture.store.projects[0].id)` before starting the rendering tasks. Use pageIndex0 for the held page render and the distinct uncached ordinary cover destination. Import does not itself invoke the page-render hook; no mutable production hook toggle is required. Do not mistake a cache hit or direct-photo branch for a rendering test. For YouTube, use the existing `addYouTubePattern` setup patterns in `YouTubeThumbnailCacheTests.swift`, then hold the post-stage hook and verify revocation prevents canonical cache publication and retains native stage cleanup semantics.
- [ ] Run `swift test --filter StoreMediaSessionDrainTests`; collect intended missing-admission/lifetime/late-result REDs.
- [ ] Put photo tracking outside the existing counter/reconcile defer:

```swift
try requireSessionWriteAccess()
let work = try sessionWork.begin(kind: .journalPhoto)
defer { sessionWork.finish(work) }
// Existing requireAccess, validations, counter, processingTask and cancellation forwarding.
// Keep the existing counter decrement + reconcile defer registered after this outer defer.
// Inside the existing post-save do/catch, before domain publication:
try requireSessionWriteAccess()
```

No signal is emitted from `activeJournalPhotoTransactions` reaching zero. The outer defer executes only after its final synchronous reconcile. Preserve the existing service error if detached save throws before the post-save admission check.
- [ ] For nonthrowing media methods, use an entry guard and accepted-work token, then retain the native body and recheck immediately before publishing/returning a late result:

```swift
guard !isSessionWriteRevoked,
      let work = try? sessionWork.begin(kind: .thumbnail) else { return nil }
defer { sessionWork.finish(work) }
// Existing detached generation and asset/version checks.
guard !isSessionWriteRevoked else { return nil }
return thumbnailURL
```

The Void YouTube method uses `return` instead of `return nil`. At its existing post-stage validation branch, include `!isSessionWriteRevoked`; the existing discard of its own stage remains inside accepted work. Do not publish after revocation. Ordinary cache generation may finish natively, but its late URL is not returned and its source is not deleted. For `projectCoverURL`, reject after revocation before even its direct-photo branch to avoid returning an old cover through this async presentation API; synchronous URL getters remain outside this change. Preserve PDF page/asset-version/cancellation validation.
- [ ] Run `swift test --filter 'StoreMediaSessionDrainTests|StorePatternSessionDrainTests|StoreSessionWorkTrackerTests|StoreBackup|ProjectJournal|PatternThumbnail|YouTubeThumbnail|PatternReaderThumbnail'`. Targeted mutations: premature photo finish before awaiting child; omitted post-stage revoked check; omitted ordinary thumbnail late-result check. Prove intended RED, restore exactly, rerun covering GREEN. Verify all test-owned native workers terminate before fixture deletion.
- [ ] Report and precommit review; controller commit `feat(sync): drain accepted photo and thumbnail work`.

### Task 4: Public aggregate wait, mixed-work acceptance and report

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`.
- Test: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`, new `StoreBackgroundDrainIntegrationTests`.
- Create: `docs/superpowers/reports/2026-09-07-store-background-write-drain-verification.md`.

**Interfaces:**
- Produces public `waitForTrackedBackgroundWritesAfterRevocation() async throws -> Void` only after Tasks2/3 reviewed. No production App caller is added.

- [ ] Add a mixed two-producer test with `StoreBackupFixture.make(journalBlocker: photo, patternBlocker: pattern)`. Start both real native operations, consume both native-block observations, revoke, and start backup-only plus aggregate waits. Backup-only returns because no backup is running; aggregate remains pending after the first native operation is released and ends only after the second. Both actual operation results are awaited and inspected; A/B full-root evidence remains isolated.

The complete mixed-lifetime test is:

```swift
@Test func aggregateWaitIncludesBothNativeProducers() async throws {
    let photo = StoreOperationBlocker()
    let pattern = StoreOperationBlocker()
    let fixture = try StoreBackupFixture.make(journalBlocker: photo, patternBlocker: pattern)
    defer { fixture.cleanup() }
    let projectID = try #require(fixture.store.projects.first?.id)
    let source = fixture.root.appendingPathComponent("mixed-source.png")
    try makeStorePNG(at: source, red: 0.4)
    let photoData = try makeStoreJPEG(red: 0.6)
    let photoTask = Task { @MainActor in
        photo.startObservingOperation()
        defer { photo.finishObservation(reachedBlock: false) }
        try await fixture.store.addJournalEntry(projectID: projectID, photoData: photoData, caption: nil)
    }
    let patternTask = Task { @MainActor in
        pattern.startObservingOperation()
        defer { pattern.finishObservation(reachedBlock: false) }
        return try await fixture.store.importPattern(from: source, projectID: projectID)
    }
    do {
        try #require(await photo.waitForObservedBlock())
        try #require(await pattern.waitForObservedBlock())
    } catch {
        photo.resume(); pattern.resume()
        _ = try? await photoTask.value
        _ = try? await patternTask.value
        throw error
    }
    fixture.store.revokeSessionWrites()
    try await fixture.store.waitForBackupOperationsAfterRevocation()
    let ready = AsyncStream<Void>.makeStream()
    var ended = false
    let all = Task { @MainActor in
        ready.continuation.yield(())
        try await fixture.store.waitForTrackedBackgroundWritesAfterRevocation()
        ended = true
    }
    var iterator = ready.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(!ended)
    photo.resume()
    await #expect(throws: StoreSessionAccessError.revoked) { try await photoTask.value }
    #expect(!ended)
    pattern.resume()
    await #expect(throws: StoreSessionAccessError.revoked) { try await patternTask.value }
    try await all.value
    #expect(ended)
}
```

Also cover one cancelled waiter while another aggregate waiter is registered, successful empty closed wait, open public error, and terminal native failures with retained evidence before/after the wait. Preserve real errors rather than discarding outcomes with `try?` outside test failure cleanup.
- [ ] Run `swift test --filter StoreBackgroundDrainIntegrationTests`. If production behavior already passes because earlier tasks implemented it, that is integration validation rather than invented RED; use a targeted mutation that excludes a live category from the aggregate wait and prove the mixed-work test fails, then restore.
- [ ] Promote the existing internal method to public and add this precise API documentation:

```swift
/// Waits for this store's registered backup, pattern, journal-photo and thumbnail
/// operations after revocation. Completion proves termination only, not durable
/// health, complete App freeze, cleanup authority, or account readiness.
public func waitForTrackedBackgroundWritesAfterRevocation() async throws {
    try await sessionWork.waitUntilClosedAndIdle(for: Set(StoreSessionWorkTracker.Kind.allCases))
}
```

- [ ] Run original default-concurrent affected command:
`swift test --filter 'JSONProjectStore|StoreBackground|StorePatternSession|StoreMediaSession|StoreSessionWorkTracker|SyncConflict|SyncRemoteBatch|SyncPublication|SyncDeletion|Backup|Watch|PatternImport|PatternInbox|PatternLibrary|ProjectJournal|PatternThumbnail|YouTubeThumbnail'`.
Record all counts, command exits/durations, warnings, expected-negative diagnostics, file/tree identities, RED/restoration evidence and limitations in the report. Do not count backup-only waiting as full freeze.
- [ ] Report, independent precommit review, controller commit `feat(sync): expose tracked background write termination`.

## Final controller-owned validation and handoff

- [ ] Review the entire plan delta plus concrete affected callers once; carry all deferred findings into one consolidated fix wave and one scoped rereview. Do not reopen the already-completed prior backup plan as a separate repeated implementation.
- [ ] Freeze HEAD, Sources tree, Tests tree and PBX blob; keep **all tracked content and HEAD unchanged** until these serial commands finish:

```sh
swift test --no-parallel
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/store-background-drain-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/store-background-drain-ios-derived CODE_SIGNING_ALLOWED=NO build
```

Use unique no-clobber logs and inspected bounded runner,3600/900/900seconds. If a bound expires, verify owned descendants really terminated before edits; retain partial evidence. Never turn a subset or timeout into a full pass.
- [ ] Update the durable report only after validation, with exact candidate identity, real outcomes and explicit remaining App owner/UI/Watch/real-cloud/device/store gates; documentation-only commit afterward and source identity readback.
- [ ] Use finishing-a-development-branch under the user's delegated overnight authority: preserve this development branch/worktree while whole-product gates remain incomplete, no speculative merge/push or release. Preserve SDD evidence. Stop starting new work at2026-09-07 08:00 Asia/Taipei and leave a truthful handoff.

## Self-review checklist

- [x] Scope covers all four categories while retaining backup-only filtering/error identity.
- [x] Pattern continuation boundaries, photo final reconcile, all four async thumbnail/cover APIs and pure-read exclusion map to Tasks2/3.
- [x] Public aggregate API is not exposed before producers are wired; no App or account-ready consumer is added.
- [x] Types, filenames, tracker property and method signatures are consistent across tasks; fixture helpers named above exist at the observed baseline.
- [x] No placeholder behavior, unspecified error mapping, new production test seam or time-based correctness assertion remains. Self-review replaced an unsafe non-returning mutation option with a prompt-failing aggregate-scope mutation, specified the existing one-page PDF fixture, and made the mixed-work example assert actual errors.
