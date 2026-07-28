# Task 9 Fix Report: Release Boundary and Entitlement Blockers

## Outcome

The four Task 9 release blockers are fixed locally. The free-conversion release
candidate is now `1.2.1` while the legacy paid-owner maximum remains `1.2.0`.
Trial persistence is deferred until a project creation or pattern import has
finished durable publication. Expired readers are entitlement-aware and
passive read-only, and transient StoreKit/AppTransaction unavailability no
longer revokes a previously verified lifetime or legacy entitlement.

No archive was uploaded. No App Store Connect metadata, price, submission, or
release state was changed.

## Implementation

### A. Version boundary

- Updated the app, Watch app, and Share extension release candidate to `1.2.1`
  in `project.yml` and regenerated `KnitNote.xcodeproj`.
- Updated the static release audit, submission checklist, and pattern-library
  verification candidate references to `1.2.1`.
- Kept `StoreKitPurchaseService.legacyPaidMaximumVersion` at `1.2.0`.
- Contract tests explicitly verify that original version `1.2.0` qualifies as
  legacy paid and `1.2.1` does not.

### B. Trial starts after successful publication

- `EntitlementCoordinator.authorize` is now a side-effect-free preflight for a
  first project creation or import.
- Added `commitSuccessfulMutation`, which starts the Keychain trial only after
  the store reports a successful durable mutation.
- Added a store success-commit seam and wired it through every live-store
  construction path.
- Project creation commits trial state after archive publication.
- Direct and inbox pattern imports commit trial state only after validation,
  file I/O, archive publication, and the required publication transition.
- The direct-import path now uses a private already-authorized helper, removing
  the nested double authorization.
- Main-actor serialization plus Keychain duplicate-item reconciliation keeps
  concurrent first commits idempotent.
- Preparation flights carry a generation. Restore and trial-start terminal
  transitions invalidate older flights, and an invalidated refresh cannot
  launch a follow-up qualification flight. This prevents stale preparation
  results from overwriting restored lifetime, authoritative revocation, active
  trial, or fail-closed trial-start failure state.

The JSON archive and Keychain are separate durable stores and cannot form one
atomic transaction. The approved ordering publishes JSON/files first, then
commits the Keychain trial. If that final Keychain commit fails, the mutation
remains published but the API returns `accessRestricted` and entitlement stays
fail-closed. A regression test verifies that this failure does not delete a PDF
already referenced by the published archive.

### C. Expired pattern reader

- `PatternReaderContext` now includes `entitlementCanWrite`; `canWrite`
  requires an active usage, incomplete project, and current write entitlement.
- Reader identity includes entitlement writeability so entitlement changes
  invalidate stale hydrated sessions.
- Passive open, canvas hydration, page navigation, background, and close paths
  remain behind `canPersist`/`canWrite` and never request unlock.
- Pattern recency is not marked when entitlement is read-only.
- Highlight, markup, and counter controls request unlock only from explicit
  edit gestures. Structurally read-only and completed-project contexts remain
  non-interactive rather than presenting unlock.

### D. StoreKit unavailable versus authoritative none

- Added `PurchaseQualification.unavailable`, distinct from authoritative
  `.none`.
- Lifetime transaction lookup is tri-state: entitled, authoritative none, or
  unavailable. A matching unverified lifetime transaction is unavailable and
  does not fall through to AppTransaction legacy qualification.
- A verified `AppTransaction` newer than `1.2.0` produces authoritative
  `.none`; an AppTransaction error or unverified result produces
  `.unavailable`.
- Initial unavailable/unverified qualification remains unprepared and
  fail-closed.
- A transient unavailable refresh preserves an already verified lifetime or
  legacy-paid-owner snapshot without consulting trial storage.
- An authoritative `.none` refresh still loads trial state and can revoke a
  previous permanent qualification.
- Restore applies authoritative `.none` immediately, while unavailable restore
  preserves an already verified lifetime or legacy-paid-owner snapshot.
- Added an injectable StoreKit entitlement source covering transient
  unavailable and authoritative free-app results.

## TDD Evidence

- A RED: six release-contract issues identified the old `1.2.0` candidate in
  `project.yml`, generated project settings, audit, submission, and
  verification documents. GREEN: 29 tests in 3 suites passed, including the
  `1.2.0` legacy / `1.2.1` free boundary.
- B coordinator RED: `commitSuccessfulMutation` was missing. Store RED:
  `commitSuccessfulMutation` was not accepted by store construction. GREEN:
  21 entitlement-boundary tests passed for blank names, missing projects,
  invalid PDFs, archive write failure, successful create/import, commit
  idempotence, and post-publication commit failure.
- B review RED: a failed Keychain commit deleted an already published imported
  PDF. GREEN: the regression passed after success commit moved outside file
  rollback scopes.
- C core RED: `entitlementCanWrite` and `canRequestUnlock` were missing. UI RED:
  five contract issues showed no entitlement-aware context or explicit-edit
  request seam. GREEN: 34 tests in 3 reader suites passed and the focused app
  tests compiled and passed.
- D RED: `PurchaseQualification.unavailable` did not exist. StoreKit-source
  RED: the injectable entitlement source did not exist. GREEN: coordinator and
  StoreKit lifecycle focused suites passed.
- Independent-review RED: Keychain trial-start failure could leave the
  coordinator prepared; unverified lifetime was collapsed into authoritative
  absence; and authoritative `.none` restore did not revoke. GREEN:
  fail-closed retry denial, tri-state lifetime lookup, and restore
  none/unavailable tests passed.
- Concurrency-review RED: controlled in-flight tests proved that stale
  preparation could overwrite restored lifetime and successful trial start.
  GREEN: generation invalidation made both races pass; the full App test suite
  remained green.

## Fresh Final Verification

| Verification | Result |
| --- | --- |
| Static release audit | `METADATA CHECK: PASS`; `RELEASE AUDIT: PASS` |
| Full Swift package suite | 946 tests in 78 suites passed |
| Full `KnitNoteAppTests` | 39 tests / 41 executions passed; 0 failures or skips |
| Unsigned generic iOS Release build | passed |
| Unsigned generic watchOS Release build | passed |
| Unsigned generic macOS Release build | passed |
| Built bundle versions | iOS, embedded Share, embedded Watch, standalone Watch, and macOS are `1.2.1` / Build `2` |
| `git diff --check` | passed |
| Final independent re-review | 0 Critical / 0 Important; independent focused coordinator suite 29/29 passed |

## Scope and Artifacts

The pre-existing untracked `KnitNote 5.xcodeproj/`,
`KnitNote 6.xcodeproj/`, and `KnitNote/Info 2.plist` were preserved and are not
part of this change. Verification DerivedData was written only under `/tmp`.
Physical StoreKit purchase/restore, legacy upgrade, expiry-reader interaction,
Share expiry, Watch offline, archive validation, and App Store Connect
acceptance remain manual release gates and were not claimed by this local task.
Two non-blocking review notes remain: unavailable restore still uses the
generic not-found message, and the selecting inbox overload retains its
accepted nested authorization.
