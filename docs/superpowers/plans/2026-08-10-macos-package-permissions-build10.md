# KnitNote macOS Package Permissions and Build 10 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct the macOS package file-permission defect, produce one immutable KnitNote 1.5.0 (Build 10) candidate, and upload both Build 10 platform binaries to App Store Connect without submitting or releasing them.

**Architecture:** Preserve private staging by creating the candidate staging/worktree directories under `umask 077`, then switch to `umask 022` before every Xcode archive/export invocation. Validate the expanded exported PKG payload fail-closed for world-readable regular files and world-searchable directories. Move every shipping target and all release tooling together from Build 9 to Build 10, then create, independently audit, and upload one exact candidate.

**Tech Stack:** Bash, Swift Testing, Swift Package Manager, XcodeGen, Xcode/xcodebuild, Python release tooling, `pkgutil`, `codesign`, App Store Connect through Xcode Organizer

## Global Constraints

- Make all source edits and commits only in `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/knitnote-1.4.1-final` on `feature/knitnote-1.5`. A temporary clean detached worktree at the final exact SHA is allowed only for the creator's immutable clean-source gate.
- Preserve existing untracked `.superpowers/brainstorm/`, `build/`, and `task-3-report.md`; they are not part of this work.
- Build 9 remains historical/unused. Do not delete it, select it for release, or rewrite its evidence.
- Do not chmod files inside a signed `.app` after archive/export.
- Do not add `-allowProvisioningUpdates`, upload destinations to ExportOptions, alternate signing, re-signing, or profile mutations.
- The supported candidate creator may run only once for the final clean Build 10 SHA. If it fails, stop and diagnose; do not retry without a new explicit authorization.
- Upload is authorized only after all candidate checks pass. Do not add for review, submit for review, automatically release, merge, or push.
- Every completion claim must cite fresh command output; a build alone is not release acceptance.

---

## Task 1: Add permission-regression tests and witness RED

**Files:**
- Modify: `Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift`
- Test: `Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift`

- [ ] **Step 1: Add an exported-PKG payload permission regression**

Extend the existing positive archive-audit fixture so a test can change one extracted macOS app file to `0600`. Use a real path inside the signed app fixture, preferably:

```swift
let codeResources = macApp
    .appending(path: "Contents/_CodeSignature/CodeResources")
try FileManager.default.setAttributes(
    [.posixPermissions: 0o600],
    ofItemAtPath: codeResources.path
)
```

Add a test that runs the production audit and expects a nonzero status plus a precise permission failure identifying an unreadable regular file. Add a companion mutation for a directory mode such as `0700` and expect an unsearchable-directory failure.

- [ ] **Step 2: Make the creator fixture record Xcode's observed umask**

Update the fake `xcodebuild` script used by `runCreatorFixture` to append `umask` once per archive/export call to a fixture-owned log path. Assert:

```swift
#expect(observedMasks == ["0022", "0022", "0022", "0022"])
```

Retain the existing assertions that the published candidate root is private, raw `Packaging.log` files are absent, staging is cleaned, and race publication fails closed.

- [ ] **Step 3: Run only the two new regressions and record RED**

Run:

```bash
swift test --disable-sandbox --filter archiveAuditRejectsUnreadableMacPackagePayload
swift test --disable-sandbox --filter creatorFixturePublishesPrivateCandidateWithoutRawPackagingLogsAndCleansRaceStaging
```

Expected before production changes:

- the audit incorrectly accepts the `0600` file and `0700` directory fixtures; and
- the fake Xcode calls record `0077`, not `0022`.

Do not weaken the expected failures or edit production in this step.

---

## Task 2: Implement the minimal creator and audit fix

**Files:**
- Modify: `AppStore/Verification/create_release_candidate.sh`
- Modify: `AppStore/Verification/release_audit.sh`
- Test: `Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift`

- [ ] **Step 1: Switch to a standard product umask before Xcode**

Keep the script's initial `umask 077`. After both private temporary roots and the detached worktree are created, but before the first `xcodebuild archive`, add:

```bash
umask 022
```

