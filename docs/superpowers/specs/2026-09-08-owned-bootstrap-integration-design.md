# Owned bootstrap execution and predecessor lineage

2026-09-08. Architectural direction accepted by the user's next-step request after design commit d0019f0. The implementation plan records the subsequent empty-before-root interruption clarification for review. Source baseline: 7d1f5962f71ad5051d502fe336fa8299fed93ef3. This document changes no production behavior and is not test or release evidence. Automatic delegation remains paused.

Extends `2026-09-08-account-source-provenance-design.md` and consumes the completed output-planner, backup-package-planning, deletion-capture-program and publication-evidence-output designs. The executable integration is one Core unit; App/transport activation, live devices, signing, push and submission remain outside this approval.

## Decision

Use a v3 owned-bootstrap active manifest with a **linear hash-linked history**, plus an explicit durable `preparing` phase published **before** allocating the next transaction tree or writing a predecessor history record. A terminal predecessor history record contains that predecessor's exact terminal envelope bytes and exact frozen UUID-tree entries. Active manifests reference history hashes; they do not recursively embed previous histories.

If preparation fails before a normal prepared manifest exists, preserve its outputs and publish `abortedPreparation` with their exact frozen inventory, after proving that live source/journal are unchanged. An aborted preparation can become an immutable history predecessor just like a completed rollback. Installation remains the current install/commit/rollback implementation. No old transaction tree is deleted, and no arbitrary old UUID is admitted.

This version extension carries lineage and preparation authority. It is not a v3 change merely to duplicate source generation. Existing v1 archive and v2 missing-source bootstrap formats remain readable with their original rules; the account source control remains the separate two-file v2 control already being implemented.

## Minimal alternatives considered

| Approach | Why not selected / consequence |
| --- | --- |
| Retire old UUID trees before new prepare | Requires a new deletion/retirement authority and disposition policy for previous Original/Staged/Failed/validation outputs; expressly outside this correction |
| Admit all UUID directories when current terminal is valid | Cannot distinguish previous owned work from injected/orphan state; destroys the current terminal reader's ownership guarantee |
| Write immutable predecessor record, then publish only the final prepared manifest | Solves old-tree proof but leaves a crash gap while new Original/Staged/history files are being created; current active still cannot explain them |
| Publish preparing first, then complete predecessor record and outputs, then prepared or abortedPreparation | Selected. One current selector explains every new allocation; prior UUID trees remain independently exact and immutable |

## Exact wire contracts

Use the existing sorted-key bootstrap `Envelope(payload: Data, digest: Data)` and its SHA256 validation. Introduce v3 only for the owned path. The manifest payload has common bindings and an explicit phase payload; custom codecs reject unknown versions/phases, mixed phase fields, null required data, invalid relative paths and incorrectly sized hashes.

```swift
struct BootstrapHistoryRef: Codable, Equatable {
    let sha256: Data                 // exactly 32 bytes
    let byteCount: Int64             // 0 ... 100_000_000
    let recordCount: Int             // positive, exactly verified chain length
    let chainByteCount: Int64        // exact sum of distinct encoded record bytes
}

struct BootstrapHistoryRecordV1: Codable {
    let version: Int                // 1
    let accountIDHash: String
    let livePath: String
    let journalPath: String
    let transactionID: UUID
    let terminalEnvelope: Data      // exact old active bytes, terminal only
    let treeEntries: [SyncAccountRecoveryInventory.Entry]
    let previous: BootstrapHistoryRef?
}
```

Record path is fixed by content: `<bootstrap namespace>/History/<lowercase SHA256 hex>.json`. The record itself is a checksummed envelope; its filename/ref hash covers the exact encoded record envelope bytes. `treeEntries` are complete, sorted, unique account-relative entries for precisely the old `<UUID>/` subtree, including that UUID directory and every descendant when it exists. Only an abortedPreparation before any transaction-root creation may have an empty treeEntries: its frozenOutputEntries must also be empty and its exact UUID path must remain absent. Prepared/rolledBack predecessors always require their root and complete Original evidence. Record root/account/live/journal/UUID bindings must agree with its terminal envelope. Physical device/inode identity remains in these frozen entries because immutable predecessor directories must never be replaced; a new seal's complete inventory independently binds all physical identities again.

For a v3 predecessor, `previous` must equal the historyHead in that predecessor terminal envelope. A migrated v1/v2 predecessor has previous=nil. A record may contain only a terminal envelope with no embedded provisional predecessor bytes. Thus each historical manifest is stored once, and every link points to older records by digest. Identical record bytes use the same name; unequal existing bytes at that name reject without overwrite.

