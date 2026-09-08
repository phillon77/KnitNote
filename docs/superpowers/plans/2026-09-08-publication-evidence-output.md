# Publication evidence save output program implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Execute implementation and target/composition checks as one coherent deliverable with independent review.

**Goal:** Model the actual bootstrap publication-evidence `save` as a finite data-only program with exact immutable/head bytes, existing-byte reuse, complete projected tree, ordered durability obligations and explicit finite-planner composition prerequisites.

**Architecture:** Keep the private stored authority/tombstone/Watch envelopes in `JSONProjectStore.swift`. Extract shared pure codecs, immutable semantic matching and save selection at the exact ordinary call sites; add an internal static planning entry in the same file and a focused data/program-builder file. Ordinary `save`, `applying`, readers and durability code retain their present order and behavior. The new program performs no I/O and does not become a bootstrap runtime caller.

**Tech Stack:** Swift 6, Foundation, CryptoKit, Swift Testing, current KnitNoteCore and Xcode targets.

**Spec:** `docs/superpowers/specs/2026-09-08-publication-evidence-output-design.md`. Main reviewed the complete draft and resolved the technical choices below; implementation remains a separate next step.

## Global constraints

- Baseline inspected: `ce09d3f958e0abefe6867a190a32f8b971908ad7`, `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`. Existing untracked `.superpowers/absent-source-design-progress.md` belongs to the ongoing user task.
- Preserve version 1.7.0 (13), iOS 18/macOS 15/watchOS 11, all wire formats and public signatures.
- Authority and tombstone envelopes: `16 * 1_024 * 1_024`; Watch proof envelopes: `1 * 1_024 * 1_024`; compact head: `FileSyncMutationJournal.maximumEncodedBytes` = `64 * 1_024 * 1_024`. Existing owned-file cap remains `100_000_000`; do not broaden any ordinary helper limit or introduce a guessed entry cap.
- No filesystem reads, dummy root URL, ledger instantiation, sink, executor, issuer, ownership certificate, trusted flag, runtime bootstrap integration, cleanup, signing, push or submission in this prerequisite.
- No mutation-batch `applying` program is included: actual bootstrap uses `save`. Preserve `applying` behavior and regression coverage because shared codecs/matching also serve it.
- Frozen bytes/proofs are caller-supplied accounting data. Physical descriptor/path identity checks, source ownership, completed source reads, actual backup/mapper validation, full recovery/Base64/history/abort affordability, durable preparing and sourceSpent remain explicit later obligations.
- Owner combines one complete prefix and all helper suffixes and invokes `SyncBootstrapOutputPlanner.plan` once. Helper plans must not synthesize a fake prefix, call the finite planner with an empty account binding, or claim local reservations cover the whole transaction.

## Actual source and dependency table

All line numbers below refer to the inspected baseline.

