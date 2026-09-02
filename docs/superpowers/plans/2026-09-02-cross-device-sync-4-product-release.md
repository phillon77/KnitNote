# Cross-Device Sync 4: Product Integration and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate synchronization into the app lifecycle and settings, preserve backup and Watch behavior, localize the experience, and produce release-candidate evidence across iPhone, iPad, Mac, and Watch.

**Architecture:** `KnitNoteApp` creates one live coordinator outside screenshot mode and injects its status projection into SwiftUI. Settings owns the explicit sync, recently deleted, and conflict-management surfaces; backup restore publishes one validated import transaction; Watch sees only the committed local merged snapshot.

**Tech Stack:** Swift 6, SwiftUI, CloudKit, WatchConnectivity, String Catalog, XCTest/Swift Testing, XcodeGen

**Spec:** `docs/superpowers/specs/2026-09-02-cross-device-icloud-sync-design.md`

## Global Constraints

- Complete Plans 1–3 first and keep their public interfaces stable.
- Normal background sync must not display alerts or block editing.
- User-created/imported text is never translated.
- Screenshot fixtures never start CloudKit or mutate live data.
- Watch remains CloudKit-free and receives only committed local snapshots.
- A simulator, archive, or one-device result is not release acceptance.
- Production schema deployment, build upload, and App Review submission remain explicit manual gates.

---

### Task 1: App lifecycle wiring and status projection

**Files:**
- Modify: `KnitNote/App/KnitNoteApp.swift`
- Create: `KnitNote/CloudSync/CloudSyncLiveFactory.swift`
- Create: `Sources/KnitNoteCore/CloudSync/SyncStatusPresentation.swift`
- Test: `Tests/KnitNoteCoreTests/SyncStatusPresentationTests.swift`
- Test: `Tests/KnitNoteCoreTests/StoreScreenshotModeContractTests.swift`

**Interfaces:**
- Consumes: `KnitNoteCloudSyncCoordinator`, `CloudSyncStatusSnapshot`.
- Produces: environment object `CloudSyncPresentationStore` and `syncNow()` action.

- [ ] Write failing tests that map every status to stable semantic presentation, reject “synced” when pending count is nonzero, and prove screenshot mode does not construct/start cloud sync.
- [ ] Run focused tests; expect RED.
- [ ] Implement `CloudSyncLiveFactory.make(projectStore:)` for normal runs and `CloudSyncPresentationStore.disabled` for screenshot fixtures. Start once from app lifecycle, call foreground fetch from `scenePhase`, and never start from a view render.
- [ ] Run status, screenshot-mode, launch, full Swift tests, and generic iOS/macOS builds; expect PASS.
- [ ] Commit with `git commit -m "feat: integrate cloud sync lifecycle"`.

### Task 2: Settings, recently deleted, and conflict UI

**Files:**
- Modify: `KnitNote/Settings/SettingsView.swift`
- Create: `KnitNote/CloudSync/CloudSyncSettingsSection.swift`
- Create: `KnitNote/CloudSync/RecentlyDeletedView.swift`
- Create: `KnitNote/CloudSync/SyncNeedsAttentionView.swift`
- Test: `Tests/KnitNoteCoreTests/CloudSyncUIContractTests.swift`
- Test: `Tests/KnitNoteMacUITests/CloudSyncSettingsUITests.swift`

**Interfaces:**
- Consumes: `CloudSyncPresentationStore`, store restore/purge APIs, `[SyncConflict]`.

- [ ] Write failing source/UI contract tests for status, last success, pending count, immediate sync, iCloud sign-in/quota guidance, recently deleted restore, duplicate comparison, and attachment-version resolution.
- [ ] Run targeted tests; expect RED.
- [ ] Build nonblocking views. “已同步” requires empty journal and complete fetch/send success; offline issues remain informational. Conflict resolution emits a new mutation and does not directly delete the unselected attachment.
- [ ] Add VoiceOver labels, Dynamic Type layouts, keyboard access on macOS, and empty/loading/error states with deterministic UI-test fixtures.
- [ ] Run core UI contracts, macOS UI tests, iPhone/iPad simulator smoke tests, and full tests; expect PASS.
- [ ] Commit with `git commit -m "feat: add iCloud sync management UI"`.

### Task 3: Localization and privacy-safe diagnostics

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Create: `Sources/KnitNoteCore/CloudSync/SyncDiagnostic.swift`
- Test: `Tests/KnitNoteCoreTests/SyncLocalizationContractTests.swift`
- Test: `Tests/KnitNoteCoreTests/SyncDiagnosticTests.swift`

**Interfaces:**
- Produces semantic `SyncDiagnosticCode` and redacted `SyncDiagnosticEvent`.

- [ ] Write failing tests requiring all shipped localization keys, Traditional Chinese and English first-class values, placeholder parity, and rejection of user text, account IDs, record names, paths, or attachment filenames in diagnostics.
- [ ] Run focused tests; expect RED.
- [ ] Add strings for statuses, guidance, recently deleted, conflicts, restore, vault expiry, and accessibility. Implement diagnostics using category codes, counts, platform, schema version, and irreversible identifier hashes only.
- [ ] Run localization, privacy manifest, diagnostics, VoiceOver contracts, and full tests; expect PASS.
- [ ] Commit with `git commit -m "feat: localize safe sync diagnostics"`.

