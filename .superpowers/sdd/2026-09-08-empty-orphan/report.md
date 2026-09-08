# Inert empty temporary residue report

## Controller scoped acceptance — 2026-09-08

Same-reviewer re-review accepted fix19dc1b033fa65f4de07eff9d165400b12ec379e4: prior Important addressed, no remaining Critical/Important/Minor in fix range. Main read complete review and both implementation reports. Transition snapshot now spans later main/next synchronization and legacy publication callbacks. Existing fixed consume full-entry baseline covers its bulk synchronization; post-publication rejection does not imply unchanged main. Test-only beforeRename hook ordering remains explicitly outside this bounded claim.

On unchanged code19dc1b0 / evidence HEADbd4fb0e7f1d9d177c4f9b8456e412b920e0a148a, controller ran serial actual-source App/root tests and fresh unsigned macOS/iOS builds. Session84329 reaped exit0; no competing compiler/source changes. Each next stage ran only after preceding exit0. Core focused170/5 result above was not repeated as a full Core run.

| Log | Verified result | Command seconds | SHA256 |
| --- | --- | --- | --- |
| /tmp/empty-orphan-app-01.log | 241 tests /12 suites, exit0 | 65.585 | 0e02a007812b52b2b14b9fea514e060057b6e71f548d731d4192ff473bfa4934 |
| /tmp/empty-orphan-root-01.log | 73 tests /7 suites, exit0 | 8.883 | 29959043f0c0222de443e68d1eec66ceb4054522bbbc04faac1ae5d4e0264069 |
| /tmp/empty-orphan-macos-01.log | unsigned TEST BUILD SUCCEEDED, exit0 | 47.095 | 03efd46a661feb0720dcdbecfdb1f735941bcba937cefc621293cec3724a28aa |
| /tmp/empty-orphan-ios-01.log | unsigned BUILD SUCCEEDED, exit0 | 44.021 | 29ab6664fd42891034d8ef8ed691651c8d4d536be95663d7b2d6981a65099a05 |

Both Xcode logs contain three expected AppIntents metadata extraction warnings (no framework dependency), no compiler errors. App live Development CloudKit remains opted out. Actual-source harnesses and bounded runner are the same verified paths used by rollback-reopen acceptance; commands are retained in logs. Fresh derived directories `/tmp/empty-orphan-macos-01-derived` and `/tmp/empty-orphan-ios-01-derived`.

Frozen trees: Sources7a72b0be70e6e8bef1e3cfd80a109e1061b32801; Tests6403d5ec3b91e6d1870fafbd9d8e56dcee941d4e; KnitNote78721554b1f8c32862824939dc7ec2e986fded90; PBXc28feabf67cfff7a33ba82d179e532ac3c88722d. HEAD unchanged and no tracked diff at completion. Original controller scratch retained. Version remains1.7.0(13); no signing, upload, push or submission.

This completes only inert-empty residue acceptance under the documented cooperative ownership model and synthetic residue tests. Nonempty orphan recovery/reclamation, realistic many-file performance, owned bootstrap/sourceSpent/reissue/preparing history, transport fullfetch/ACK and actual App/cloud/device release integration remain separate gates. This is not whole-sync or release readiness. Older pending-review prose below records chronology and is superseded by this section.

CURRENT REVIEW FIX COMPLETE: implementation **19dc1b033fa65f4de07eff9d165400b12ec379e4** (`fix: bind inert snapshot through recovery phase publication`), baseline a9c8337e3f197d35848930d38df5bbb389bf5edf. Final /tmp/empty-orphan-fix-green.log passed **170 tests / 5 suites, EXIT 0**, 84.425s tests / 107.625s elapsed. RED has 70 issues across 20 failing later-sync cases; 8 ordinary consume cases already passed via full baseline equality. Both compiler sessions reaped and stopped. Same reviewer re-review next. Earlier evidence below is chronological and superseded by the appended fix report where applicable.

Baseline ff559299184e0f3e18e87c497e9a37534ca39e23. Implementation commit **8562380ccaf3b3c364ddaaef97300442e6003351** (`fix: retain authenticated inert temporary residue`). Final focused verification passed; all four compiler sessions reaped and stopped before commit/report completion. Approved bounded brainstorming design, systematic debugging, TDD/test-writing and verification-before-completion skills applied. Parent owns independent review; no subagents spawned.

