# Cloud Sync 4A.1: Revocable Store Write Admission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add irreversible, per-instance write revocation to the existing store's synchronous admission and durable publication boundaries, independently of purchase authorization.

**Architecture:** Keep the store's paths and mutation sink immutable. An initially open, MainActor-isolated admission flag belongs to that exact store instance; revocation never transfers or restores authority. Check it before maintenance, purchase callbacks, and final synchronous publication. This is the first prerequisite of the approved session design, not a complete session manager or a proof that asynchronous writers have drained.

**Tech Stack:** Swift 6, Swift Testing, Foundation; existing KnitNoteCore Swift package and unsigned Xcode targets.

**Spec:** `docs/superpowers/specs/2026-09-06-cloud-sync-app-session-lifecycle-design.md`

## Global Constraints

- Version remains **1.7.0 (13)**.
- Work only in `.worktrees/cross-device-sync-design`, branch `docs/cross-device-sync-design`; planning baseline `5c0fea008edc32f39acc9b3f00435d9f07e60a53`.
- No sync record, journal or publication format changes; preserve merge rules, immutable versions, full FIFO, durable ACK, account epoch and recovery evidence.
- Keep the **100,000,000-byte** file/authority limit and **64 MiB** journal metadata limit.
- Do not change purchase policy, language preferences, user content, or the deferred development story.
- No CloudKit/Keychain activation, real user store access, signing, installation, archive/export, merge, push, upload, submission or cleanup of existing work.
- Tests own explicit temporary directories. Normal release and screenshot factory behavior stay unchanged.
- No locks across `await`, no reusable authority for a new account, no unbounded retry.
- Revocation is not deletion, hiding, transport cancellation, a freeze receipt, or completed account isolation.
- The historical 2,467-test/179-suite result belongs to source commit `0860960270db87f23a1f4c238f84241599e10da1`, not to this implementation.

---

## Scope and sequence

This is a deliberately bounded first implementation plan for spec sections 3, 6 and 7. It closes a synchronous entry/publication gap before installing an App session owner. It does **not** implement all of Phase 4A.

Subsequent dependent work remains explicit:

1. Track every asynchronous producer through actual completion, guard its final file/publish boundary, and prove drain-before-inventory. In particular, `restoreBackup` currently calls a detached `service.install(backup)`; adding a store-entry check does not fence that detached replacement. Import, thumbnail/cache and photo writers also require their own staging/cleanup boundaries.
2. Implement verified/absent/indeterminate account identity and generation-fenced queries; map actual Apple API evidence. Preserve the approved offline cold-start exception and do not infer never-bound legacy ownership from directory presence or absence.
3. Implement `CloudAccountDomainLifecycle` using native storage, bootstrap, canonical and vault authorities. Separate same-account local readiness from successful cloud fetch. Keep original unbound edits usable during first-bootstrap fetch and reprepare on changed source authority.
4. Build the one-per-App session owner and generation-keyed root; replace all store-bound dependencies together. Stop/drain inbox and Watch bindings, and refuse unproven cross-account Watch commands until the later handshake gate.
5. Run the full eleven-case Phase 4A matrix, independent review, then frozen full Core and unsigned platform validation.

**Hard enablement gate:** nothing in this plan may call revocation from the live App or claim that `revokeSessionWrites()` makes it safe to seal, clean or switch a directory. Those operations require the subsequent drain/lifecycle work. Do not expose `waitForDrain()` returning immediately from this partial implementation.

## File structure

| File | Responsibility |
| --- | --- |
| Create `Sources/KnitNoteCore/Projects/StoreSessionAccessError.swift` | A distinct, payload-free session access error; no account names, paths or purchase decisions |
| Modify `Sources/KnitNoteCore/Projects/JSONProjectStore.swift` | Per-instance irreversible admission and checks at the named synchronous entry/publication boundaries; no large-file restructuring |
| Create `Tests/KnitNoteCoreTests/JSONProjectStoreSessionAdmissionTests.swift` | Behavioral tests with real temporary stores and exact archive-byte assertions |
| Create `docs/superpowers/reports/2026-09-06-session-write-admission-verification.md` | Candidate-bound results and explicit remaining asynchronous/lifecycle gates |

There is one implementation task because a standalone flag without real store callers would not be a useful deliverable. Report writing and build verification belong to that same task.

