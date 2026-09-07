# Bootstrap current-context recovery verification

狀態：本子計畫完成。實作、兩次獨立審查及固定候選四項完整驗證均通過；這不是帳號／雲端／實機或發布驗收。

Version 1.7.0 (13), iOS 18 / macOS 15 / watchOS 11. Worktree `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`, branch `docs/cross-device-sync-design`.

## Scope and source

Plan `docs/superpowers/plans/2026-09-07-bootstrap-current-context-recovery.md`, approved parent owner/lifecycle integration specifications. Whole-subplan baseline 0416855, task baseline `eddcfabf9af35ef812695d62b8aeca93720a0dde`, implementation `747d83949b7541ddfb4f5e2be8c334879e8f1187`.

The single explicit Core `recoverUnderCurrentContext()` entry point admits historical same-account bootstrap evidence only under the newly supplied current validator. Ordinary APIs still require exact epoch/freeze context. Committed recovery returns through the existing canonical handoff and leaves manifest/receipt unchanged. Nonterminal recovery uses original rollback; only exact terminal rolledBack evidence can rebind existing context fields for new preparation. Missing evidence is nil, never local-ready.

Changed files: existing SyncBootstrapTransaction, SyncBootstrapTransactionTests and JSONProjectStoreCanonicalDurabilityTests. No App, wire, schema, byte-limit, purchase, preference or production-data change.

## Focused implementation evidence

Preserved report `.superpowers/sdd/2026-09-07-bootstrap-current-context-recovery/task-1-report.md` records all commands and intermediate failures. Compiler-cache sandbox failures, macro compile failures and fixture device-ID mismatches are explicitly separate from passing evidence; original logs retained.

- Final focused actual-source run `/tmp/bootstrap-current-final-green.log`: 53 tests / 2 suites, exit 0; 21.284 command seconds, no final warnings.
- Runtime current-validator removal `/tmp/bootstrap-current-guard-mutation-red.log`: two tests fail with five issues, including retained handoff accepting revoked authority and a forbidden live move. Guard restored before final GREEN.
- Clean API absence `/tmp/bootstrap-current-api-red-clean.log`: missing public method compiler RED; not substituted for behavior proof.
- Thirteen corruption/foreign cases and nine interruption boundaries compare actual durable trees, Original, private bytes and pending attachment sources. Actual store canonical activation consumes recovered handoff, then normal reopen uses `bootstrap: nil`; later daily edits invalidate bootstrap reuse.

Task review `/tmp/bootstrap-current-context-task-review.md` approved both compliance and quality with no findings. Whole-subplan review `/tmp/bootstrap-current-context-final-review.md` also approved without findings. No earlier App-root test result is reused as proof for this changed Core candidate.

## Final frozen validation

Unified session 72527 completed exit 0 on unchanged `747d83949b7541ddfb4f5e2be8c334879e8f1187`. All four serial commands succeeded; controller verified no source/test/PBX/project.yml diff. Only completion documentation changed. The inspected bounded runner limited Core to 3600s and each later step to 900s; each next command required prior exit 0.

| Check | Final result | Command seconds | Log |
| --- | --- | --- | --- |
| Full Core | 2528 tests / 186 suites, exit 0 | 1403.156 | `/tmp/bootstrap-current-frozen-core.log` |
| Actual-source App/hosting | 73 tests / 7 suites, exit 0 | 6.309 | `/tmp/bootstrap-current-frozen-combined.log` |
| macOS unsigned build-for-testing | TEST BUILD SUCCEEDED, exit 0 | 44.415 | `/tmp/bootstrap-current-frozen-macos.log` |
| iOS unsigned build | BUILD SUCCEEDED, exit 0 | 42.695 | `/tmp/bootstrap-current-frozen-ios.log` |

Core and combined commands used `arch -arm64 swift test --no-parallel`, combined with `--package-path /tmp/knitnote-app-root-kbh3SM`. Xcode destinations were `platform=macOS,arch=arm64` and `generic/platform=iOS`, with `CODE_SIGNING_ALLOWED=NO` and isolated `/tmp/bootstrap-current-{macos,ios}-derived` directories. No App/test-host launch, real service, signing or install occurred.

Diagnostics preserved: Core's three provenance mismatch messages and four missing-artifact negative cases with chained Python tracebacks belong to explicitly passing rejection tests. Combined has no warning/error matches. macOS and iOS each emitted three AppIntents metadata-extraction warnings; unsigned strip-bitcode messages were three and two respectively. No Swift compiler errors/warnings appeared. These logs are not described as pristine, and unsigned results do not establish device acceptance.

SHA-256:

```text
0e01b4010bb7890f5da64e133ba1a98693b6d3957692355383d009d7e3b68cbe  bootstrap-current-frozen-core.log
cc7e542faf1bad4d53323119313e2b8790b35fe6a0309df3977fe3f1694d1098  bootstrap-current-frozen-combined.log
06da40eb3e13a81a2cb48631bb5085a11eac049a1884adf73fb02f041c1d445f  bootstrap-current-frozen-macos.log
ea97de6d8ae290af88e3888683ef67b88bd4c5b98dc9e07bb0aae137bdf1f169  bootstrap-current-frozen-ios.log
```

Frozen identities: Sources `381d2d1db6d9aa24ba1c0049f8d476bfffb67790`; App `20e636b382539585e21a7103419472c810da5746`; Tests `d1ca7ccaec9d8c2523af6b81676995392f4afc5f`; PBX `f53ecc5c062fa0f122ca092b48b0f7c908eb9ce9`. Only controller documentation changed before launch.

## Decisions and costs

1. Keep historical recovery in the existing Core authority, not App-owned manifest decoding. If wrong, the App install call site may need adaptation; there is no competing data policy or transaction to reconcile.
2. Preserve committed evidence and validate new current ownership through a private historical facade; allow existing context rebinding only after verified rollback. If wrong, stale capabilities or invalid recovery could escape, so the guard-removal RED, corruption/Original assertions and independent authority review are required.

## Remaining integration boundaries

The concrete App account domain installer must retain the actual storage owner, recover bootstrap before terminal namespace validation, validate canonical/source/journal authority and distinguish local readiness from fetch success. Identity confirmation/serialization, first remote preparation, proven legacy ownership, account-specific media/ACK source resolution, product UI/localization, live cloud/device/Watch acceptance and release gates remain unfinished. No signing, install, push, schema deployment, upload, submission or production-data cleanup occurred.
