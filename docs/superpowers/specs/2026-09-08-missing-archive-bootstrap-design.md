# Missing-archive bootstrap preparation design

Date: 2026-09-08. Status: technical design under the user's delegated routine implementation authority; not implemented, not cloud or release acceptance.

Baseline: `196404a` (production `1d7563dd9f67f9406a27db7b80ff57d2697b9e6e`), isolated `docs/cross-device-sync-design` worktree. Parent policy: `2026-09-06-cloud-sync-app-session-lifecycle-design.md` and `2026-09-07-app-session-owner-integration-design.md` in this directory.

## Scope and sequencing

Provide the Core preparation route required when an account's working directory exists but its archive has legitimately been removed by completed account isolation/recovery. The present account recovery deliberately restores pending mutations, immutable upload bytes and selected deletion evidence, not a usable archive. Current `SyncBootstrapTransaction.prepare` requires that archive, so an App collector alone cannot close the gap.

This is one independently testable part of actual remote-bootstrap integration. Transport full-fetch provenance, durable consumed input/ACK authority and stream ownership are the next App integration part, not proved by this Core route. Preserve the existing ordinary archive preparation API and its stricter round-trip checks. Do not publish an empty `JSONProjectStore` as a prerequisite.

Keep 1.7.0 (13), iOS 18/macOS 15/watchOS 11, existing record/journal/publication formats, FIFO mutation identity, merge/deletion rules, 100,000,000-byte file/authority limits and 64 MiB journal metadata limit. No live CloudKit, Keychain, device, signing, push, upload, schema or submission actions. No user data or worktree cleanup.

## Alternatives and ruling

1. **Recommended: explicit absent-source preparation in the existing transaction.** Preserve the actual original working tree, stage reconstruction, then use existing install/commit/rollback and canonical handoff. Add typed absence provenance to new transaction evidence while continuing to read existing v1 evidence. Cost: all transaction readers, including account recovery, must validate both evidence forms; malformed mixed forms must fail closed.
2. Create an empty archive in the live working directory and call existing preparation. Rejected: it changes original evidence before a recoverable transaction, pretends an archive was present, and risks a false-ready empty account.
3. Build a separate reconstruction installer. Rejected: duplicates swap/rollback/receipt authority and makes crash and account cleanup semantics diverge.

The technical format extension is limited to bootstrap transaction evidence. It must not reinterpret v1 archive hashes as absence hashes or change remote record, journal, publication, encryption or retention policies.

## Authority and entry point

Add an explicit `prepareReconstruction(remote:pendingSnapshot:counterReminderContext:)` entry to `SyncBootstrapTransaction`. It uses the same `SyncBootstrapContext` and validator as ordinary preparation. `pendingSnapshot` is required, including when the verified pending list is empty. The App caller must have positively confirmed account identity, completed account recovery and acquired its existing freeze before calling this API.

Core must independently check safe existing working directory, exact absence of `projects-v1.json` using no-follow filesystem evidence, unchanged full source-tree fingerprint and current context. Permission/IO errors, a dangling symlink, a directory at the archive path or a malformed archive are not absence. The existing ordinary `prepare` must continue to reject missing archives.

Unresolved publication/canonical evidence is not authority to reconstruct from scratch. The lifecycle must first invoke existing interrupted-bootstrap/daily-canonical recovery selection. A valid selected temporary candidate must be recovered; an unrelated or corrupt candidate remains blocked. The reconstruction entry must reject contradictory remaining archive/publication/canonical authority rather than deleting or bypassing it. This route does not classify arbitrary old local data as an account working set.

The remote snapshot still has the current Core input contract: exact context, complete records and verified attachment sources. The App must not set completeness from a successful incremental fetch; this Core API does not certify CloudKit inventory completeness.

## Pending reconstruction and materialization

Preserve the complete original working tree as `Original`, copy it to `Staged`, and retain immutable pending upload source URLs and byte identities. Validate pending mutations using the existing journal validation and preserve original FIFO mutation IDs; legacy standalone reminder pending remains `pendingRepair` as in ordinary bootstrap.

Use the existing `SyncMergeEngine.merge(local:remote:pendingLocalMutations:counterReminderContext:)` with no local archive-derived records, the complete remote record set and the actual pending snapshot. Do not separately invent latest-record selection or rewrite mutation IDs. The merge engine's `replayingPendingMutations` is the existing authority for FIFO saves/deletes; mutation records absent from remote must still participate. Include a regression for a pending-only project graph, not just pending edits of remote-present records.

An empty in-memory `ProjectArchive` may serve solely as mapper metadata base for this explicit absence route. It is not written to live storage, passed off as a source archive, published to UI, or used as proof that remote is empty. The materialized merged archive and referenced files must pass existing full graph/media validation before installation. Missing parents, incomplete six-counter aggregates, unresolved attachment bytes and illegal deletions block with original evidence intact.