Only authenticated selected recovery may tolerate physically verified empty, canonical immediate UUID directories absent (including descendants) from captured inventory. These are inert physical observations, not historical ownership receipts. Never delete or put them in cleanup worklists. Preserve all captured entry rules and existing capacity bounds. Extra empty directories accumulate against current metadata caps; future ordinary source capture may inventory them. Nonempty orphan recovery, App, transport, wire formats and public ownership authority remain outside scope.

## Root cause and bounded implementation

The selected recovery paths `remainingEntries` and `validateRestored` rejected every directory absent from the authenticated capture, except the current Storage session. A second reopening after a prior uncaptured empty session remained on disk therefore failed with changedInventory, even after successful vault authentication. Ordinary ARC release is not that scenario: Storage.deinit invokes close and removes an unregistered current session.

Only `Sources/KnitNoteCore/CloudSync/SyncAccountRecoveryTransaction.swift` and its existing transaction test file changed. No Storage helper was needed: existing account-owned descriptor access, openDirectory/openParent and binding validation suffice. Report/progress are the only additional files.

- Shared private `inertTemporaryEntries` receives Authorized (already vault-authenticated) evidence and fresh descriptor inventory. It accepts only immediate canonical lowercase UUID directory names, absent from captured paths and descendants, with zero inventory descendants. It opens through the owned temporary root using nofollow, checks type/device/inode against both inventory and named entry, enumerates a fresh directory descriptor to require literally only dot entries, then rechecks identity and Storage bindings. Empty child directories are not empty enough.
- `remainingEntries` excludes only classified inert entries from its returned cleanup worklist. All captured equality, sealed completeness, legacy legitimate-missing, retained-directory and current-session rules remain unchanged. An empty captured directory or a captured directory whose file disappeared cannot use the exception.
- `validateRestored` uses the same classifier; legitimate restored files, replay proof and captured retained directory checks remain unchanged.
- Parent explicitly approved barrier snapshot validation after trace showed existing barrier checked only selected payload/control. Before and after existing synchronization, classify from fresh inventories and require identical inert Entry arrays. New names, disappearing names, inode replacement, or acquiring any child fail before the next unlink/install/consume effect. Vault/control reauthentication and other transition barriers remain in place.

## Behavioral evidence

