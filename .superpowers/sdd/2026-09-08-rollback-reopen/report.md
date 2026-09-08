# Nil-control rollback reopen report

Baseline d92c7c19aabfc98e495b67a15d77ba4795acf653. Scoped implementation commit: **33c1e14bcd895b72a00656c6562ac6dbd4c2dd8c** (`fix: admit exact missing-archive rollback on account reopen`). Parent compatibility ruling resolved as recorded below. Final post-ruling focused verification passed; independent parent review required. All six compiler sessions reaped and compiler stopped before reporting/committing.

Design approved by explicit bounded delegation: preserve archive/control routes; require exact absent main/next plus nonnil strict terminal missingArchive + rolledBack evidence. Reuse the Bootstrap bounded physical reader and parser; validate before ownership mutations and again under the held account lock. Arbitrary existing archive bytes remain compatible. Normal close is not abrupt process crash acceptance.

Systematic debugging, approved bounded brainstorming design, TDD/test-writing reference, verification-before-completion and requesting-code-review skills used. The already approved design restricted implementation to the two Storage admission gates; behavioral RED preceded production edits. Parent will perform independent review; no additional subagents were spawned.

## Root cause and scoped change

Real prepareReconstruction/install/rollback writes `.KnitNote-SyncBootstrap/<accountHash>/<hash(live.path)>/active.json`. Storage's pre-lock requireExistingEvidence and owned nil-state validation only recognized archive, control main, or an older top-level bootstrap active file. Therefore valid nested rollback could be captured by an existing owner but could not survive ordinary close into either verified reopening API.

- `Sources/KnitNoteCore/CloudSync/SyncAccountStorage.swift`: add strict nested fallback to both gates. Before even creating a lock, inventory through account descriptors, require absent main/next and nonnil existing parser evidence with rolledBack + missingArchive, then repeat inventory/control checks. Carry the preflight snapshot across account-lock acquisition and compare before creating a session. Existing owned validation and its post-synchronization inventory check remain.
- `Sources/KnitNoteCore/CloudSync/SyncBootstrapTransaction.swift`: extract the existing physical reader into an evidence-returning internal overload; retain the void validation wrapper and pure parser unchanged. Expected byte count/hash and device/inode checks remain.
- `Tests/KnitNoteCoreTests/SyncAccountRecoveryInventoryTests.swift`: add five focused parameterized regressions below; no fixture-wide source behavior changes.
- `Tests/KnitNoteCoreTests/SyncAccountRecoveryTransactionTests.swift`: extend the existing media/deletion roundtrip to perform ordinary close and actual verified/existing reopen before any selection exists, then authenticate/seal/cleanup/restore/consume/reseal with the existing exact pending/dependency assertions.
- This report and `progress.md`: scope, exact evidence, costs, and review handoff. Existing controller scratch `.superpowers/absent-source-design-progress.md` is untouched.

## TDD and verification

