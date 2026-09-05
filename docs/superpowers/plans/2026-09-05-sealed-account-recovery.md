# Sealed Account Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete migration/account-safety Plan3 Task5 with authenticated pending recovery, seal-authorized plaintext cleanup, and a composed account-transition boundary.

**Architecture:** Separate cryptographic persistence from destructive ownership and engine lifecycle. A bounded typed pending packet retains exact journal mutations and verified source bytes; an account-locked transaction seals and verifies recovery before removing plaintext. The transition coordinator composes these real components and defers persistent engine reset until sealing succeeds. App UI activation and daily canonical checkpoint integration remain separately recorded Plan4 gates.

**Tech Stack:** Swift 6, CryptoKit AES.GCM, Security Keychain adapter, Foundation/Darwin, Swift Testing and existing app-hosted tests.

**Spec:** `docs/superpowers/specs/2026-09-02-cross-device-icloud-sync-design.md`, account lifecycle and recovery sections. Refines Task5 of `docs/superpowers/plans/2026-09-02-cross-device-sync-3-migration-account-safety.md`.

## Global Constraints

- Account data never crosses CloudKit user record IDs.
- Decrypted account-vault content never remains after sign-out handling completes.
- 立即停止 UI mutation publication 與舊帳號 sync engine。
- 舊資料永遠不自動匯入或上傳到新帳號。
- Recovery vault 使用 authenticated encryption、Keychain key、原帳號 identity gate 與 30 天期限。
- Any identity, key, authentication, expiry, capture, or cleanup failure blocks completion; never downgrade to plaintext import or erase the sole unsent copy.
- Correct destructive order: stop/invalidate/freeze; capture; durably seal and authenticate readback; remove old plaintext while ownership remains held; close; open new; fetch/merge before send.
- Seal only exact pending changes and necessary recovery dependencies, not a whole account archive or acknowledged journal history.
- No live account, cloud, Keychain, user-data deletion, push, archive, upload, or submission operations during implementation/tests. Tests use injected memory keys and temporary fixtures. A production Keychain adapter may be compiled and reviewed without invoking it.
- Reviewed storage uses one exclusive account owner and descriptor-relative no-follow validation. Its close removes only owned reconstructible decrypt temporaries; broader plaintext inventory includes accountRoot/.KnitNote-SyncBootstrap and working-set .sync-deletions. Six persistent roots are not exhaustive.
- Existing domain stop/freeze and daily canonical persistence require Plan4 integration. An injected domain lifecycle boundary is permitted, but journal packet, vault, storage cleanup and transport reset must be concrete composed implementations, not opaque callbacks pretending those operations succeeded.
- Preserve exact mutation identities, versions and attachment URLs on same-account recovery. No missing-journal acknowledgement, URL rewriting, raw-ID logging, or automatic legacy namespace migration.
- One relevant affected validation run per task; known full-suite/socket sandbox limitations remain final gates. Each task and one integrated review must pass before parentTask5 completion.

## Files and contracts

| File | Responsibility |
| --- | --- |
| `Sources/KnitNoteCore/CloudSync/SyncRecoveryVault.swift` | Authenticated bounded ciphertext persistence, per-vault injected key ownership, expiry. |
| `Sources/KnitNoteCore/CloudSync/SyncPendingRecoveryPacket.swift` | Typed exact pending journal and bounded account-owned attachment capture/validation. |
| `Sources/KnitNoteCore/CloudSync/SyncAccountRecoveryTransaction.swift` | Account-bound sealed receipt, persistent cleanup intent, same-account replay, selected recovery dependencies. |
| `Sources/KnitNoteCore/CloudSync/SyncAccountStorage.swift` | Narrow locked inventory/cleanup/install primitives preserving vault and lock ownership. |
| `Sources/KnitNoteCore/CloudSync/SyncDeletionLedger.swift` | Narrow selected unsent deletion/marker recovery export/import only if required by capture. |
| `KnitNote/CloudSync/CloudAccountTransitionCoordinator.swift` | Transition phases, domain lifecycle dependency, composition of real journal/vault/storage/transport. |
| `KnitNote/CloudSync/CloudSyncEngineTransport.swift` | Immediate stop/invalidation separated from durable reset; blocked sends until authorized new-account readiness. |
| `KnitNote/CloudSync/KnitNoteCloudSyncCoordinator.swift` | Account-event handoff and fetch/commit completion gate. |
| `KnitNote/CloudSync/KeychainSyncRecoveryVaultKeychain.swift` | Production injected key-store adapter, no invocation in tests. |

## Task 1: Authenticated vault and exact pending packet

**Files:** Create vault and packet files above; create `Tests/KnitNoteCoreTests/SyncRecoveryVaultTests.swift` and `Tests/KnitNoteCoreTests/SyncPendingRecoveryPacketTests.swift`.