Do not add any post-signing chmod of app contents. Keep `chmod 700 "$ARTIFACTS"`, Packaging.log removal, provenance, formal audit, and atomic publication unchanged.

- [ ] **Step 2: Add fail-closed macOS payload permission checks**

After `MAC` resolves to the unique extracted `KnitNote.app`, inspect that lexical app tree before the existing localization/signing checks:

```bash
unreadable_file="$(find "$MAC" -type f ! -perm -0004 -print -quit)"
[[ -z "$unreadable_file" ]] \
  || fail "macOS package app contains a file that is not world-readable: $unreadable_file"

unsearchable_directory="$(find "$MAC" -type d ! -perm -0001 -print -quit)"
[[ -z "$unsearchable_directory" ]] \
  || fail "macOS package app contains a directory that is not world-searchable: $unsearchable_directory"
```

Keep the checks scoped to regular files and directories in the exported PKG's app root. Do not follow symlinks or replace the existing trusted-root/symlink checks.

- [ ] **Step 3: Run the new GREEN regressions**

Run the two Task 1 commands again. Expected: both pass, the fake Xcode log contains four `0022` entries, and the negative payload fixtures fail for the intended reason.

- [ ] **Step 4: Run adjacent release contracts**

Run:

```bash
swift test --disable-sandbox --filter 'candidateCreator|creatorFixture|atomicPublication|archiveAudit'
bash -n AppStore/Verification/create_release_candidate.sh
bash -n AppStore/Verification/release_audit.sh
AppStore/Verification/release_audit.sh --static-only
git diff --check
```

Expected: all selected tests and static checks pass, and the test summary proves that a nonzero number of tests ran. Confirm creator ordering, production override rejection, signing, raw-log deletion, provenance, package signature, and atomic publication assertions remain intact.

- [ ] **Step 5: Commit the permission fix**

```bash
git add AppStore/Verification/create_release_candidate.sh \
  AppStore/Verification/release_audit.sh \
  Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift
git commit -m "fix: preserve readable macOS package permissions"
```

---

## Task 3: Move every release identity contract to Build 10

**Files:**
- Modify: `project.yml`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`
- Modify: `AppStore/Verification/release_audit.sh`
- Modify: `AppStore/Screenshots/README.md`
- Modify: `Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ReleaseCandidateIdentityTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/StoreScreenshotFixturesTests.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchPackagingContractTests.swift`
- Verify unchanged generation outputs: `KnitNote/Info.plist`, `KnitNoteWatch/Info.plist`, `KnitNoteShare/Info.plist`

- [ ] **Step 1: Change identity tests to require Build 10 and witness RED**

Update test names and exact expectations from Build 9 to Build 10. The previous-build archive fixture must use Build 9 and require the exact production error:

```swift
#expect(result.output.contains("iOS product build is 9, expected 10"))
```

Update screenshot fixture arguments and generated build-setting expectations to `10`. Run:

```bash
swift test --disable-sandbox --filter 'ReleaseConfigurationContractTests|ReleaseCandidateIdentityTests|WatchPackagingContractTests|StoreScreenshotFixturesTests'
```

Expected: RED only because production/configuration still says Build 9.

- [ ] **Step 2: Apply the synchronized Build 10 identity**

Change all shipping target `CURRENT_PROJECT_VERSION` values in `project.yml` from `9` to `10`. Change `EXPECTED_BUILD` in `release_audit.sh` to `10`. Update screenshot instructions to `CANDIDATE_BUILD='10'` and exact `1.5.0 (10)` copy.

Do not change `MARKETING_VERSION`, bundle identifiers, team, signing style, thirteen locales, catalog contents, user content, or historical Build 9 records.

- [ ] **Step 3: Regenerate Xcode files twice and prove no drift**

Run:

```bash
xcodegen generate
shasum -a 256 KnitNote.xcodeproj/project.pbxproj > /tmp/KnitNoteBuild10-pbx-first.sha
xcodegen generate
shasum -a 256 KnitNote.xcodeproj/project.pbxproj > /tmp/KnitNoteBuild10-pbx-second.sha
cmp /tmp/KnitNoteBuild10-pbx-first.sha /tmp/KnitNoteBuild10-pbx-second.sha
```

Expected: `cmp` exits 0. Confirm the three generated Info plists remain dynamic (`$(CURRENT_PROJECT_VERSION)`) and their content does not drift unnecessarily.

- [ ] **Step 4: Run the focused Build 10 contracts GREEN**

Run the combined focused command from Step 1. Expected: all tests pass and every shipping product resolves to 1.5.0 (10).

- [ ] **Step 5: Commit the atomic Build 10 bump**

```bash
git add project.yml KnitNote.xcodeproj/project.pbxproj \
  AppStore/Verification/release_audit.sh AppStore/Screenshots/README.md \
  Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift \
  Tests/KnitNoteCoreTests/ReleaseCandidateIdentityTests.swift \
  Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift \
  Tests/KnitNoteCoreTests/StoreScreenshotFixturesTests.swift \
  Tests/KnitNoteCoreTests/WatchPackagingContractTests.swift