```swift
struct BootstrapManifestV3: Codable {
    let version: Int                // 3
    let id: UUID
    let context: SyncBootstrapContext
    let livePath: String
    let journalPath: String
    let sourceProof: SyncBootstrapSourceProof
    let original: [String: FileProof] // existing portable live-source proof map
    let historyHead: BootstrapHistoryRef?
    let body: Body
}

enum Body {
    case preparing(Preparing)
    case prepared(PreparedBody)
    case installed(PreparedBody)
    case committed(PreparedBody)
    case rollingBack(PreparedBody)
    case rolledBack(RolledBackBody)
    case abortedPreparation(AbortedPreparation)
}

struct Preparing {
    let sourceControlSHA256: Data?  // exact active source control; nil only valid legacy archive route
    let pendingSnapshotSHA256: Data
    let outputAllocation: OutputAllocation
    let predecessor: PendingHistoryRecord?
}
struct PendingHistoryRecord {
    let record: Data               // exact fully preflighted encoded history record
    let reference: BootstrapHistoryRef
}
struct OutputAllocation {
    let transactionID: UUID        // equals manifest.id
    let allowedRoles: [Role]       // exact unique enum values, not arbitrary prefix strings
    let roleLimits: [RoleLimit]
}
enum Role: String { case original, staged, attachments, validationOriginal, validationMerged }
struct RoleLimit {
    let role: Role
    let maximumEntryCount: Int
    let reservedEncodedProofBytes: Int64
}
struct PreparedBody {
    let installed: [String: FileProof]
    let mutations: [SyncMutation]
    let preparationSHA256: Data    // digest of the durable preparing payload
    let commitProgram: CommitProgram
    let originalLiveRoot: InstallRootIdentity
    let stagedRoot: InstallRootIdentity
}
struct AbortedPreparation {
    let preparationSHA256: Data
    let sourceControlSHA256: Data?
    let pendingSnapshotSHA256: Data
    let outputAllocation: OutputAllocation
    let frozenOutputEntries: [SyncAccountRecoveryInventory.Entry]
}
```

These are wire specifications, not requests to expose public constructors. `FileProof` is the existing bootstrap manifest proof `(bytes, digest)` with its directory sentinel. PreparedBody uses existing installed/mutations semantics; source proof remains explicitly tagged archive or missingArchive in v3, with the same contradictory source checks as current v1/v2. The existing receipt's source meaning remains unchanged; v3 does not require changing journal/publication/remote record formats. A receipt for a committed v3 manifest must still bind the same transaction/account/source proof, using the existing strict receipt codec rather than making v3 a synonym for missing archive.

The intended predecessor record is temporarily embedded only in preparing. Successful prepared and abortedPreparation replace it with historyHead; their payloads contain no PendingHistoryRecord. Therefore two sequential preparations cannot nest predecessor histories recursively. The per-attempt preparing payload may duplicate one predecessor envelope temporarily; budget it before publishing anything.

## What preparing positively owns

`preparing` authorizes creation of **one previously nonexistent transaction UUID tree** beneath the exact existing account/live bootstrap namespace. It does not grant authority for another UUID, another account, or arbitrary siblings. Top-level roles map exactly to `Original`, `Staged`, `Attachments`, `ValidationOriginal`, `ValidationMerged`; no caller-supplied names or additional roles. The private owned preparation capability is the only route passing those output roots to the existing copy/materialization/backup/deletion helpers.

Role authority is narrowly about allocation of preparation outputs, not a claim that partial output bytes are valid archives. Original files remain copies of manifest.original; full prepared readiness still requires exact Original and Staged validation as today. During incomplete preparation, partial regular files and the helpers' atomic-write temporaries can exist in the specifically allocated roles. They are never installable merely because they are inside the allocation. Their exact content is frozen only when aborting, under storage ownership and the still-held producer freeze. Ordinary user/domain writers are not admitted to this transaction-private allocation.

This is a positive ownership grant written before any output exists, comparable to a storage owner's designated temporary session. It is **not** a rule accepting an arbitrary UUID tree found later. Before publishing preparing, prove its UUID path absent via no-follow checks and prove there are no unaccounted siblings. After publication, unknown top-level roles, extra UUID siblings, symlinks, hardlinks, special files, replaced roots or changed historical tree entries reject without writes. All generated files retain existing per-file and inventory aggregate limits.

On abort, freezing partial output under this pre-issued allocation is allowed only while the unchanged live source and exact pending/source dependencies remain independently valid. A crash after the preparing barrier but before UUID creation freezes an empty output list and proves that UUID path absent; abort does not create a directory just to satisfy a terminal reader. An empty list never authorizes a subsequently appearing UUID path. No observed partial bytes are promoted to canonical data, returned as a bootstrap handoff, or substituted for pending media. If live or pending source changed, abort certification fails and preserves all evidence.

Preparation allocation does not require a per-chunk write-ahead protocol. Preparation abort validates allocated role bounds and unchanged sources rather than certifying partial bytes as valid content. Postinstallation commit has the stricter durable operation-prefix requirement specified below; preparing allocation alone never certifies Failed. Exact historical proofs begin at the freeze-to-terminal boundary; before that, the durable record proves allocated output ownership and source preservation, not output completion.

## Publication ordering and crash cases

Use fixed `active.json` and `active-next.json` slots in the bootstrap namespace for owned v3 publication. They are **bootstrap controls included in full account inventory**, not new excluded account recovery controls. Stop using an unannounced random `.active.json.<UUID>.tmp` for the owned active selector; existing generic writes retain their behavior.