**Interfaces:**

```swift
public protocol SyncRecoveryVaultKeychain: Sendable {
    func insert(_ key: Data, for vaultID: UUID) throws
    func key(for vaultID: UUID) throws -> Data?
    func remove(for vaultID: UUID) throws
}
// SyncRecoveryVault(directory:keychain:maximumPayloadBytes:) defaults to 100_000_000.
// seal(_:account:now:) -> UUID; restore(_:account:now:) -> Data;
// purgeExpired(account:now:) -> [UUID]. A UUID is NOT cleanup authority.
```

`SyncPendingRecoveryPacket` is Codable/Sendable and carries accountIDHash, exact `[SyncMutation]`, and verified account-relative file entries (path, byte count, SHA256, bytes). `capture(account:accountRoot:journal:)` reads `pending()` under the caller's freeze, not acknowledged frames. `encoded(maximumBytes:)` and decoding validate actual encoded size, identities, duplicate/path/hash constraints. Every attachment URL stays verbatim in its mutation; file entries must reconstruct that exact URL under the same account root. Supplemental selected-domain dependencies are Task2, not guessed from arbitrary files here.

```swift
let packet = try SyncPendingRecoveryPacket.capture(account: account, accountRoot: root, journal: journal)
let bytes = try packet.encoded(maximumBytes: 100_000_000)
let id = try vault.seal(bytes, account: account, now: now)
#expect(try vault.restore(id, account: account, now: now) == bytes)
#expect(throws: (any Error).self) { try vault.restore(id, account: otherAccount, now: now) }
```

- [ ] Add vault tests for same-account roundtrip, wrong account/key, authenticated metadata and ciphertext tampering, nonfinite dates, exact 30-day boundary, random independent keys, failed key persistence, interrupted durable write, unsafe paths and payload limit. Inspect failure before implementation.
- [ ] Add actual `FileSyncMutationJournal` packet tests: multiple immutable versions and deletes retained, acknowledged mutation absent, ordinary and already-staged sources, source replacement/escape/hash mismatch refusal, exact original URLs after encoded roundtrip. A journal-only packet is not yet permission to destroy account state.
- [ ] Run `CLANG_MODULE_CACHE_PATH=/tmp/plan3-clang-cache swift test --disable-sandbox --filter 'SyncRecoveryVaultTests|SyncPendingRecoveryPacketTests'`; record expected behavioral/API RED.
- [ ] Use AES256.GCM with a random per-vault key. Authenticate format version, vault UUID, account hash, created/expiry dates and payload hash. Key insertion must be durable and non-overwriting before ciphertext persistence; seal returns only after file/parent fsync and authenticated reopen. No plaintext temporary file. Cap plaintext at 100,000,000 bytes (configurable lower bound); oversized recovery blocks transition with original sources intact, not truncation.
- [ ] Validate expiry before restore; expiry purge removes only authenticated expired vault material and its key, with retryable interrupted cleanup. Never delete another account's material. Key/file failure must not falsely report complete cleanup.
- [ ] Run focused plus relevant existing journal-source tests once; commit `feat: persist authenticated pending recovery packets`. Report exact output, limitations and durable artifact ownership for Task2.

## Task 2: Seal-authorized account cleanup and recovery replay

**Files:** Create `SyncAccountRecoveryTransaction.swift`, `Tests/KnitNoteCoreTests/SyncAccountRecoveryTransactionTests.swift`; modify storage and narrowly scoped deletion-ledger recovery APIs/tests as needed.

**Interfaces:** Consume open `SyncAccountStorage.Paths`, its held ownership, Task1 vault/packet and the actual journal. Produce `SyncAccountRecoveryTransaction` prepare/seal/cleanup/recover operations with a non-forgeable-in-process sealed receipt binding account, vault UUID, exact packet hash and inventory fingerprint. Durable intent must be revalidated by authenticating the vault on crash recovery; an arbitrary caller UUID is never authorization.

Use an initializer bound to `storage`, `paths`, `account`, `vault`, and `journal`; expose `prepare(now:)`, `seal(_:now:)`, `cleanup(_:)`, `restore(vaultID:now:)`, and `recoverInterruptedTransition(now:)`. Prepared/sealed handle initializers are internal and their proofs are revalidated by the durable operations. This sequence is the destructive boundary:

```swift
let prepared = try transaction.prepare(now: now)
let sealed = try transaction.seal(prepared, now: now)
try transaction.cleanup(sealed)
try storage.close()
```

