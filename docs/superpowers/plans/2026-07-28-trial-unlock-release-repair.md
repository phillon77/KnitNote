# KnitNote Trial Unlock Release Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a reviewed release-repair branch that combines the live 1.2.0 Build 3 fixes with the completed seven-day trial and lifetime-unlock implementation for iOS, iPadOS, macOS, Apple Watch, and the Share Extension, without changing App Store pricing or submitting a build.

**Architecture:** Start from current `main` (`f9a6c04`) in an isolated worktree and merge the completed `feature/trial-lifetime-unlock-watch` branch without rewriting either source branch. Resolve conflicts by preserving the current 1.2 pattern-library, share-extension, and rotation fixes while adding the feature branch's StoreKit, Keychain trial, mutation-gate, Watch entitlement, Share Extension projection, and free-app metadata contracts. Keep App Store Connect writes behind a later explicit approval boundary.

**Tech Stack:** Swift 6, SwiftUI, StoreKit 2, Security/Keychain, WatchConnectivity, Swift Testing, XcodeGen, App Store Connect

## Global Constraints

- Deployment targets remain iOS 18.0, macOS 15.0, and watchOS 11.0.
- Lifetime product identifier is exactly `com.phillon.KnitNote.lifetimeUnlock`.
- Trial duration is exactly 7 × 24 hours and starts only after the first successful project creation or completed pattern import.
- The final paid-app version boundary is `1.2.0`; Apple-verified paid owners must receive lifetime access.
- New users must not receive permanent access from a local Boolean, backup restore, unverified transaction, or StoreKit test configuration.
- Trial expiry preserves all user data and complete backup while every mutation path becomes read-only.
- iPhone is authoritative for Apple Watch entitlement; macOS uses the same verified StoreKit lifetime purchase.
- The Share Extension must not bypass expired entitlement.
- Preserve the released 1.2 pattern-library, share-extension activation, PDF/highlight persistence, and iPhone rotation fixes.
- Preserve Traditional Chinese and English localization, VoiceOver behavior, privacy declarations, and the absence of analytics, ads, accounts, servers, and subscriptions.
- Preserve user-owned untracked files and do not modify the original `feature/trial-lifetime-unlock-watch` branch.
- Do not merge to `main`, push, upload, change App Store pricing, create the production IAP, restore availability, or submit for review without a later explicit user choice.
- The existing full-suite baseline may hang during process teardown; never report it as passing unless the command exits zero. Use focused suites plus fresh unsigned platform builds as the minimum integration gate and rerun the full suite with captured exit status before completion.

---

### Task 1: Integrate the Completed Entitlement Branch onto Current Main