1. Under caller freeze, read the current source and pending snapshot; validate current account/source control, bootstrap terminal and full prior history. A predecessor must be rolledBack or abortedPreparation. Committed remains alreadyCommitted. Snapshot the exact predecessor UUID tree and build/preflight its HistoryRecord in memory. Choose a fresh new UUID and prove it absent. No new transaction/history output has been created.
2. Build preparing with common original/source bindings, output allocation, prior historyHead and exact PendingHistoryRecord. Its predecessor terminal bytes are still the actual old main bytes used to construct the record. Recheck the old active/control/tree observations under storage ownership.
3. Write/sync active-next, compare old main and all source bindings again, rename next over active, sync bootstrap namespace and account ancestry, and reread/synchronize preparing. **No new transaction root or History record creation may occur until this barrier succeeds.** Current account generation validation stays outside the storage mutex, with pure comparison inside it.
4. Materialize the exact pending HistoryRecord at its fixed digest path. It is backed by the exact record bytes in durable preparing. If missing, create/sync it; if present with exact bytes, resynchronize; if an interrupted file contains an exact prefix of those bytes, complete/rewrite that derivative from the durable copy and synchronize. A different byte sequence, directory, link or oversize file rejects. A completed history record is immutable thereafter. Creating the History directory is authorized by preparing's exact pending record; it is not a place for arbitrary metadata.
5. Create the selected transaction UUID and permitted role directories, then execute the existing source copy, materialization, deletion retention and validation work. All these writes are explained by the selected preparing allocation. Existing helpers may not create bootstrap-namespace siblings; their work roots are explicit role children. No archive is moved into live in this phase.
6. Success: finish current validation, verify live/journal/source unchanged, Original exact, final Staged exact and every generated output role valid. Replace preparing with v3 prepared, historyHead set to the newly completed record. Preserve all previous UUID trees. Only after this prepared barrier may sourceSpent bind the existing transaction UUID and exact prepared manifest digest and the current installer perform its live move.
7. Failure/cancellation/restart while preparing: join all producing work, validate current selected preparing and complete its exact predecessor history record as in step 4, verify unchanged original live/journal/pending source, and read a complete bounded output inventory. Revalidate that inventory and all bindings, then atomically publish abortedPreparation with frozenOutputEntries and final historyHead. Do not delete outputs or construct an archive. Reissue active absent-source provenance if the original source was legitimately absent; an archive source remains an archive source.

Crash interpretation:

| Durable state | Safe action |
| --- | --- |
| Old terminal main; incomplete/new active-next; no new UUID/history outputs | Old main stays authoritative. Retry may rebuild the bounded derivative after revalidating old main/source. No new output could have started under the required ordering |
| Old terminal main plus an unexplained new UUID/history output | Reject: the output-before-publication invariant was violated; never infer preparing from those files |
| preparing visible but its directory fsync previously failed | Revalidate and resynchronize the exact main before any output write; visible is not sufficient |
| preparing and missing/partial exact intended History record | Reconstruct only the declared record from preparing's durable exact bytes; no previous data is removed |
| preparing with partial Original/Staged/validation output | Stop/join writers and certify abortedPreparation only after unchanged source and exact current output snapshot pass |
| complete prepared or terminal visible after failed selector fsync | Revalidate and resynchronize the exact selected state before install, abort, source handoff or seal |
| missing/corrupt current main with partial next during the **first ever** bootstrap selector initialization | Fail closed without issuing fresh bootstrap authority or deleting files. No transaction/history output was allowed before the initial preparing barrier, so no new source data should depend on this derivative |

The first-initialization partial-selector case is explicitly bounded and fail-closed, analogous to the chosen account-directory allocation interruption boundary. It does not excuse later output or orphan-history nodes. If automatic recovery of a mainless first selector is required, that requires an additional durable reservation in the account source control before initial publication; do not claim it is solved by trusting next alone.

## History selection and recovery validation

Validation is iterative with a single shared budget; never recursively decode a record's embedded terminal envelope into another copy of its entire history. Start from active.historyHead (or preparing's old head plus its exactly declared pending record), maintain visited hashes and UUIDs, and enforce:

- Every record filename, envelope digest, byte count and declared chain totals match exact bytes. Every next link decreases remaining count/byte total consistently; cycles, duplicates and overflows reject.
- Every historical terminal envelope passes the same pure source/binding checks for its own version. Only rolledBack/abortedPreparation predecessors are allowed. A committed predecessor is not an allowed retry lineage and must not be introduced by an old record.
- Every recorded tree entry belongs to exactly that record's transaction UUID, is complete/sorted/unique and passes existing no-follow/path/file-kind/size constraints. Actual predecessor tree equals the exact record snapshot; no additional/missing/changed file or physical directory substitution is accepted.
- For rolledBack predecessor, its own Original proof map/source evidence is valid and its frozen tree contains the exact Original tree. Do **not** compare every historical original against today's live tree: the historical tree is frozen evidence, and newer legitimate generations may differ. The selected current source alone must match live/pending baseline.
- For abortedPreparation predecessor, the terminal frozenOutputEntries exactly match its history tree snapshot, its allowedRoles/source bindings are valid, and it proves no install phase was reached. Partial Original does not masquerade as a complete rollback Original.
- The namespace's allowed set is the exact active control names, selected current UUID/role state, History directory plus referenced record names, and the exact historical UUID entries in validated records. Unknown History records and extra UUID siblings reject. Preparing adds only its one declared pending history record and one allocated UUID.