| Actual source | Meaning for this program |
| --- | --- |
| `JSONProjectStore.swift:77-494` | Existing v1/v2 decode, canonical attachment lineage ordering, validation, and compact active-head projection. Preserve version-only evidence and optional fields exactly. |
| `JSONProjectStore.swift:562-647` | Private storageVersion 1 authority, tombstone and Watch envelopes. Never introduce a parallel permissive decoder. |
| `JSONProjectStore.swift:768-787` | `save`: lock, canonicalize/validate candidate, form authority/tombstone lists, preflight selected files, install authorities, tombstones, Watch proofs, then compact and write head. Head is always written even for empty/unchanged input. |
| `JSONProjectStore.swift:1112-1159` | Ordered selected-file preflight: candidate validate/encode/size guard then existing-path read/match, each authority before next authority; tombstones additionally require matching candidate authority; Watch proofs use full proof equality. |
| `JSONProjectStore.swift:1160-1270` | Install rereads each target, reuses only matching immutable bytes, synchronizes reused file parent, otherwise creates root/shard then no-clobber file. No-clobber race rereads winner; preserve this ordinary path unchanged. |
| `JSONProjectStore.swift:1273-1416` | Bounded reads, exact UUID/shard path binding, authority immutable-snapshot equality, tombstone optional-record compatibility, exact Watch equality. |
| `JSONProjectStore.swift:1432-1537` | Lowercase UUID; first two characters as shard; `.sortedKeys` JSON. Directory creation synchronizes parent. |
| `JSONProjectStore.swift:671-740,882-931` | `load` separately validates compact-head supporting authorities and enumerates history. `save` does neither. A planner must not silently add `load()` semantics to ordinary save. |
| `SyncBootstrapTransaction.swift:475-490` | Existing runtime saves into `Staged/SyncMetadata/attachment-versions.json` after canonical checkpoint; receives all result attachment records and de-duplicated orphan/counter Watch proofs. Runtime call remains unchanged. |
| `SyncDurableFile.swift:62-150,176-202` | Lock path `.attachment-versions.json.lock`; temporary `.<name>.<UUID>.tmp`; write fsync/rename/parent-sync; immutable no-clobber rename. Ordinary lock accepts any regular file length, while finite owned lock contract requires empty proof. |
| `SyncBootstrapOutputPlanner.swift:1-160` | Finite action/proof types; prior copied-file create action required before replace/reuse/existing lock; parents explicit; per-write temp reserved; no implicit initial tree parameter. |

Paths relative to the future Staged role are fixed, not caller-configurable:

| Output or dependency | Exact path | Required input content | Result |
| --- | --- | --- | --- |
| Head | `SyncMetadata/attachment-versions.json` | Existing file proof if present; no old-head semantic bytes required by save | Always write exact compact-v2 bytes, create or replace by original proof |
| Lock | `SyncMetadata/.attachment-versions.json.lock` | Absent or exact SHA256(empty)/0 file proof | One lock action encompassing the complete save sequence |
| Authority for UUID u | `SyncMetadata/attachment-versions.attachment-records/<lowercase first 2>/<lowercase u>.json` | Existing exact bytes and proof if selected candidate addresses it | Reuse exact existing proof after semantic match, otherwise create exact sortedKeys envelope |
| Tombstone for UUID u | `SyncMetadata/attachment-versions.attachment-tombstones/<lowercase first 2>/<lowercase u>.json` | Existing exact bytes and proof if selected candidate addresses it | Same, retaining optional-record compatibility |
| Watch proof for UUID u | `SyncMetadata/attachment-versions.watch-proofs/<lowercase first 2>/<lowercase u>.json` | Existing exact bytes and proof if selected candidate addresses it | Reuse only equal decoded Watch proof, otherwise create exact sortedKeys envelope |
| Parent directories | `SyncMetadata`, each needed immutable root and shard | Complete tree records every already-present directory | Create only absent directories in ordinary order; each new directory requires parent synchronization |
| Temporary for each actual write | Same parent, `.<lastComponent>.<allocated UUID>.tmp` | Must be absent from complete initial/projected tree and all earlier allocated temporaries | One explicit temporary ID per new immutable/head write; none for exact reuse |
| Unselected copied content | Every other initial directory/file, including old immutable history and hidden remnants | Exact path/type and valid proof; optional supplied bytes must match proof | Preserve unchanged in complete final tree; no semantic decode or deletion |

Only selected immutable existing-file bytes are semantic read dependencies. Old head is an overwrite-predecessor proof dependency; unselected history is retained whole-tree ownership/accounting dependency. A copied corrupt old head is not decoded by ordinary save. Do not reject it merely because a full `load` would fail. Conversely, a corrupt selected immutable file is a hard conflict. Full-tree safety can reject path/proof/lock incompatibility on the new planned route without changing ordinary permissiveness.

## Concrete API and representation

