# Owned deletion content program implementation proposal

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Execute as one coherent deliverable with independent final review, not separately accepted tiny extractions.

**Goal:** Produce a finite data-only incoming-deletion program containing exact ledger snapshots, fixed restoration identities, write contents/copy sources, ordered output actions and explicit unfulfilled physical-validation jobs.

**Architecture:** Share real incoming selection, manifest reduction/encoding and restoration bodies with ordinary ledger code. Ordinary I/O/error order stays unchanged. The new planner consumes a complete frozen ledger tree and source proofs, performs no I/O and grants no authority. The future owner composes its actions with copied-tree/backup/publication actions and executes validation behind durable preparing in a separate change.

**Tech Stack:** Swift 6, Foundation/CryptoKit, Swift Testing, existing KnitNoteCore/Xcode targets.

**Spec:** `docs/superpowers/specs/2026-09-08-deletion-capture-program-design.md` (controller-approved under delegated technical authority). References under `docs/superpowers/specs/`: `2026-09-08-account-source-provenance-design.md`, `2026-09-08-bootstrap-output-planner-design.md`, `2026-09-08-backup-package-planning-design.md`.

## Global constraints

- Remain 1.7.0 (13), iOS 18/macOS 15/watchOS 11; no dependency/schema changes.
- Ledger envelope and owned files at most 100,000,000 bytes; preserve all existing limits. No arbitrary new entry cap, pruning or cap increase.
- Owned-only read-only preflight rejects outstanding purge intents before preparing/output. Ordinary initialization/purge remains unchanged.
- Future owned scratch lives under ValidationMerged and is retained, never Staged/live. This prerequisite has no executor and changes no cleanup.
- No sink/issuer, trusted boolean, dummy root URL, source-state/journal activation, account/Keychain/device/signing/merge/push/submission.
- Preserve ordinary source-read/validation/write ordering, callback points, locking, random-ID behavior and failure side effects. Pure extraction cannot move validation ahead of earlier physical checks.
- Preserve raw UTF-8 paths and ordinary `.sortedKeys` envelope bytes. Recovery export filters groups and uses different encoding: it is not a snapshot substitute.
- One compiler lane; retain user `.superpowers/absent-source-design-progress.md`; freeze sources for verification.

## Actual dependency map

`SyncBootstrapTransaction.retainIncomingDeletions` (769) initializes `.sync-deletions` in copied Staged and captures each media-free project with six counter children. Live supporting media still enters both validations, and an old matching group can supply retained attachment heads. Incoming media-free does not imply output media-free.

| Producer in SyncDeletionLedger.swift | Real effects that the future program must describe |
| --- | --- |
| init, 144 | Root/ancestors, `.ledger.json.lock`, optional initial manifest; existing ledger invokes completePurges and can unlink retained files. |
| live validation, 448 | Watch-aware merge, `.incoming-validation-UUID/<attachment UUID>` copies, actual mapper reads, archive comparison, defer cleanup. |
| stage, 168 | Fresh group dir even without media; required UUID.retained files/readback; inactive group append; ledger replacement. |
| restoration, 388 | Fresh child versions; `.incoming-restoration-validation-UUID/<supporting or child UUID>` copies; mapper reads and slot/path comparison; explicit/defer cleanup. |
| final capture lock, 417 | Exact prior/no-restoration/stage guard; prior-ID retained create or exact readback; final active incoming group and ledger replacement. Fresh stage directory/files remain. |
| each durable write | Distinct `.<target>.<UUID>.tmp`; ordinary failure cleanup. Existing no-clobber target also currently allocates/unlinks a temp. |
| each locked | Same `.ledger.json.lock`, not a new lock filename per acquisition. |

Plan initial manifest if absent, every stage/final manifest and distinct temp, empty stage dirs, complete scratch copies, and prior retained create/reuse. Preserve initial historical/unreferenced files in the full tree. Ordinary restore/publication methods are outside this helper and unchanged.

## Concrete new internal data API

Create `Sources/KnitNoteCore/CloudSync/SyncDeletionCaptureProgram.swift`. Values are not Codable, not certificates. Frozen paths are relative to `.sync-deletions`; output action paths use existing role-relative conventions.