A terminal reader returns a typed current terminal observation plus the exact ordered encoded history records. Recovery Inventory v2 must embed these bounded record bytes alongside the selected current bootstrap envelope. After account cleanup, authenticated decode validates source/history against embedded inventory entries and these embedded bytes; it never needs already-deleted plaintext history. Count all their JSON/Base64 overhead in preflight.

Wire clarification for the owned integration: Inventory v2 adds an optional `bootstrapEvidence` object with exactly required `activeEnvelope: Data` and `historyRecords: [Data]` fields; records are exact encoded envelopes in newest-first chain order, including an explicit empty array when no history exists. Omit the object on unchanged legacy/v2 paths. An absent bootstrap-origin source retains its existing `sourceAuthority.absent.evidence.rollbackEnvelope`; when both are present the bytes must exactly equal `bootstrapEvidence.activeEnvelope`. This deliberate current-envelope duplication is included at every Base64 layer in affordability accounting. Historical records remain the exact linear chain, not recursively duplicated. The fingerprint remains canonical `{entries,sourceAuthority}`; complete authenticated validation must bind active/history bytes to their exact inventory Entry hashes, selected names, terminal bindings and chain. A committed source uses existing archive sourceAuthority and the actual sourceSpent control bytes in Envelope v2 sourceControl, not a new spent authority tag or replacement absent source. Encoding-only shared seams may precede the complete validator, but runtime capture/decode must keep rejecting unsupported evidence until the writer and authenticated terminal/history path are complete.

Cleanup remains the existing authenticated account recovery transaction, exact current physical inventory and repeated intent/vault barriers. History metadata or preparing output allocation alone authorizes no deletion. Restore still replays only selected pending/deletion source, never historical bootstrap trees or partial outputs. After restore, normal atomic consumed-selection provenance is sufficient; no historical manifest remains necessary to authorize the restored source.

## Account source and prepared digest integration

Task 1's absentSource/sourceSpent states remain sufficient. Source provenance originating from bootstrap needs a typed terminal kind at interpretation: rolledBack or abortedPreparation. The account control may keep its compact bootstrap-origin transaction/envelope digest; exact phase and evidence live in the selected bootstrap envelope and authenticated inventory. Do not add a public “aborted=true” override.

For preparing/abortedPreparation, bind the starting active source control digest and pending snapshot. An interrupted abort-to-source-handoff can be retried only against that exact original source state or the exact already-issued terminal origin. A conflicting selection, spent generation, changed source or different transaction blocks.

`pendingSnapshotSHA256` uses the existing `SyncAccountSourceBaseline.digest` domain: initial observed entries/accountRoot/journalURL, native packet mutations, selected packet files plus deletion files, deletionLedger and pendingMarkerVersions. This intentionally binds portable source and ordered pending/deletion content using the existing codec. It is not packet-only SHA256 and not complete-inventory SHA256: packet-only omits deletion selection, while complete inventory changes when the owned preparation adds its declared outputs. Later unchanged-source validation recomputes the same baseline; current control digest and full physical ownership/inventory comparisons remain separate obligations.

Normal prepared/installed/committed/rollback continues sourceSpent(UUID, preparedManifestDigest). The v3 prepared digest includes historyHead, original, installed, mutations and the preparation digest, so its lineage is part of the bound immutable preparation. For rolledBack unwrap its PreparedBody and exclude only frozenTransactionEntries; otherwise normalize phase only when checking later phases; do not reinterpret v3 as old v2 or omit its historyHead.

Preserve a terminal envelope's exact historical context while it is an active source origin. For a later owned retry, validate the old terminal using its historical context under the freshly verified current owner, then snapshot it into the new history record; the new preparing/current transaction uses the new context. Do not rewrite the historical terminal in place merely to satisfy current-context loadManifest. Generic v1/v2 current-context methods retain their ordinary rules. This avoids invalidating the source origin envelope digest or previously bound history hashes.

## Compatibility and necessary narrow reader changes

- Read existing v1/v2 terminal bootstrap without History as today. A first owned retry of a valid legacy rolledBack tree writes its exact terminal bytes into the first HistoryRecord, then uses v3 preparing. Existing unaccounted old UUIDs are not retroactively certified; they remain unresolved.
- Existing `validateTerminalRecovery`'s single-current-UUID restriction becomes a typed exact-union check only for v3 lineage. The old-format reader is not loosened.
- Current `Inventory.compatibilityGate` rejects every `.tmp`/`.transaction.json` globally. A crash-created temporary in an explicitly allocated and later **frozen abortedPreparation output tree** therefore needs exact typed terminal classification before this generic unresolved-artifact gate. Permit only a path/entry proven in that terminal or immutable history record as abandoned preparation output. Keep canonical live candidate/publication guards and arbitrary temp files elsewhere unchanged. No suffix-wide exception is allowed.
- The existing backup validation helper catches failures and deletes its package root, and `SyncDurableFile.write` removes its uncommitted temporary on ordinary thrown errors. The owned preparation route must retain its declared outputs for this no-deletion correction: execute the completed ordered helper programs through the private owned executor, including physical validation and synchronization, while leaving generic helpers unchanged. Do not call ordinary deleting wrappers and merely suppress their outer catch. A later authenticated account cleanup can remove exact captured outputs under the unchanged recovery policy. Do not silently rely on helper deletion to make the lineage validator pass.