Create `Sources/KnitNoteCore/CloudSync/SyncPublicationEvidenceOutputProgram.swift` for internal value types and pure tree/action assembly. Use arrays at ingestion so duplicate raw spellings cannot disappear through Swift String dictionary canonical equivalence.

```swift
struct SyncPublicationEvidenceFrozenTree {
    struct File {
        let path: String                 // relative to Staged
        let proof: SyncBootstrapOutputProof
        let bytes: Data?                 // required for selected existing immutable files
    }
    let directories: [String]            // complete Staged projection; includes ""
    let files: [File]                    // complete Staged projection, not only evidence subtree
}

struct SyncPublicationEvidenceOutputProgram {
    struct Output {
        let action: SyncBootstrapOutputAction
        let bytes: Data?                 // exact payload only for write; nil for others
    }
    enum Step {
        case output(Output)
        case synchronizeParentDirectory(path: String)
    }
    let expectedInitialTree: SyncPublicationEvidenceFrozenTree
    let steps: [Step]
    let compactHeadBytes: Data
    let finalDirectories: [String]
    let finalFiles: [SyncPublicationEvidenceFrozenTree.File]
    var actions: [SyncBootstrapOutputAction] {
        steps.compactMap {
            if case let .output(output) = $0 { return output.action }
            return nil
        }
    }
}

// Add inside JSONProjectStore.swift so private envelopes stay private.
extension SyncAttachmentPublicationEvidenceFile {
    static func planSave(
        _ evidence: SyncAttachmentPublicationEvidence,
        initial: SyncPublicationEvidenceFrozenTree,
        temporaryID: () -> UUID = UUID.init
    ) throws -> SyncPublicationEvidenceOutputProgram
}
```

`synchronizeParentDirectory(path:)` names the file/directory whose parent must be synchronized, relative to Staged. It creates no Entry reservation and grants no authority. It follows every created directory and immutable reuse. Writes already carry the future write/rename/parent-sync contract, so do not emit a duplicate write sync step. The single lock action starts before candidate output; lock lifetime covers the last head durability operation. There is no callable sync closure or retained FileManager/URL/reader on this program.

Proposed pure errors in the new file:

```swift
enum SyncPublicationEvidenceOutputError: Error, Equatable {
    case invalidTree, invalidProof, missingSelectedBytes, collision
}
```

Candidate decoding/validation/size/matching failures retain `SyncPublicationTransactionFileError.corrupt`. These errors describe supplied data, not physical `.unsafeFile`/`.unavailable` observations. The formal spec adopts this separation; it does not change ordinary physical error mapping.

Input rules: verify all raw paths before converting to any dictionary; reject duplicate identical paths, Unicode/case/diacritic aliases, file/dir clashes, missing exact-spelling parents, unsafe components, invalid 32-byte SHA or size outside `0...100_000_000`. Root directory `""` is mandatory and unique. All provided optional bytes must hash/length-match. Existing head/root/shard/lock paths cannot be directories/files of the wrong type. Lock must have the exact empty proof. Missing selected bytes is distinct from an absent target. Do not inspect an unselected immutable file's JSON just because its bytes are supplied.

Final arrays preserve every untouched entry and exact spelling; replace only head bytes/proof, append created dirs/lock/files, retain immutable existing bytes/proof even when candidate encoding differs. Program may attach exact selected decoded-source bytes to final reused entries because they are already present in input. It must not fill unselected files with invented bytes.

## Shared private semantics and ordinary ordering

Make these exact private pure seams in `JSONProjectStore.swift`; ordinary instance wrappers call them where their old bodies already ran. Access modifiers must not expose the stored envelope types.

