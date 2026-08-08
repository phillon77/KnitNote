# Task 3 — Two-stage Distribution Candidate Evidence

Date: 2026-08-08 (Asia/Taipei)

## Immutable input gate

- Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/knitnote-1.4.1-final`
- Branch: `release/knitnote-1.4.1-final`
- Exact HEAD: `58e9789b7de229572d82e2075c7886525188ca8c` (`58e9789`)
- Expected version/build: `1.4.1 (8)`
- Requested final candidate path: `/tmp/KnitNoteRelease-1.4.1-Build8-58e9789`

Before construction, `git diff --check` emitted no errors, `git status --short` was empty, and the requested output path was absent. The final post-failure check preserved the same exact HEAD, had no diff errors/status output, and again found the candidate output absent.

## Required preflight evidence

All required preflight verification passed:

- `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin swift test --filter StoreScreenshotFixturesTests`: 19 tests in 1 suite passed.
- `swift test --filter ReleaseCandidateIdentityTests`: 4 tests in 1 suite passed.
- `swift test --filter ReleaseAuditLocalizationTests`: 42 tests in 1 suite passed.
- `swift test --disable-sandbox`: 1365 tests in 122 suites passed.
- `AppStore/Verification/release_audit.sh --static-only`:
  - `METADATA CHECK: PASS`
  - `COMMERCIAL RELEASE CHECK: PASS (offline)`
  - `STATIC RELEASE AUDIT: PASS`

## Single supported creator attempt

Exactly one sandbox-external invocation was made, using only the checked-in creator and the requested output path:

```bash
AppStore/Verification/create_release_candidate.sh \
  /tmp/KnitNoteRelease-1.4.1-Build8-58e9789