## Bounds and complexity

Every bootstrap/control/history envelope and file remains bounded by 100,000,000 bytes; account recovery's existing aggregate encoded cap remains unchanged and includes history/proof/Base64 bytes. The account recovery control's 8192-byte cap is unchanged because no history body is stored there. No canonical, incoming, journal or attachment limit is relaxed.

Bound the chain by its exact aggregate encoded bytes and existing inventory entry/depth constraints; walk iteratively. No new retention duration or “keep last N” rule is introduced. If adding a predecessor would exceed the existing capture/metadata budget, fail before publishing preparing or creating new output, retain the terminal source and all history, and report the size limit. This is a capacity failure, not permission to prune old records.

Proof encoding grows linearly with retained transaction trees and their manifests. It can still be sizeable because history records duplicate manifests and tree metadata; account sealing must preflight that cost before admitting another owned preparation. Do not merely enforce the bound after generating a large tree that can no longer be sealed. Exact new media remains subject to existing data-size checks, while known output allocation/entry limits reserve metadata capacity for partial-output abort certification.

Concretely, preparing.roleLimits reserves an upper bound for the exact generated relative-path metadata, including both destination and possible temporary entries at interrupted helper boundaries. Derive Original from its existing proof map, Attachments from the merged source-version keys, Staged from original plus materialization/deletion/publication outputs, and validation packages from each archive's referenced media set and fixed package/manifest structure. UUID path overhead is fixed. Preflight canonical encoding of maximal-sized physical identity/file-proof fields for those path bounds, add the embedded abort envelope/history/Base64 expansion and selected recovery data overhead, and require the sum within the existing aggregate maximum. Helpers used by the owned route must expose/respect those construction bounds before running; if an output set cannot yet be bounded, stop before publishing preparing. Do not reserve an unspecified amount or allow a helper to allocate an unlimited child tree and discover the overflow only while aborting.

## Required regression/fault evidence for later implementation

1. Real rolledBack legacy v2 -> owned v3 prepare -> commit -> full account seal/cleanup/restore; old UUID tree remains exact until authenticated cleanup. An extra UUID and an unreferenced History record fail.
2. Two or more aborted/rolledBack attempts form a linear chain, not embedded recursive manifests. Altering the oldest record/tree invalidates current seal; missing/duplicated/cyclic links and wrong chain totals reject.
3. Fault before/after every preparing-next write/fsync/rename/parent fsync; prove no transaction/history outputs exist before successful preparing publication.
4. Crash during exact history-record write and each output role's partial generation; reopen, certify abortedPreparation without deleting or changing live/pending bytes, then full seal/cleanup/restore and retry.
5. Crash after aborted main but before source handoff; match exact source predecessor on retry. Current pending/attachment change, conflicting selection, sourceSpent mismatch or live archive change rejects.
6. Prepared->spent->install->rollback and new-context retry preserve exact historical digest; a committed archive later missing remains lost-data failure, never old absence.
7. Partial `.tmp` accepted only as an exact frozen abandoned output entry; same suffix in live canonical/source, undeclared role, or unrelated UUID rejects. Symlink/hardlink/physical replacement always rejects.
8. Capacity failure before preparing publication preserves old main/history/source bytes; 100,000,000-byte per-file semantics and aggregate preflight stay intact, including the prospective abort metadata budget.

The following execution and postinstallation contracts complete this design. The writer, terminal reader, source transitions and committed-plus-spent sealing must be reviewed together before the internal route becomes callable. No partial v3 runtime reader may ship ahead of its writer.

## Global constraints

- Baseline inspected: `7d1f5962f71ad5051d502fe336fa8299fed93ef3`, worktree `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`.
- Preserve version 1.7.0 (13), iOS18/macOS15/watchOS11; no signing, push, submission, live cloud/account/device use, schema change or App activation.
- Per-file/bootstrap/history/canonical/batch 100,000,000 bytes; journal 64MiB; incoming 128 batches/16MiB; control 8192 bytes; existing recovery aggregate cap unchanged.
- Preserve ordinary backup limits: archive20,000,000, manifest1,000,000, markup2,000,000/512 entries, media200,000,000, package4,000,000,000. Owned output intersects its independent100,000,000 file cap.
- Publication authority/tombstone16MiB, Watch1MiB, head64MiB; no invented count cap or retention duration.
- Caller holds producer freeze; context verification occurs outside synchronous account ownership; pure comparisons inside it. No lock across await and no recursive public sourceState/capture/context callback while holding storage ownership.
- No cleanup, unlink, pruning, arbitrary UUID adoption, source recreation from absence, fake `isJournalStaged` authority or test-only capability issuer. Retain outputs on first error; abort interrupted preparation instead of resuming it with new temporary identities.
- The public `remote.isComplete` Boolean remains insufficient transport provenance. This Core unit exposes no new public caller that blesses it; transport issuance and App factory activation remain separately gated.