```swift
private static func canonicalSaveEvidence(_ evidence: SyncAttachmentPublicationEvidence)
    throws -> SyncAttachmentPublicationEvidence
private static func encodeAuthority(_ value: SyncStoredAttachmentVersionAuthority) throws -> Data
private static func encodeTombstone(_ value: SyncStoredAttachmentTombstoneAuthority) throws -> Data
private static func encodeWatchProof(_ value: SyncProcessedWatchCommandProof) throws -> Data
private static func encodeCompactHead(_ value: SyncAttachmentPublicationEvidence) throws -> Data
private static func decodeAuthority(_ bytes: Data, expectedID: UUID)
    throws -> SyncStoredAttachmentVersionAuthority
private static func decodeTombstone(_ bytes: Data, expectedID: UUID)
    throws -> SyncStoredAttachmentTombstoneAuthority
private static func decodeWatchProof(_ bytes: Data, expectedID: UUID)
    throws -> SyncProcessedWatchCommandProof
```

Convert existing `attachmentAuthorities(in evidence:)`, `attachmentTombstones(in evidence:)`, `authoritiesMatch`, `tombstonesMatch`, `tombstoneMatchesAuthority` and deterministic encoder to private static pure methods, preserving their exact bodies/order. Share path suffix creation with `immutableURL` via `private static func immutableRelativePath(_ id: UUID) -> String` returning `<shard>/<uuid>.json`; ordinary URL uses the returned components. Envelope encoders validate and enforce the existing exact caps. Ordinary preflight already validates then encodes each candidate; it calls the corresponding encoder at that position. Install may reuse the already-shared encoding helper after its original validation; do not move its existing read earlier. Decoder wrappers keep actual `reader.read` and regular-file error mapping at their original positions, then invoke pure decode and preserve exact destination-path check. `expectedID` validates decoded identity, not ownership.

Do not implement ordinary `save` by calling `planSave`: that would require complete-tree enumeration, add source reads, change locking semantics and move head-size failure before immutable side effects. Ordinary save must remain:

```text
with existing exclusive file lock
  canonicalize/validate candidate
  form candidate authority and tombstone arrays
  preflight candidate authority 1, read existing 1, match 1; repeat
  preflight candidate tombstone 1, matching candidate authority, read existing 1; repeat
  preflight candidate Watch proof 1, read existing 1; repeat
  install authorities in candidate canonical order
  install tombstones in UUID order
  install Watch proofs in canonical UUID order
  compact head, encode, enforce journal limit, write, record head counter
```

New pure planning may finish all semantic/encoding/shape checks before requesting temporary IDs. This difference must remain confined to pure plan construction. Keep ordinary reader counters, mapped errors, file-lock scope, directory sync boundaries, no-clobber race handling and injected faults unchanged. In particular, do not add missing-head reads to save or historical directory enumeration to applying.

## Plan assembly algorithm

1. Validate complete initial projection and every supplied proof/raw path. Construct a staged-only in-memory node table; record initial absence and initial-file proofs. Never read from disk.
2. Canonicalize/validate supplied evidence with the shared function. Compute actual authority and tombstone lists with shared selection. Check all candidate encoded immutable bytes at existing limits. For each selected existing target, require exact supplied bytes, verify proof, decode with its expected UUID and shared matching semantics. Tombstones require their candidate authority. Watch proof decoded equality is exact.
3. Compute exact compact head bytes with shared encoder and journal cap. Old head content is never decoded. Keep the old file proof for `.replace`, or `.create` if absent. Reject wrong path type. Save of empty evidence still produces lock and head write.
4. Build ordered draft steps: create missing `SyncMetadata` then sync its parent, acquire exact/absent empty lock, each authority install in canonical order, then tombstone, then Watch, then head. For absent immutable destination, create missing root/shard just before its write, with parent-sync steps. For matching existing destination emit `.reuseExact(... existingProof)` and a parent-sync step. Candidate bytes are discarded for reuse, not installed.
5. Validate all non-temporary semantics and file/name caps before calling `temporaryID`. Request one ID per actual write, head included. Register each generated `.<name>.<UUID>.tmp` against complete initial paths, projected outputs, aliases, and prior temporaries; repeated IDs are allowed only when generated paths differ and have no alias (finite planner collision identity is path, not UUID). Reject collision without returning a partial program. Do not cache random IDs in global state.
6. Attach each exact write Data directly to its ordered output; hash/length must equal the action new proof. Directory/lock/reuse carry nil bytes. Finish complete final tree preserving initial unselected entries.
7. Return helper suffix plus initial-tree precondition. Future owner must demonstrate its prior actions project exactly this supplied initial tree (including prior helper results), append this suffix, and call the existing finite planner once for complete source-copy, attachments, backups, deletion, publication and later declared outputs. Existing-file reuse is not a create; tests supply actual preceding copy actions.

