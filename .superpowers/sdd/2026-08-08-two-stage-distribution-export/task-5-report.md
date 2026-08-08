# Task 5 — Exact-SHA Candidate Verification Evidence

Date: 2026-08-08 (Asia/Taipei)

## Immutable input gate

- Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/knitnote-1.4.1-final`
- Branch: `release/knitnote-1.4.1-final`
- Exact HEAD: `3c5c540055f57e85cd37cc30dddd6f354016b183`
- Expected version/build: `1.4.1 (8)` (checked-in project settings)
- Requested output: `/tmp/KnitNoteRelease-1.4.1-Build8-3c5c540`

Before the creator call and again after it stopped, `git status --short` was empty, `git diff --check` emitted no errors, and the requested final path was absent.

## Required preflight

All required preflight checks passed with retained local evidence:

- `StoreScreenshotFixturesTests`: 19 tests in 1 suite passed (7.875 seconds).
- `ReleaseCandidateIdentityTests`: 4 tests in 1 suite passed (11.068 seconds).
- Fresh logged `ReleaseAuditLocalizationTests`: 54 tests in 1 suite passed (251.126 seconds), `/tmp/KnitNoteTask5-3c5c540-focused-release.log`, status `0`.
- Fresh logged `swift test --disable-sandbox`: 1,377 tests in 122 suites passed (260.545 seconds), `/tmp/KnitNoteTask5-3c5c540-full.log`, status `0`.
- `AppStore/Verification/release_audit.sh --static-only` emitted `METADATA CHECK: PASS`, `COMMERCIAL RELEASE CHECK: PASS (offline)`, and `STATIC RELEASE AUDIT: PASS`.

## Single supported creator attempt — STOP

Exactly one sandbox-external call to the checked-in creator was made:

```bash
AppStore/Verification/create_release_candidate.sh \
  /tmp/KnitNoteRelease-1.4.1-Build8-3c5c540
```

No alternate signing/profile/export command, `-allowProvisioningUpdates`, `destination=upload`, upload, App Store Connect mutation, session/profile mutation, push, or merge was used. iOS archive/export and macOS archive completed. macOS local export then stopped with this exact error:

```text
error: exportArchive No signing certificate "Mac Installer Distribution" found
** EXPORT FAILED **
```

The creator's final path was absent after the failure; no final candidate was published. The creator was not rerun and no alternative signing or export action was attempted.

## Consequences and remaining gates

Because no final candidate exists, provenance verification, formal `RELEASE AUDIT: PASS`, IPA/pkg extraction, four-product signing/profile/locale/privacy/entitlement inspection, package-container signature inspection, export record checks, and candidate inventory/permission checks were not run and cannot be claimed.

The immediate blocker is the unavailable local `Mac Installer Distribution` certificate required by the supported macOS export. A separately authorized retry may occur only after that signing-identity condition is remedied and all immutable input/preflight gates are rerun. Any future candidate must still pass independent audit and the physical iPhone/iPad/Watch/macOS plus separately authorized App Store metadata/IAP/pricing/submission gates.

## Retry 1 — package-container signature gate

The user authorized a Retry 1 after Xcode created the required installer identity. Before the new creator call, the same exact clean HEAD and absent output path were reconfirmed. A read-only keychain identity check confirmed the expected `3rd Party Mac Developer Installer` identity for team `9CFPAUL5N5` was present. Because the source SHA was unchanged, the retained fresh preflight evidence above was reused without rerunning it.

Exactly one new sandbox-external invocation of the same checked-in creator targeted the same absent output path. iOS archive/export, macOS archive/export, and the creator's isolated `1,377 tests in 122 suites` source verification completed. Its internal formal audit then stopped before publication with this exact error:

```text
release audit: macOS pkg is not signed by the required trusted Apple installer distribution
```

The final path remained absent after cleanup, and the exact source HEAD/status remained clean. No independent provenance, formal-audit rerun, product extraction, package inspection, upload, App Store action, alternate signing/profile/export command, or further creator call was made. The remaining blocker is therefore the produced package-container signature failing the formal trust/leaf-team gate despite the local installer identity being present; this task does not diagnose or modify that signing state.

## Follow-up: Task 6 audit compatibility repair

Read-only inspection established that the local package verifier exited zero and reported the exact installer leaf, WWDR intermediate, and Apple Root CA, but used the precise status line `Status: signed by a developer certificate issued by Apple (Development)`. The old audit only accepted the different `trusted by macOS` line. Task 6 adds a narrow, tested status allowlist while retaining the zero exit, exact `1.` leaf/team, WWDR, and Apple Root requirements. No candidate was created or retried in that repair task.