```swift
enum SyncDeletionFrozenLedger {
    case absent
    case present(manifestBytes: Data, directories: Set<String>,
                 files: [String: SyncBootstrapOutputProof])
}
struct SyncDeletionCaptureRequest {
    let domain: SyncDeletedDomain
    let exactRemovalVersions: [SyncRecordVersion]
    let deletedAt: Date
    let currentRecords: [SyncRecord]
    let currentArchive: ProjectArchive
    let attachments: [UUID: SyncBootstrapOutputProof]
    let restoreRelativePaths: [UUID: String]
    let supportingAttachments: [UUID: SyncBootstrapOutputProof]
    let counterReminderContext: SyncCounterReminderMergeContext
}
struct SyncDeletionCaptureAllocation {
    let stagedEntryID: UUID
    let liveValidationID: UUID
    let restoredValidationID: UUID
    let restoredAttachmentIDs: [UUID: UUID] // predecessor -> child
}
struct SyncDeletionCaptureProgram {
    enum Source {
        case incoming(requestIndex: Int, attachmentID: UUID)
        case initialRetained(path: String)
        case earlierOutput(stepIndex: Int)
    }
    enum Content {
        case bytes(Data)
        case copy(source: Source, proof: SyncBootstrapOutputProof)
    }
    struct Output {
        let action: SyncBootstrapOutputAction
        let content: Content? // required for write; forbidden for dir/lock/reuse
    }
    struct Validation {
        enum Comparison {
            case liveArchive(ProjectArchive)
            case restorationPaths([SyncAttachmentSlot: String])
        }
        let records: [SyncRecord]
        let baseArchive: ProjectArchive
        let sources: [UUID: Int] // attachment -> preceding scratch write step
        let counterReminderContext: SyncCounterReminderMergeContext?
        let comparison: Comparison
    }
    enum Step {
        case output(Output)
        case validate(Validation) // obligation, never successful result
    }
    struct Capture {
        let stagedManifestBytes: Data
        let finalManifestBytes: Data
        let retainedEntry: SyncDeletionEntry
    }
    let expectedInitialLedger: SyncDeletionFrozenLedger
    let initialManifestBytes: Data? // new empty manifest only for absent ledger
    let steps: [Step]
    let captures: [Capture]
    let finalManifestBytes: Data? // nil for no-request no-op
    let finalDirectories: Set<String> // complete ledger tree, not scratch
    let finalFiles: [String: SyncBootstrapOutputProof]
}
```

Entry point in SyncDeletionLedger (its private Manifest stays private):

```swift
static func planIncomingCaptures(initial: SyncDeletionFrozenLedger,
    requests: [SyncDeletionCaptureRequest], allocations: [SyncDeletionCaptureAllocation],
    temporaryID: () -> UUID = UUID.init) throws -> SyncDeletionCaptureProgram
```

The identity closure is invoked during planning only after all semantic/proof/encoding checks, once per write and never for exact reuse. It is not retained or executed later. Allocation count must equal request count; reject reused/colliding paths. Empty requests produce an empty program without validating or certifying the ledger or invoking IDs, matching current bootstrap early return; final tree equals supplied tree, or empty for absent.

`present` requires `""` directory, ledger.json proof matching exact supplied bytes, complete exact UTF-8 parents, no case/Unicode aliases or file/dir conflicts, safe components and valid bounded proofs. Existing root with missing manifest is invalid, not absent. Existing lock must be empty file proof. Preserve all unreferenced files/dirs. Supplied tree is only a frozen projection; future descriptor owner must revalidate physical identity under lock.

Incoming source combines attachment/supporting maps and rejects the same UUID with differing proofs. initialRetained names an exact original frozen file; earlierOutput must point backward to a write with the matching proof. Thus request 2 can use bytes produced by request 1, without claiming they existed initially. Validation.sources names only its preceding scratch writes. Every Data payload is length/hash-bound to action. Directory/lock/reuse cannot smuggle content. Replacing ledger.json multiple times cannot overwrite earlier payload data in a path-keyed map: content is attached to the ordered step.

## Shared semantic seams, all in existing ledger file