No physical validation job is marked complete. Evidence JSON semantic validation does not certify staged archive, attachment media, markup, physical ownership, durability or source provenance. Parent-sync steps document future executor obligations; this program cannot perform or certify them.

## Task 1: Implement and test the complete save content program

**Files:** Create `Sources/KnitNoteCore/CloudSync/SyncPublicationEvidenceOutputProgram.swift`; modify only publication helper semantic seams/extension in `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`; create `Tests/KnitNoteCoreTests/SyncPublicationEvidenceOutputProgramTests.swift`; add targeted regressions to `Tests/KnitNoteCoreTests/SyncPublicationEvidenceDurabilityTests.swift`. Xcode membership and harness links belong in the integration checks of this same task. Do not edit runtime `SyncBootstrapTransaction.swift`.

**Consumes:** Frozen full Staged projection, candidate evidence and planning-only temporary-ID callback.

**Produces:** API above; same ordinary bytes/order with pure reusable semantics; exact complete output/durability program with no runtime caller.

- [ ] Write a red empty-input test using only public-to-tests internal program API:

```swift
@Test func emptySaveStillWritesCompactHeadAndLock() throws {
    let id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    var allocations = 0
    let program = try SyncAttachmentPublicationEvidenceFile.planSave(
        .init(), initial: .init(directories: [""], files: []),
        temporaryID: { allocations += 1; return id })
    #expect(allocations == 1)
    #expect(program.actions.count == 3) // SyncMetadata, lock, head
    #expect(program.actions[0] == .directory(role: .staged, path: "SyncMetadata"))
    #expect(program.actions[1] == .lock(role: .staged,
        path: "SyncMetadata/.attachment-versions.json.lock", expectedExisting: nil))
    #expect(try JSONDecoder().decode(SyncAttachmentPublicationEvidence.self,
        from: program.compactHeadBytes).allVersions.isEmpty)
}
```