- [ ] Write real storage/journal/vault tests for old-account cleanup containing working data, pending attachments, bootstrap sibling and deletion recovery bytes. Assert no plaintext deletion before seal readback, no vault/key removal, and refusal after inventory mutation or account mismatch.
- [ ] Test each cut: before key/cipher persistence, after sealed intent before first unlink, during unlink, after cleanup before close, and after recovered files before journal enqueue. Reopen must preserve either original plaintext or authenticated exact recovery, never neither.
- [ ] Capture only pending payload plus selected deletion/marker dependencies associated with pending removal versions. Existing unresolved bootstrap/publication repair state must be explicitly settled or refused without cleanup; do not silently discard an unsupported recovery witness. Add actual pending-deletion retention roundtrip and pending marker preservation. Unknown/unproven dependencies fail closed, with a concrete compatibility gate rather than whole-archive sealing.
- [ ] Run `CLANG_MODULE_CACHE_PATH=/tmp/plan3-clang-cache swift test --disable-sandbox --filter 'SyncAccountRecoveryTransactionTests|SyncRecoveryVaultTests|SyncPendingRecoveryPacketTests|SyncAccountStorageTests|SyncDeletionLedgerTests'` and record RED.
- [ ] Fingerprint exact account-owned plaintext inventory while frozen; exclude encrypted vault and retained lock/ownership control paths, not arbitrary user-selected exclusions. Persist cleanup intent after sealed proof. Revalidate before descriptor-relative no-follow cleanup while lock remains held. Keep storage bindings usable for final close; complete cleanup and fsync before sign-out success.
- [ ] Same-account restore authenticates first, installs verified packet files to exact original owned paths, then uses actual journal enqueue retaining immutable identities. Cross-account restore is refused. Retry is idempotent; do not retire the encrypted sole copy before durable restored journal/dependencies. Current/new-account material cannot be overwritten by a stale receipt.
- [ ] Run focused and one affected storage/journal/deletion sweep; commit `feat: gate account cleanup on sealed recovery`. Document exact receipt/phase APIs for Task3 and every unsupported-state refusal.

## Task 3: Composed runtime account-transition gate

**Files:** Create coordinator and Keychain adapter above; modify transport/coordinator narrowly; create `Tests/KnitNoteAppTests/CloudAccountTransitionCoordinatorTests.swift` and extend existing transport account tests. If app project uses explicit membership, add only required file references.

**Interfaces:** `CloudAccountTransitionCoordinator.transition(from:to:now:)` consumes Task2 transaction and concrete old/new transport/journal/storage adapters. Define an explicit domain lifecycle protocol for stop/hide/freeze and validated current-account installation; Plan4 provides its app composition. Existing epoch and fetch receipt acknowledgements remain authority, not a new guessed Boolean. Keychain adapter implements Task1 protocol with a fixed service and per-vault UUID account, random key supplied by vault, and device-local key accessibility.

```swift
enum CloudAccountTransitionPhase {
    case stopping, frozen, sealed, cleaned, opening, fetching, ready, blocked
}
// Only ready may enable sends. Any throwing phase leaves completion false;
// sealed recovery remains available after cleanup even if opening/fetch fails.
```

- [ ] Add A→B and B→A composed tests using real temporary storage, real journal packets and crypto vault, plus the existing controllable transport driver. Verify old mutation IDs/bytes return only to A, B is empty/isolated, old callbacks cannot write, and no send occurs before the first fetch/merge receipt is committed.
- [ ] Test frozen-domain failure, sealing failure, cleanup failure, wrong/missing key, expired vault, cancellation and restart mid-transition. Every failure must retain sole recoverable data, keep new sends blocked and avoid claiming successful sign-out.
- [ ] Run the targeted app test command supported by the current project/scheme (record exact command and any build environment blocker before code); record behavioral RED. Unit-test Keychain mapping with injected Security-call adapter, never the live user keychain.
- [ ] Split `receiveAccountChange` into immediate epoch invalidation/detach/cancel and a seal-authorized durable engine/incoming reset. Account-change restart/send remains blocked until transition completion. Route coordinator account event to this boundary instead of independently clearing old durable state. Preserve journal truth through CKSyncEngine reset.
- [ ] Compose actual packet capture, sealed cleanup and same-account recovery; an opaque successful closure cannot replace those operations. Wire initial fetch/commit completion before enabling replay/send. Domain lifecycle callbacks are explicit integration gates, not proof that app UI and daily checkpointing are already enabled.
- [ ] Run vault/transaction/transport/coordinator targeted suites and one proportional platform validation; commit `feat: coordinate sealed iCloud account transitions`. Record any signing/toolchain constraints without live cloud operations.

## Parent completion

All three tasks need independent review, then one integrated security/data-loss review and any single unified fix/scoped review. Retain original parent and subplan rulings/gates for final reporting. ParentTask5 is not complete at a crypto-only checkpoint. Full Swift/platform validation, UI lifecycle/daily checkpoint, live CloudKit, physical matrix and release candidate approval remain separate gates; do not claim complete cross-device sync or submission.