## Verified current boundaries and decisions

The following completed implementations are consumed, not reimplemented:

```swift
SyncBootstrapOutputPlanner.plan(accountIDHash:livePathSHA256:transactionID:actions:maximumMetadataBytes:)
KnitNoteBackupService.planOwnedPackage(source:role:packageID:accountIDHash:livePathSHA256:transactionID:appVersion:now:maximumMetadataBytes:temporaryID:)
KnitNoteBackupService.validateFrozenPackageSource(_:source:)
SyncDeletionLedger.planIncomingCaptures(initial:requests:allocations:temporaryID:)
SyncAttachmentPublicationEvidenceFile.planSave(_:initial:temporaryID:)
```

Their outputs certify accounting and semantic projections only. None authorizes filesystem access or discharges physical mapper/backup validation. The first integration deliverable must actually execute their ordered programs through the real preparing barrier; no further standalone pure-helper release is proposed.

Remaining gaps that belong inside this integration unit:

1. **Materialization before physical staging:** `ProjectArchiveSyncMapper.materialize` lines202–355 requires staged sources and reads each attachment before checking that slot's destination, then checks required slots. It is not a pure preflight API. Add a shared internal projection path that accepts proofs and yields archive/records/file descriptors; retain the ordinary method's current per-slot validation/read/error order. Projection is explicitly unvalidated, and the owner reruns the existing physical mapper on its actual Attachments outputs before prepared. Do not construct nonexistent URLs with `isJournalStaged=true` merely to call the existing method.
2. **Complete direct prefix:** choose transaction/package/deletion/restoration/temp UUIDs in memory; enumerate Original and initial Staged copies, Attachments, materialized archive/media/checkpoint, helper outputs and all parents. Exact proof sources accompany ordered operations. Verify finite path/type/alias/precondition consistency once over the entire composition. Identity choice grants no ownership; UUID path absence must be re-proven immediately before preparing.
3. **Helper program execution:** backup returns actions with a role-root create. Deletion scratch may already require ValidationMerged. Composer creates each role once, consumes a helper's identical root declaration only as an already-established precondition, and otherwise preserves every action and its order. Record this one structural adaptation explicitly; never deduplicate writes, locks, validations or sync steps. Program-level deletion step indices stay local to that exact program, not accidentally shifted by global prefix length.
4. **History/receipts/state codecs:** v3 preparing/aborted/normal phases, linear exact history, active-next publisher, normalized prepared digest and typed terminal-origin evidence do not exist. Keep compact bootstrapRollback origin tag, interpreting rolledBack versus abortedPreparation from strict embedded v3 evidence; retain legacy evidence decoding with exact keys.
5. **Full lifetime affordability:** existing output planner reserves only supplied Entry metadata. It does not cover source-control snapshots, history/abort envelopes, Base64 nesting, pending/deletion bytes, live journal commit, receipt or rollback Failed/Displaced footprints. Full bound must precede preparing, including successful and failed postinstall shapes.
6. **Journal commit is an additional writer dependency:** existing `enqueueLocked` can stage attachments, append frames, migrate state, compact/checkpoint, emit proof shards, reset segments and clean/truncate under ordinary behavior. Its `copyAttachmentAtomically` and `defaultAtomicWrite` generate random temps and remove failed temps. A generic enqueue call cannot be assumed to fit the five preparation role reservations. Use an internal owned enqueue adapter sharing the actual journal reduction/encoding, with an exact precomputed operation trace and fixed temps, executed only at the current postinstall journal phase. Preserve ordinary enqueue behavior. Reuse precisely the existing account `recoverySnapshot` admission at lines1307–1315: base legacy journal URL absent, no partial final frame, and no unresolved cleanup intents. These are existing account recovery gates, not new arbitrary rejection of ordinary supported accounts. Clean segmented checkpoint versions1–5 remain supported. The exact operation mapping below preserves their upgrades and deterministic compaction decisions.

### Owned journal operation mapping and ordinary reopen contract

`preparedStateLocked` currently loads/migrates, repairs durability, then reconciles acknowledged attachments. The owned route uses the existing read-only segmented loader under the account recovery admission above. It proves cleanupIntents empty before execution and reruns that proof against actual installed files. The enqueue request contains saves/deletes only, never ACK/cleanup frames, so no cleanup intent can be created by this commit. Do not call or stub `reconcileAcknowledgedAttachmentsLocked`; use the exact proved-empty state. Do not mark an unperformed cleanup completed.