## Task 1: Reject revoked store writes before synchronous side effects

**Interfaces — existing:**

- `@MainActor JSONProjectStore`, its public `init(url:..., authorizeMutation:..., commitSuccessfulMutation:...)`, `add(name:)`, `rename(id:to:)`, `delete(id:)`, `reloadFromDisk()`, `retryLoad()`, `repairSyncPublication()` and `restoreRecentlyDeleted(id:now:)`.
- `MutationAuthorizer` and `MutationSuccessCommitter` retain their current `FeatureAccessDecision` contracts.
- Existing `withCommitOwnership` callbacks, journal leases, predecessor checks, canonical proof and transport ACK verification remain required.

**Interfaces — produced:**

```swift
public enum StoreSessionAccessError: Error, Equatable, Sendable {
    case revoked
}

// Members of the existing @MainActor JSONProjectStore:
public private(set) var isSessionWriteRevoked = false

public func revokeSessionWrites() {
    isSessionWriteRevoked = true
}

private func requireSessionWriteAccess() throws {
    guard !isSessionWriteRevoked else {
        throw StoreSessionAccessError.revoked
    }
}
```

There is no setter to reopen a revoked store, no global singleton and no injectable flag that two stores could accidentally share. A future session creates a new store only after its lifecycle proofs. The flag is not persisted: startup privacy must be enforced by the future owner **before constructing a bound store**, not by interpreting this flag as identity proof.

- [ ] **Step 1: Add the isolated test fixture and retained-closure regression.**

Create `Tests/KnitNoteCoreTests/JSONProjectStoreSessionAdmissionTests.swift`:

```swift
import Foundation
import Testing
@testable import KnitNoteCore

@MainActor
@Suite struct JSONProjectStoreSessionAdmissionTests {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-admission-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                               withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func retainedClosureCannotWriteAfterRevocation() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("projects-v1.json")
            let store = JSONProjectStore(url: url)
            try store.add(name: "Original")
            let id = try #require(store.projects.first?.id)
            let before = try Data(contentsOf: url)
            let lateSave: () throws -> Void = {
                try store.rename(id: id, to: "Late edit")
            }

            store.revokeSessionWrites()
            store.revokeSessionWrites()

            #expect(store.isSessionWriteRevoked)
            #expect(throws: StoreSessionAccessError.revoked) { try lateSave() }
            #expect(try Data(contentsOf: url) == before)
            #expect(store.projects.first?.name == "Original")
        }
    }
}
```

- [ ] **Step 2: Run the focused test and retain RED.**

From the specified worktree:

```sh
swift test --filter JSONProjectStoreSessionAdmissionTests
```

Expected RED: the new access error and revocation members do not exist. An unrelated toolchain, sandbox or fixture failure is not the intended RED. Record the actual command and exit code; do not silently broaden filesystem permissions or disable isolation.

- [ ] **Step 3: Add the remaining entry-boundary tests inside the same suite.**

```swift
@Test func revocationDoesNotConsumePurchaseAuthorization() throws {
    try withRoot { root in
        var calls = 0
        let url = root.appendingPathComponent("projects-v1.json")
        let store = JSONProjectStore(
            url: url,
            authorizeMutation: { _ in calls += 1; return .allow }
        )
        try store.add(name: "Original")
        let before = try Data(contentsOf: url)
        calls = 0
        store.revokeSessionWrites()

        #expect(throws: StoreSessionAccessError.revoked) {
            try store.add(name: "Rejected")
        }
        #expect(calls == 0)
        #expect(try Data(contentsOf: url) == before)
    }
}

@Test func revocationIsPerStoreNotGlobal() throws {
    try withRoot { root in
        let aURL = root.appendingPathComponent("a/projects-v1.json")
        let bURL = root.appendingPathComponent("b/projects-v1.json")
        for url in [aURL, bURL] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        let a = JSONProjectStore(url: aURL)
        let b = JSONProjectStore(url: bURL)
        try a.add(name: "A")
        let beforeA = try Data(contentsOf: aURL)
        a.revokeSessionWrites()
        try b.add(name: "B")

        #expect(!b.isSessionWriteRevoked)
        #expect(b.projects.map(\.name) == ["B"])
        #expect(try Data(contentsOf: aURL) == beforeA)
        #expect(throws: StoreSessionAccessError.revoked) {
            try a.add(name: "Rejected")
        }
    }
}

@Test func maintenanceAndDeleteCannotBypassRevocation() throws {
    try withRoot { root in
        let url = root.appendingPathComponent("projects-v1.json")
        let store = JSONProjectStore(url: url)
        try store.add(name: "Original")
        let id = try #require(store.projects.first?.id)
        let before = try Data(contentsOf: url)
        store.revokeSessionWrites()

        #expect(throws: StoreSessionAccessError.revoked) {
            try store.delete(id: id)
        }
        #expect(throws: StoreSessionAccessError.revoked) {
            try store.reloadFromDisk()
        }
        #expect(throws: StoreSessionAccessError.revoked) {
            try store.repairSyncPublication()
        }
        #expect(throws: StoreSessionAccessError.revoked) {
            try store.restoreRecentlyDeleted(id: id, now: .now)
        }
        store.retryLoad()
        #expect(try Data(contentsOf: url) == before)
        #expect(store.projects.map(\.name) == ["Original"])
    }
}
```