git commit -m "chore: bump release identity to build 10"
```

---

## Task 4: Verify the complete Build 10 source candidate

**Files:**
- Verify only: all tracked source/configuration
- Report only: `.superpowers/sdd/2026-08-10-macos-package-permissions-build10/task-4-report.md`

- [ ] **Step 1: Verify exact clean identity**

Run:

```bash
git branch --show-current
git rev-parse HEAD
git status --short
git diff --check
```

Expected: correct branch, a full immutable SHA, and no tracked/staged changes; only the three preserved pre-existing untracked paths may appear. The supported creator requires a fully clean source worktree, so create a temporary clean detached worktree at that exact commit for Task 5, rather than moving or deleting the preserved paths.

- [ ] **Step 2: Run focused release suites**

Run each once and retain exact counts/exits:

```bash
swift test --disable-sandbox --filter ReleaseAuditLocalizationTests
swift test --disable-sandbox --filter 'ReleaseConfigurationContractTests|ReleaseCandidateIdentityTests|WatchPackagingContractTests|StoreScreenshotFixturesTests'
```

Expected: both commands exit 0; the audit suite includes the new payload permission and creator umask cases.

- [ ] **Step 3: Run the full Swift suite once**

```bash
swift test --disable-sandbox
```

Expected: exit 0 with zero issues. If a retained SwiftPM process owns the build lock, wait for that exact process; do not launch duplicates.

- [ ] **Step 4: Run static and generation checks**

```bash
python3 AppStore/Verification/metadata_check.py AppStore/Metadata
AppStore/Verification/release_audit.sh --static-only
bash -n AppStore/Verification/create_release_candidate.sh
bash -n AppStore/Verification/release_audit.sh
python3 -m py_compile AppStore/Verification/release_archive_manifest.py AppStore/Verification/atomic_publish.py
plutil -lint AppStore/Verification/ExportOptions-AppStore.plist
git diff --check
```

Expected: all pass.

- [ ] **Step 5: Run four unsigned builds**

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Release -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -target KnitNoteShare -configuration Release -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: four `BUILD SUCCEEDED` results. Inspect the produced Info plists for 1.5.0 (10), the exact source revision where embedded, and thirteen declared/localized languages.

- [ ] **Step 6: Review the cumulative source diff**

Confirm no signing, entitlement, privacy, bundle ID, locale, user-data, upload, submission, or release-boundary drift. Record exact evidence and the candidate SHA in the task report.

---

## Task 5: Create and independently audit one immutable Build 10 candidate

**Files:**
- Execute: `AppStore/Verification/create_release_candidate.sh`
- Execute: `AppStore/Verification/release_archive_manifest.py`
- Execute: `AppStore/Verification/release_audit.sh`
- Report only: `.superpowers/sdd/2026-08-10-macos-package-permissions-build10/task-5-report.md`

- [ ] **Step 1: Establish the one-shot creator gate**

Set:

```bash
CANDIDATE_SHA="$(git rev-parse HEAD)"
CANDIDATE_DIR="/tmp/KnitNoteRelease-1.5.0-Build10-${CANDIDATE_SHA:0:7}"
```

Verify the exact SHA is clean, the output is absent, project identity is 1.5.0 (10), and required local Apple Distribution/Mac Installer Distribution identities are present. Do not change signing or profiles.

- [ ] **Step 2: Invoke the checked-in creator exactly once**

```bash
AppStore/Verification/create_release_candidate.sh "$CANDIDATE_DIR"
```

Expected: exit 0, one atomically published candidate, no raw `Packaging.log`, root mode `0700`, no staging/worktree residue, and `RELEASE AUDIT: PASS`. If it fails, stop; do not rerun or substitute archive/export commands.

- [ ] **Step 3: Independently verify provenance and formal audit**

```bash
python3 AppStore/Verification/release_archive_manifest.py verify \
  --archives "$CANDIDATE_DIR" --source-commit "$CANDIDATE_SHA" \
  --input "$CANDIDATE_DIR/provenance.json"
