# Account source inventory and atomic handoff verification

Status: scoped implementation and frozen validation complete on 2026-09-08. Not whole-sync or release acceptance.

Candidate `42403d955ccdafade6a3470be3c3d1864dc2b93e`, isolated branch `docs/cross-device-sync-design`, version/build unchanged at 1.7.0 (13). Source inventory task commits: bd78c2a, 820e887, de86182; final selected-session lifetime fix 42403d9. No push, signing, upload, submission, App activation or live account/device/schema operation.

## Implemented and reviewed scope

Strict source-backed Inventory/Envelope v2, legacy wire compatibility, embedded pure rollback evidence, native journal inventory-backed effective-pending validation and outer Base64 capacity preflight. Authenticated phase adapter binds immutable source separately from changing phase predecessors. replayComplete consumption atomically publishes restored source authority, validates idempotent retry without old key/expiry dependence, and preserves exact selected FIFO/media/deletion/marker evidence.

All three individual task reviews approved. Broad final review found a real sealed-close availability failure: ordinary close deleted an entry required by the authenticated v2 inventory. The final fix registers exact current-capture retention before selector publication, releases it only after authenticated durable cleanup readiness, preserves controlled abandoned trees on generic reopen and reuses validated close during normal ARC destruction. Scoped re-review found the Important issue addressed with no new breakage. Missing-entry guards were not relaxed.

Latest focused evidence: 161 tests /5 suites, exit0, /tmp/account-source-inventory-sealed-close-green.log SHA256 `3e071528694a960774522f7723191413400e4c342856bb75bb11f7718880d447`. Actual RED contained24 issues across12 sealed-close cases. Final matrix includes18 fresh/rollback and generic/verified/existing reopen cases, data/empty/visible-publication-failure, plus retention identity/ARC/unsafe-close coverage. These are ordinary release and deterministic syscall-failure/reopen tests, not physical power-loss acceptance.

Review artifacts: `/tmp/account-source-inventory-task1-review-20260908.md`, `task2-review-20260908.md`, `task3-review-20260908.md` with the same account-source-inventory prefix; `/tmp/account-source-inventory-final-review-20260908.md` and `/tmp/account-source-inventory-final-fix-review-20260908.md`. Complete implementation reports, RED/GREEN logs and decisions retained in `.superpowers/sdd/2026-09-08-account-source-inventory/` and the absolute log paths those reports name.

## Frozen validation

Session20176 completed with exit0: serial Core/App/root/macOS/iOS with bounded runner, each next stage only after prior exit0. Core unsets KNITNOTE_RUN_CLOUDKIT_INTEGRATION; App/root explicitly disable live tests. Log prefix `/tmp/account-source-inventory-frozen-01-`, suffixes below. Derived paths `/tmp/account-source-inventory-macos-01-derived`, `/tmp/account-source-inventory-ios-01-derived`. Exact commands are written in each log.

| Log suffix | Result | Command seconds | SHA256 |
| --- | --- | --- | --- |
| core.log | 2613 tests /187 suites, exit0 | 1490.390 | d0b5e3f596324156179c22d3b25c0ae77ef7b0808316e06f0d0ce96a5c51f679 |
| app.log | 241 tests /12 suites, exit0 | 69.650 | 2e9005d158466d021c693cb5f94cde1736d1565be9f540ee00eb8dddda39ede2 |
| root.log | 73 tests /7 suites, exit0 | 12.236 | e2fb57154be47b4fe1d3804b8900f85bb6dce671ea937c355514c02ed3ab142d |
| macos.log | unsigned TEST BUILD SUCCEEDED, exit0 | 75.378 | e5362795f4b10251142ca1bd62b3b7b79a30894e54e8eef55d41bf0d5e0ccef4 |
| ios.log | unsigned BUILD SUCCEEDED, exit0 | 47.251 | 2c3d136a6fa723c4a7db7f8644c341d8149048e25de84be4123b9bc4a2c3c5dd |

Diagnostics: App's Development CloudKit test explicitly skipped; no live cloud acceptance inferred. Both Xcode logs have three AppIntents metadata-extraction warnings (no AppIntents.framework dependency). Core includes expected missing-release-artifact negative-test tracebacks, not a failed suite; final test result and command exit are successful. No recorded Swift Testing issues or compiler error diagnostics found.