```swift
private static func decodeManifest(_ data: Data,
    validateRetainedFile: (SyncDeletionFileProof) throws -> Void) throws -> Manifest
private static func encodeManifest(_ manifest: Manifest) throws -> Data
private struct IncomingSelection {
    let domain: SyncDeletedDomain
    let versions: [SyncRecordVersion]
}
private static func mergeIncoming(domain: SyncDeletedDomain,
    versions: [SyncRecordVersion], prior: SyncDeletionEntry?) throws -> IncomingSelection
private static func requiredAttachments(_ domain: SyncDeletedDomain)
    throws -> [UUID: SyncAttachmentVersion]
private static func appendStaged(_ manifest: Manifest,
    entry: SyncDeletionEntry) -> Manifest
private static func incomingStage(_ manifest: Manifest, stagedID: UUID,
    expectedPrior: SyncDeletionEntry?, rootIDs: Set<SyncEntityID>) throws -> SyncDeletionEntry
private static func activateIncoming(_ manifest: Manifest, stagedID: UUID,
    expectedPrior: SyncDeletionEntry?, selection: IncomingSelection,
    finalFiles: [SyncDeletionFileProof]) throws -> Manifest
```

The decoder callback is PRIVATE, invoked exactly at old per-group retained-file read position. Existing instance wrapper supplies actual read verification or the existing explicit no-I/O recovery path. Planner uses no-I/O callback on supplied bytes, then binds every selected proof against projected source tree. Do not validate every group before reading files: that changes ordinary error order. Convert pure validateRestoration to static if required, without changing body/order.

Encoder is exact current persist code minus write: sortedKeys, payload encoding/hash, Envelope encoding, 100 MB guard. Persist calls it at its existing write position.

mergeIncoming extracts canonical merge, selected-ID union and embedded-reminder/photo/legacy mismatch checks only. Ordinary sequence remains initial guards -> source reads -> live validation -> prior read -> merge -> fallback source construction -> final domain/removal validation/required-head filter -> stage -> restoring -> physical restored validation -> final locked transition. Do not fold final validation into merge, which would move it before fallback construction.

appendStaged only appends inactive Group. Ordinary stage constructs its real entry after copy/readback and calls this reducer. incomingStage performs the exact current active prior equality, nil restoration and staged-index guards; ordinary final block calls it BEFORE copying to prior ID. activateIncoming calls the same guard and applies current group removal/active incoming append after copies; ID is prior.id or stagedID, date comes from staged entry. Rechecking pure guards after copy must not replace the pre-copy check.

## Deterministic restoration seam: sort slots, preserve head order

Add internal `restoring(into:now:deviceID:attachmentVersionIDs: [UUID: UUID]) throws -> Restoration` to SyncDeletedDomain. Share the real private restoration body; ordinary overload retains its existing complete head order/fresh UUID behavior.

The deterministic overload sorts SLOTS by complete stable tuple, then flattens each slot's existing array unchanged. SyncRecordValidation.swift:83 sorts heads by deletedAt.stamp then UUID, and :98 selects max. Globally sorting heads by UUID changes winner and is forbidden. Keep unselected heads in the complete sequence because existing index gaps affect revisions.

```swift
private static func slotLess(_ a: SyncAttachmentSlot, _ b: SyncAttachmentSlot) -> Bool {
    let left = [a.owner.kind.rawValue, a.owner.uuid.uuidString, a.role, a.slotID]
    let right = [b.owner.kind.rawValue, b.owner.uuid.uuidString, b.role, b.slotID]
    for (x, y) in zip(left, right) {
        if !x.utf8.elementsEqual(y.utf8) { return x.utf8.lexicographicallyPrecedes(y.utf8) }
    }
    return false
}
let orderedHeads = lineage.headsBySlot.keys.sorted(by: Self.slotLess)
    .flatMap { lineage.headsBySlot[$0]! }
```

Exact map keys equal selected predecessor head IDs; child values unique and disjoint from all current/owned record UUIDs. Reject missing/extra/duplicate/colliding maps before mutation; empty selected heads requires empty map. Pass child UUID to existing `SyncAttachmentVersion.issuing(..., versionID:)`; no public API change. Private shared body accepts chosen complete head array plus child-ID lookup; deterministic entry validates map first, ordinary supplies `{ _ in UUID() }`. Freeze resulting records/predecessor map once in planner. Future executor must use that result, not call restoring again.

