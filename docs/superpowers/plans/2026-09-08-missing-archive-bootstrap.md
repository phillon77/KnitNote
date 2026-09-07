# Missing-archive bootstrap implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reconstruct an account working set from complete remote records plus exact pending mutations without inventing an original archive.

**Architecture:** Extend the existing Core bootstrap transaction with explicit missing-source evidence and an absent-source preparation entry. Reuse the actual staging, install, commit, rollback, canonical activation and account recovery validators. App full-fetch collection and ACK integration follow separately; this Core input API never certifies a network fetch.

**Tech Stack:** Swift, Swift Testing, existing Foundation/CryptoKit/Darwin durable-file infrastructure.

**Spec:** `docs/superpowers/specs/2026-09-08-missing-archive-bootstrap-design.md`

## Global Constraints

Keep 1.7.0 (13), iOS 18/macOS 15/watchOS 11, existing record/journal/publication formats, FIFO mutation identity, merge/deletion rules, 100,000,000-byte file/authority limits and 64 MiB journal metadata limit. No live CloudKit, Keychain, device, signing, push, upload, schema or submission actions. No user data or worktree cleanup.

Existing v1 manifests/receipts remain archive-bound and decode unchanged. New absence transactions use a v2 manifest with an explicit source discriminator and full original-tree fingerprint. The absence proof binds account, live path, source tree and archive absence; it must be distinguishable from an archive digest in both manifest and receipt validation.

Do not publish an empty `JSONProjectStore` as a prerequisite. Do not weaken a validator merely to make reconstruction succeed.

Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`; branch `docs/cross-device-sync-design`; baseline `2462593`. Preserve all evidence. One compiler lane; no worker subagents. Use scoped local commits only. Main owns plan/ledger/report routing; implementer owns production/tests and its report.

## Task 1: Implement absent-source preparation and all evidence readers

**Files:**
- Modify: `Sources/KnitNoteCore/CloudSync/SyncBootstrapTransaction.swift`
- Test: `Tests/KnitNoteCoreTests/SyncBootstrapTransactionTests.swift`
- Test: `Tests/KnitNoteCoreTests/SyncAccountRecoveryTransactionTests.swift` (locate actual terminal inventory fixture before adding coverage)
- Read: `Sources/KnitNoteCore/CloudSync/SyncMergeEngine.swift`, `ProjectArchiveSyncMapper.swift`, `SyncAccountStorage.swift`, `SyncAccountRecoveryTransaction.swift` in the same directory.

**Interfaces:**
- Consumes existing `SyncBootstrapContext`, `SyncBootstrapRemoteSnapshot`, required `SyncBootstrapPendingSnapshot`, `SyncCounterReminderMergeContext`, install/commit/handoff and recovery APIs.
- Produces `public enum SyncBootstrapSourceProof: Equatable, Sendable { case archive(sha256: Data); case missingArchive(treeSHA256: Data) }`.
- `SyncBootstrapReceipt.sourceProof: SyncBootstrapSourceProof`; `sourceArchiveFingerprint: Data?` computes archive hash or nil. Existing transaction/account identifiers remain.
- Produces `public func prepareReconstruction(remote: SyncBootstrapRemoteSnapshot, pendingSnapshot: SyncBootstrapPendingSnapshot, counterReminderContext: SyncCounterReminderMergeContext = .init()) throws -> SyncBootstrapPreparation`.
- Existing ordinary `prepare` signature remains unchanged and missing-source rejecting.

- [x] **Step 1: Add behavioral/API RED tests using actual transaction fixtures.**

Extend existing private fixture helpers in place. Obtain a complete remote export before removing only the test fixture's archive; do not open a store to cause automatic archive creation. Capture original tree after absence is established. Minimal principal test shape:

```swift
let fixture = try Fixture(); defer { fixture.remove() }
let remote = try fixture.export()
try FileManager.default.removeItem(at: fixture.live.appendingPathComponent("projects-v1.json"))
let original = try treeBytes(fixture.live)
let transaction = try fixture.transaction()
let fingerprint = try transaction.sourceFingerprint()
let preparation = try transaction.prepareReconstruction(
    remote: .init(context: fixture.context, records: remote.records,
                  attachments: remote.attachments, isComplete: true),
    pendingSnapshot: .init(mutations: [], sourceTreeFingerprint: fingerprint))
#expect(try treeBytes(fixture.live) == original)
try transaction.install(preparation)
let receipt = try transaction.commit(preparation)
#expect(receipt.sourceProof == .missingArchive(treeSHA256: fingerprint))
#expect(receipt.sourceArchiveFingerprint == nil)
try transaction.canonicalHandoff(preparation).revalidate()
#expect(try fixture.readArchive().projects == fixture.archive.projects)
```

Also establish ordinary `prepare` absent-source failure as the existing behavioral RED that motivates the distinct route. Record compile-only RED separately from behavioral evidence.

- [x] **Step 2: Run and retain RED output.**

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --no-parallel --filter SyncBootstrapTransactionTests
```

Use a new `/tmp/missing-archive-bootstrap-task1-red-01.log`, shell redirection permitted for command output. Expected new entry/source-proof API missing; existing absent-source route rejects. Do not run the full Core suite here.

- [x] **Step 3: Implement versioned source evidence and shared validation.**

Custom encode/decode the exact spec forms: archive writes unchanged v1 shape, absence writes v2 source kind/tree hash and omits archive hash. Receipt legacy absent version is allowed only with legacy archive hash; v2 requires `formatVersion: 2`. Reject mixed fields/unknown kinds/versions/bad hash lengths. Refactor the existing duplicated manifest source checks into one internal validator consumed by normal decoding and terminal account recovery. Validation uses original inventory, account and live/journal path; source-kind mismatch is corruption, not fallback.