Every run used exactly this command from the worktree, changing only the output log filename:

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 1200 arch -arm64 swift test --no-parallel --filter 'SyncAccountSourceStateTests|SyncAccountStorageTests|SyncAccountRecoveryInventoryTests|SyncAccountRecoveryTransactionTests|SyncBootstrapTransactionTests' > /tmp/rollback-reopen-red.log 2>&1
```

Core integration override explicitly unset. Bounded runner SHA-256: `c9fbdb35fa3743e27a7fbf63a1a0cbabfb02ca10e299167c214841a915faec0b`. The authorized focused compiler cache access used escalation; no full suite, Xcode, App activation, live account, device, signing or push occurred.

| Log in /tmp | Actual result |
| --- | --- |
| rollback-reopen-red.log | 162 tests / 5 suites, four expected unsafePath failures in actual rollback → ordinary close → both verified/existing APIs × with/without media/deletion. All existing tests passed. EXIT 1; test time 37.228s, elapsed 59.213s. Production unchanged at this run. Session 29514 reaped. |
| rollback-reopen-green.log | 163 tests / 5 suites, positive cases passed; two negative fixture path lookup failures, not a production failure. EXIT 1; test time 40.224s, elapsed 65.001s. Session 51731 reaped. |
| rollback-reopen-green-2.log | 166 tests / 5 suites, two remaining fixture path lookup failures. Inspected native journal and corrected the target to its existing segment file. EXIT 1; test time 41.577s, elapsed 67.167s. Session 14373 reaped. |
| rollback-reopen-green-3.log | 166 tests / 5 suites passed, no recorded issues, warning or compiler error. EXIT 0; test time 40.960s, elapsed 61.893s. Session 72090 reaped. |
| rollback-reopen-top-level-red.log | 166 tests / 5 suites, exactly six issues from the two bogus top-level-only cases: no error thrown and new lock/session changed bytes/names. Real reopened full transaction cases passed. EXIT 1; test time 44.091s, elapsed 65.732s. This ran before removing the obsolete top-level route. Session 19938 reaped. |
| rollback-reopen-final-green.log | 166 tests / 5 suites passed after both approved production changes, including both reopened full media/deletion transaction flows. No warning/error/issue output. EXIT 0; test time 45.706s, elapsed 52.872s. Session 24974 reaped. |

The intermediate failures are not counted as behavioral RED or passing evidence. They came from assuming the logical pending.json URL itself is persisted; FileSyncMutationJournal uses native .segment/.checkpoint files. No production tweak was made in response.

## Behavior coverage and self-review

- Four real rollback/ordinary-close/reopen cases reach complete recovery inventory capture without creating archive or control authority. Exact pending mutation FIFO and all on-disk bytes remain unchanged; media and selected retained deletion bytes are present.
- Forty-eight direct Storage rejection cases cover empty nested directories, missing/bogus active, bad digest, unknown version, mismatched source fingerprint, prepared/installed/rollingBack/committed phases, foreign account/live/journal/namespace, missing or changed Original, changed live segment, extra foreign tree, symlink/hardlink/FIFO, corrupt main, mainless next and bogus top-level-only bootstrap. Rejections preserve all bytes and directory names; no-control cases remove only the isolated fixture lock first and prove no new lock/scaffold is created by rejection.
- Two actual reopened full transaction cases retain existing exact selected media/deletion bytes, pending markers, mutation FIFO, authenticated origin, complete cleanup, restore, consumption and second seal/restore/consume assertions. These are not a composition of a capture-only reopen test with an original-owner roundtrip.
- Two valid committed-proof cases first prove the unchanged terminal parser accepts the committed evidence and matching receipt, then prove Storage still refuses it as missing-archive rollback admission.
- Two final account-generation rejection cases preserve all original media/evidence bytes and create no source/control state.
- Four synchronization cut cases mutate active or existing live segment only after read-only preflight, while account ownership is held; reopening throws and preserves exactly the injected evidence bytes with no additional mutation.
- Existing corrupt-archive compatibility, control selection, source state, retention, sealed recovery, and bootstrap suites remain GREEN. No parser weakening, unbounded metadata allowance, additional owner, recursive lock, recovery writer, or trusted public bool was introduced. New fallback performs extra full descriptor inventory/hashing passes; this accepted cost is not a performance optimization.
- Self-review mentally removed each new discriminator: nil/empty evidence is caught by empty/missing tests; phase by valid committed case; missingArchive/source integrity by strict parser matrix; control absence by mainless next; post-read inventory consistency by owned synchronization cuts. Physical read expectations are unchanged from the previously tested reader.

## Resolved compatibility ruling and unresolved integration boundary

Self-review surfaced the existing third existence-only route for **top-level** `.KnitNote-SyncBootstrap/active.json`. Parent confirmed its removal from verified/existing admission after read-only source tracing found no current producer. Direct bogus-top-level behavioral RED reproduced both APIs incorrectly admitting it, then the obsolete tuple was removed. Archive/control routes remain compatible; generic legacy open semantics are unchanged. Cost: an unknown historical top-level-only namespace now fails closed, without deletion, migration or any inference of archive loss. No permissive legacy parser was introduced.

This fix proves ordinary close/reopen only. Abrupt process termination leaving extra unselected temporary sessions remains a separate fail-closed orphan protocol boundary. No interrupted/nonterminal bootstrap recovery is authorized. Recovery evidence is strict local filesystem evidence under cooperative account ownership, not vault authentication; subsequent existing transaction authentication remains required. Independent parent review is pending.

## Source SHA-256 (GREEN candidate)

```text
8e8d754b13dcb8cd5fe55a96c04c0803d8036ffc93d2feb41cad01f2f5c61b5d  Sources/KnitNoteCore/CloudSync/SyncAccountStorage.swift
833213aa090a3827daec15fa3b3994194d7453a0de496573e9754d087538bb64  Sources/KnitNoteCore/CloudSync/SyncBootstrapTransaction.swift
ad3e1c8fee57c3953051ef7536599a9c94f2ebcd75c049ff03ce89a79ccfc4eb  Tests/KnitNoteCoreTests/SyncAccountRecoveryInventoryTests.swift
b9deb5565b306e85faabd70bdcf35b5bcc6f18bf40645e642fc01880d73bb022  Tests/KnitNoteCoreTests/SyncAccountRecoveryTransactionTests.swift
```

## Log SHA-256

```text
ca3070115d050ad03ebaf5f742b156ec76c92b14c18c0c12f111d31f48311586  /tmp/rollback-reopen-red.log
873fc495b670884430bda9f3786edb3f85b718ef20594b01384dbdd44a0af569  /tmp/rollback-reopen-green.log
a1a6c6e013f62376f8739fdccd7375869732ae43f39025becdfb62aa9373c0e1  /tmp/rollback-reopen-green-2.log
44cc13e161ebd377e06915802a8857c31caff837288b5bab1f0be24ed021470f  /tmp/rollback-reopen-green-3.log
e664e773f3f8bfc74b371651f55d11c7f76e4c94d27571698db09d3e0b70daf0  /tmp/rollback-reopen-top-level-red.log
2a23f3a2dd39adf2d967496f242eb75b615e46407aca9a35718c1035229f8184  /tmp/rollback-reopen-final-green.log
```

Final `git diff --check` exited 0. Source hashes rechecked unchanged after implementation commit. Report/progress are a separate evidence-only commit so this report can identify the immutable implementation SHA. No implementation changes or compiler starts occur after this handoff. Parent review should compare baseline through the implementation commit; documentation commit contains only this report and progress ledger.