AppStore/Verification/release_audit.sh --archives "$CANDIDATE_DIR" \
  --expected-commit "$CANDIDATE_SHA" \
  --provenance "$CANDIDATE_DIR/provenance.json"
```

Expected: both exit 0 and the formal audit prints `RELEASE AUDIT: PASS`.

- [ ] **Step 4: Inspect only the exported IPA and PKG products**

Unpack `Distribution/iOS/KnitNote.ipa` with `ditto` and expand `Distribution/macOS/KnitNote.pkg` with `pkgutil --expand-full` into fresh temporary roots. Verify independently:

- iOS, Watch, Share, and macOS use Apple Distribution for team `9CFPAUL5N5`;
- exact bundle IDs, profiles, entitlements, privacy manifests, thirteen locales, 1.5.0 (10), and `CANDIDATE_SHA`;
- profiles are valid App Store profiles without development devices/debug grants;
- the PKG has the trusted exact-team installer signature chain; and
- every regular file in the expanded `KnitNote.app` is world-readable and every directory is world-searchable, including `_CodeSignature/CodeResources` and `embedded.provisionprofile`.

Do not inspect archive Development signatures as if they were exported distribution-product signatures.

- [ ] **Step 5: Record candidate acceptance**

Record paths, exact SHA, command exits, product identities, permission results, and remaining upload-only boundary in the task report. Preserve the accepted candidate unchanged.

---

## Task 6: Upload Build 10 without submission or release

**Files:**
- Read only: accepted Build 10 candidate archives/exports
- Report only: `.superpowers/sdd/2026-08-10-macos-package-permissions-build10/task-6-report.md`

- [ ] **Step 1: Reconfirm upload authorization and candidate binding**

Before any UI action, reconfirm the accepted candidate path, SHA, 1.5.0 (10), provenance PASS, formal audit PASS, and independent exported-product PASS. Build 9 must remain unused.

- [ ] **Step 2: Upload the iOS-family Build 10 archive in Xcode Organizer**

Open the exact candidate's iOS archive, choose Distribute App → App Store Connect → Upload, keep the default managed-symbol/upload choices that do not alter signing, and wait for Xcode's terminal success.

Expected: Xcode shows `Uploaded to Apple` / `App upload complete` for Build 10. Stop on any error; do not retry automatically.

- [ ] **Step 3: Upload the macOS Build 10 archive in Xcode Organizer**

Open the exact candidate's macOS archive and perform the same App Store Connect upload flow.

Expected: Xcode shows `Uploaded to Apple` / `App upload complete` for Build 10, with no error 90255.

- [ ] **Step 4: Verify App Store Connect processing state read-only**

Confirm Build 10 appears for both platform records, or is explicitly processing. Do not select Build 9, add either build for review, submit, release, change pricing, or alter metadata.

- [ ] **Step 5: Write the upload report and stop**

Record timestamps, exact candidate SHA/path, both Xcode success states, and any processing state in the ignored task report. Final status must say clearly: uploaded only; not submitted; not released; not merged; not pushed.
