# Task 4 Report — Entitlement Coordinator and Store Mutation Gate

## Scope

- Base: `713cb313b2f3c4699c2a46130e2c9fa185fe3be9`
- Added the pure entitlement resolver, app entitlement coordinator, store
  authorizer injection, and mutation-boundary enforcement.
- Wired the coordinator into the live and screenshot app construction paths.
- Added no paywall UI, purchase UI, Watch entitlement payload, Share Extension
  projection, or yarn-label feature.

## TDD evidence

### Store boundary

Mutation tests were added in four batches and failed before their corresponding
gates existed:

1. project creation and yarn mutation;
2. counters and Watch commands, row notes, and journal;
3. pattern import/library/inbox/link/detail and reader state/page note/markup;
4. remaining project/yarn mutations and backup restore.

The final store suite covers 45 public mutation gates. It verifies the
authorizer receives the expected `FeatureMutation`, rejected operations do not
change memory or files, Watch rejection does not change the command ledger,
and gates execute before archive, photo, pattern, markup, or restore writes.
Public reads and backup export remain allowed. A real
`JSONProjectStore.live(baseDirectory:authorizeMutation:)` test confirms that
the live factory forwards the injected authorizer.

### Coordinator

Five app-target behavior tests were written before
`EntitlementCoordinator` existed. The RED build failed with:

```text
cannot find 'EntitlementCoordinator' in scope
```

The GREEN tests verify:

- verified lifetime purchase takes precedence and does not read Keychain;
- first project creation atomically starts the trial before the store writes;
- failed Keychain trial creation rejects the triggering operation without
  creating an archive and publishes the unlock request;
- an expired trial publishes the exact rejected mutation;
- screenshot configuration publishes `.legacyPaidOwner` and constructs
  neither StoreKit nor Keychain services.

## Implementation

- `EntitlementResolver` applies purchase precedence over a stored trial and
  resolves first use to `.trialNotStarted`.
- `EntitlementCoordinator.prepare()` verifies StoreKit first and reads the
  trial record only when no verified purchase qualification exists.
- `authorize(_:)` converts `.startTrial` to `.allow` only after
  `TrialStore.startIfNeeded` succeeds and the trial snapshot is published.
  Trial-start failure and `.requiresUnlock` both publish `unlockRequest` and
  fail closed.
- Screenshot mode uses a preverified `.legacyPaidOwner` coordinator and does
  not evaluate the external-service factories.
- `KnitNoteApp` creates the coordinator before the store, injects its
  authorizer into both live-store paths, exposes it through the SwiftUI
  environment, and prepares it from the root task.
- The added `ProjectStoreError.accessRestricted` case is handled by the
  existing yarn operation failure mapping so both app platforms compile.
- Existing default-allow store initializers remain available for fixtures and
  tests outside live app wiring.

## Coverage audit

The gate mapping covers:

- project create/edit/delete/complete/resume;
- counter select/increment/decrement/reset/update/rename, reader counter, and
  Watch command application;
- row notes and journal add/update/delete;
- pattern import, inbox processing/discard, library/project import,
  rename/note/open/delete, link/unlink, and every reader-state/page-note/markup
  write;
- yarn create/update/delete/link;
- backup restore.

Backup export, restore staging/cancellation, project/pattern/yarn reads,
thumbnails, and markup loads remain available as specified.

## Verification

| Command | Result |
| --- | --- |
| `swift test --filter Entitlement` | 23 tests passed |
| `swift test --filter JSONProjectStoreEntitlementTests` | 16 tests passed |
| `swift test` | 885 tests in 73 suites passed |
| Coordinator-focused app tests | 5 tests passed |
| Full `KnitNoteAppTests` | 11 tests / 13 parameter executions passed |
| unsigned generic iOS build | passed |
| unsigned generic macOS build | passed |
| `git diff --check` | passed |

The full Swift suite emitted the pre-existing CoreGraphics PDF diagnostic but
had no failures.

## Limitations

- StoreKit and Keychain were exercised through deterministic app-test seams;
  no physical-device purchase or Keychain acceptance test was performed.
- This task enforces the mutation boundary and publishes unlock requests. The
  unlock/paywall presentation belongs to the following task.

## Fix round 1 — durable Watch authorization and preparation single-flight

### RED evidence

- The new restricted Watch persistence tests initially reported 14 issues:
  durable commands could save a prepared receipt and archive before the
  authorizer rejected the counter mutation, while recovery, handshake, and
  reconciliation could also rewrite or quarantine persistence while access
  was restricted.