All runs used the single authorized lane from this worktree, with only the log filename changed:

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 1200 arch -arm64 swift test --no-parallel --filter 'SyncAccountSourceStateTests|SyncAccountStorageTests|SyncAccountRecoveryInventoryTests|SyncAccountRecoveryTransactionTests|SyncBootstrapTransactionTests' > /tmp/empty-orphan-red.log 2>&1
```

Bounded runner SHA-256: `c9fbdb35fa3743e27a7fbf63a1a0cbabfb02ca10e299167c214841a915faec0b`. Core integration override unset. Focused compiler cache access used authorized escalation; no App, Xcode, full chain, live account, signing, release or push.

| /tmp log | Actual result |
| --- | --- |
| empty-orphan-red.log | 167 tests / 5 suites, EXIT 1, exactly ten changedInventory issues (fresh/rollback × five selected phases), tests 49.129s / elapsed 72.011s. Production unchanged before behavioral RED. Session 72391 reaped. |
| empty-orphan-green.log | 169 tests / 5 suites passed, EXIT 0, tests 68.798s / elapsed 93.338s. Session 36531 reaped. |
| empty-orphan-final-green.log | 169 tests / 5 suites passed, EXIT 0, tests 71.073s / elapsed 93.71s. Session 56076 reaped. This includes removal of an unrelated assertion and comment correction; before adding explicit wrong-key coverage and deterministic uppercase UUID. |
| empty-orphan-final-green-2.log | 169 tests / 5 suites passed, EXIT 0, tests 68.336s / elapsed 89.689s. Final candidate includes all thirteen negatives, including wrong key and deterministic uppercase UUID. No warning/error/issue output. Session 54582 reaped. |

No compiler errors or intermediate unexpected test failures occurred. The second final run is for test completeness, not a production repair after GREEN.

## Tests and self-review

- Ten real selected-recovery cases cover fresh source and real prepareReconstruction/install/rollback with media, each in sealed, cleanupStarted, cleanupComplete, restoreStarted and replayComplete. Intermediate phases are reached by real synchronized transition cuts, not fake phase JSON.
- A is genuinely selected and normally closed. B genuinely opens/closes. The fixture explicitly recreates only B's empty UUID directory to model abrupt-exit **filesystem residue**; it does not claim ARC is a crash or execute/kill a child process. C and another owner authenticate through repeated reopens with one, then three, extra empty directories. Read-only admission preserves all bytes, including control and ciphertext. Cleanup/restore/consume retains each residue empty; exact pending/media bytes survive. Recapture inventories them normally. Once captured by a later authenticated selection, the ordinary captured rules apply; no permanent cleanup exemption is minted.
- Thirteen negatives cover nonempty, nested-empty, fixed uppercase UUID, unknown name, symlink, regular file, captured empty directory removed/replaced, captured directory emptied by removing a captured file, missing key, wrong existing AES key, expiry and stale control. Authentication/recovery throws and all existing bytes/names remain unchanged.
- Nine deterministic existing synchronization cuts cover content acquisition, identity replacement and newly appearing empty directories × cleanup, restore and consume. They assert the callback was reached, exact control bytes remain unchanged, and no on-disk byte change beyond the fixture's deliberate injection occurred. Thus the failure is before the next effect, not merely a later reporting failure.
- Self-review checked that classification is only reachable with private Authorized evidence, all directory handles are closed, readdir starts with a fresh open description, literal descendants never qualify independently, cleanup exclusion is explicit, and the selected captured completeness guard is untouched. Existing 5-suite coverage remains included rather than compiling isolated new tests only.

## Costs and limits

Extra directory entries intentionally remain and count against existing metadata limits; no cap increased. Barrier validation adds account inventory/hashing passes and directory I/O. This was explicitly accepted, not optimized or benchmarked as a performance improvement. The change proves safe handling of inert empty filesystem residue, not provenance of any abandoned session. Nonempty/unknown orphan recovery remains fail-closed and requires a separate design. No reclamation, ownership inference, new disk wire, public trusted flag or source minting was introduced.

## Hashes

```text
ee18cfcecd9f855e65f57af5f108537ee5d7a127df1f9af7f29d227c602a630b  /tmp/empty-orphan-red.log
a8f7fca3ed064047d29c510809ddfa245b8e2f818ae52fd3b5ea24aa9ff43b00  /tmp/empty-orphan-green.log
7f7263096a0a965ed95b85614ecf2f03b6539a3c2627f673328d1ed2216ea28a  /tmp/empty-orphan-final-green.log
f8b3c18b3f427e9a2696dd1de935cf55849b2d64caf6cb118d199e9db648b312  /tmp/empty-orphan-final-green-2.log
04671e6f746619431d61fefc8a3305b76ae8a42b4be7042966f8c190b6ea8ea1  Sources/KnitNoteCore/CloudSync/SyncAccountRecoveryTransaction.swift
26e8a631d21d0ee6ef17453467ab08b657e2f84595a4ed72911472efccaf0517  Tests/KnitNoteCoreTests/SyncAccountRecoveryTransactionTests.swift
```

Final `git diff --check` exited 0; source/test hashes rechecked after compiler completion. Scoped implementation commit has only Transaction and its tests. This report/progress is a separate evidence-only commit so the report records the immutable implementation SHA. Controller scratch `.superpowers/absent-source-design-progress.md` remained untouched/untracked. No subsequent compiler or implementation work is planned before parent independent review.

## Independent-review fix wave (19dc1b0)

Read receiving-code-review, TDD and its test-writing reference. Verified the Important finding against actual control publisher and transaction code: the barrier's local snapshot did not span `controlFile.replace`'s later main synchronization or next-file write/synchronization. Its callback merely classified a fresh set. The legacy transition similarly synchronized directly outside the wrapper, then could publish and proceed to cleanup. This was a real gap, not a test expectation adjustment.

### Behavioral RED and GREEN

Exact focused command, changing only red to green in the output filename:

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 1200 arch -arm64 swift test --no-parallel --filter 'SyncAccountSourceStateTests|SyncAccountStorageTests|SyncAccountRecoveryInventoryTests|SyncAccountRecoveryTransactionTests|SyncBootstrapTransactionTests' > /tmp/empty-orphan-fix-red.log 2>&1
```

