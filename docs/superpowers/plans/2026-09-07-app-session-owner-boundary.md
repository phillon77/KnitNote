# App Session Owner Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the fixed local session owner and synchronous hide/stop/retired-drain boundary that the approved App integration will consume.

**Architecture:** An immutable resource bundle holds one store and a producer group built for that store. A MainActor observable owner publishes a single optional session and issues opaque generation tokens; transitions immediately hide and stop prior resources and retain them until successful drain. This is only local publication ownership, never an account/bootstrap readiness authority.

**Tech Stack:** Swift 6, Combine, Swift Testing, existing AppSessionProducerGroup and actual-source no-host harness.

**Spec:** `docs/superpowers/specs/2026-09-07-app-session-owner-integration-design.md`, approved by user; upper policy `docs/superpowers/specs/2026-09-06-cloud-sync-app-session-lifecycle-design.md`.

## Global Constraints

- 維持1.7.0(13)，iOS18/macOS15/watchOS11；不改100,000,000-byte與64MiB上限、資料/wire格式、購買、語言偏好、開發故事或30天復原條件。
- No live CloudKit/Keychain/Watch/App host, production-data operation, signing, install, push, merge, upload or submission.
- Preserve existing linked worktree and completed SDD workspaces. No automation restart is implied by this interactive execution.
- This plan implements the local owner portion of delivery 1 only. It does not fulfill the entire approved integration spec. Identity query, transaction/readiness integration, UI generation subtree, startup factory routing and real devices remain explicit follow-up work, not placeholders inside this local boundary.
- No invented account-readiness receipt. Accepting a locally prepared bundle only checks owner generation and successful retired drain; later callers must separately prove account/install authority.
- New production files only; existing App startup remains unchanged until the later complete assembly is ready. No dead claim that this owner is already shipping-wired.

### Task 1: Fixed resource bundle and generation-gated local owner

**Files:**
- Create `KnitNote/App/AppSessionResources.swift`.
- Create `KnitNote/App/AppSessionOwner.swift`.
- Create `Tests/KnitNoteAppTests/AppSessionOwnerTests.swift` (fixture helpers in same file, or `AppSessionOwnerTestSupport.swift` if necessary).
- Modify `KnitNote.xcodeproj/project.pbxproj` only for existing-target source/test membership, following current platform target conventions; no new shipping target.

**Interfaces:**
- Consumes `JSONProjectStore`, `AppSessionProducer`, `AppSessionProducerGroup(store:producers:)`, `stopForSessionTransition()`, `waitForStoppedOperations() async throws`.
- Produces `@MainActor final class AppSessionResources: Identifiable, AppSessionProducer` with immutable `id: UUID`, immutable `store: JSONProjectStore`, read-only `isStopped: Bool`; initializer `init(store: JSONProjectStore, makeProducers: (JSONProjectStore) -> [any AppSessionProducer])` synchronously constructs its own private group. The closure is a local composition seam, not account authority. Store must not already be revoked; reject with a throwing initializer if this can be verified from the current store API. Do not add mutable group/gate injection.
- Produces `@MainActor final class AppSessionOwner: ObservableObject`, `@Published private(set) var visibleSession: AppSessionResources?`, `private(set) var generation: UUID`; methods `beginTransition() -> UUID`, `waitForRetiredSessions() async throws`, `publishPreparedSession(_:for:) throws`.
- Failures `staleGeneration`, `retiredWorkPending`, `stoppedSession` at App layer; no new store or cloud errors. Initial owner has no visible session and a fresh generation. Publication failure leaves candidate ownership with caller (owner does not stop unrelated candidates). Document this explicit ownership contract.

- [x] **Step 1: Create the failing actual-source test harness and tests.** Make a fresh `mktemp -d /tmp/knitnote-app-owner-XXXXXX` harness using the previous native harness manifest shape, symlinking Core and actual required App/test files. Read prior harness inventory only, never its completed ledger. Record exact symlinks/manifest. Use new test imports `Foundation`, `Testing`, `@testable import KnitNote`. Example behavior test below requires fixture to create two distinct real stores in isolated roots and independently drain before deleting them.

```swift
@Test @MainActor func transitionImmediatelyHidesAndRevokesOldStore() async throws {
    try await withOwnerFixture { fixture in
        let owner = AppSessionOwner()
        try owner.publishPreparedSession(fixture.first, for: owner.generation)
        let previous = owner.generation
        let next = owner.beginTransition()
        #expect(next != previous)
        #expect(owner.visibleSession == nil)
        #expect(fixture.first.isStopped)
        #expect(fixture.first.store.isSessionWriteRevoked)
        try await owner.waitForRetiredSessions()
        try owner.publishPreparedSession(fixture.second, for: next)
        #expect(owner.visibleSession === fixture.second)
    }
}
```

Use actual available read-only revocation API; if not public, assert a real existing mutation throws StoreSessionAccessError.revoked instead of adding broad production access. A missing-type RED establishes API only; use runtime mutations for hide/stop/stale-publish/drain assertions.

- [x] **Step 2: Implement fixed resource ownership.** Generate resource id, hold exact store, and create group from producers constructed with that same store. Stop flag before forwarding stop; repeated stop safe. Drain delegates to fixed group and rejects open use. No store replacement, cleanup or journal rebinding. Producers remain strongly held through group lifetime.

