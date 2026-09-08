# Owned bootstrap checkpoint2 — durable preparation

Version1.7.0(13); base d42e789bd9dee05dab5046d1d14a2cc05ce56ce3. This checkpoint implements real preparing publication, private synchronous output execution, helper validation and retained-output abort. Installation, source-origin handoff, authenticated v3 seal/restore and App/transport activation remain separate mandatory gates.

## Evidence

- Relevant Core136tests/7suites exit0,84.861s; /tmp/owned-execution-fix1-relevant-green.log SHA03e261d93d28aab8e322db7aaa85b32d6f9e0ea698cc961993dab2e45e18cd52.
- Post-fix controller App241tests/12suites exit0,65.159s; /tmp/owned-execution-fix1-app-green.log SHAc6ac1bc4ca28e85573e218c82e4f0d899bc75e5d94e265ec8f85f7be35eee411. Compiler16274 exited.
- Independent full review found one Important frozen-output durability gap. Fix1 added bound file fsync, bottom-up directory/namespace barriers and exact rechecks before abortedPreparation publication. Genuine pre-fix3test/12issue RED, focused29/1 GREEN and final relevant136/7 GREEN recorded in plan-scoped task-2-execution-report.md. Scoped re-review approved all findings addressed/no new Critical/Important.
- New tests verify persistent abort file/directory sync failure retains preparing, partial bytes and both diagnostics; same-byte inode replacement rejects. Existing real partial-write crash worker exits86 through the built test-bundle runner; a new storage owner opens the same root, retaining device/inode/bytes and pending journal. This is process-interruption evidence, not hardware power-loss testing.
- Source hashes frozen and independently matched; PBX lint and git diff --check passed. New output source has both production source-phase memberships.

## Boundaries and remaining gates

No UUID/history allocation before durable preparing. All output uses declared roles/fixed temps and original helper steps; actual mapper/package/deletion validations run, immutable reuse retains exact bytes and required lock/fsync order. Partial output is evidence, never canonical data. First mainless partial selector fails closed. Legacy authoritative main/fixed-next recovery is narrowly validated; new attempts from v3 terminals still await complete physical source adapter.

History records persist exact hash/name/chain, while historical UUID entries also persist inode evidence. Cross-restart same-byte replacement of a History record file alone is not distinguishable by the accepted wire; current/same-call and later recovery capture identity checks remain. No wider identity exemption.

Minor deferred to checkpoint4: extend complete helper trace beyond current write/output indices to all synchronization/validation events and lock lifetime; fix1 separately covers the required abort barrier order. Also retain checkpoint1's isolated committed-budget regression improvement.

Task3 must implement exact source spend, installer/commit/rollback, abort/rollback source-origin handoff, coherent authenticated v3 inventory/seal/cleanup/restore and repeated retry. Task4 must finish the full syscall/crash matrix, review and unsigned platform checks. No signing, merge, push, upload or submission occurred; device/schema/privacy/store acceptance and exact-candidate final authorization remain required.