```

No `-allowProvisioningUpdates`, `destination=upload`, profile/certificate/signing override, network/App Store, or source/config change was used.

The creator reached its internal formal archive audit after archive/export/provenance staging. Its internal source verification reported `1365 tests in 122 suites passed`, and metadata plus commercial checks passed. The audit then stopped with this exact failure:

```text
Could not unarchive /private/tmp/.KnitNote-1.4.1.staging.VbzcwU/artifacts/Distribution/macOS/KnitNote.pkg (The operation couldn’t be completed. File exists)
release audit: macOS pkg expansion failed
```

## Candidate/provenance state

The creator cleaned its staging area on failure. The requested final directory `/tmp/KnitNoteRelease-1.4.1-Build8-58e9789` does not exist, so no candidate, IPA, pkg, archive, export summary/options record, or canonical provenance was published for independent verification.

Accordingly, there is no audit-accepted Distribution candidate and no valid basis to inspect or claim final product signing, provisioning, entitlements, locales, privacy manifests, or export records. No upload, submission, selected-build, pricing, IAP, metadata, screenshot publication, certificate/profile mutation, or App Store Connect action occurred.

## Blocker and remaining gates

The blocking failure is the supported creator's formal audit inability to expand its staged macOS pkg because the extraction destination already exists. Under the task instructions, no alternate extraction, signing, profile, export, or creator command was attempted.

Before any release progression: repair and verify the supported creator/audit packaging path, then in a separately authorized clean attempt create one immutable candidate and require `RELEASE AUDIT: PASS`; after that, complete physical iPhone/iPad/Watch/Mac acceptance and the separate App Store candidate/metadata/IAP/pricing gates. This task stopped before all of those actions.

## Follow-up: Fix Round 2

The failing audit path was repaired in a later source commit `422fbc8` (`fix: preserve pkgutil expansion destination`) with a RED/GREEN regression test that makes the fake pkgutil reject an existing expansion child. The repair was verified by the full 43-test ReleaseAuditLocalizationTests suite, 4 identity tests, static audit, Bash/Python/plist checks, and `git diff --check`.

No candidate was rebuilt in this follow-up: the failed `58e9789` candidate remains absent, and a new immutable candidate attempt must use the later exact commit only after the appropriate Task 3 authorization.

## Retry 1: `422fbc8` candidate attempt

- Exact source: `422fbc893735fada1c66db5d110bd48130cf1a68` on `release/knitnote-1.4.1-final`; `git diff --check` and `git status --short` were clean, and `/tmp/KnitNoteRelease-1.4.1-Build8-422fbc8` was absent before the attempt.
- Preflight PASS: StoreScreenshotFixturesTests 19/19; ReleaseCandidateIdentityTests 4/4; ReleaseAuditLocalizationTests 43/43; full `swift test --disable-sandbox` 1366 tests in 122 suites; static audit metadata/commercial/static checks PASS.
- Exactly one sandbox-external, checked-in creator invocation ran without signing/profile/upload/provisioning overrides:

  ```bash
  AppStore/Verification/create_release_candidate.sh \
    /tmp/KnitNoteRelease-1.4.1-Build8-422fbc8
  ```

- The creator passed its internal source suite (1366 tests in 122 suites) and metadata/commercial checks. It then failed its formal audit with:

  ```text
  release audit: macOS provisioning profile is expired or is not App Store distribution for 9CFPAUL5N5
  ```

- The final candidate directory remains absent after creator cleanup; therefore no IPA/pkg/provenance/export record was published or independently inspectable. No alternate signing/profile command, retry, Archive/Export action outside the supported creator, upload, network, or App Store action occurred.

## Follow-up: Fix Round 3

The Retry 1 profile rejection was repaired in later source commit `ff3b613` (`fix: accept omitted Mac profile get-task-allow`). Read-only decoding showed that the actual local Mac Team Store profile is otherwise valid for team `9CFPAUL5N5` but legitimately omits `get-task-allow`; the prior formal audit treated that omission as a failure. A RED fixture reproduced the exact omission, and the minimal fix treats an absent key as not granted while a new regression continues to reject explicit `get-task-allow=true`.

Verification passed: focused regressions; fresh full `ReleaseAuditLocalizationTests` (45 tests, 216.978 seconds); `ReleaseCandidateIdentityTests` (4 tests, 13.181 seconds); static audit; Bash/Python/plist checks; and `git diff --check`.

No creator or candidate retry was run in this follow-up. `/tmp/KnitNoteRelease-1.4.1-Build8-422fbc8` remains absent, and no candidate/provenance/export record now exists. A subsequent authorized Retry must start from the later exact commit, use a new output path, and stop on the first failure.

## Retry 2: immutable candidate `ff3b613`

### Input and preflight gates

- Worktree and branch: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/knitnote-1.4.1-final`, `release/knitnote-1.4.1-final`.
- Exact HEAD: `ff3b61304d291bd2ef81b27878a30354c4494870`; version/build: `1.4.1 (8)`.
- Before construction, `git status --short` and `git diff --check` were clean, and `/tmp/KnitNoteRelease-1.4.1-Build8-ff3b613` was absent.
- Focused preflight PASS:
  - `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin swift test --filter StoreScreenshotFixturesTests`: 19 tests PASS (7.830 seconds).
  - `swift test --filter ReleaseCandidateIdentityTests`: 4 tests PASS (13.415 seconds).
  - `swift test --filter ReleaseAuditLocalizationTests`: 45 tests PASS (223.300 seconds).
  - `swift test --disable-sandbox`: 1,368 tests in 122 suites PASS (222.694 seconds).
  - `AppStore/Verification/release_audit.sh --static-only`: metadata, offline commercial, and static release audit all PASS.

### One supported creator call

Exactly one sandbox-external invocation ran:

```bash
AppStore/Verification/create_release_candidate.sh \
  /tmp/KnitNoteRelease-1.4.1-Build8-ff3b613
```

It used no `-allowProvisioningUpdates`, `destination=upload`, signing/profile override, alternate export/signing command, or App Store action. A later review established that macOS export may contact authorized Apple developer services for managed package signing; this was remote signing, not an app upload or App Store mutation. Both iOS and macOS archives/export stages succeeded. Its isolated source suite passed 1,368 tests in 122 suites, then its own formal audit emitted `RELEASE AUDIT: PASS` and exited 0.