Runner `/tmp/task4-run-bounded.py` SHA256 `c9fbdb35fa3743e27a7fbf63a1a0cbabfb02ca10e299167c214841a915faec0b`. App harness `/tmp/knitnote-account-domain-jnjVrd/Package.swift` SHA256 `be651083b0427f1d2067dbc2b4fe0e6f1248d46211ff0d125baf7ef7d3c3f04b`; root harness `/tmp/knitnote-app-root-kbh3SM/Package.swift` SHA256 `9d80d3ca53ffbb96203f5cb590a54dac7a095a102d5bba3148afa4eb828e89eb`.

Initial source tree identities: Sources `9e73b0cfb0aedbe48b75b0e3f3cb11c4c4e85e33`; KnitNote `78721554b1f8c32862824939dc7ec2e986fded90`; Tests `dd73be5e4b4b9c577fd8b0a8f174401fbd3dc417`; PBX `c28feabf67cfff7a33ba82d179e532ac3c88722d`. No tracked dirty source at start; controller scratch preserved. Actual-source App symlinks and root whole-Core symlink verified before run. No source edits allowed during validation.

## Rulings made, in decision order

1. Use v1 initial selector with authenticated v2 payload only for exact no-control legacy rollback: no real predecessor exists; cost dual-version route/crash tests and retained first-main fail-closed limit.
2. Keep immutable original source snapshot in authenticated envelope and immediate phase predecessor in control: prevents identity conflation; cost bounded metadata and adapter complexity.
3. Retain only exact safe authenticated temporary UUID trees/parent proofs: preserves captured data; cost storage until authenticated cleanup, no wildcard exception.
4. Commit scoped tasks after focused self-review, then independent review: corrects draft sequencing; cost possible follow-up local fix commits, no publication.
5. Caller computes raw inventory allowance from exact empty outer envelope/inverse Base64: avoids duplicate budget parameters; cost mandatory caller integration coverage.
6. Capacity-before-media means before selected payload materialization, not prerequisite inventory hashing: cost full descriptor hash scan remains and tests must distinguish the boundaries.
7. Extend Task1 narrowly into native journal snapshot proof validation: avoids early selected-data materialization; cost another internal proof-validation boundary and dedicated negative/equivalence tests. Normal snapshot remains unchanged.
8. Correct the initial all-historical-physical-proof requirement to effective pending after native replay: exact ACKs may legitimately reclaim old files; cost explicit ACK equivalence tests, all historical semantic/lineage/cleanup checks retained.
9. Keep Task2 rollback roundtrip under original ownership and do not widen nil-control Storage admission there: cost a real unresolved nested rollback reopen integration blocker; separate reopened fresh/selected-source coverage does not close it.
10. Resolve sealed-close at session lifetime rather than permit missing v2 entries: cost narrow Storage behavior extension and retention regressions.
11. Register exact current capture internally before selected publication and clear only after authenticated durable cleanup: no unauthenticated phase-based deletion permission; cost conservative retained bytes after uncertain/failed publication.
12. Generic open preserves abandoned temporary trees when bounded safe control evidence exists: prevents bypass of selected retention; cost retained legacy-control sessions until authenticated cleanup. No-control behavior unchanged.
13. Normal ARC destruction best-effort reuses validated close: protects pinned data and handles ordinary unselected release; cost cleanup I/O and unreportable failure. No fallback deletion; abrupt crash is a distinct limitation.

## Remaining integration and release gates

- Nil-control nested bootstrap rollback cannot yet reopen through Storage's old top-level evidence check. Original-owner and selected/restored-main reopen acceptance are narrower.
- Abrupt process termination can leave unselected temporary-session orphans that fail closed; no separate orphan protocol has been implemented. Ordinary ARC evidence is not crash evidence.
- Per-entry whole-vault authentication latency at many-file/large-payload scale needs measurement before App activation. Any optimization must preserve authentication/destructive-boundary checks.
- Optional direct journal-resolver tests for wrong root, unsafe/duplicate path, missing/non-directory parent and zero identifiers remain deferred; existing guards are present.
- Owned bootstrap/sourceSpent issuance/reissue, v3 preparing/history, transport fullfetch/ACK, actual producer/factory/account lifecycle gates, product UI/localization and live cloud/device/Watch validation remain future work.

Post-run HEAD and all four source tree identities above are unchanged, with no tracked source diff. The recorded KnitNote identity is the whole KnitNote tree; its App subtree is `20e636b382539585e21a7103419472c810da5746`. Version remains 1.7.0 (13). Controller scratch is preserved; the worktree is not claimed wholly clean.

This report completes only the reviewed source-inventory subplan and cannot establish whole sync or release readiness. All remaining gates above remain open. Automation remains paused after cancellation; no push or submission occurred. Evidence/scratch is deliberately retained for audit and continuation, not deleted.
