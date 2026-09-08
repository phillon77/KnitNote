# Nil-control rollback reopen progress

Current handoff: scoped implementation commit `33c1e14bcd895b72a00656c6562ac6dbd4c2dd8c`; final `/tmp/rollback-reopen-final-green.log` has 166 tests / 5 suites passed, EXIT 0, 45.706s tests / 52.872s elapsed. Session 24974 reaped; all compiler work stopped. Parent independent review next. No unresolved design ruling; abrupt-process orphan recovery remains out of scope. Evidence-only report/progress commit follows implementation so report records exact implementation SHA.

Baseline: d92c7c19aabfc98e495b67a15d77ba4795acf653. Owner: source_inventory_task3. Single focused compiler lane assigned; no other compilers started by this worker.

Approved scope: Storage admission for exact no-control, missingArchive + rolledBack evidence only, reusing strict Bootstrap parser and physical reader. Read-only preflight must precede lock/scaffold creation; repeat under ownership. No source minting, orphan protocol, App, transport, release, or push.

Status: behavioral RED completed, /tmp/rollback-reopen-red.log exit 1: 162 tests / 5 suites, exactly four expected unsafePath issues from both APIs × with/without media/deletion. Session 29514 reaped. Minimal two-gate production fix implemented with shared physical reader and full preflight/owned snapshot validation.

Intermediate /tmp/rollback-reopen-green.log exit 1: 163 tests / 5 suites, positive cases passed; two negative fixture lookups used a guessed journal filename. Corrected to paths.mutationJournalURL. Session 51731 reaped.

Second intermediate /tmp/rollback-reopen-green-2.log exit 1: 166 tests / 5 suites, two remaining fixture lookup failures. Native journal inspection confirmed pending.json is a logical location; fresh frames live in pending.json.segment. Both mutation tests now target that existing physical segment. Session 14373 reaped.

Final focused verification: /tmp/rollback-reopen-green-3.log, 166 tests / 5 suites passed, EXIT 0, tests 40.960s, elapsed 61.893s. Session 72090 reaped; compiler stopped. Direct negative matrix includes malformed/foreign/nonterminal/mismatched evidence, conflicting controls, symlink/hardlink/FIFO; valid committed evidence remains rejected; generation rejection and owned-validation evidence changes preserve bytes.

Self-review concern sent to parent: existing top-level `.KnitNote-SyncBootstrap/active.json` regular-file existence route is unchanged. The new nested route is strict, but removing the obsolete top-level compatibility route requires the parent ruling requested before further production changes. Archive/control compatibility remains unchanged. No abrupt-process-crash or orphan recovery claim.

Parent ruling received: remove obsolete top-level bootstrap filename-only route from verified/existing admission; preserve archive/control and generic legacy open semantics. Unknown top-level-only namespaces must fail closed without deletion or migration. Added direct top-level-only bogus proof RED and extended existing real media/deletion transaction test with ordinary close + both verified/existing APIs before seal, cleanup, restore, consume and reseal. Current single compiler session 19938, /tmp/rollback-reopen-top-level-red.log. Production route removal waits for behavioral RED.

Completed ruling: top-level RED exited 1 with exactly six expected admission/bytes/names issues for the two APIs; actual reopened full transaction cases passed. Session 19938 reaped, obsolete route removed, final GREEN above completed. Both original nested rollback RED and this second direct bypass RED are preserved with hashes in report.md. The older status paragraphs above are chronological evidence, not current blockers.

Report: `.superpowers/sdd/2026-09-08-rollback-reopen/report.md`.