The two-store test proves instance isolation only, not account switching or valid account opening. The temporary trees are fixture-owned, not native account-storage authorities.

- [ ] **Step 4: Add the error and admission members exactly as defined above.**

Put the error in its new file. Put the flag and methods in `JSONProjectStore` beside the existing immutable sync dependencies. Retain MainActor isolation and existing initializers; no initializer acquires live identity or opens another account. Do not add the new case to `ProjectStoreError`, which has existing exhaustive UI switches and purchase-error mappings.

- [ ] **Step 5: Check admission before entry-side effects.**

Use this exact statement at the start of each throwing method listed below:

```swift
try requireSessionWriteAccess()
```

| Method | Required placement |
| --- | --- |
| `ensureSyncPublicationReady` | First, before checkpoint checks or deletion-ledger recovery |
| `preflightAccess` | First, before readiness and `authorizeMutation` |
| `commitAccessIfNeeded` | First, before the decision switch |
| `commitSuccessfulAccess` | First, before `commitSuccessfulMutation` |
| `beginDataOperation` | First, before changing operation state |
| `reloadFromDisk` | First, before startup publication reconciliation |
| `repairSyncPublication` | First, outside error translation/recovery blocks |
| `hydrateSyncBootstrap` | First, before assigning projection or hydration state |
| `activateSyncCanonicalState` | First, before any recovery or pending-repair mutation |
| `purgeRecentlyDeleted` / `restoreRecentlyDeleted` | First, before archive checks, references callbacks or ledger access |

For the existing nonthrowing `retryLoad()`, preserve its signature and return without side effects:

```swift
guard !isSessionWriteRevoked else { return }
```

An access error must escape as `StoreSessionAccessError.revoked`, not be translated into `.requiresUnlock`, `.accessRestricted`, corrupt authority or a successful no-op.

- [ ] **Step 6: Check the actual synchronous publication boundaries.**

Insert the same access check as the first statement in `commitArchiveAndPublish`, before its early no-op projection branch, disabled-sink archive writer, artifact callbacks, journal transaction creation or canonical publication. This protects late ordinary store commits as well as normal preflighted writes.

For the two existing remote commit methods, check both on entry and **inside** the caller-supplied ownership closure, before obtaining/using authority:

```swift
// commitRemoteBatch and commitConflictRebase, retaining their existing
// signatures, result types and entire native transaction bodies:
try requireSessionWriteAccess()
```

The first statement of each existing `withCommitOwnership { ... }` body is also:

```swift
try requireSessionWriteAccess()
```

Keep all current epoch, journal-lease, predecessor, authority and durable-ACK checks. This admission is additional, not a replacement. In `retireRemoteBatchReceipt`, check once on entry and again immediately after `verifyTransportAcknowledgement()` returns, before receipt lookup/retirement. A supplied synchronous callback can revoke authority before returning.

Do not skip necessary rollback of an already-started transaction merely because it is revoked. This task does not add cancellation inside native durable transactions or recovery bodies. A synchronous transaction that started before a later MainActor revocation runs to its native outcome; asynchronous installation/drain needs the next plan.

- [ ] **Step 7: Run the focused tests to GREEN.**

