# Account source control foundation verification

Candidate: `cc0ae51b7aaba5670864aa5f52a3dfdeb2752aa6`, branch `docs/cross-device-sync-design`, existing isolated worktree. Version/build remains 1.7.0 (13). Foundation commit fabf135 plus legacy recovery compatibility fix cc0ae51. This is local foundation validation, not App activation, cloud/device acceptance, push or submission evidence.

## Reviewed behavior

Internal source models and portable baseline, backward-compatible v1/v2 main/next codec, descriptor-relative bounded atomic control replacement, and verified fresh/existing storage opening. Freshness derives only from actual mkdir, existing ambiguous missing namespaces fail closed, generic open remains unchanged. Actual journal initialization and recovery snapshot do not mutate fresh baseline. No account/domain writer is newly admitted.

Task review approved; final review found interrupted v1 main/next compatibility failure. Real transition fault tests reproduced complete and torn next through both new opens. Fix preserves bounded legacy derivative as routing-only, requires strict recognizable v2 predecessor validation, rejects mainless next, and prevents new helper replacement of legacy derivatives. Existing authenticated transaction remains sole rebuild owner. Scoped final re-review approved without new breakage.

Focused final fix: 62 tests / 3 suites, exit0; `/tmp/account-source-task1-fix1-green.log`, SHA256 `9b1e91dd9f40e72af9febb189d89d4d8107c0832582ab0ad79d17a7c8569bf36`. RED had four expected routing failures. Full report and review evidence retained under `.superpowers/sdd/2026-09-08-account-source-control/` and `/tmp/account-source-control-{task-review,final-review,fix-review}-20260908.md`.

## Frozen validation

Session39375 completed and reaped exit0. Commands ran serially, next only after previous exit0. Core unset KNITNOTE_RUN_CLOUDKIT_INTEGRATION; App/root explicitly disabled live integration. Used bounded runner with established commands from missing-archive verification report; Core3600s, remaining stages900s. Logs below are exact captured command/output/exit evidence.

| Stage | Result | Log SHA256 |
| --- | --- | --- |
| Core | 2567 tests /187 suites; exit0;1388.697s | 358652b8413275a160e7a940b9f53d21469e92bd9149c1d716b9069ce9f3ccf9 |
| App | 241 tests /12 suites; exit0;62.144s | 9fa97cd865c7a2fcd6690e500ccd459c456e256619b30595db4702493f2d1ec1 |
| Root/Watch | 73 tests /7 suites; exit0;8.126s | 36c4c2b748738b237aca8b90cf423e5c73ea75c2484b02797ade6b5d3025c656 |
| macOS unsigned build-for-testing | succeeded; exit0;70.609s | aac636b1e5e513f4bc1cd201674bcaf993f206efc0d8236b4945a0a03399ac02 |
| iOS unsigned build | succeeded; exit0;43.063s | b210bf7b14beca6a9d5dac23c8795b1dd44f18aa9992778c623658fb187eddae |

Log prefix `/tmp/account-source-control-frozen-02-`, suffixes `core.log`, `app.log`, `root.log`, `macos.log`, `ios.log`. Derived directories `/tmp/account-source-control-macos-02-derived` and `/tmp/account-source-control-ios-02-derived`.

Diagnostics: one explicitly skipped Development CloudKit test. Three AppIntents metadata-extraction warnings per platform because those targets lack AppIntents.framework. No test issues, compiler errors or timeouts in frozen02. Earlier frozen01/session13752 stopped before tests, exit1 after1.326s, because sandbox denied compiler ModuleCache output; exact cache escalation allowed frozen02. Earlier failed log preserved, not counted as behavioral RED or successful validation.

Source trees verified identical before/after frozen02: Sources `504421f75244eaa5ad8fa751cadb8d4033d13a0e`, KnitNote `78721554b1f8c32862824939dc7ec2e986fded90`, Tests `fab35e9f9a19e2930b1da6c770d5cfeb4f304238`, PBX `c28feabf67cfff7a33ba82d179e532ac3c88722d`. No tracked dirty source; untracked controller scratch preserved.

App harness `/tmp/knitnote-account-domain-jnjVrd` gained exact worktree source symlinks for both new Core files; root harness `/tmp/knitnote-app-root-kbh3SM` already links whole Core directory. Package SHA256 respectively `be651083b0427f1d2067dbc2b4fe0e6f1248d46211ff0d125baf7ef7d3c3f04b` and `9d80d3ca53ffbb96203f5cb590a54dac7a095a102d5bba3148afa4eb828e89eb`. Runner `/tmp/task4-run-bounded.py` SHA256 `c9fbdb35fa3743e27a7fbf63a1a0cbabfb02ca10e299167c214841a915faec0b`. Actual PBX targets compiled both files.

## Rulings made and costs

1. Extract independent foundation while predecessor lineage design proceeds: avoids blocking ready controls; cost is possible later interface rework, no premature App activation.
2. Keep generic open unchanged; derive creation only in verified/existing modes: preserves legacy readers; cost is mandatory downstream App no-bypass test.
3. No v3 bootstrap in foundation: lineage needs its own reviewed preparation/history design; cost is another scoped integration unit.
4. Preserve scratch/evidence rather than delete: reliable audit/continuation; cost is retained scratch files.
5. Preserve abandoned temporary sessions in verified/existing open: rejected generation cannot authorize deletion; cost is retained bytes until authenticated cleanup.
6. Regular corrupt archive is routing evidence only, never fresh proof or canonical readiness: cost is mandatory downstream exact factory validation.
7. Permit bounded legacy-main derivative routing exception: real v1 writes can interrupt before rename; cost is version-specific compatibility logic and real crash regression. Derivative never gains authority or new-helper cleanup permission.

## Remaining gates and next work

Minor coverage: direct restored/rollback/sourceSpent variants and pending-marker content/order assertions, to carry into inventory integration. Source inventory authentication, full missing-archive seal/restore, atomic consumed-selection handoff, owned-bootstrap spending/lineage, actual App admission/no generic-open bypass and engine namespace/fullfetch/ACK remain outstanding. This foundation cannot claim these outcomes. All data limits, retention policy, FIFO/attachment bytes and release constraints remain unchanged.

Next draft adaptation assigned to source_inventory_plan at `/tmp/account-source-inventory-plan-20260908.md`; formalize only after controller review. No signing, live account, Keychain, schema, device operation, push, upload or submission occurred.
