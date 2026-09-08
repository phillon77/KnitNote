# Inert empty temporary residue report

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
