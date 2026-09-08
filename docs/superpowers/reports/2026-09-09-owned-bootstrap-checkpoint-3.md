# Owned bootstrap checkpoint3 — terminal authority and authenticated recovery

Version remains 1.7.0 (13). Base commit: `63e8a5c8c34002f631fa7b2e37dbbd86f6d5722e`, branch `docs/cross-device-sync-design`. This is a reviewed local Core integration checkpoint, not App activation, release readiness, push, upload or App Review submission.

## Implemented

- Durable legacy absent-source handoff; exact source-control, full former-source identity and pending baseline retained through prepared phases and sourceSpent. No source authority derived from transient inventory identities.
- Shared ordinary/owned install and rollback sequencing; private phase-bound native journal commit, receipt and legal-prefix Failed evidence. Actual frozen outputs stay unchanged until authenticated cleanup.
- Complete immutable-role portable digest, same-owner physical identity pins and strict terminal/history bindings. Authenticated recovery embeds exact bounded history and restores only selected pending/deletion data.
- Read-only Original journal backing preserves native logical URLs, FIFO and encoders, with distinct coordination and cache invalidation on all exits. No repairing loader or ordinary temporary cleanup on owned failed outputs.
- True encrypted seal/cleanup/restore/consume for fresh, legacy rollback, restored selection and archive origins, including media/deletion bytes and repeated handoff/retry.
- Recovery-only missing-live Storage admission for both absent/spent and archive/nil-control sources, with exact read-only preflight and validation under account ownership. No empty replacement working-set.
- Forward install/commit require exact epoch/freeze context before selector synchronization. Historical context is confined to rollback/recovery and terminal-origin handling.

## Review and verification

Independent task review found two Important issues: archive-origin crash gaps could not reopen, and stale epoch/freeze tokens could advance. Both were reproduced before repair. Scoped fix1 re-review marked both ADDRESSED with no new Critical/Important breakage. It inspected the exact 492-line fix and recorded test evidence; no reviewer reran suites or mutated code.

All runs used isolated test accounts, memory-only vault keys and a bounded single compiler lane. No live account, Keychain, device, schema or signing operation occurred.

| Frozen validation | Result | Log |
| --- | --- | --- |
| Complete integration before review fixes, including full former-source witness | 312 tests /12 suites, exit0 | `/tmp/owned-authority-resume-regression-01.log` |
| Supplemental native segment/final-fix, unchanged by fix1 | 68 tests /2 suites, exit0 | `/tmp/owned-authority-resume-native-journal-01.log` |
| Genuine review-finding RED | 2 tests /22 issues, exit1 | `/tmp/owned-authority-fix1-red-02.log` |
| Fix1 focused paths, including 8 actual subprocess gaps and16 archive evidence negatives | 5 tests /1 suite, exit0 | `/tmp/owned-authority-fix1-reopen-green-01.log` |
| Post-fix affected integration, including complete media chains | 211 tests /6 suites, exit0;314.954s total | `/tmp/owned-authority-fix1-regression-01.log` |
| Post-fix actual-source App account-domain harness | 241 tests /12 suites, exit0;72.923s total | `/tmp/owned-authority-fix1-app-01.log` |

Do not add overlapping test counts as unique tests. Post-fix tests cover the three files changed by fix1; unchanged native parser suites retain their frozen evidence. Final logs checked for warning/error lines and `git diff --check` passed. Earlier interrupted or compiler/fixture-failure runs are not completion evidence.

Final affected encoded capture/bound bytes: legacy rollback549170/51115091; restored selection213966/42932131; fresh17990/5535695; archive72176/8664175. Actual complete envelopes remain below the existing planned bounds; no capacity cap increased.

Key evidence SHA-256:

```text
9874daf0411b0c3416b70c65c2e63421944c9101d84334fa0ba2551a3769cc99  resume-regression-01.log
575c6369e2ceaff8f6a31bed1d26e4803155ebc974d785dadca5769432db311b  resume-native-journal-01.log
fee1cef411a86646aa2a955d8995e372864e1a6dfc688c7e0490c59c00db3f20  fix1-regression-01.log
cdb02d2bd237229ad0fddcc292b97ac52acc5bd2dc235c564624cb03a42dd170  fix1-app-01.log
c91da1031131912fa8b12dcde937d9ff9fa5299e289cde39ff3153fb4269b3e3  SyncBootstrapOwnedTransaction.swift
c24d625f613efba24d904c3c8d6cf2c45f1184e24bdd11dfa750e1fa9cba8e42  SyncAccountStorage.swift
271aad7a6b4ac7931a5858f69f15e49664681fce961a77e9bb8ccd9f58c50634  SyncBootstrapOwnedTransactionTests.swift
```

## Explicit limits and remaining gates

Unfrozen auxiliary trees do not persist prior inode values; portable content/path proofs plus same-owner physical pins cannot distinguish identical-byte replacement across restart from a previously unstored inode. Persisted live/staged, frozen and historical identities keep their stronger checks. Authenticated post-cleanup decoding cannot reconstruct append bytes from a deleted original's hash; first terminal publication still proves the actual legal prefix from physical source bytes.

Checkpoint4 remains: exhaustive syscall/durability/move/commit interruption matrix, broader helper sync/validation/lock-lifetime traces, isolated committed-budget test cause, target/platform validation and internal activation gate. Two stale lifecycle comments from review remain deferred there. App runtime/transport/device acceptance, schema/privacy/store evidence and final exact-candidate release authorization are separate. No release readiness is inferred from these tests.

The detailed implementation/fix reports, red/green classifications and review packages are preserved under `.superpowers/sdd/2026-09-08-owned-bootstrap-integration/`. The unrelated `.superpowers/absent-source-design-progress.md` is untouched. Automatic delegation remains paused after the user's cancellation; the explicit subsequent `go on` resumed only this local work.