## Ordered program algorithm

1. Validate nonempty-request tree, supplied manifest/proofs/allocations. Decode full manifest and reject purge intents. Maintain projected files/dirs and origin for each file. Decode is semantic only, not readback certification.
2. Emit Staged/.sync-deletions directory only if absent, lock create/exact-existing, and initial empty ledger when needed. Role roots come from owner's prefix. Repeated lock acquisition has no new file action.
3. Per request, execute existing pure initial domain/removal/current-record and proof-consistency guards. Emit supporting scratch copies under ValidationMerged/DeletionValidation/<liveValidationID> when nonempty (shared ancestor once). Emit live Validation even with no files: Watch-aware merge and archive comparison remain required. No stage mutation precedes this job.
4. Find prior in projected manifest; shared merge, fallback sources, selected validation and marker gate. Fresh staged ID must not collide with any manifest group or complete tree path. Emit group dir even when empty, required retained files in UUID-sorted order, appendStaged exact encoded manifest replacement. Retain all stage files.
5. Form authority and frozen deterministic Restoration. Supporting scratch map is extended with child->selected predecessor source. Emit restored scratch under ValidationMerged/DeletionValidation/<restoredValidationID>, then restored Validation. Comparison requires requested required slots match paths; additional unrelated live slots are allowed as in current allSatisfy. No fake mapper result is produced.
6. Exact incomingStage guard. Prior-ID retained targets create from corresponding earlier stage output, reuse if exact, reject if conflicting; no overwrite. Derive final files, activateIncoming, encode exact final manifest replacement, update projected state for next request. Stage dirs remain.
7. Validate all generated path/type/raw-alias transitions, content proofs and manifest bounds before allocating temp IDs. Then assign one per write and resolve backward source indices against final step sequence. Retained source writes are immutable; reject references to superseded mutable writes. Final tree includes all old/new ledger outputs, not scratch.
8. Parent composes complete copied-tree prefix + program output actions, then existing SyncBootstrapOutputPlanner.plan once. Validation jobs are not writes. Fragment cannot claim reservation independently of prefix or full history/Base64 budget.

## One implementation/test/review cycle

Files: modify SyncDeletionLedger.swift and SyncDeletedDomain.swift; create SyncDeletionCaptureProgram.swift and Tests/KnitNoteCoreTests/SyncDeletionCaptureProgramTests.swift; extend SyncDeletedDomainTests.swift; add new source Xcode membership and actual App harness symlink. Bootstrap request-selection extraction is NOT necessary here: generic planner receives explicit requests, and runtime bootstrap remains unchanged; future owner must use existing selector rules when wiring.

