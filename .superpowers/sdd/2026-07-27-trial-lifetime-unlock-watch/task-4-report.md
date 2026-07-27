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