- `/tmp/empty-orphan-fix-red.log`: 170 tests / 5 suites, EXIT 1, tests 75.258s / elapsed 97.622s. Exactly **70 issues in 20 failing parameter cases**: fresh/rollback cleanup and restore, plus legacy replayComplete normalization, each with later-main appearance/removal and next-file appearance/replacement. Errors were incorrectly not thrown, main changed, domain bytes changed, and next derivatives were consumed when they should remain. The **8 ordinary consume cases already passed** via the existing complete baseline checks; they are not represented as failing RED. Production was unchanged until the real failures were observed. Session 24228 reaped.
- `/tmp/empty-orphan-fix-green.log`: 170 tests / 5 suites passed, EXIT 0, tests 84.425s / elapsed 107.625s, all 28 new cases passed, no warning/error/recorded issue. Session 59836 reaped. `git diff --check` exited 0. No compiler remained active before commit/report completion.

Tests use actual synchronized transitions and actual fresh or missing-archive rollback selections. Cleanup targets the third main synchronization, restore the second, and consume/legacy normalization the third; next-file cuts target the actual next descriptor. The callback must be reached. Main and domain bytes remain exact on rejection. A next-file synchronization has already written a derivative, so tests retain/allow exactly that next file rather than asserting impossible whole-tree byte equality. At later-main cuts the prior derivative (including an opaque legacy derivative) remains exact.

### Minimal implementation and inspected paths

Only `SyncAccountRecoveryTransaction.swift` and its existing tests changed in this fix commit (71 additions / 2 deletions). `transition` now captures one authenticated inert Entry array before its initial barrier. The source validator compares against that fixed array before and after payload/inventory validation. That same closure is passed into legacyTransition, checked after its direct barriers and synchronized derivative removal/write, and before rename; it is also checked after transition publication before returning a refreshed authorization. Reclassification is no longer a new acceptance baseline halfway through the transition. No captured equality, completeness, physical classifier, wire, capacity or ownership rules changed.

Inspected consume independently: `consumeRestoredSelection` captures `entries` **before** its bulk directory/file synchronization loop. After the loop it calls `restoredSourceBaseline(value, entries: entries, ...)`, whose first and final guards require `access.entries() == entries`. That same fixed full-inventory baseline is checked inside the control replace callback after later main and next-file synchronization. Therefore changes during the earlier bulk consume sync are already covered by fixed full-entry equality before source publication, rather than only by a freshly computed inert set. The eight targeted consume cases confirm the later replacement checks; no redundant consume production change was made. Its legacy opaque-derivative normalization uses the now-fixed `transition` and is directly covered by the four rollback-normalize cases. Initial seal already uses exact full capture entries in its source callback and does not use the selected inert exception.

Self-review checked callback ordering against every actual synchronization in both transition implementations, fixed snapshot capture placement, main preservation before publication, derivative evidence after a next-write cut, and the existing consume full-entry guards. Additional validation I/O is accepted; no performance refactor was mixed in.

### Parent ruling and remaining limit

Parent explicitly kept ControlFile outside this wave: its test-only `beforeRename` hook remains after the final source callback and before rename. This fix targets actual synchronization callbacks, not a new permission for adversarial mutation inside that artificial hook. That existing test-boundary ordering is **not claimed covered**. No control publisher edit was made absent a concrete production path. Earlier inert-empty retention costs and nonempty-orphan fail-closed limits remain unchanged. Independent same-reviewer re-review is pending; no release or App acceptance is claimed.

### Fix hashes

```text
ece097fe02cc791f7ea2619070f5d60d94195eef5931c100e9dd00591bd87762  /tmp/empty-orphan-fix-red.log
1b78df9a1f2295d0502f56f40d447b28c34219a13a7e48b8b46c1424694227de  /tmp/empty-orphan-fix-green.log
2f738c25e024b409590c51258f1273cdd2b961853edd57516b2b35fbb252a1b2  Sources/KnitNoteCore/CloudSync/SyncAccountRecoveryTransaction.swift
c6ad69dd6dbf021be5cec9d79a51396fada49fb67f7f1292559b3ce4957e5478  Tests/KnitNoteCoreTests/SyncAccountRecoveryTransactionTests.swift
```

Implementation commit is 19dc1b033fa65f4de07eff9d165400b12ec379e4; the following evidence-only commit contains report/progress. Original controller scratch remains untracked and unchanged. No further test or edit wave is planned before re-review.