```swift
public var sourceArchiveFingerprint: Data? {
    guard case let .archive(sha256) = sourceProof else { return nil }
    return sha256
}
```

Do not write a v2 archive transaction merely to normalize old data. Cover Codable wire keys with `JSONSerialization` assertions and literal legacy receipt bytes. Keep original v1 `version:2` tampering test rejected because it lacks valid absence evidence.

- [x] **Step 4: Implement reconstruction through shared existing staged transaction machinery.**

Resolve interrupted authority through existing owner paths; this entry rejects contradictory remaining archive/publication/canonical evidence without modifying it. Use no-follow archive absence check distinguishing ENOENT from all other errors. Validate complete/context/pending/source tree before copying; preserve `Original` and full staged original. Skip only ordinary source-archive decode/export roundtrip/backup validation of an absent archive, not final merged validation. Factor common stage/checkpoint/evidence/mutation/manifest code so ordinary and absence routes cannot drift.

```swift
let merged = try SyncMergeEngine().merge(local: [SyncRecord](),
    remote: remote.records, pendingLocalMutations: pendingSnapshot.mutations,
    counterReminderContext: counterReminderContext)
let base = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
let materialized = try ProjectArchiveSyncMapper.materialize(
    records: merged.records, attachments: sources, baseArchive: base)
```

`sources` comes from existing staging verifier applied to remote sources plus every exact validated pending attachment source. The in-memory base is metadata only. Preserve pending journal FIFO identities/source bytes and existing legacy reminder/deletion repair gates. Install/commit/rollback reuse existing real directory moves; no fake original source file. Revalidate original inventory/context before prepared manifest and every existing boundary.

- [x] **Step 5: Add and run the complete focused regression matrix.**

Use actual fixtures, parameterization and existing `SyncBootstrapBoundary.allCases`. Cover: populated and empty complete remote; pending-only full project graph; remote-only graph plus overlapping pending; pending immutable attachment and FIFO identities; source archive appearing/changing, symlink/directory/error and stale freeze/context; incomplete remote; missing parent/attachment; unsupported legacy reminder pending; unresolved publication/canonical evidence; exact rollback at every existing boundary; fresh-context committed handoff; literal v1 compatibility; malformed v2 discriminator/hash/mixed evidence; real account terminal recovery for v2 committed and rolled-back evidence. Preserve test-only source file contents to compare bytes after rejection/recovery. Confirm actual canonical activation with existing activation fixture, not handoff existence alone.

Clarification from reproduced integration failure: committed v2 covers full account seal/cleanup; rolled-back v2 covers actual `storage.withRecoveryInventory` plus `validateTerminalRecovery`. Preserve/report the full-seal `unsafeBinding` failure caused by Inventory's archive-required contract. Do not weaken that guard here. Full missing-source sealing, including cancelled pre-prepare restores, is load-bearing downstream work rather than a passing acceptance claim.

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 1200 arch -arm64 swift test --no-parallel --filter 'SyncBootstrapTransactionTests|SyncAccountRecoveryTransactionTests|SyncCanonical'
```

Verify actual suite names before selecting; append all necessary directly affected named suites rather than broad undocumented filters. Behavioral mutation RED should remove the absent-source proof check and demonstrate a specific safety test fails, then restore code and rerun final focused GREEN. Do not use timeout increases as a fix. Keep all failed and final logs, hashes and exit statuses in the report.

- [x] **Step 6: Self-review and commit exact task files.**

```sh
git diff --check
git add Sources/KnitNoteCore/CloudSync/SyncBootstrapTransaction.swift Tests/KnitNoteCoreTests/SyncBootstrapTransactionTests.swift Tests/KnitNoteCoreTests/SyncAccountRecoveryTransactionTests.swift
git commit -m "feat(sync): reconstruct bootstrap without a source archive"
```

Adjust exact test-file staging to actual changed covering files, never `git add .`. Main will dispatch independent spec+quality review from baseline through all task commits. Report all deviations before claiming done. Do not execute Task 2 or dispatch reviewers.

## Task 2: Independent review and frozen validation

**Files:** create `docs/superpowers/reports/2026-09-08-missing-archive-bootstrap-verification.md`; update this plan's checkboxes. Controller task, no production code changes.

- [x] Read Task 1 full report and final log output/hashes, inspect exact diff and issue task review with spec/global constraints. Resolve all load-bearing findings using the same implementer and scoped re-review. Preserve all rulings and costs.
- [x] Run one final broad review of this subplan, explicitly carrying downstream full-fetch/ACK and canonical-probe/live-helper gates. Do not claim these are implemented by Core preparation.
- [x] Freeze full SHA/source trees. Run serial final Core with `env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION`, then actual-source App harness with explicit `KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0`, root harness, unsigned macOS build-for-testing and generic iOS build. Exact established commands/harness manifests are in the prior committed identity verification report; use fresh `/tmp/missing-archive-bootstrap-frozen-01-*` logs and derived paths, verify they do not exist, and stop chain on failure. No production edits while frozen.
- [x] Verify every final exit and diagnostic, unchanged source trees and 1.7.0 (13); record hashes, failures/limits and all rulings in report. Commit docs, preserve ledger, then continue the real App full-fetch/ACK integration. Do not push/merge/upload/submit from this task.

Self-review: Task 1 owns the whole tightly-coupled format/prepare/recovery change, so no reviewer sees a half-migrated reader set. Task 2 consumes its exact committed candidate. Empty Core metadata base is never an App readiness shortcut. No other bootstrap, identity or producer plan is repeated.
