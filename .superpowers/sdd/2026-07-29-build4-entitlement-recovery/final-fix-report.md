# KnitNote Build 4 Final Fix Report

Date: 2026-07-29 (Asia/Taipei)

Status: functional correction committed and full local verification passed.
Physical TestFlight/iPad acceptance remains outstanding.

## Scope

The final fix wave addressed every finding from the review of
`4531033..d1c8875` without changing pricing, App Store metadata, external
state, marketing version `1.2.1`, or build number `4`.

Functional candidate:
`b1eda5981ce448996ba50af39f322c97c7e44d05`
(`fix: defer project unlock and retain outage status`).

## Root causes and corrections

1. `JSONProjectStore.add` called `EntitlementCoordinator.authorize`, which
   published `.createProject` before throwing `accessRestricted`.
   `RootView` read that request directly, making its unlock binding true while
   `CreateProjectView` was still presented. The later `onDismiss` wrote true
   again and therefore had no new presentation edge.

   `RootView` now uses the production
   `UnlockPresentationOrchestrator`. `ProjectsView` reports the create sheet's
   real `onAppear` and `onDismiss` phases. A `.createProject` request is held
   false while the child is active and becomes true after dismissal; other
   mutations stay immediate.

2. StoreKit unavailability was consumed only as control flow, so the
   coordinator could resolve local trial access but could not retain a
   non-entitlement availability status.

   `EntitlementCoordinator` now publishes
   `PurchaseVerificationAvailability` separately from `EntitlementSnapshot`.
   Initial `.unavailable` resolves the Keychain trial and records
   `.unavailable`; later outages preserve verified lifetime or legacy-paid
   ownership. The availability value is not persisted and is never sent to the
   Watch entitlement projection.

3. `UnlockSheet.runRestore` treated every qualification without an entitlement
   snapshot as no purchase, so `.unavailable` displayed restore-not-found.

   A pure `UnlockPresentation.restorePresentation(for:)` mapper now returns
   retry for `.unavailable`, restore-not-found for `.none`, and close for
   verified lifetime or legacy-paid ownership.

4. Earlier coverage did not prove that a successful project mutation after an
   initial outage durably started the production Keychain trial.

   The regression now runs an actual `JSONProjectStore.add` through the
   coordinator and `KeychainTrialStore`, then loads the record through a fresh
   store instance.

## TDD RED

### Root orchestration and restore mapping

```text
swift test \
  --scratch-path /tmp/KnitNoteBuild4FinalFixCoreRed \
  --filter UnlockPresentationTests
```

Exit `1`. Expected compile failures named the missing
`UnlockPresentationOrchestrator`, `UnlockRestorePresentation`, and
`UnlockPresentation.restorePresentation`.

### Availability status and durable Keychain project trial

```text
xcodebuild test -quiet \
  -project KnitNote.xcodeproj \
  -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteBuild4FinalFixAppRed \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests/EntitlementCoordinatorTests
```

Exit `65`. Expected compile failures reported that
`EntitlementCoordinator` had no
`purchaseVerificationAvailability` member.

## Focused GREEN

```text
swift test \
  --scratch-path /tmp/KnitNoteBuild4FinalFixCoreGreen \
  --filter UnlockPresentationTests
```

Exit `0`: `8` tests in `1` suite passed.

```text
xcodebuild test -quiet \
  -project KnitNote.xcodeproj \
  -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteBuild4FinalFixAppGreen2 \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests/EntitlementCoordinatorTests \
  -only-testing:KnitNoteAppTests/CreateProjectPresentationTests
```

Exit `0`: xcresult reports `34` logical tests, `35` parameterized cases,
and `0` failures.

## Full verification

| Check | Exact result |
| --- | --- |
| `swift test --scratch-path /tmp/KnitNoteBuild4FinalFixSwiftTests` | Exit `0`; `966` tests in `78` suites passed. |
| Full macOS app suite at `/tmp/KnitNoteBuild4FinalFixAppTests` | Exit `0`; `44` logical tests, `47` parameterized cases, `0` failed, `0` skipped, `0` expected failures. |
| `bash AppStore/Verification/release_audit.sh --static-only` | Exit `0`; metadata and release audit passed. |
| KnitNote Release, generic iOS, `/tmp/KnitNoteBuild4FinalFix-iOS-OutsideSandbox` | Exit `0`, unsigned. |
| KnitNote Release, generic macOS, `/tmp/KnitNoteBuild4FinalFix-macOS` | Exit `0`, unsigned. |
| KnitNoteWatch Release, generic watchOS, `/tmp/KnitNoteBuild4FinalFix-watchOS` | Exit `0`, unsigned. |
| KnitNoteShare Release, generic iOS, `/tmp/KnitNoteBuild4FinalFix-share` | Exit `0`, unsigned. |

The first sandboxed iOS Release attempt exited `65` because Xcode could not
reach CoreSimulator/watchsimulator asset-catalog services. The identical build
with normal Xcode service access exited `0`.

## Self-review

- The create-project gate is limited to `.createProject` while the child sheet
  is actually presented; a regression proves `.createYarn` still requests the
  root sheet immediately.
- The fresh presentation transition is asserted as `[false, true]` across the
  create-sheet dismissal boundary.
- Availability has its own published type and never enters
  `EntitlementSnapshot`, `onSnapshotChange`, persistence, or Watch projection.
- Initial unavailable preparation projects only `.trialNotStarted`; tests
  explicitly reject lifetime and legacy ownership projection.
- Verified lifetime and legacy-paid snapshots survive a later outage without a
  trial-store read.
- Restore-result expectations are hand-derived for all four
  `PurchaseQualification` cases.
- The durable trial regression uses production `KeychainTrialStore` encoding
  and production `JSONProjectStore.add`, with only the Security framework
  storage boundary replaced by an in-memory implementation.
- `git diff --check` passed before the functional commit.
- No external action or release-state mutation was performed.

## Concerns and remaining gates

- Physical TestFlight/iPad acceptance is still required to prove the SwiftUI
  sheet transition and durable behavior in the distributed Build 4 binary.
- No archive, validation, upload, tester assignment, App Store Connect change,
  submission, or release was authorized or performed.
- The full Swift run retains the pre-existing deprecated
  `String(contentsOf:)` warning in `HighlightOverlayContractTests`; it did not
  affect the `966/966` result.
- Xcode continues to print its existing multiple-matching-macOS-destination
  warning; xcresult confirms the arm64 local Mac run and zero failures.
