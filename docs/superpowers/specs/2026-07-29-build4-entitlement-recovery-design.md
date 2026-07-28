# KnitNote Build 4 Entitlement Recovery Design

Date: 2026-07-29

## Problem

KnitNote 1.2.1 Build 3 fails on a physical iPad installed through TestFlight.
Creating a project displays the raw message
`KnitNote.ProjectStoreError error 6`. The error is
`ProjectStoreError.accessRestricted`.

Two behaviors combine to produce the failure:

1. A temporarily unavailable StoreKit lookup prevents the entitlement
   coordinator from loading the local trial state, so every mutation is denied.
2. The create-project sheet catches and displays the internal store error while
   the parent unlock sheet cannot be presented over the active child sheet.
   Dismissing the child sheet does not recover the lost presentation request.

## Product Decision

StoreKit verification remains the only way to grant lifetime or legacy-paid
ownership. A failed or unverified StoreKit lookup must never grant permanent
access.

StoreKit availability is not required to use the local seven-day trial. When
purchase qualification is temporarily unavailable, the coordinator loads the
Keychain trial record and resolves only trial access. It retains an
unavailable-purchase signal so the UI can offer retry or restore without
claiming that no purchase exists.

## User Experience

- A new user can create a project and start the seven-day trial even if the
  initial StoreKit lookup is unavailable.
- A verified lifetime purchase or verified legacy paid version still grants
  permanent access.
- An unavailable or unverified lookup never grants permanent access.
- If a mutation genuinely requires unlock, a child editor dismisses before the
  root presents the unlock sheet.
- User-facing alerts do not expose `ProjectStoreError error 6`.
- The unlock sheet provides purchase, restore, and retry behavior using the
  existing localized UI.

## Architecture

`EntitlementCoordinator` separates purchase verification availability from the
local trial snapshot. Its preparation path:

1. asks `PurchaseService` for the current qualification;
2. immediately publishes verified lifetime or legacy ownership;
3. otherwise loads the Keychain trial state;
4. resolves trial access for both `.none` and `.unavailable`;
5. records whether purchase verification is unavailable for retry messaging.

The unavailable flag must not be persisted as an entitlement and must not be
projected to Apple Watch as a permanent state.

Create-project error handling maps `accessRestricted` to an explicit
access-request outcome. The create sheet dismisses and notifies its owner, which
then presents `UnlockSheet` after the child presentation has ended. Storage and
unexpected persistence errors continue to use the save-failed alert.

## Tests

Tests are written and observed failing before production changes.

- Coordinator preparation with `.unavailable` loads a missing Keychain record
  and publishes `trialNotStarted`.
- The first successful mutation after that state durably starts the trial.
- An existing active or expired trial remains authoritative while StoreKit is
  unavailable.
- Unavailable or unverified StoreKit data never yields lifetime or
  legacy-paid ownership.
- Create-project presentation maps `accessRestricted` to a deferred unlock
  request and does not expose the raw error.
- Other project-store errors remain save errors.
- Existing lifetime and legacy-owner preservation tests remain green.

## Release Boundary

The repair produces version 1.2.1 Build 4. It does not change App Store pricing,
availability, in-app-purchase metadata, external testing, or review state.
Automated tests and unsigned Release builds are required before requesting
authorization to archive and upload. Physical TestFlight behavior remains the
acceptance gate.