- [ ] Read formal approved spec, freeze baseline identity/compiler lane. Write failing planner and restoration overload tests before extraction. No separate selection-only milestone.
- [ ] Preserve actual ordinary timing while extracting private methods; implement deterministic overload; implement complete program using those same methods.
- [ ] Absent-ledger media-free fixture: empty stage dir, lock, init/stage/final manifest writes and distinct temps; no scratch copies but two validation jobs. Compare resulting final entry to ordinary capture at same inputs and compare encoded snapshots through shared codec, not a duplicate test encoder.
- [ ] Live supporting media: both full scratch copy sets under ValidationMerged, none under Staged, real mapper validation run separately on actual staged fixture sources; missing bytes cannot make a Validation job pass merely because proof matches.
- [ ] Prior group: earliest date/prior ID retained; new stage tree retained; prior target create/exact reuse/no-temp or conflict rejection; prior contributes attachment absent incoming sources, with restored child source bound to predecessor proof.
- [ ] Multiple captures: second request resolves earlierOutput correctly, no future references, no mutable superseded source. Final manifest history preserves unrelated groups/markers/restorations.
- [ ] Valid outstanding purge intent rejects without init/lock/unlink; use interrupted purge fixture from SyncDeletionLedgerTests and snapshot physical bytes/metadata. Existing ordinary purge still passes. Present root/missing manifest, malformed/oversized envelope, raw Unicode/case/ancestor alias, invalid lock and changed proof reject.
- [ ] Proof-only 100 MB/+1 boundaries, existing manifest cap technique, metadata budget via full prefix composition, identity collisions/duplicate allocation paths and zero temp callbacks on preflight rejection. No 100 MB buffer required for proof-size cases.
- [ ] Focused GREEN and independent review. New source Xcode/App membership means proportional App/root + unsigned macOS/iOS validation on frozen candidate; local scoped commit only after review.

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 900 swift test --no-parallel --filter 'SyncDeletionCaptureProgramTests|SyncDeletedDomainTests|SyncDeletionLedgerTests|SyncBootstrapTransactionTests|SyncBootstrapOutputPlannerTests' > /tmp/deletion-capture-program-green.log 2>&1
```

RED uses the same bounded command with the new suite/overload test alone and a fresh `-red.log`; distinguish missing API from behavioral failure. Do not launch concurrently with existing compiler lane.

## Concrete restoration regression

Use real domain/deleted/stamp fixture construction from `SyncDeletedDomainTests.incomingMediaRequiresCompleteBoundSourcesAndRejectsRetiredHistorySelection` (70-142), including attachment metadata/relationships and selected cascade consistency. Add a concurrent same-slot project-photo head with SMALLER lexical UUID but LATER deletion stamp than its peer, and retain a second slot. That ensures UUID sorting demonstrably contradicts canonical head order. Give the conflicting heads distinct valid file hashes so the test proves winning bytes, not just identity.

```swift
let lineage = try SyncAttachmentLineage(records: domain.ownedRecords)
let selected = lineage.headsBySlot.values.flatMap { $0 }
    .filter { domain.selectedLiveIDs.contains($0.id) }
let ids = Dictionary(uniqueKeysWithValues: selected.map { ($0.id.uuid, UUID()) })
let a = try domain.restoring(into: deleted, now: stamp.modifiedAt,
    deviceID: "incoming-validation", attachmentVersionIDs: ids)
let reversed = Dictionary(uniqueKeysWithValues: ids.map { ($0.key, $0.value) }.reversed())
let b = try domain.restoring(into: Array(deleted.reversed()), now: stamp.modifiedAt,
    deviceID: "incoming-validation", attachmentVersionIDs: reversed)
#expect(a.records.sorted { $0.id.uuid.uuidString < $1.id.uuid.uuidString }
    == b.records.sorted { $0.id.uuid.uuidString < $1.id.uuid.uuidString })
#expect(a.restoredAttachmentPredecessors == b.restoredAttachmentPredecessors)
let restoredLineage = try SyncAttachmentLineage(records: a.records)
let restored = restoredLineage.resolvedLiveVersionIDs()
for (slot, heads) in lineage.headsBySlot {
    guard let oldWinner = heads.last, domain.selectedLiveIDs.contains(oldWinner.id) else { continue }
    let child = try #require(restored[slot])
    #expect(child == ids[oldWinner.id.uuid])
    #expect(restoredLineage.recordsByVersionID[child]?.payload.attachment?.contentSHA256
        == oldWinner.payload.attachment?.contentSHA256)
}
var missing = ids
missing.removeValue(forKey: try #require(ids.keys.first))
#expect(throws: (any Error).self) {
    try domain.restoring(into: deleted, now: stamp.modifiedAt,
        deviceID: "incoming-validation", attachmentVersionIDs: missing)
}
```

Also test extra key, duplicate child, child equal an existing UUID and empty-map media-free success. Reverse current record/map insertion for slot determinism; opposing stamp/UUID priority with distinct hashes proves within-slot winner preservation. Existing ordinary tests keep original overload. Do not modify lineage's comparator to fit new tests.

## Completion boundary

This yields a shared data program, NOT an executor or validated operation. Durable preparing, descriptor source revalidation, private sink, retained output execution, abort/reopen history, sourceSpent/reissue and remote integration remain separate. Full metadata/history/Base64 affordability remains owner's gate. No unresolved product choice is needed; controller must formally approve technical scope, then review actual implementation/evidence. No placeholder content/source fields or arbitrary authority API are needed by this proposal.