```swift
func stopForSessionTransition() {
    guard !isStopped else { return }
    isStopped = true
    group.stopForSessionTransition()
}
func waitForStoppedOperations() async throws {
    try await group.waitForStoppedOperations()
}
```

- [x] **Step 3: Implement owner synchronous invalidation and retained drain.** In beginTransition, advance generation and take a strong local of current session before publishing nil; record the old bundle for drain exactly once by identity, then stop it synchronously. Observable notifications can synchronously reenter owner: protect transition/publication critical sections with explicit synchronous reentry state or snapshot comparisons, never let nested calls publish during half-complete stop. No await inside this boundary, no lock across await.

```swift
// Publication preconditions; reevaluate after any externally observable callout.
guard requestedGeneration == generation else { throw Failure.staleGeneration }
guard retiredSessions.isEmpty else { throw Failure.retiredWorkPending }
guard !candidate.isStopped else { throw Failure.stoppedSession }
```

Reject replacing an existing different visible session without beginTransition (add `sessionAlreadyVisible` App error); idempotent publication of the same visible object may return without another notification. Store admission must still be open at publication. The owner does not close arbitrary rejected candidates. `waitForRetiredSessions` captures exact retired identities, waits each existing producer/store group, and removes only successfully drained identical entries. A thrown/cancelled wait retains unresolved resources and cannot clear newer retirement or authorize publication. Multiple waiters may share group work but must not discard each other's new retirements; loop/recheck until no retired entries remain. Do not retain untracked Task fire-and-forget cleanup, retry timers or mutable test gate authority.

- [x] **Step 4: Exercise real ownership and adversarial sequencing.** Cover empty initial owner; synchronous hide/revoke and all registered producer stops before any await; old generation denied after two transitions; replacement requires transition; already-stopped and externally revoked store denied; same-object publication idempotence; held real producer work prevents new publication; two drain waiters with one cancelled; failed drain retains resource; newer transition during drain cannot be erased by earlier completion; synchronous Combine subscriber reentry during visibleSession change; rejected B remains untouched and usable by its caller; actual inbox, coordinator and native adapter registered together and all stopped. Use immutable signals and explicit native/producer start/end events, no sleeps/yields/empty Task fences. Teardown always releases and independently joins actual work in a fresh uncancelled task before deleting roots, even under deliberately broken owner drain. Do not use the method being deliberately broken as the only cleanup proof.

- [x] **Step 5: Verify, self-review and commit scoped changes.** Run focused RED/GREEN as needed, complete fresh owner harness once, and existing producer/native tests in the same actual-source harness before committing. Record command, log path, exit and warnings, names and exact SHA. Controller owns review and broad frozen validation; do not run full Core independently.

```sh
python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --no-parallel
git diff --check
plutil -lint KnitNote.xcodeproj/project.pbxproj
git add -- KnitNote/App/AppSessionResources.swift KnitNote/App/AppSessionOwner.swift Tests/KnitNoteAppTests/AppSessionOwnerTests.swift KnitNote.xcodeproj/project.pbxproj
git commit -m 'feat(sync): own local sessions across generation transitions'
```

Explicitly add optional fixture file only if used. Do not alter App startup or account coordinator as a shortcut; raise any required public-interface change to controller before widening scope.

### Task 2: Review and frozen local-boundary validation (controller-owned)

**Files:** Create `docs/superpowers/reports/2026-09-07-app-session-owner-boundary-verification.md` and update plan completion status.

**Interfaces:** Consumes Task 1 reviewed SHA, actual-source harness and reports; produces durable exact-candidate local boundary evidence, not full owner integration acceptance.

- [x] **Step 1: Task and whole-subplan independent reviews.** Task review checks spec/quality and reentry/retirement/cancellation invariants. Final review spans subplan baseline `81941c7` to candidate, names external constraints and parked findings. Fix and scoped rereview before freeze.
- [x] **Step 2: Freeze candidate and run serial full Core, combined owner/producer/native no-host, unsigned macOS build-for-testing and iOS build.** Use inspected bounded runner, unique logs and derived data. Do not combine results from differing source trees.

```sh
python3 /tmp/task4-run-bounded.py 3600 arch -arm64 swift test --no-parallel
# In new combined actual-source harness:
python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --no-parallel
# In worktree:
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/app-owner-boundary-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/app-owner-boundary-ios-derived CODE_SIGNING_ALLOWED=NO build
```

- [x] **Step 3: Save evidence and remaining integration work.** Report exact source/test/PBX identity, raw command summaries, log hashes, any warnings, review outcomes/rulings and cleanup evidence. Preserve local worktree; do not push or restart automation. Explicit next tasks: full session composition/presentation ownership, identity and account transaction/readiness, UI generation subtree and startup wiring. The approved larger integration remains incomplete until those are implemented and tested.

## Self-review

This is the first executable local boundary extracted from the approved integration, not a substitute spec. All local owner requirements map to Task 1; independent/frozen evidence maps to Task 2. Larger integration requirements are explicitly outside this first plan and remain unfinished. Both tasks share the new sources/harness, but Task 2 cannot change source after freeze; review fixes return to the implementer. No public local publication API is presented as proof of verified iCloud identity or completed bootstrap.
