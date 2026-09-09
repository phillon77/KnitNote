# Owned Commit Crash Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove receipt-before-commit rollback and committed-before-publication idempotent recovery with real process termination and same-disk reopen.

**Architecture:** Reuse the actual owned transaction and existing fixture patterns. Add one focused Swift Testing suite; no production API or disk format changes. This implements section 10 of the spec only, not the V4 import subsystem.

**Tech Stack:** Swift Testing, Foundation Process, Darwin, existing KnitNoteCore native storage.

**Spec:** `docs/superpowers/specs/2026-09-10-legacy-import-durable-transaction-design.md`, section 10 with sections 2/3/7/9 safety constraints.

## Global Constraints

- 版本維持 1.7.0 (13)；最低 iOS 18、macOS 15、watchOS 11。
- 無新增套件、帳號、網路傳輸、CloudKit schema、Keychain 或真實使用者資料操作。
- shipping、screenshot、Watch 與 Share 啟動不接入新匯入能力。
- 原始內容、成功備份及復原證據不因取消、失敗或空間不足而刪除。
- caller Boolean、URL、帳號 hash、UUID、可解碼紀錄都不是來源／安裝／清理權限。
- 本機提交與雲端同步是不同狀態；不宣稱已推送、上傳、送審或發布。

Test-only fixtures may clean successful isolated roots; retain and print failed roots/logs. Do not edit production code, project files, old tests, unrelated untracked files, or run multiple compiler lanes. Parent owns docs; implementer owns the one new test file. Every child process must be bounded, awaited/reaped, and actual intentional exit distinguished from timeout/failure.

### Task 1: Native receipt/commit crash and rejection matrix

**Files:**
- Create: `Tests/KnitNoteCoreTests/SyncBootstrapOwnedCommitCrashTests.swift`
- Read: `Tests/KnitNoteCoreTests/SyncBootstrapOwnedInterruptionMatrixTests.swift` and its native child/fixture helpers.
- Read: `Tests/KnitNoteCoreTests/SyncBootstrapOwnedTransactionTests.swift` and `Sources/KnitNoteCore/CloudSync/SyncBootstrapOwnedTransaction.swift` commit/recover.

**Interfaces:**
- Consumes: `SyncBootstrapOwnedTransaction.prepare(_:)`, `install(_:)`, `commit(_:)`, `recover()`, existing `.afterReceipt` observation hook, `SyncAccountStorage.openExistingAccount(identity:validateAccount:)`, existing real fixture/export helpers.
- Produces: test suite `SyncBootstrapOwnedCommitCrashTests`, worker `nativeCommitCrashWorker`, parent case `receiptBoundaryReopensWithoutDuplicateImport`, corruption case `invalidCommittedReceiptPreservesEvidence`.
- No new production interface. Helper naming may follow the actual accessible existing fixture signatures; native ownership and nonempty expectations may not be replaced with mocks.

- [x] **Step 1: Inspect fixture and establish baseline.** Root runs existing `SyncBootstrapOwnedTransactionTests` once. Reuse its verified-account fixture patterns, but create nonempty archive content and at least one actual journal mutation. Child writes before/installed expected snapshots outside the account root before the cut. Parent must not initialize data. Keep child fixture construction private to worker, with a unique `owned-commit-crash-` temporary root that must not exist yet.

- [x] **Step 2: Add parent and real child tests.** The child invokes actual `prepare`, `install`, `commit`; cut uses `Darwin._exit(86)` at `.afterReceipt`, or immediately after successful `commit` returns without handoff/publication. Pass cut/root through dedicated `KNITNOTE_OWNED_COMMIT_CHILD`/`KNITNOTE_OWNED_COMMIT_ROOT` environment keys; remove real CloudKit integration flag. Launch current `swiftpm-testing-helper` with only worker filter, stripping both separated and equals-form prior filters. Worker is a no-op without its dedicated environment. Timeout is at most 60 seconds with termination/grace/KILL and reaping. Logs remain available on failure.

```swift
// Break caught: receipt existence is confused with committed native state,
// or recovering a committed transaction enqueues the same import again.
@Test(arguments: ["after-receipt", "after-commit"])
func receiptBoundaryReopensWithoutDuplicateImport(cut: String) throws {
    // Launch actual child, require exit 86, then openExistingAccount on same root.
    // after-receipt: installed manifest + present valid receipt BEFORE recover;
    // recover returns nil, rolledBack, source bytes equal before snapshot.
    // after-commit: committed manifest + receipt BEFORE recover;
    // recover returns nonnil, original project and nonempty journal preserved.
    // Close and open a second storage instance; recover again.
    // Compare project content, journal mutation IDs/order and retained file bytes.
}
```

This code block defines the behavioral skeleton; each comment must become a real assertion/operation, not remain an empty test. The actual fixture must contain a literal named project and prove nonempty journal before comparing snapshots, to avoid empty-set equality.

- [x] **Step 3: Prove oracle sensitivity.** These tests characterize existing code, so no missing production feature is expected. First run with the two parent phase expectations deliberately inverted (installed vs committed), retain the expected assertion failure log, then restore the correct expectations with apply_patch and rerun. Do not change production for this sensitivity check, and do not claim the negative control found a production defect.

- [x] **Step 4: Add invalid receipt matrix.** Generate a real committed crash fixture for each `missing`, `corrupt`, `wrong-account`, `wrong-transaction` case. Mutate only the receipt in the isolated root; for valid JSON wrong-binding cases preserve all unrelated fields so rejection is not merely bad JSON. Snapshot all regular account-root bytes AFTER intentional damage, attempt native reopen/recover, require rejection and unchanged bytes after. Parent must record actual observed exception and not swallow unexpected setup failures. Baseline valid committed case in Step 2 is the positive control. No wrong-account store opening that could create a new empty namespace.

```swift
@Test(arguments: ["missing", "corrupt", "wrong-account", "wrong-transaction"])
func invalidCommittedReceiptPreservesEvidence(damage: String) throws {
    // Actual committed child; modify receipt only; snapshot damaged account.
    // Require openExistingAccount/recover to throw, then compare damaged tree.
}
```

- [x] **Step 5: Focused tests, self-review and commit.** Run the new suite, then new suite plus `SyncBootstrapOwnedTransactionTests|SyncBootstrapOwnedHandoffTests|SyncBootstrapOwnedInterruptionMatrixTests` once. Record exact commands, counts, exit codes and logs; no claims from previous counts. Use the existing bounded runner and cache paths below, formal escalation if native fixture permission requires it. Commit only new suite after `git diff --check` and self-review. Report RED as negative-control oracle sensitivity, GREEN as actual restored assertions, explicitly no production fix.

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/knitnote-legacy-final-iHUGGh/run-bounded.py 900 arch -arm64 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --no-parallel --filter 'SyncBootstrapOwnedCommitCrashTests'
git add Tests/KnitNoteCoreTests/SyncBootstrapOwnedCommitCrashTests.swift
git commit -m "test: verify owned receipt and commit crash recovery"
```

## Controller completion

- [ ] Task spec/quality review, fix if necessary; final review of this bounded candidate from documentation base, not a release/whole historical branch sign-off.
- [x] Fresh root targeted verification on final source SHA; record report and update plan status.
- [ ] Keep local branch/worktree and review evidence. No merge, push, upload or submission.

## Plan self-review

Section 10 is fully covered by one cohesive task; other V4 requirements remain explicitly outside this prerequisite plan. No new wire/authority API is implied by the test suite. Native phase, receipt bytes, nonempty journal and repeated reopen are independently observed. User delegated routine execution choice; use one implementer and independent review, without another approval round.