- The new coordinator concurrency test failed with seven expectations under
  the old implementation. Two overlapping callers independently invoked both
  `PurchaseService.prepare()` and `currentQualification()` (two calls instead
  of one), and a later `.none` result replaced a previously verified lifetime
  snapshot.

### Fix

- Every public Watch persistence mutation now authorizes `.changeCounter`
  before reading, quarantining, preparing, or writing durable state. Direct
  application and each durable entry point authorize exactly once, then use
  internal authorized application/recovery primitives so nested recovery does
  not authorize twice.
- `EntitlementCoordinator.prepare()` now stores one identified
  `Task<PreparationResult, Never>` flight. Overlapping callers await that same
  task; only a caller whose flight identifier is still current may publish the
  result and clear the flight.
- Published entitlement snapshots use an explicit verification rank
  (`lifetime` above legacy ownership above trial state), so a lower
  qualification or failed refresh cannot revoke a previously verified
  lifetime unlock.
- Normal coordinators remain fail-closed until preparation finishes. A
  durable Watch regression test verifies that an unprepared coordinator
  publishes `.changeCounter`, throws `accessRestricted`, leaves the archive
  byte-for-byte unchanged, and creates neither ledger nor prepared receipt.
  Screenshot mode remains the intentionally pre-resolved exception; a
  companion test applies a durable Watch command successfully without calling
  `prepare()` or constructing StoreKit/Keychain services.
- `PhoneWatchSyncCoordinator` may receive a command before entitlement
  preparation completes. That command is deliberately not acknowledged, so
  the Watch retains it for retry; after preparation, the next command or
  handshake authorizes recovery and does not lose the queued mutation.
- The overlap test uses a `MainActor` continuation signal, rather than timing
  or `Task.yield`, to prove the second caller has entered `prepare()` before
  the controlled purchase qualification resumes.

### Verification

| Command | Result |
| --- | --- |
| `swift test --filter WatchSyncPersistenceTests` | 20 tests in 1 suite passed |
| Coordinator-focused app tests | 8 tests passed |
| `swift test` | 889 tests in 73 suites passed |
| Full `KnitNoteAppTests` | 14 tests / 16 parameter executions passed |
| unsigned generic iOS build | passed |
| unsigned generic macOS build | passed |
| `git diff --check` | passed |

The previously noted nested import double-authorization cleanup remains a
deferred minor and was intentionally not included in this focused fix.
An independent read-only review found no Critical or Important issues; its two
Minor test-coverage suggestions were both incorporated before the final
focused runs.

## Fix round 2 — authoritative refresh and failed-refresh closure

The round-1 verification-rank rule was re-reviewed as an Important semantic
error. It made an older lifetime or legacy snapshot monotonic even after a
newer completed StoreKit refresh authoritatively returned `.none`, and it
kept mutation authorization prepared when the required trial-record load
failed.

### RED evidence

- The coordinator-focused run exited 65 with three reported failures.
- After an overlapping lifetime flight completed, a later controlled
  `.none` refresh loaded no trial but incorrectly left the snapshot
  `.permanentlyUnlocked` instead of publishing `.trialNotStarted`.
- When the later `.none` refresh reached a failing trial load, the stale
  lifetime still authorized `.changeCounter` and did not publish the rejected
  mutation.

### Fix

- The identified preparation single-flight remains unchanged: overlapping
  callers still share one external `prepare()` and
  `currentQualification()` operation, and only the current flight identifier
  may publish and clear.
- A completed current flight now publishes its resolved snapshot
  unconditionally. StoreKit `.none` plus the authoritative trial-store result
  can therefore revoke a previous lifetime or legacy snapshot.
- Any preparation failure now sets `isPrepared` to false regardless of the
  previous snapshot. Subsequent mutations fail closed and publish the exact
  `unlockRequest`.
- Screenshot mode remains intentionally pre-resolved because it has no
  external preparation flight.

### Verification

| Command | Result |
| --- | --- |
| Coordinator-focused app tests | 9 tests passed |
| Full `KnitNoteAppTests` | 15 tests / 17 parameter executions passed |
| `swift test` | 889 tests in 73 suites passed |
| `swift test --filter WatchSyncPersistenceTests` | 20 tests in 1 suite passed |
| unsigned generic iOS build | passed |
| unsigned generic macOS build | passed |
| `git diff --check` | passed |

The deferred nested import double-authorization minor remains out of scope and
unchanged.
An independent round-2 read-only review found no Critical or Important
issues. It noted optional legacy-owner-specific revocation coverage as a
non-blocking Minor; both lifetime and legacy currently use the same
unconditional authoritative publication branch.