| Existing operation | Owned execution with exact predeclared trace | Reopen invariant |
| --- | --- | --- |
| `repairDurabilityIfNeededLocked` | synchronize existing checkpoint/segment/referenced shards and parent; no added paths | readable-but-uncertain bytes become durable before dependent effects |
| clean checkpoint v1 upgrade | shared `replaceLegacyHistoryCheckpointLocked` reduction: encode exact proof shards, then v4 checkpoint and empty segment via fixed-temp atomic replacements | same history/proof ordering, pending FIFO and completed cleanup metadata; ordinary loader sees v4 |
| clean checkpoint v2/v3 upgrade | shared `persistCheckpointLocked` reduction: append required proof shards, normalize existing completion metadata in memory, encode v4 checkpoint, atomic empty segment replacement | same root/count/throughSequence and pending data; older retained unselected shard files remain untouched |
| v4/v5 load | no migration; retain exact initial encoded files and semantic state | no new journal format |
| non-staged save attachment | fixed `<mutationUUID>-<versionUUID>.asset` destination, bounded fixed temp, verified copy then rename+parent sync; exact existing destination is reused | staged source URL matches the existing journal attachments-directory rule |
| already-staged save attachment | real `validatePersistedAttachmentSource`; no fabricated staged flag or copy | existing byte/hash/path validation remains |
| duplicate request | share effectiveProof/proofsMatch checks and skip exactly matching enqueue; no new source file | same deduplication result |
| append new frames | preflight exact current clean segment bytes and framed bytes; append once, fsync, parent sync if created | frame sequences/checksums/trailer unchanged; successful normal reopen replays exactly once |
| compaction threshold | use actual condition `framesSinceCheckpoint >= 256 && acknowledgedOperationCount * 2 >= enqueuedOperationCount`; publish unpersisted proof shards, checkpoint, then atomic empty segment replacement in current order | checkpoint throughSequence causes ordinary replay to ignore older retained segment frames if interrupted before reset |
| `truncateSegment` | unreachable for admitted clean initial state; after an interrupted owned append, owner rolls back before any journal reopen/second enqueue | torn frame remains only in exact frozen Failed tree; original clean live journal restored |
| temp error cleanup / source reclamation | no unlink/remove; retain partial exact allocated temp and stop execution | successful commit has no failed temp; interrupted commit must finish owned rollback before ordinary journal access |
| legacy base-envelope migration | no owned invocation, because base `url` already fails current account recovery admission | generic non-account journal still migrates with its existing `retainMigratedLegacyEnvelope` rename; no format support silently removed from current account route |

Atomic replacement of a predeclared mutable checkpoint or segment is an authorized state transition already allowed by the lineage design. It can shorten the new segment to empty; this differs from cleanup/unlink or ad hoc ftruncate. Previous source tree remains exact in Original and Displaced until existing rollback or authenticated cleanup. Every replacement names old proof, new exact bytes, fixed temp and required directory barrier, and is included in the prospective Failed capture footprint. No older proof shard, attachment or derivative is pruned.

Prove ordinary reopen using a new ordinary `FileSyncMutationJournal` on each successfully committed fixture, not the executor's cached state. Compare pending mutations/order, source URLs/bytes, duplicate detection, checkpoint/shard root and new enqueue/ACK behavior against an ordinary journal fixture with the same admitted initial state and requests. For failures after shard publication, checkpoint publication, empty-segment replacement and partial append, reopen through owned transaction first, finish existing rollback, then reopen the restored ordinary journal and compare the original pending state. Do not open the failed journal to let its normal repair path erase evidence.

### Retained failed commit output wire contract

The preparing allocation does not authorize installation `Failed`/`Displaced` paths. A failed postinstall journal copy can leave retained temp bytes inside Failed after exact rollback, so v3 rolledBack carries the following required evidence:

```swift
// v3 only: PreparedBody additionally stores this exact bounded phase program.
// Types are private wire types; construction grants no capability.
struct CommitProgram {
    let journalRelativePath: String
    let initialJournalDirectories: [String]
    let initialJournalFiles: [String: SyncBootstrapOutputProof]
    let operations: [CommitOperation]
}
enum CommitOperation {
    // Paths are live-relative fixed supported journal artifacts, or the fixed receipt.
    case synchronize(path: String)
    case directory(path: String)
    case reuse(path: String, proof: SyncBootstrapOutputProof)
    case replace(path: String, old: SyncBootstrapOutputProof?, bytes: Data, temporaryID: UUID)
    case copyAttachment(path: String, sourceVersionID: UUID, proof: SyncBootstrapOutputProof, temporaryID: UUID)
    case appendSegment(expected: SyncBootstrapOutputProof?, frames: Data)
}
// PreparedBody.commitProgram: CommitProgram is covered by normalized prepared digest.
// Initial paths are live-relative and form an exact portable journal subtree;
// projected device/inode values from synthetic Entries never enter authority.
struct InstallRootIdentity {
    let device: UInt64
    let inode: UInt64
}
// PreparedBody.originalLiveRoot and stagedRoot: InstallRootIdentity are actual
// no-follow directory observations captured at successful preparation.
// The existing Original subtree has its own independently verified identity.
// v3 only: replaces Body.rolledBack(PreparedBody) in the prior design.
struct RolledBackBody {
    let prepared: PreparedBody
    let frozenTransactionEntries: [SyncAccountRecoveryInventory.Entry]
}
// Body.rollingBack remains PreparedBody; Body.rolledBack becomes RolledBackBody.
```