- [ ] Run `swift test --filter SyncPublicationEvidenceOutputProgramTests/emptySaveStillWritesCompactHeadAndLock`; record red missing API diagnostic, not a claimed result now.
- [ ] Implement exact types, shared codecs and assembly algorithm above. Keep all private envelope code in the existing file; use `Data(SHA256.hash(data: bytes))` for proofs. New file has no `FileManager`, physical `URL`, file reader or durable writer dependency. Ordinary wrappers retain physical code and counters.
- [ ] Add actual ordinary-output comparison fixture: fixed parent UUID `20000000-0000-0000-0000-000000000001`, versions `...0002` and `...0003` linked in one project-photo/primary lineage, exact `Data("first".utf8)`/`Data("second".utf8)`, fixed record stamps/date at Unix seconds 1 and 2; second record tombstoned. Include a fixed Watch orphan proof at Unix second 3 using the existing `orphanProofMutation` fixture construction in `SyncPublicationEvidenceDurabilityTests.swift:732`. Invoke ordinary `save` only into isolated temporary fixture, enumerate regular final output bytes after completion, and compare every planned write/reuse path/proof/bytes and final compact head to this independently obtained ordinary tree. Include version-only v1 evidence and current v2 record-backed evidence as separate cases.
- [ ] Add immutable byte reuse fixtures: first generate a valid ordinary immutable file, re-encode its decoded JSON with `.prettyPrinted` so its bytes differ, supply exact new proof, and plan same candidate. Assert `.reuseExact` retains pretty-printed byte proof, no immutable temporary allocation, and parent-sync follows reuse. For tombstone compatibility use valid stored bare tombstone (`record` absent) against candidate full matching deletion; assert existing bare bytes reused. Authority nil-record vs full record must reject. A differing immutable content snapshot must reject; a same UUID Watch proof with differing rejection/identity must reject. Require zero temporary callbacks on every semantic rejection.
- [ ] Add overwrite/history fixture: existing malformed head bytes `Data("old malformed head".utf8)` with correct proof and a valid unrelated immutable file; candidate empty save must replace only head and preserve unrelated bytes/proof. Add unrelated hidden regular file and empty shard to prove complete final projection retention. Supplying old head as directory rejects. Missing semantic bytes for selected file rejects even with a valid-looking proof.
- [ ] Add shape and temp fixtures: selected hash/length mismatch; raw NFC/NFD parent mismatch; case aliases; duplicate file array path; file/dir alias; missing root and parent; stale/nonempty lock; target used by unselected file; generated temp already present; duplicate generated temp for same destination is rejected by builder if repeated writes are later supported. No directory enumeration is allowed in pure planning.
- [ ] Add exact byte limits with valid envelopes plus trailing JSON whitespace: authority/tombstone payload padded to 16 MiB decodes, 16 MiB + 1 rejects; Watch to 1 MiB succeeds, +1 rejects. For the compact head use a shared internal `validateCompactHeadByteCount(_ count: Int) throws` guard called by the real encoder immediately after encoding. Reject negative counts and values above the unchanged journal cap. Test exact 64 MiB and +1 through that guard, plus ordinary-sized real head encoding/parity and call-site review. This verifies admission arithmetic and wiring, not a full 64 MiB semantic candidate; record that distinction. Do not allocate huge collections merely to hit this boundary or lower the production cap. For the 100,000,000 generic projection proof cap, test exact cap and +1 using unselected proof-only file; do not allocate that Data.
- [ ] Add ordinary read/error ordering regression with recording `SyncRegularFileReading`: candidate authority A conflicts on disk while later B is oversized, and verify ordinary save reports/reads A at existing point and never advances to B. Keep existing `SyncPublicationEvidenceIOCounters` expected snapshots unchanged. Preserve all durability fault tests, including parent resync on reuse and immutable-created-before-head-failure side effects.
- [ ] Run `swift test --filter 'SyncPublicationEvidenceOutputProgramTests|SyncPublicationEvidenceDurabilityTests|JSONProjectStoreSyncPublicationTests|SyncCanonicalPublicationTransactionTests|SyncConflictPublicationTests'`. Review exact command output and any fixtures that require too much memory before broadening tests; no source modification while compiler runs.

## Task 1 continued: Prove real finite-planner composition and target inclusion

**Files:** Extend `Tests/KnitNoteCoreTests/SyncPublicationEvidenceOutputProgramTests.swift`; modify `KnitNote.xcodeproj/project.pbxproj` only for new source membership; add the existing App harness source link using the repository's current convention after locating it read-only; create focused formal spec/verification report only under main authority.

**Consumes:** Task 1 program `actions`, `expectedInitialTree`, exact bytes and final tree.

**Produces:** A tested data-only publication suffix composed with a real declared prefix, independently reviewed ordinary compatibility, and compiled source inclusion without activation.

