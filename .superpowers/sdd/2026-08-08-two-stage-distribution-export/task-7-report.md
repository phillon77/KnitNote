# Task 7 — Candidate Retry 2 Evidence

Date: 2026-08-09 (Asia/Taipei)

## Immutable input gate

- Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/knitnote-1.4.1-final`
- Branch: `release/knitnote-1.4.1-final`
- Exact HEAD: `b62b036638a01fb9fd06be0119885c13fa650092`
- Expected version/build: `1.4.1 (8)`
- Requested output: `/tmp/KnitNoteRelease-1.4.1-Build8-b62b036`

Before construction and after the failure, source status was clean, `git diff --check` had no errors, and the requested output was absent. Read-only keychain checks confirmed Apple Distribution and 3rd Party Mac Developer Installer identities for team `9CFPAUL5N5`.

## Fresh preflight evidence

- `StoreScreenshotFixturesTests`: 19 tests in 1 suite passed (8.721 seconds), `/tmp/KnitNoteTask7-b62b036-screenshots.log`.
- `ReleaseCandidateIdentityTests`: 4 tests in 1 suite passed (10.779 seconds), `/tmp/KnitNoteTask7-b62b036-identity.log`.
- `ReleaseAuditLocalizationTests`: 54 tests in 1 suite passed (270.826 seconds), `/tmp/KnitNoteTask7-b62b036-release-audit.log`.
- Full `swift test --disable-sandbox`: 1,377 tests in 122 suites passed (285.570 seconds), `/tmp/KnitNoteTask7-b62b036-full.log`.
- `AppStore/Verification/release_audit.sh --static-only`: metadata, offline commercial, and static release audit checks passed.

## One supported creator attempt — STOP

Exactly one sandbox-external invocation of the checked-in creator targeted the requested path. No alternate signing/profile/export command, `-allowProvisioningUpdates`, upload, App Store Connect mutation, profile/session mutation, push, or merge was used. Both archives and both local exports completed.

The creator's internal audit then stopped before publication with this exact error:

```text
release audit: macOS pkg is not signed by the required trusted Apple installer distribution
```

The final candidate directory remains absent after cleanup. Consequently no independent provenance/formal-audit invocation, artifact extraction, product signing/profile/localization/privacy/entitlement inspection, package-container verification, inventory/permission inspection, or publication claim was made.

## Remaining blocker and gates

Although the local identities and preflight tests were present/passing, the produced macOS package did not satisfy the supported formal audit's structured installer-signature gate. This task stops here; it does not diagnose, alter, or retry signing. A separately authorized repair and clean retry are required before candidate verification can resume. Physical iPhone/iPad/Watch/macOS acceptance and separately authorized App Store Connect metadata/IAP/pricing/submission gates also remain outstanding.

## Follow-up: Task 8 indentation compatibility repair

Read-only real `pkgutil` output showed legitimate leading indentation on the status, certificate-chain header, and numbered entries. Task 8 normalizes only leading/trailing whitespace before applying the existing exclusive status/header/three-entry chain contract; it retains all duplicate, decoy, nonzero, and embedded-text rejections. No candidate was retried in that source-only repair.