**Files:**
- Merge: `feature/trial-lifetime-unlock-watch`
- Preserve current-main behavior in: `KnitNote/Patterns/PatternReaderView.swift`
- Preserve and combine configuration in: `project.yml`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`
- Reconcile release records: `AppStore/AppStoreSubmission.md`
- Reconcile release records: `AppStore/KnitNotePricing.md`
- Reconcile contracts: `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`
- Reconcile packaging contracts: `Tests/KnitNoteCoreTests/WatchPackagingContractTests.swift`

**Interfaces:**
- Consumes: current `main` release state and completed feature branch `cd43e83`.
- Produces: one conflict-free integration commit containing both current 1.2 fixes and entitlement implementation.

- [ ] **Step 1: Record the clean integration base**

Run:

```bash
git status --short
git rev-parse HEAD
git merge-base main feature/trial-lifetime-unlock-watch
```

Expected: clean branch at `f9a6c04`; merge base is `10d8220`.

- [ ] **Step 2: Merge without committing**

Run:

```bash
git merge --no-ff --no-commit feature/trial-lifetime-unlock-watch
```

Expected: conflicts are limited to files changed independently after `10d8220`; no original branch is rewritten.

- [ ] **Step 3: Resolve source and configuration conflicts**

For each conflict, retain the current-main pattern-library, Share activation, Build 3, and rotation-crash changes, then layer in the feature branch's entitlement calls and target membership. `project.yml` remains the source of truth; regenerate `KnitNote.xcodeproj` rather than manually choosing one entire project file.

Run:

```bash
rg -n '^(<<<<<<<|=======|>>>>>>>)' .
xcodegen generate
plutil -lint KnitNote.xcodeproj/project.pbxproj
```

Expected: no conflict markers; generated project is valid.

- [ ] **Step 4: Reconcile release truth**

`AppStore/KnitNotePricing.md` must label the paid-download schedule as historical and state that no free-app price change occurs before the repaired binary and first non-consumable IAP are approved. `AppStore/AppStoreSubmission.md` must distinguish already-released 1.2.0 Build 3 from the pending repair build and record that public availability is currently being removed from all 175 storefronts.

- [ ] **Step 5: Run integration-focused tests**

Run:

```bash
swift test --scratch-path /tmp/KnitNoteTrialRepairFocused --filter 'Entitlement|Trial|Unlock|Purchase|ShareExtensionEntitlement|WatchEntitlement|ReleaseConfiguration|WatchPackaging'
```

Expected: command exits zero with no failed cases.

- [ ] **Step 6: Commit the integration**

Run:

```bash
git add AppStore KnitNote KnitNoteShare KnitNoteWatch Sources Tests project.yml KnitNote.xcodeproj
git commit -m "fix: integrate trial and lifetime unlock release"
```

Expected: one integration commit on `codex/trial-unlock-release-repair`; neither `main` nor the feature branch moves.

### Task 2: Close Release-Repair Gaps and Verify Every Platform

**Files:**
- Modify: `Sources/KnitNoteCore/Entitlements/FeatureAccessPolicy.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift`
- Test: `Tests/KnitNoteCoreTests/FeatureAccessPolicyTests.swift`
- Test: `Tests/KnitNoteCoreTests/JSONProjectStoreEntitlementTests.swift`
- Test: `Tests/KnitNoteCoreTests/PhoneWatchSyncSourceContractTests.swift`
- Test: `Tests/KnitNoteCoreTests/WatchCommandApplicationTests.swift`
- Modify other files only as required by failing tests or builds from Task 1.
- Record evidence in: `AppStore/Verification/TrialUnlockReleaseRepair.md`

**Interfaces:**
- Consumes: conflict-free integrated entitlement implementation.
- Produces: test/build evidence for iOS, iPadOS, macOS, Apple Watch, and Share Extension.

- [ ] **Step 1: Add failing tests for restored-data trial bypass**

Create a fresh `trialNotStarted` store containing restored or migrated project data, then attempt counter, note, journal, yarn, pattern markup, and other existing-data mutations. Each first meaningful mutation must return `.startTrial`; backup restore itself remains readable/recoverable but must not grant a permanently writable `trialNotStarted` state.

Run:

```bash
swift test --scratch-path /tmp/KnitNoteTrialRepairRed --filter 'FeatureAccessPolicyTests|JSONProjectStoreEntitlementTests'
```

Expected before the repair: at least one new assertion fails because existing-data mutations currently return `.allow`.

- [ ] **Step 2: Start the trial before the first existing-data mutation**

Change the access policy so every user-authored data mutation in `trialNotStarted` returns `.startTrial`, not only project creation and pattern import. Keep reads and complete backup export allowed. The coordinator must durably commit the Keychain trial record and publish the trial snapshot before the store mutation proceeds; if the Keychain commit fails, fail closed and do not mutate data.

Run:

```bash
swift test --scratch-path /tmp/KnitNoteTrialRepairGreen --filter 'FeatureAccessPolicyTests|JSONProjectStoreEntitlementTests|EntitlementCoordinatorTests|KeychainTrialStoreTests'
```

Expected: command exits zero and covers both restored data and Keychain failure.

- [ ] **Step 3: Add a failing test for expired Watch commands**

Queue a Watch counter mutation against an expired authoritative iPhone entitlement. Assert that the command is acknowledged and removed without changing the counter, and cannot be replayed after a later lifetime unlock.

Run:

```bash
swift test --scratch-path /tmp/KnitNoteTrialRepairWatchRed --filter 'WatchCommandApplicationTests|PhoneWatchSyncSourceContractTests'
```

Expected before the repair: the new replay assertion fails because the feature branch retains the rejected command.

- [ ] **Step 4: Drop entitlement-rejected Watch commands**

At the iPhone authority boundary, map `.entitlementRequired` to a deterministic acknowledgement/removal result. Preserve counter state, clear the queued command, publish the current snapshot, and never defer the write until a later unlock.

Run:

```bash
swift test --scratch-path /tmp/KnitNoteTrialRepairWatchGreen --filter 'WatchCommandApplicationTests|PhoneWatchSyncSourceContractTests|WatchEntitlementSnapshotTests|WatchOptimisticStateTests'
```

Expected: command exits zero and proves no delayed replay.

- [ ] **Step 5: Run app-layer Keychain and StoreKit lifecycle tests**

Run:

```bash
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTrialRepairAppTests CODE_SIGNING_ALLOWED=NO -only-testing:KnitNoteAppTests
```

Expected: real Keychain duplicate/corruption coverage and StoreKit lifecycle tests exit zero.

- [ ] **Step 6: Run the complete Swift package suite with an explicit timeout**

Run the full `swift test` suite from a fresh scratch path. If every test reports completion but the process fails to exit, record the teardown hang as a baseline limitation; do not convert it into a passing claim.

```bash
swift test --scratch-path /tmp/KnitNoteTrialRepairFull
```

- [ ] **Step 7: Run release audit and metadata checks**

Run:

```bash
bash AppStore/Verification/release_audit.sh
python3 AppStore/Verification/metadata_check.py
git diff --check main...HEAD
```

Expected: all commands exit zero and no stale paid-download marketing remains in the repaired submission metadata.

- [ ] **Step 8: Build iOS, macOS, Watch, and Share Extension**

Run:

```bash
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteTrialRepairIOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteTrialRepairMac CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Release -destination 'generic/platform=watchOS' -derivedDataPath /tmp/KnitNoteTrialRepairWatch CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNoteShare -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteTrialRepairShare CODE_SIGNING_ALLOWED=NO build
```

Expected: all four commands exit zero; macOS contains StoreKit purchase UI but no Watch or Share target leakage.

- [ ] **Step 9: Record exact evidence**

Create `AppStore/Verification/TrialUnlockReleaseRepair.md` with commit SHA, commands, exit codes, test counts, build destinations, known limitations, and the remaining physical-device/TestFlight/App Store Connect gates.

- [ ] **Step 10: Commit verified fixes and evidence**

Run:

```bash
git add AppStore/Verification Tests Sources KnitNote KnitNoteShare KnitNoteWatch project.yml KnitNote.xcodeproj
git commit -m "test: verify trial unlock release repair"
```

Expected: only focused repairs and verification evidence are added.

### Task 3: Review and Stop at the External-Release Boundary

**Files:**
- Review: all changes in `main...codex/trial-unlock-release-repair`

**Interfaces:**
- Consumes: verified integration branch.
- Produces: reviewed branch and an explicit list of App Store Connect actions requiring user approval.

- [ ] **Step 1: Perform task and whole-branch review**

Review the complete diff for specification compliance, mutation-gate completeness, legacy paid-owner safety, StoreKit verification, macOS behavior, Watch authority, Share Extension fail-closed behavior, target membership, and release-document truth.

- [ ] **Step 2: Re-run verification after review fixes**

Repeat every command covering modified code. A review fix is incomplete until its focused test and affected platform build both exit zero.

- [ ] **Step 3: Present the integration choice**

Stop with the branch name, commit range, test/build evidence, and remaining manual gates. Do not merge or push until the user explicitly selects integration.

- [ ] **Step 4: Preserve the App Store Connect safety sequence**

After a later explicit approval, the external sequence is:

1. merge and push the reviewed repair;
2. archive and upload a new iOS/Watch build and a new macOS build;
3. create the first non-consumable IAP `com.phillon.KnitNote.lifetimeUnlock` with localized metadata, review screenshot, availability, and pricing;
4. submit the first IAP with the new app version;
5. perform TestFlight/Sandbox and physical-device acceptance, including a legacy paid owner;
6. only after approval, change the App price to Free and restore storefront availability;
7. verify the public product page and production purchase/restore flow;
8. only then resume Apple Ads.

## Self-Review

- The plan preserves both source branches and all current-main release fixes.
- The plan covers iOS, iPadOS, macOS, Watch, and Share Extension.
- It explicitly prevents changing the live App to free before the repaired binary and IAP are approved.
- It includes legacy paid-owner protection and production StoreKit verification.
- It records the known full-suite teardown hang without misreporting it.
- It stops before merge, push, upload, pricing, IAP creation, availability restoration, and review submission.