- [ ] Add prefix fixture actions: `.directory(role: .staged, path: "")`, exact directories sorted parent-first and exact file `.write(.create)` copies for frozen initial projection. Use explicit unique temporary IDs for fixture prefix. Do not use physical paths or a test-only issuer. Call `SyncBootstrapOutputPlanner.plan(accountIDHash: String(repeating: "a", count: 64), livePathSHA256: String(repeating: "b", count: 64), transactionID: fixedID, actions: prefix + program.actions)` once. Assert total `actionCount`, potential final/temp/lock paths, expected proof maximums, no missing parent, and no reservation based on guessed output counts.
- [ ] Change prefix's initial immutable bytes proof while retaining suffix; require finite planner `.invalidTransition` at reuse. Remove copied head action; require replace failure. Change prior helper output/parent spelling, inject prefix-temp collision, omit Staged root and prove rejection. Ensure full prefix preserving unrelated files succeeds; suffix-only call fails rather than pretending missing files exist.
- [ ] Include deletion helper output followed by publication suffix over its projected tree in one pure integration fixture where practical, so a prior `.sync-deletions` subtree is retained and complete composition is demonstrable. No new generic planning coordinator or runtime owner is part of this deliverable.
- [ ] Add actual Xcode build-file/file-reference/source-build-phase entries beside existing JSONProjectStore membership. Add the new source symlink at `/tmp/knitnote-account-domain-jnjVrd/Sources/KnitNote/Core/CloudSync/SyncPublicationEvidenceOutputProgram.swift` targeting this worktree new source. Existing root harness `/tmp/knitnote-app-root-kbh3SM/Sources/KnitNote/Core` already points to whole Core. Do not replace other links.
- [ ] Run `swift test --filter 'SyncPublicationEvidenceOutputProgramTests|SyncBootstrapOutputPlannerTests|SyncDeletionCaptureProgramTests|KnitNoteBackupServiceTests'`, then appropriate existing App/root/unsigned platform verification with main's one-compiler lane and frozen source candidate. Use the exact bounded controller commands below; no validation is claimed until executed.
- [ ] Main reviews formal-spec coverage, privacy of envelopes, actual ordinary ordering, deterministic bytes, immutable semantic-vs-byte reuse, exact limits, full initial/final tree and composition. Only after that independent review record test output and exact SHA in verification report. Commit or execution decisions remain with main; this planning subtask makes neither.

## Main technical decisions and self-review

- Complete Staged tree accepted: retains unselected proof metadata and catches parent/temp aliases; no new semantic dependency on historical JSON.
- Explicit parent-sync obligations and whole-save lock lifetime accepted; no step certifies execution.
- Pure input error separation accepted; ordinary physical errors unchanged.
- Temporary collision is full raw path/alias identity, not global UUID uniqueness.
- Head cap tested through actual shared count guard plus encoder wiring/parity, explicitly not full-size semantic candidate certification.
- One coherent deliverable includes implementation, composition and membership, not separate acceptance cycles.

Main checked API types against existing action enum, all save output families, semantic reuse versus original bytes, ordinary ordering, limits and scope. No product choice or new authority is needed. Physical writer/owner and full recovery budgeting remain excluded, not omitted from a completion claim.

## Exact bounded verification commands

Run Core focused suites with `arch -arm64 env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 900 swift test --disable-xctest --no-parallel --filter 'SyncPublicationEvidenceOutputProgramTests|SyncPublicationEvidenceDurabilityTests|JSONProjectStoreSyncPublicationTests|SyncCanonicalPublicationTransactionTests|SyncConflictPublicationTests|SyncBootstrapOutputPlannerTests|SyncDeletionCaptureProgramTests|KnitNoteBackupServiceTests'`; fresh RED/GREEN logs under `/tmp/publication-output-`. Resolve suite spelling against actual tests before running; never allow a zero-test filter to count as success.

Controller after independent review runs these serially on frozen source; necessary cache permission may require scoped escalation, no signing or cloud access:

```sh
KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0 CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/task4-run-bounded.py 900 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --package-path /tmp/knitnote-account-domain-jnjVrd --no-parallel
KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0 python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --package-path /tmp/knitnote-app-root-kbh3SM --no-parallel
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/publication-output-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/publication-output-ios-derived CODE_SIGNING_ALLOWED=NO build
```