```sh
swift test --filter JSONProjectStoreSessionAdmissionTests
```

Require all four tests to pass, with an actual zero exit code. Then prove the behavior test is effective by temporarily removing only the `preflightAccess` and `ensureSyncPublicationReady` admission statements using a reversible patch, rerunning the purchase-callback test and observing its `calls == 0` assertion fail. Restore the exact statements and rerun the full new suite. Do not reset the worktree or disturb unrelated changes.

- [ ] **Step 8: Run existing affected regression suites.**

```sh
swift test --filter 'JSONProjectStore|SyncConflict|SyncRemoteBatch|SyncPublication|SyncDeletion|Backup|Watch'
git diff --check
```

Record the discovered/executed test counts and actual exit status. A filter matching zero tests is a failure of verification. Existing active-store behavior, corruption recovery, backup and Watch semantics must remain unchanged while no caller revokes the store. Passing existing tests does not establish the unimplemented async drain boundary.

- [ ] **Step 9: Review the diff and record bounded evidence.**

```sh
git diff -- Sources/KnitNoteCore/Projects/JSONProjectStore.swift
git status --short
```

Review against the insertion table, especially entry checks outside error-mapping blocks and checks inside externally supplied commit-ownership callbacks. The new source file is automatically discovered by the Swift package; do not run a project-wide generator or change project configuration unless actual unsigned compilation demonstrates it is necessary.

Create the report with these exact section headings and populate each from observed results, not expected outcomes:

```markdown
# Session Write Admission Verification

## Source identity and scope

## RED and restored GREEN evidence

## Affected regression command, counts and exit code

## Review findings and resolutions

## Remaining asynchronous writers and activation gates

## Candidate-bound full validation
```

The report must explicitly list detached backup installation, inbox reconciliation/import, journal-photo processing, thumbnail/cache writes, external Watch ledger writers and constructor-time recovery as **not proven drained by this task**. It must not label the eleven-case Phase 4A matrix passed.

- [ ] **Step 10: Obtain independent implementation review before committing source.**

Use the required implementation workflow's spec and code-quality reviews. Review the four tests, the first-side-effect placement, error separation and the deliberately limited scope. New security findings require actual reproduction and a bounded correction; do not silently expand this task into live account switching.

- [ ] **Step 11: Commit only this task's reviewed files.**

```sh
git add Sources/KnitNoteCore/Projects/StoreSessionAccessError.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/JSONProjectStoreSessionAdmissionTests.swift docs/superpowers/reports/2026-09-06-session-write-admission-verification.md
git diff --cached --check
git diff --cached --stat
git commit -m "feat(sync): add revocable store write admission"
git rev-parse HEAD
```

- [ ] **Step 12: Freeze this source SHA and run full candidate verification.**

Run serially, capturing each complete output and actual exit code separately. Do not launch the App test host or use a previous log as this candidate's proof.

```sh
swift test --no-parallel
```

```sh
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/session-admission-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing
```

```sh
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/session-admission-ios-derived CODE_SIGNING_ALLOWED=NO build
```

If one of those temporary derived-data paths already belongs to another run, select a new run-specific path and record it; do not delete existing evidence. Long commands use short polling/yields so progress remains visible. Record warning counts and any timeout/permission/toolchain limitation as such. A failed/incomplete full suite blocks a completion claim; focused GREEN cannot replace it.

After validation, update only the report with the frozen source SHA, exact commands, counts, warnings and outcomes, then commit that documentation separately. If source changes, invalidate the candidate results and rerun on the corrected source.

## Planning self-review and coverage

- The new error and the three store members used by the tests are defined in this plan; existing test APIs were checked against the current checkout.
- The write check is before purchase callbacks, before maintenance, before the central disabled/enabled-sink commit, and within external ownership callbacks. No authority-reset method is provided.
- Spec sections 3/6/7 receive their first synchronous admission prerequisite. Spec matrix 6 receives a retained-closure regression; this is not the full cross-await test.
- Spec matrix 1–5 and 7–11, plus the asynchronous part of 6, remain the dependent work listed at the top. They are not waived, implemented, or accepted by this plan.
- The plan intentionally exposes no drain receipt and makes no App, Watch, account, bootstrap or production activation change. Completing it permits the next implementation plan, not switching accounts or submitting a release.
