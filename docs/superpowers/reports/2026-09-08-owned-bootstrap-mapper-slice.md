# Owned bootstrap — mapper slice 1A

2026-09-08. Working-tree implementation based on `1733d1d57877f665ea440e01b1a3e6e5118df920`; not a completed Task 1 checkpoint or release candidate. Automatic delegation remains PAUSED. No new agent was dispatched, and no source commit/push/signing/upload/submission occurred in this slice.

## Changes and boundaries

`ProjectArchiveSyncMapper.swift` now shares its existing archive construction, attachment destination/collision walk and required-slot checks through one private projection function. The new internal `projectUnvalidated` accepts immutable version proofs only: no URL, physical-read callback, staged flag, install capability or filesystem writes. Ordinary `materialize` still checks each source's existence in the source map, staged status, declared proof and actual descriptor-read bytes before that slot's destination checks. Only this physically validating wrapper produces the existing public materialization.

Four new test methods cover empty projections; exact yarn label slot/path and missing/changed proofs; five source/destination ordering cases; legacy and current-library projection parity (including fixture markup) plus physical corruption after planning. The required-media test removes the actual attachment record while retaining the archive's label requirement. The label path expectation is independently constructed from the fixture filename, not from the projection helper.

The existing mapper file is already included in the Core package and Xcode source lists. No new production filename, Xcode target membership, App factory or runtime owned-bootstrap caller was added. The actual App harness symlink was verified to resolve to this worktree's mapper file.

## Fresh evidence

All Swift runs disable live CloudKit integration. Tests ran serially through the inspected 900-second bounded runner; no timeout occurred. Parameterized cases are not added to the reported Swift Testing method counts.

| Check | Result | Log |
| --- | --- | --- |
| Original mapper baseline | 20 tests / 1 suite, exit 0 | /tmp/owned-mapper-baseline-01.log |
| New API RED | Missing projectUnvalidated compile failure, exit 1; not runtime proof | /tmp/owned-mapper-api-red-01.log |
| New projection runtime RED | Throwing scaffold fails both legacy/library cases; ordinary ordering cases pass, exit 1 | /tmp/owned-mapper-runtime-red-01.log |
| Expanded mapper GREEN | 24 tests / 1 suite, exit 0 | /tmp/owned-mapper-green-02.log |
| Deliberate ordering mutation RED | Destination-before-source mutation caught by missing/unstaged/corrupt-byte cases: 3 issues, exit 1 | /tmp/owned-mapper-order-mutation-red-01.log |
| Restored final Core integration | 193 tests / 6 suites, exit 0 | /tmp/owned-mapper-integration-green-01.log |
| Actual App harness | 241 tests / 12 suites, exit 0 | /tmp/owned-mapper-app-green-01.log |

The deliberate mutation was restored before the final Core and App runs. The Core filter covered mapper, bootstrap transaction, deletion capture program, deletion ledger, backup package planning and backup service. Final Core and App logs contain no warnings. Earlier recompilation output includes existing redundant-require warnings; these were not presented as new production failures. Full Core, App-root and unsigned Xcode builds were not rerun for this slice; they remain part of the later coherent checkpoint validation.

## Candidate and log fingerprints

- Mapper SHA256: `20d7590b0ce05f7771714df57d588c26126f1eb50560e056c96f2a26da26d063`.
- Mapper tests SHA256: `34bb1bf5ad0354a9f5c8596c33850f82ef594000511b85aed8f82d5649133d74`.
- Baseline log SHA256: `93e88d114fc3e74f64f30dac9b32cfe5674b0a9a6b4a601b40a11f361cd1ac68`.
- API RED log SHA256: `23070b3544eb400d44516c4e9d3d19b50721a634459b8282490b9b9db44de161`.
- Runtime RED log SHA256: `d4f40351645ccd05c1d4a78f548ff682dd90b359b24ae47c1953a86e5555f1fb`.
- Expanded GREEN log SHA256: `d9f868c3eea575dbcd98000acfd53cbc5ae9f0aa7eccea608813ab08c569bb83`.
- Ordering mutation RED log SHA256: `3473f4696eb49eb5a080e35dd4e2deb2efb4de9f3b3967120c6611d3bbae0ec4`.
- Final Core log SHA256: `68124f56c86e78468e568abfc29613a1a2084b56b4fee06f3add1f1c0ad263d8`.
- App log SHA256: `c237febfba0d6220cd5cde19a795a283e6d83dc1adbe2b76a0330bef19a91351`.

## Review and next step

Main self-review checked source-read ordering, proof/destination association, unchanged collision checks, required media, and separation between unvalidated projection and physical materialization. No independent checkpoint review is claimed. The source/test hashes remained unchanged across final Core and App runs. User scratch `.superpowers/absent-source-design-progress.md` was preserved.

Continue Task 1B (strict manifest/history codecs and full recovery accounting), then 1C/1D (journal trace and complete composition). Tasks 2–4 still own durable preparing, real helper execution, spending/install/rollback, exact terminal sealing, fault matrix and activation gating. This slice alone neither reserves the complete recovery budget nor makes cross-device synchronization or release preparation complete. Keep the implementation in the worktree until the coherent checkpoint review; do not treat this as a standalone helper release.