The final candidate is published at `/tmp/KnitNoteRelease-1.4.1-Build8-ff3b613` (the local filesystem reports the same directory canonically as `/private/tmp/KnitNoteRelease-1.4.1-Build8-ff3b613`). It contains both xcarchives, `Distribution/iOS/KnitNote.ipa`, `Distribution/macOS/KnitNote.pkg`, both `DistributionSummary.plist` and `ExportOptions.plist` records, raw packaging logs, and `provenance.json`. It is quarantined and must not be shared or promoted; Task 4 removes these raw logs in future candidates.

### Independent post-creator verification

- Deterministic provenance independently passed:

  ```bash
  python3 AppStore/Verification/release_archive_manifest.py verify \
    --archives /private/tmp/KnitNoteRelease-1.4.1-Build8-ff3b613 \
    --source-commit ff3b61304d291bd2ef81b27878a30354c4494870 \
    --input /private/tmp/KnitNoteRelease-1.4.1-Build8-ff3b613/provenance.json
  ```

- Independent formal audit independently passed:

  ```bash
  AppStore/Verification/release_audit.sh \
    --archives /private/tmp/KnitNoteRelease-1.4.1-Build8-ff3b613 \
    --expected-commit ff3b61304d291bd2ef81b27878a30354c4494870 \
    --provenance /private/tmp/KnitNoteRelease-1.4.1-Build8-ff3b613/provenance.json
  ```

  It reran 1,368 tests in 122 suites (164.674 seconds) and emitted `METADATA CHECK: PASS`, `COMMERCIAL RELEASE CHECK: PASS (offline)`, and `RELEASE AUDIT: PASS`.

- A separate fresh temporary extraction using `ditto -x -k` for the IPA and `pkgutil --expand-full` for the pkg checked each exported product directly. iOS, Watch, Share, and macOS all have Apple Distribution authority `Apple Distribution: Chen Chung Lung (9CFPAUL5N5)`, team `9CFPAUL5N5`, exact bundle identities, version `1.4.1`, build `8`, and embedded source revision `ff3b61304d291bd2ef81b27878a30354c4494870`.
- Two initial report-only extraction summarizers stopped before completing their first iOS profile: first because a jq key-quoting mistake made the local summary invalid, then because converting the complete profile (which includes a non-JSON plist type) to JSON was unsupported. Neither command modified the candidate or reached a product assertion failure. The final field-specific plist inspection above used a fresh extraction and completed with exit 0; the independent formal audit had already passed.
- Each embedded Store profile has team `9CFPAUL5N5`, exact application identifier, no `ProvisionedDevices` or `ProvisionsAllDevices`, and expiration `2027-07-17`. iOS/Watch/Share have explicit `get-task-allow=false`; macOS correctly omits it in its profile and has no signed debug grant. Signed iOS/Share application groups are exactly `group.com.phillon.KnitNote`; signed macOS sandbox and network-client entitlements are true.
- All four exported products declare and contain exactly the 12 release locales: `da,de,el,en,fi,fr,ja,ko,nb,sv,zh-Hans,zh-Hant`. Their privacy manifests report tracking false and zero collected-data types; accessed API counts are iOS 2, Watch 1, Share 0, macOS 2.
- Both export-options records state `destination=export`, `method=app-store-connect`, `signingStyle=automatic`, `teamID=9CFPAUL5N5`, `generateAppStoreInformation=false`, and `manageAppVersionAndBuildNumber=false`; no upload/provisioning-update behavior was used. Both export summaries identify Apple Distribution, team `9CFPAUL5N5`, version 1.4.1, build 8, and profile expiration 2027-07-17.

### Remaining gates

This is a local, signed, formal-audit-passing candidate—not a submitted or release-ready App Store build. Remaining gates include physical iPhone/iPad/Watch/macOS acceptance, and separately authorized App Store Connect build selection/submission plus live metadata, IAP, and pricing checks. No upload, submission, selected-build, price/IAP/metadata mutation, screenshot publication, or App Store Connect action occurred in Retry 2.