Use both remote verified sources and every pending attachment source; reject version-ID/digest/size disagreement and reverify bytes on staging. Preserve staged original deletion evidence. Continue existing incoming-deletion witness validation rather than silently dropping unsupported retained domains. Do not weaken a validator merely to make reconstruction succeed.

Produce the existing canonical checkpoint, attachment/Watch evidence, pending enqueue plan and real canonical handoff. No transport ACK capability is issued by this task.

## Versioned source evidence

Existing v1 manifests/receipts remain archive-bound and decode unchanged. New absence transactions use a v2 manifest with an explicit source discriminator and full original-tree fingerprint. The absence proof binds account, live path, source tree and archive absence; it must be distinguishable from an archive digest in both manifest and receipt validation.

Expose `SyncBootstrapSourceProof: Equatable, Sendable` with cases `archive(sha256: Data)` and `missingArchive(treeSHA256: Data)`, and `SyncBootstrapReceipt.sourceProof`. The old `sourceArchiveFingerprint` accessor becomes `Data?`: archive proof returns its digest; absence returns nil. Repository search finds no callers outside this transaction file. This explicit API correction is preferable to a fabricated hash; all clients must compile against it.

Use custom evidence encoding/decoding. Ordinary archive transactions continue writing the exact v1 shape: manifest `version: 1` and `sourceArchiveFingerprint`, receipt with the original three fields and no new version key. Absent-source manifests write `version: 2`, `sourceKind: "missingArchive"`, `sourceTreeFingerprint`, and omit `sourceArchiveFingerprint`. Their receipts write `formatVersion: 2`, the same source discriminator/tree fingerprint, transaction ID and account hash, omitting the archive hash. Missing receipt version means legacy v1 only when its archive hash exists. Reject unknown versions/kinds and contradictory source fields; never default a malformed new receipt to v1. The tree digest uses the existing `sourceFingerprint()` inventory encoding.

All readers must share validation of source kind, supported version, 32-byte digest, original inventory and absence/presence consistency. In particular, update `validateTerminalRecovery`, `decodeManifest`, `readReceipt`, current-context recovery and canonical handoff together; testing only fresh prepare/commit is insufficient. V2 absence requires no `projects-v1.json` file or directory entry and an exact original-inventory tree digest; v1 requires the original archive digest to match.

The original inventory is still real and nonoptional. Installation always moves an existing working directory, so existing displaced-tree rollback can restore exact pre-reconstruction bytes, including the absence of an archive. The transaction must not create fake source content to simplify this path.

## Failure and restart contract

Context/freeze changes reject new work. Already-entered synchronous durable boundaries retain existing linearized ownership checks. Failure before install leaves live bytes unchanged. Failed/interrupted install restores the exact original missing-archive tree through existing rollback. A committed reconstruction returns the existing validated handoff under freshly verified context after restart.

All existing boundaries must be exercised: prepared, first move, staged move, installed, journal, receipt, rollback intent, failed move and original restore. Reject tampered source kind, source digest, account/path, mixed v1/v2 fields and changed original inventory. Preserve evidence on rejection.

## Acceptance tests

- Ordinary preparation still rejects absent/corrupt source; existing v1 fixtures and recovery remain valid.
- Actual complete populated remote + empty pending reconstructs a usable canonical store without a preexisting archive.
- Actual complete empty remote + verified empty pending produces a genuinely empty installed result, but only after transaction commit.
- Remote-only and pending-only projects, overlapping edits and pending attachment bytes survive with exact original mutation identities and ordering.
- Missing parent/media, malformed pending, legacy reminder pending, source mutation, archive appearing during preparation, symlink/path hazards and stale context do not install or lose original bytes.
- Every crash boundary recovers original or committed result; committed restart activates through actual `JSONProjectStore` canonical activation, not a fake success callback.
- Terminal account recovery validates new committed/rolled-back evidence while unchanged v1 evidence stays readable.
- No test invokes live factories; focused TDD and independent review precede one frozen full validation after the cohesive integration work.

## Explicit downstream obligations

The full-fetch collector must independently bind fresh source provenance and exact account/zone/request/batch membership, reduce hard deletes correctly, retain incoming evidence under backpressure, and durably link consumption to committed installation before any ACK/send readiness. A successful delta is never complete authority. Main-session startup must transfer one event consumer and retain real stop/join semantics.

Canonical probe Minor1 remains open until four cases are covered: valid temporary only, exact current temporary, unrelated valid same-account temporary, and legitimate interrupted daily candidate. The live helper's container/account binding remains a separate pre-live acceptance gate.

Self-review: this document specifies one existing installer, exact backward-readable source-evidence forms, explicit receipt API semantics and no new product policy. Transport design is being evaluated independently before integration is scheduled. Its remaining decisions do not authorize Core to infer remote completeness or issue an ACK.