CommitProgram must be encoded in durable prepared, not kept only in memory. All operation paths are live-relative and accepted only if equal to the exact journal base/segment/checkpoint/migrated/proof-shard/attachment naming family derived from journalRelativePath or the fixed `SyncMetadata/bootstrap-receipt.json`; arbitrary role/path strings reject. Its operation list uses strict phase/path/kind codecs and real journal encoders; receipt bytes use the existing strict receipt encoder. Reopen can derive exact permitted temp names and each operation's prefix state without inventing fresh IDs. Initial journal proof uses the already copied installed projection, portable across live/Failed moves. Actual originalLiveRoot and stagedRoot identities bind the legal live→Displaced→live and Staged→live→Failed moves across process restart; record them at prepared publication and include them in normalized prepared digest. Copy sources bind exact transaction Attachments version/proof, never an arbitrary path. The trace contains no generic caller-directed rename/delete. Root move permissions remain the fixed existing install/rollback algorithm.

The frozen entries cover the entire selected UUID tree, including the UUID directory, exact Original, remaining Staged/Attachments/validation outputs and phase-created Failed. Freeze only after existing rollback proves live equals Original and current ownership validates the exact selected prepared digest, matching spent UUID when issued (or exact initial unspent source for preinstall rollback), transaction/root identities, original source/pending evidence and legal install/commit prefix. Failed root is only the previously installed live directory moved by the same owner; its full entries must match the exact installed baseline modified by a prefix of CommitProgram. A torn append/write is permitted only at that prefix's last issued file operation, bounded by its declared bytes and exact output path; no following operation may have run. Unknown file, unplanned temp, directory replacement, wrong source or unmatched prefix rejects before terminal publication. On a restarted rollingBack phase, compare the observed live/Displaced/Failed placement against the existing legal move states and the same program; do not infer ownership merely from a directory named Failed. Persist no failed byte as valid canonical data. Later terminal capture must equal frozen entries; history record treeEntries must equal the same frozen snapshot. Repeated readback may synchronize but never refreeze a changed terminal tree. Normalized prepared digest unwraps `prepared` and normalizes its phase, excluding only this explicit terminal freeze extension; historyHead, preparation digest and exact CommitProgram remain included. Exact key validation rejects a rolledBack body lacking this required v3 evidence or any other phase containing it. Legacy v1/v2 remains unchanged.

This required wire contract applies only to the currently unwritten owned v3 format. Its Entry and Base64 costs join both prospective rolledBack and next pending-history budgets. Ordinary v1/v2 readers remain unchanged.


## Delivery checkpoints and acceptance

1. Compose the complete ordered attempt, shared unvalidated mapper projection, exact journal trace, v3 codecs and prospective full-recovery budget. No authority is issued by planning.
2. Publish and synchronize preparing before any UUID/history output; issue only a private synchronous executor; run actual mapper, backup, deletion and publication validation. Interrupted preparation freezes an exact aborted terminal after unchanged-source checks.
3. Reuse the existing installer/rollback through narrow phase adapters. Bind sourceSpent before the first live move; preserve terminal context and exact history bytes. Admit committed-plus-spent sealing only with matching receipt, transaction/prepared digest, present valid canonical archive, journal/export and complete history. Capture the actual spent control. Missing/corrupt committed archive never becomes absence. Exact typed terminal classification precedes the generic temporary-artifact gate, including frozen Failed entries only after restored Original equality.
4. Exercise all selector/history/output/spent/install/journal/receipt/rollback/reissue interruption boundaries, repeated retry chains and cap/cap+1 rejection. Verify ordinary journal reopen parity and unchanged helper error ordering. Independently review the coherent unit, then run relevant Core/App/root and unsigned platform checks for the same source candidate. App and transport remain inactive.

Authenticated decode after plaintext cleanup reconstructs exact terminal/history proof from embedded bytes and inventory entries. Historical or failed data is evidence only; restoration replays selected pending/deletion sources. No new cleanup authority, public trusted Boolean, source-state bypass or temporary-file suffix exception is allowed.

The integration implementation plan must give each checkpoint concrete tests, command context and review gates. The scratch planning draft is not execution authority. Current completion is design consolidation only: no new tests, source edits, device acceptance, push or submission are claimed.

## Main self-review

### Existing attachment filename compatibility clarification (implementation inspection)

The actual ordinary journal persisted-source validator accepts a safe regular direct child of its exact attachment directory; it does not require every preexisting child to use the new-copy mutationUUID-versionUUID.asset name. Owned initialJournalFiles must retain these admitted existing files rather than silently omit them or invent a new clean-account rejection. A noncanonical attachment filename is permitted only as an exact initial entry also present with the same proof in the installed projection. Reuse requires that exact initial proof; synchronization may name that exact recorded entry. No new noncanonical file may be created or copied, and replace is forbidden for every attachment child. New copyAttachment keeps the fixed generated filename and sourceVersion binding. Exact parent/UTF-8/alias and file limits remain; there is no arbitrary child adoption, nested-directory permission or temporary-file suffix exemption. Actual physical validation and complete inventory admission remain required by the owner.

Reviewed for source lifetime, phase ownership, historical immutability, old-format compatibility, bounded encoding and interruption recovery. Corrected the draft's ambiguous journal-relative comment: all commit operation paths are live-relative and constrained to exact journal artifacts or the fixed receipt. Prepared root identities are actual observations, never synthetic budget values. RolledBack requires its frozen evidence in v3; normalizing the prepared digest must retain commitProgram and root bindings. The existing first-ever mainless partial-selector case remains explicitly fail-closed, not automatically repaired.