### Task 4: Backup restore and Watch post-merge integration

**Files:**
- Modify: `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift`
- Test: `Tests/KnitNoteCoreTests/BackupSyncImportTests.swift`
- Test: `Tests/KnitNoteCoreTests/CloudMergeWatchRegressionTests.swift`

**Interfaces:**
- Consumes: validated restored `ProjectArchive`, `SyncMutationSink`, committed merged store generation.
- Produces: one `SyncImportTransaction` per successful restore and one Watch snapshot publication per committed relevant merge.

- [ ] Write failing tests proving restore publishes only after installation commit, rollback publishes nothing, a restored archive merges by UUID, cloud merge triggers one Watch snapshot, and duplicate/old Watch commands remain exactly-once.
- [ ] Run focused tests; expect RED.
- [ ] Add a single post-restore publication hook after backup commit. Coalesce remote batch mutations into one store generation and publish Watch snapshot only after atomic local commit; preserve pending reminder queue, schema rejection, revision, prepared command, and ledger precedence.
- [ ] Run backup, Watch, reminder, sync, and full tests; expect PASS.
- [ ] Commit with `git commit -m "feat: preserve backup and Watch across cloud sync"`.

### Task 5: Release contracts and automated fault matrix

**Files:**
- Create: `Tests/KnitNoteCoreTests/CloudSyncReleaseContractTests.swift`
- Create: `AppStore/CloudSyncReleaseVerification.md`
- Modify: `AppStore/release_audit.sh`
- Modify: `project.yml`

**Interfaces:**
- Produces candidate-bound automated checks and a manual evidence ledger.

- [ ] Write failing contract tests for container parity, no Watch CloudKit entitlement, remote notifications, privacy declarations, source revision, schema version, migration floor, screenshot isolation, and release configuration.
- [ ] Add deterministic fake-transport fault scenarios: duplicate/out-of-order delivery, child-before-parent, asset-later, hash mismatch, quota, rate limit, zone reset, termination at every transaction phase, A→B→A account transition, and 30-day clock boundary.
- [ ] Extend `release_audit.sh` to print and verify full SHA, marketing/build versions for iOS/macOS/Watch, entitlement files, container identifier, privacy manifests, packaged Watch app, and the exact test result bundle. It must never deploy schema, upload, or submit.
- [ ] Run `bash -n AppStore/release_audit.sh`, all contract/fault tests, full `swift test`, macOS tests, generic iOS/watchOS/macOS builds, and `git diff --check`; expect PASS.
- [ ] Commit with `git commit -m "test: audit cross-device sync release gates"`.

### Task 6: Development environment and physical acceptance

**Files:**
- Modify: `AppStore/CloudSyncReleaseVerification.md`

**Interfaces:**
- Consumes one immutable release-candidate full SHA and archive set.
- Produces signed evidence rows; no source changes after candidate selection.

- [ ] Record the exact full SHA, marketing version, build, Xcode version, CloudKit development schema identifier, container, and device OS/build identities before testing.
- [ ] On one iPhone, one iPad, and one Mac using the same test Apple ID, verify local-only bootstrap, cloud-only bootstrap, three-device existing-data union, bidirectional sync, and same/different-field offline concurrency.
- [ ] Verify large PDF, project/yarn/label/journal photos, pattern markup, asset conflict preservation, delayed download, interrupted upload/download, quota failure, and recovery.
- [ ] Verify synchronized delete, restore, controlled-clock 30-day purge, referenced-yarn survival, and stale-device non-resurrection.
- [ ] Verify iCloud sign-out, A→B switch, no old-data visibility/upload, B→A switch-back recovery, wrong-account vault rejection, and controlled expiry cleanup.
- [ ] Pair Apple Watch with the tested iPhone; verify Mac/iPad changes reach Watch through the iPhone and reminder queue/schema/revision/exactly-once behavior remains correct.
- [ ] Perform overwrite-install from each supported released archive/schema on iPhone, iPad, and Mac; verify projects, six counters, reminders, yarn links, photos, patterns, markup, backup export, and restore.
- [ ] Re-run release audit against the unchanged candidate. If any source, configuration, CloudKit schema, entitlement, archive, version, or build changes, invalidate all acceptance evidence and restart from candidate selection.
- [ ] Commit only the completed verification ledger with `git commit -m "docs: record cross-device sync acceptance"`.

### Task 7: Manual production gates

**Files:**
- Modify only after authorization: `AppStore/CloudSyncReleaseVerification.md`

- [ ] Present the reviewed development-to-production CloudKit schema diff, container ID, candidate SHA, test totals, physical matrix, privacy answers, localized release notes, and rollback plan to the user.
- [ ] Wait for explicit authorization before deploying the production CloudKit schema.
- [ ] After authorized deployment, perform a read-only production schema verification and record the result; do not upload a build under the same authorization.
- [ ] Wait for separate explicit authorization before uploading the exact candidate build.
- [ ] Re-read App Store Connect selected builds, privacy/export declarations, localized fields, and processing status; record actual state without treating upload as submission.
- [ ] Wait for separate explicit authorization before submitting for App Review.

Final gate: completion requires the same immutable candidate to retain passing automated checks, development/production schema verification, and iPhone/iPad/Mac/Watch physical acceptance. Any candidate mutation resets the gate.
