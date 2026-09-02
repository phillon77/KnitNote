# Cross-Device Sync 3: Migration and Account Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Safely bootstrap existing local data, install merged remote data atomically, support 30-day deletion, and isolate iCloud accounts with encrypted pending-change recovery.

**Architecture:** Migration exports existing schema-14 content into staging, merges before upload, and installs through transaction manifests modeled after the backup service. Each CloudKit user record ID owns separate state roots; account changes close the old store before opening the new one, and only unsent data is retained in a 30-day encrypted vault.

**Tech Stack:** Swift 6, Foundation, CryptoKit, Security, Swift Testing

**Spec:** `docs/superpowers/specs/2026-09-02-cross-device-icloud-sync-design.md`

## Global Constraints

- Complete Plans 1 and 2 first.
- Preserve every supported legacy archive and current schema 14 input.
- Never upload local records before the first cloud fetch and merge completes.
- Different UUIDs remain separate even when names match.
- Account data never crosses CloudKit user record IDs.
- Decrypted account-vault content never remains after sign-out handling completes.

---

### Task 1: Domain export and duplicate hints

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/ProjectArchiveSyncMapper.swift`
- Create: `Sources/KnitNoteCore/CloudSync/PossibleDuplicateDetector.swift`
- Test: `Tests/KnitNoteCoreTests/ProjectArchiveSyncMapperTests.swift`

**Interfaces:**
- Produces: `ProjectArchiveSyncMapper.export(archive:liveRoot:deviceID:) throws -> SyncExportPackage`, `record(for:)`, and `materialize(records:attachments:baseArchive:) throws -> ProjectArchiveSyncMaterialization`.

- [ ] Write failing fixtures covering projects, all six counters, reminders, row notes, journals, yarn links, photos, pattern assets/usages/markup, and two same-name different-UUID projects.
- [ ] Run `swift test --filter ProjectArchiveSyncMapperTests`; expect missing mapper failure.
- [ ] Implement `SyncExportPackage(records:attachments:possibleDuplicates:)`; derive stable entity IDs from existing UUIDs, hash assets without moving them, emit link records instead of embedded yarn deletion semantics, and use duplicate detection only for hints. Implement the inverse materializer in the same mapper: rebuild archive collections by UUID, reject missing required parents, resolve attachment metadata only to verified staged files, and preserve unsupported local-only cache fields from `baseArchive` without emitting them as sync records. Conform the mapper to Plan 2's `SyncRecordProvider`.
- [ ] Run exporter, backup, migration, yarn, pattern, and reminder tests; expect PASS.
- [ ] Commit with `git commit -m "feat: export existing archives for sync"`.

### Task 2: Bootstrap transaction and migration receipt

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncBootstrapTransaction.swift`
- Test: `Tests/KnitNoteCoreTests/SyncBootstrapTransactionTests.swift`

**Interfaces:**
- Consumes: `SyncExportPackage`, remote `[SyncRecord]`, `SyncMergeEngine`.
- Produces: `SyncBootstrapTransaction.prepare`, `install`, `commit`, `rollback`, `recoverInterruptedInstallation`.

- [ ] Write failing tests for local-only, cloud-only, both-sides, three-device union, same UUID merge, different UUID preservation, every interruption hook, and receipt idempotency.
- [ ] Run focused tests and verify RED.
- [ ] Implement a versioned transaction manifest with `prepared`, `installed`, and `committed` phases. Stage merged archive and files under `.KnitNote-SyncBootstrap`, validate with the same archive/domain checks as backup restore, atomically replace live data, then write a receipt containing account ID hash and source archive fingerprint.
- [ ] Run bootstrap, backup rollback, pattern migration, and full tests; expect PASS.
- [ ] Commit with `git commit -m "feat: bootstrap existing data into sync"`.

### Task 3: Recent deletion and anti-resurrection ledger

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncDeletionPolicy.swift`
- Create: `Sources/KnitNoteCore/CloudSync/SyncDeletionLedger.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Test: `Tests/KnitNoteCoreTests/SyncDeletionPolicyTests.swift`

**Interfaces:**
- Produces: `SyncDeletionPolicy.evaluate(now:records:references:) -> SyncDeletionActions` and store restore/purge operations.

- [ ] Write failing clock-injected tests for delete propagation, restore at day 29, content purge at day 30, referenced-yarn preservation, attachment reference safety, and stale-device upload rejection by compact marker.
- [ ] Run focused tests and verify RED.
- [ ] Implement user-visible deleted records separately from compact `DeletionMarker`; purge content only after cloud acknowledgement and reference analysis, but retain marker through the supported offline compatibility window.
- [ ] Run deletion, project, yarn-link, backup, and full tests; expect PASS.
- [ ] Commit with `git commit -m "feat: add recoverable synchronized deletion"`.

### Task 4: Account-scoped storage roots

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncAccountIdentity.swift`
- Create: `Sources/KnitNoteCore/CloudSync/SyncAccountStorage.swift`
- Test: `Tests/KnitNoteCoreTests/SyncAccountStorageTests.swift`

**Interfaces:**
- Produces: `SyncAccountIdentity`, `SyncAccountStorage.open(identity:)`, `close()`, and paths for working set, journal, engine state, staging, quarantine, and vault.

- [ ] Write failing tests proving path separation for two accounts, no raw CloudKit user ID in filenames/logs, symlink rejection, and removal of decrypted staging on close.
- [ ] Run focused tests and verify RED.
- [ ] Implement account directory names as SHA-256 of container ID plus CloudKit user record name, validate every descendant with standardized-file containment checks, and make `close()` synchronously remove decrypted temporary data before returning.
- [ ] Run account and full tests; expect PASS.
- [ ] Commit with `git commit -m "feat: isolate sync storage by iCloud account"`.

### Task 5: Encrypted 30-day recovery vault and account transition

**Files:**
- Create: `Sources/KnitNoteCore/CloudSync/SyncRecoveryVault.swift`
- Create: `KnitNote/CloudSync/CloudAccountTransitionCoordinator.swift`
- Test: `Tests/KnitNoteCoreTests/SyncRecoveryVaultTests.swift`
- Test: `Tests/KnitNoteAppTests/CloudAccountTransitionCoordinatorTests.swift`

**Interfaces:**
- Produces: `SyncRecoveryVault.seal`, `restore`, `purgeExpired`; `CloudAccountTransitionCoordinator.transition(from:to:now:)`.

- [ ] Write failing tests for authenticated encryption, wrong account, wrong key, tampering, expiry, switch A→B, switch B→A, and CKSyncEngine pending-state reset with Plan 1 journal preservation.
- [ ] Run focused tests and verify RED.
- [ ] Implement AES.GCM encryption with a random per-vault key stored through an injected Keychain protocol. Bind account identity hash, created date, expiry date, payload hash, and format version as authenticated metadata. Transition order is stop old engine → close old store → seal only unsent payload → remove decrypted old roots → open new account root → fetch before send.
- [ ] Run vault, coordinator, bootstrap, full Swift tests, and macOS app tests; expect PASS.
- [ ] Commit with `git commit -m "feat: secure iCloud account transitions"` and run `git diff --check`.

Phase gate: independent security/data-loss review covers account-crossing attempts, wrong-key behavior, plaintext cleanup, migration rollback, and stale-device resurrection.
