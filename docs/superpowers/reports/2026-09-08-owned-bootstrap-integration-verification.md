# Owned bootstrap integration verification

Execution date: 2026-09-09. Version: **1.7.0 (13)**.

Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`; branch `docs/cross-device-sync-design`.

**Local verification complete — not a release-readiness or submission report.** Task4's three Important test gaps and the final coherent-unit review's two P2 recovery-selector defects are addressed. Both scoped re-reviews are clean. Final-candidate full Core03, App account-domain, root harness, unsigned macOS test build and unsigned iOS build all passed. This report belongs to the local checkpoint `test: verify owned bootstrap interruption and recovery boundaries`; its containing Git commit identifies the checkpoint. Automatic delegation remains paused. No App/transport activation, live cloud/device/schema/key/sign/export/merge/push/upload/submission action occurred.

## Final coherent-unit review: two findings addressed, scoped re-review clean

The independent reviewer read the complete11823-line net source/test/PBX diff, SHA-256 `e5cb96e311c80e85dfa7492cb8d9e16f724d17831b4ba1cef37e0cafd8a60658`, and verified all14 candidate source/test witnesses. No Critical finding; two Important/P2 findings confirmed by controller source inspection:

1. Post-preparing InstallOwner/unspent rollback excludes active-next content from admission comparisons, while publication permits truncating any existing next when a main exists. A complete conflicting next selector can therefore be overwritten. Fix must validate phase-appropriate full next lineage and source/prepared/history bindings before effects while preserving legitimate interrupted derivatives.
2. Legacy archive rolledBack recovery always requires a derivative; a healthy no-next terminal fails, including the second recovery after successful derivative repair. Fix must validate and synchronize the exact healthy legacy terminal without creating a derivative or bypassing source/inventory checks.

The one focused production/test fix wave and the same reviewer's scoped re-review completed: both findings ADDRESSED, no new breakage. It validates exact native permitted successor envelopes (or exact partial prefixes), pins the admitted next before truncation, rechecks bytes/name after late observer boundaries, and validates/synchronizes no-next legacy terminals. Actual RED covers original overwrite/legacy failures, late content/inode replacement and NFC/NFD byte-distinct paths. Final10tests/2suites passed60.470s, exit0/68.134s; log `/tmp/owned-final-fix-final-green02.log` SHA-256 `0337934cba0127060a61bd50a6070001c991adfc2c8b8a77d24736a663ea0318`. The earlier149/8 pass predates final guards and is not same-final-source aggregate evidence.

Only existing `SyncBootstrapOwnedTransaction.swift` changed (SHA-256 `01f32fb3168e03c1849cf7ed3925c3420563af0d2ec01b1768e9b8d8baee65e0`) plus new `SyncBootstrapOwnedSelectorRecoveryTests.swift` (SHA-256 `97a39a2bed20a950fd33bf603cae4568c60aaa4bb5c4a6db9c23f680e01a08ea`); other13 previous witnesses remain unchanged. Scoped487line diff SHA-256 `d3ff72b7f2b65d582edd579789d1c9523ba9a39f456ec523ae4b7ac72e28464f`; detailed final-fix-report.md SHA-256 `38e6d8545574f7ebee43b29c39eb2b7e02d8cf4abe74c494da665bca4cede0ac`. All compiler/test sessions exited before handoff. Earlier Task4 test review approval is not whole-unit approval. Protected evidence and unrelated scratch remain preserved.

Full Core02 was safely stopped before edits: its exact runner/test groups were resolved and terminated, then verified absent. `/tmp/owned-bootstrap-final-core-02.log` records EXIT-15/593.986s (tool exit241), SHA-256 `b5bbc08e2eee2ebc217ec9a555cb152bd649351416e5fe472055d29331e33cc1`. **Incomplete/superseded, not pass or code-failure evidence.** Full Core01 remains separately incomplete due its900s limit. Fresh Core03 below supplies final-candidate evidence; neither earlier run substitutes for it.

## Candidate and scope

- Coherent-unit baseline: `1733d1d57877f665ea440e01b1a3e6e5118df920` (accepted implementation plan).
- Task1 checkpoint: `d42e789bd9dee05dab5046d1d14a2cc05ce56ce3`.
- Task2 checkpoint: `63e8a5c8c34002f631fa7b2e37dbbd86f6d5722e`.
- Task3 / Task4 base: `f74dd04d0e2e089773be1cf04e4a08a620b6b530`.
- Final Task4 source/test candidate: three production files, four existing tests, eight new focused test/helper files; no new production filename, App source change or PBX edit.
- Independent Task4 review1 package:1811lines, SHA-256 `4a069ab5a8f83b8ea52a6ad3d9745239135f2730dbaf3ef3d0aa3ca4dd909d26`. Its initial findings and clean fix1 re-review are recorded below.

## Independent review1 findings

Initial review found no Critical finding or confirmed defect in the narrow production repair. The following three Important test gaps were subsequently addressed in fix round1:

1. Shard/checkpoint child cuts currently prove seven-byte temporary writes, not post-publication/pre-next-operation windows. Explicit publication cases, including new checkpoint with old segment, are required.
2. The rollback child test currently performs only a read-only snapshot before encrypted cleanup/reconstruction, then ordinary reopen. Exact rollback output must receive immediate ordinary-loader verification in a separate equivalent fixture if migration would invalidate frozen authentication evidence.
3. Source-control matrix currently permits either recovery or unchanged rejection at every cut and only checks control enum category. Tests must enforce each cut's expected outcome and exact main/next/source-origin evidence.

The clean scoped re-review below closes these three test findings; final platform validation remains a separate Task4 gate.

### Fix1 and scoped re-review

All three findings **ADDRESSED**, no new Critical/Important breakage. The same independent reviewer read all438 fix-diff lines and verified amended-source/report/log hashes. Final fix diff SHA-256 `ff58d7f62cdb20d6c87ca163f41544cf4df915d46912ff5af5eee28a7705a1b5`.

- I1 now retains partial-write cases and adds distinct post-replacement/pre-next-operation shard/checkpoint cuts. Assertions compare selected installed state, exact new publication bytes, absent temp/later outputs, old checkpoint/segment bytes and original segment physical identity retained into Failed.
- I2 now runs12cuts × two independently created ordinary/authenticated roots. Ordinary route immediately loads the exact owned-rollback result with a fresh native journal, comparing full pending values, file bytes, duplicate/enqueue/ACK and subsequent reopen. Authenticated route avoids ordinary loading before seal/cleanup/restore.
- I3 requires success/authentication at control cuts1–3/6–7 and unchanged rejection at4–5. Main/next predecessor bytes, complete original source identity, spent digest/transaction and matching reissued terminal origin are asserted.

Fix1 `/tmp/owned-matrix-fix1-control-01.log`: exit0/35.401s,14cases; SHA-256 `cdc5790e14df241c01837b38bcd31cbad21263cbb7be24db5417e3b6350b1b66`.

Fix1 `/tmp/owned-matrix-fix1-covering-01.log`: exit1/249.046s, one authenticated attachment child exceeded60seconds; Control cases,35role cases and23other child routes completed. SHA-256 `1b2074c7b06cde500e17037b27d8fde625c906dee15329b7f9fa75ccdbdeaf83`. **Not an aggregate pass.** Original startup-only child log cannot establish the timeout cause; the old parent removed that synthetic fixture. The timeout is not claimed fixed or proven transient.

Added synchronous monotonic child stderr markers and retention/reporting of future failed synthetic roots, without changing the60second cap. `/tmp/owned-matrix-fix1-child-diagnose-01.log`: all24child routes passed,2tests/1suite107.956s, exit0/130.066s; SHA-256 `48b082fb42e16a2d809e205ea691c51423bdba699e3199d9480eed854c1f8a15`. Attachment ordinary/authenticated reached their cuts17.251/18.057s. This validates that run, not the earlier timeout cause. Full Core will exercise these cases again.

Final detailed fix report SHA-256 `a3c16e43c7ba0eb18724019f46b2de32ff6b6766ec5bfec7831f5329cc584161`. Only two test hashes override review1: Control `73e4c5c49ec33da0df1aa3ab343fcb6141c4dfcd2d7980fbd9b716b369d02e22`; Interruption `41c1f64d5f8adf63a6df56e9b12ab12bc6a3c66c7a5854509a83cf1e45a962c3`. Other12 source/test witnesses unchanged.

## Frozen full-validation candidate

After scoped re-review, read-only tree witness script `/tmp/owned-bootstrap-tree-witness.rb` (SHA-256 `caf94ccd40e45b245a352f4602757e0d10c9ce5fb7b5c4836fc0e436dee39eba`) hashes each tree's sorted relative-path bytes, NUL, file SHA256, LF; includes untracked source/test files. No source/test/App/project edits are permitted during the following serial runs.

| Tree | Files | SHA-256 |
| --- | --- | --- |
|Sources|153|`b324815fee719e7a63e2ab6b649f75af2552354df74f0d1719164cca4a52e0fb`|
|Tests|269|`7ff3c29d989d075b14c847266a50b3fe726b7927d0ac641c670a5625bdb847ef`|
|KnitNote|169|`79f8944e224dcfd8a6776bd20e9671b02ad4aadb2bdaa9e64a9999036129f4f1`|
|KnitNote.xcodeproj|5|`126c36c2df45bf74fd3bd21d4e2638f3188d5caed87817d70c2f9e28a0b9bfeb`|

Full Core01 reached the900second outer timeout while existing archive-audit cases were still progressing, with no warning/error/test issue recorded. Exit124/900.016s is **incomplete**, not a pass. Its `/tmp/owned-bootstrap-final-core-01.log` SHA-256 is `348479aa18f0c88dc7d8a4c1a69cc3e1d935f1b4c5966d3bc4aa5f2e76623a76`. Two existing parameterized archive-audit tests alone recorded206.630s and333.859s; the whole-run allowance was insufficient. All four candidate tree hashes were reverified unchanged.

Controller ruling: extend only full-Core outer budget to3600seconds; do not omit tests, weaken assertions, alter the60second child cap or overwrite evidence. Cost if unnecessary is extra local compute, bounded to one hour; no new external authority. App/root/platform budgets remain900seconds. Core02 used this command but was later stopped as superseded by final review findings:

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION python3 /tmp/task4-run-bounded.py 3600 arch -arm64 swift test --disable-xctest --no-parallel
```

Log `/tmp/owned-bootstrap-final-core-02.log`; runner hash `c9fbdb35fa3743e27a7fbf63a1a0cbabfb02ca10e299167c214841a915faec0b`. Both earlier full runs are incomplete. The tree hashes above identify the final repaired, cleanly re-reviewed candidate; old witnesses remain preserved separately.

Core03 used the same bounded command on this final candidate: **2842tests/204suites passed2078.982s, EXIT0/2080.985s**. Log `/tmp/owned-bootstrap-final-core-03.log`, SHA-256 `018e67c2153878f11f7a04234ea147ee5a625fedca7bfa2872906db289a33e33`. All four tree hashes reverified unchanged after exit. No test issue/failure, compiler warning/error or timeout markers. Existing ReleaseAuditLocalizationTests alone took913.164s; its missing-artifact Python tracebacks are expected negative synthetic-fixture checks (source1194–1205), not actual user archive deletion or test failures.

All24 current abrupt routes passed in InterruptionMatrix198.030s, with original60second per-child cap unchanged. This closes final-candidate validation of that matrix, not the unknown cause of the earlier timeout. Final SelectorRecovery30.776s and OwnedTransaction219.585s suites also passed; these counts are included in2842, not additional unique tests.

## Implemented physical coverage

| Family | Actual evidence exercised |
| --- | --- |
| Selector | Preparing/prepared/aborted phases × eight before/after native fsync cuts; exact main/next bytes, real seven-byte selector partial before UUID allocation, first-mainless unchanged rejection, authenticated terminal restart. Selected-file fsync is before later ancestry barriers/readback; this is not injected read-syscall evidence. |
| Source control | Spend/reissue × seven native fsync locations; no early live move; unresolved derivatives reject without changes; valid durable origin survives recovery. Native control replacement tests separately cover write/rename callbacks. |
| Outputs | Five real output roles × seven write/file-fsync/post-rename parent-fsync boundaries; exact retained name, bytes, hash, physical entry and no later forward writes; same-root authenticated recovery. |
| Abrupt termination | Final12 built-helper child cuts × independent ordinary/authenticated roots (24routes), exit86 at real preparing/journal attachment/append/shard/checkpoint/segment/receipt/rollback boundaries; includes both partial and post-publication shard/checkpoint cuts. New storage at same root; exact interrupted fd path/bytes/device/inode and selector/control evidence; owned rollback before ordinary journal access. Existing eight legacy move-gap children remain separately covered. |
| Helper order | Ten paired actual validation calls;43 independent native publication-lock probes and355 write/fsync events on the complete media fixture; before/after backup/deletion failures freeze issued output only. |
| Physical history | Abort→abort→installed rollback→retry, four contexts/generations, three exact immutable predecessor envelopes; same-root reopen and authenticated restore. Oldest record/file/root-inode, symlink, hardlink, valid unreferenced record and extra UUID tamper/restore pairs reject unchanged and have restored positive controls. Four history fsync cuts retain the first observed inode through repair. |
| Source/expiry | Real valid FIFO reorder/payload changes, selected attachment/deletion bytes, removed/directory/changed/appeared archive, issuer root replacement, expiry before handoff and surviving matching durable origin afterwards. |
| Failed placement | Genuine receipt partial frozen under Failed; identical bytes/name in live, undeclared role or extra UUID reject recovery/capture without evidence changes. |
| Ordinary parity | Real installed commit matches native journal file bytes and FIFO; a fresh ordinary instance preserves duplicate/enqueue/ACK parity. Existing v1–v5 journal tests and exact rollback/authentication coverage remain separate. |
| Budget | Seven-byte physical file inclusive cap; actual three-record history fifth-plan exact cap/cap-minus-one unchanged rejection; pure committed-envelope dominance isolates final projection from six earlier scenarios. Existing Entry/Base64/history/per-file wire limits remain unchanged. |

## Defect and test-oracle corrections

The matrix exposed one production defect: archive-origin terminal `recover()` could return nil without fully validating retained evidence, although inventory capture rejected the same illegal Failed placement. Archive `handoffTerminal` now invokes existing internal capture under current RecoveryAccess before returning. Genuine three-case RED and corresponding GREEN, plus valid terminal positive, are recorded. This creates no App authority, nested owner lock, wire field, cleanup permission or capacity increase.

Other failures were fixture/observation errors, not claimed product defects:

- Ordinary `pending()` mutates absent/legacy journal metadata; frozen evidence verification now uses read-only `recoverySnapshot()`.
- `/var` versus `/private/var` caused blind relative-path slicing mismatches. Tests canonicalize their routing root and compare the same exact relative map, without normalizing hash-bound source bytes.
- Storage close/open rotates exactly one empty uncaptured temporary-session directory. Tests allow only that exact empty UUID delta, preserve every other physical entry, then require full after-open/after-recover equality.
- Preparing persists portable source proof, not the old working-set inode. The same-scope issuer rejects root replacement; a fresh verified owner may certify an empty abort of byte-identical portable source. Prepared and frozen/historical identities remain strict. No wire change was made to satisfy the test.
- Encrypted restore replays semantic pending mutations, not the original journal frame sequence. Exact byte parity is tested across ordinary reopen immediately after real commit; genuine encrypted recovery is tested separately.
- Internal synchronous output IO cannot directly satisfy ControlFile's Sendable callback. A separate internal Sendable fsync callback retains the real default and uses Mutex-backed test observations; no unchecked concurrency escape was introduced.
- Final role fixtures use smaller real archives for four nonattachment roles; Attachments and full helper trace retain media. All35 boundary cases and source/recovery assertions remain, and the earlier full-media35 pass is preserved.

## Targeted execution evidence

Counts overlap and must not be added as unique tests. Failed/incomplete logs are preserved, not overwritten.

| Log | Exit / result | SHA-256 |
| --- | --- | --- |
| `/tmp/owned-matrix-batch-green-03.log` |0;57tests/5suites; includes original full-media35role cases and10child cuts |`b97b7bc1504b78a436b840450289a4b1e1864725c7052e1169e5677ae6432e9d` |
| `/tmp/owned-matrix-focused-green-02.log` |1; genuine archive-terminal negatives plus parity oracle failures; helper/history/source groups passed |`7e0c1d8f1a8d14f50c9ed7f59de9c55583083711801045221de4581a4b97d4e8` |
| `/tmp/owned-matrix-focused-green-03.log` |1; archive-terminal fix GREEN, two post-authentication byte-oracle issues remained |`351875d0a236adbafeada063720e8319e8360af082543ceb9ed2b3a5aafce6e2` |
| `/tmp/owned-matrix-durability-green-01.log` |0;4tests/1suite, native cap/ordinary parity/three Failed negatives/four history cuts |`9e490f7b4d7a5cbb883ff546e05736451ebc81c799124241f966d162a9e12ad6` |
| `/tmp/owned-matrix-owned-regression-01.log` |1;169tests/13suites, exactly two Control fixture path-map issues; other12suites passed |`73f04ac147c93adcddde00d7ba32261ad5ca032ac67c7b13fd9ca5850ef1285d` |
| `/tmp/owned-matrix-ordinary-covering-regression-01.log` |0;410tests/17suites341.679s,364.429s total; corrected Control24, pinned History4, optimized Role35 and all required ordinary suites |`696df84773358ba66a2dcd3ee502b1defffa962b8e94de7b0e7ad041b0a08201` |

The final covering run emitted no warning/error/issue diagnostics. Earlier whole-module recompilation exposed existing unrelated deprecation/redundant-require warnings; intermediate compile errors and fixture failures are retained in the detailed execution report. The early manually stopped matrix run is incomplete, not GREEN. The separately recorded final Core03 now provides the coherent full-Core result.

Exact pre-existing compiler warnings in `/tmp/owned-matrix-helper-observation-red-01.log`: `HighlightOverlayContractTests.swift:92` deprecated `String(contentsOf:)`; `JSONProjectStoreCanonicalDurabilityTests.swift:16` redundant `#require` on a nonoptional value. Both files have no diff from coherent-unit baseline1733d1d; no unrelated warning cleanup was mixed into this matrix. They remain visible for final review triage.

Detailed exact commands, intermediate diagnostics, closure maps and source/test hashes are preserved in this plan's `.superpowers/sdd/2026-09-08-owned-bootstrap-integration/` artifacts. Matrix report after fix1 SHA-256 `a3c16e43c7ba0eb18724019f46b2de32ff6b6766ec5bfec7831f5329cc584161`; earlier `590ffa8142a97e081bda3abf119103f76067e54a54f1902cb74bf7e4d38fc5a0` was the pre-fix1 report. Final coherent-unit fix report and15 final witnesses are recorded separately above/below. Do not delete that evidence workspace or unrelated protected scratch.

## Platform configuration and completed local execution gates

Read-only PBX resolution verified all40 CloudSync production files in both KnitNote and KnitNoteWatch, with no missing/duplicate membership. Core tests belong to SwiftPM, not the KnitNote-only App test module. Final source+test link inventory is account-domain198 (184source+14test), root26 (16source+10test), all resolving into this worktree with zero broken/off-worktree links; this supersedes the preliminary197 account-harness count. No links changed during this recheck. App source has no SyncBootstrapOwned/prepareOwned/ownedBootstrap references. The actual live CloudKit gate returnsfalse before the live closure unless its run variable equals1; harness commands explicitly set0.

Actual Xcode destination query exited0 in47.323s: macOS arm64 and generic iOS available. Log `/tmp/owned-bootstrap-destinations-01.log`, SHA-256 `242cf3de0462e627b0458d2fe9b0cd53c570e525f57ce191ddc9797bd88f9130`.

Actual macOS build-settings query exited0 in1.79s: marketing1.7.0, build13, signing disabled, macOS26.5 SDK. Log `/tmp/owned-bootstrap-build-settings-01.log`, SHA-256 `4a073bdfc0ff75e1f83a495cb78b9b52f122018ae08d31b2079e6ffc1dc8c6a4`. Queries are not builds or device acceptance.

- [x] Independent Task4 code review and scoped fix1 re-review; cross-task platform/report checks completed below.
- [x] Freeze complete Sources/Tests/KnitNote/PBX candidate hashes.
- [x] Full Core on final reviewed source,2842tests/204suites, exit0.
- [x] Actual App account-domain and root harnesses, serially; both exit0.
- [x] Unsigned macOS build-for-testing and generic iOS build, serially; both exit0.
- [x] Final coherent-unit review and its one scoped fix/re-review, both findings addressed.
- [x] Final evidence/report, ready for its containing local checkpoint commit.

## Final App/platform execution evidence

All commands run serially from the inspected worktree against the same frozen source. The900second bounded runner is unchanged; no signing, service opt-in, simulator boot or device installation.

| Run | Actual result | Log SHA-256 |
| --- | --- | --- |
| App account-domain01 |241tests/12suites57.195s; exit0/69.558s; one explicit live Development probe skipped by opt-in gate |`432bcacf2277a272c2aac569b65378a2bc725f15e430a5ac297c11e815705292`|
| App root01 |73tests/7suites0.797s; exit0/16.188s |`374bdd4c967ce1af5b52e4a09ab58ba5e12c4adcbd2ae3f09725d84aaa922b68`|
| macOS01 |TEST BUILD SUCCEEDED; exit0/75.727s |`a3ff09af9b75792ac86a1dbb8dddaaed57ea11882ea3e9b47eda28b91babd9ff`|
| iOS01 |BUILD SUCCEEDED, including Watch target; exit0/49.915s |`f3d28e292d4b67104dd94cf21811ce0d853111548f795002fb0cdc504d7bf304`|

App logs: `/tmp/owned-bootstrap-final-app-01.log` and `/tmp/owned-bootstrap-final-root-01.log`. Both have no test issue, compiler warning/error or timeout markers. Explicitly skipped live probe is not cloud/device acceptance.

Platform logs: `/tmp/owned-bootstrap-final-macos-01.log` and `/tmp/owned-bootstrap-final-ios-01.log`. Each contains three Xcode metadata extraction warnings (`No AppIntents.framework dependency found`), no compile errors. Read-only source/project search found no AppIntents imports/framework or AppIntent/AppShortcuts declarations; these are tooling metadata-skip notices, not an introduced functional defect. No unrelated framework was added to silence them. Actual macOS and iOS built Info.plists both report1.7.0/13. No UI test or physical-device acceptance is inferred from build-for-testing.

After every final run completed, all four tree hashes and all15 individual source/test witnesses matched the reviewed candidate; `git diff --check` passed. Final App reachability remains inactive, harness manifests/links and PBX membership remain as audited. The branch/worktree, detailed review evidence and unrelated scratch are deliberately preserved.

```sh
KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0 CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/task4-run-bounded.py 900 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --package-path /tmp/knitnote-account-domain-jnjVrd --no-parallel
KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0 python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --package-path /tmp/knitnote-app-root-kbh3SM --no-parallel
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/owned-bootstrap-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/owned-bootstrap-ios-derived CODE_SIGNING_ALLOWED=NO build
```

## Final reviewed source/test witnesses

Paths below are relative to this worktree. All15 files are covered by the final tree witnesses and review chain; no source changes are permitted during final validation.

```text
5de8e86ff1f0c7d78f5f5332b52242048d01fd28420e7db5b60b3ff4975bedc1  Sources/KnitNoteCore/CloudSync/SyncAccountRecoveryInventory.swift
1b5e936ce8dc40631969e617bc6eaf378f77af377aba137a8484a5463657f9b9  Sources/KnitNoteCore/CloudSync/SyncBootstrapOwnedOutput.swift
01f32fb3168e03c1849cf7ed3925c3420563af0d2ec01b1768e9b8d8baee65e0  Sources/KnitNoteCore/CloudSync/SyncBootstrapOwnedTransaction.swift
978041707a07bff51c6e5cf318a851380035b13e12eec952071ba740011abaae  Tests/KnitNoteCoreTests/SyncBootstrapOwnedBudgetTests.swift
4ebcd9451b9a58d21fd76dddabb9b980b12737dccb8933de38099bc9afa635a0  Tests/KnitNoteCoreTests/SyncBootstrapOwnedOutputTests.swift
e80ff8dd6e61eaa4267758c525c0c260752c3723e670f9f078d3efd87bc2f660  Tests/KnitNoteCoreTests/SyncBootstrapOwnedTransactionTests.swift
f596132e4799547ddf75afbbb16e70ffdba3bb18de938f0543948840524db523  Tests/KnitNoteCoreTests/SyncPublicationEvidenceOutputProgramTests.swift
73e4c5c49ec33da0df1aa3ab343fcb6141c4dfcd2d7980fbd9b716b369d02e22  Tests/KnitNoteCoreTests/SyncBootstrapOwnedControlMatrixTests.swift
fa818c670af599ac3041fc8d3bff96fb0a4d78d2c60c257e820db6c5f0ea0c07  Tests/KnitNoteCoreTests/SyncBootstrapOwnedDurabilityMatrixTests.swift
21d1d050c8267b59025d2a667cbc80ae5cdec4b6b0cb7325d102d82c0bcd4127  Tests/KnitNoteCoreTests/SyncBootstrapOwnedHelperTraceTests.swift
41c1f64d5f8adf63a6df56e9b12ab12bc6a3c66c7a5854509a83cf1e45a962c3  Tests/KnitNoteCoreTests/SyncBootstrapOwnedInterruptionMatrixTests.swift
3d1932a2e4aa826fed5cae55d903b3bbdb498aee882c0188ba2d17a89bbfd5b8  Tests/KnitNoteCoreTests/SyncBootstrapOwnedMatrixFixture.swift
91f4e3edf71f1dbddaeb33ad9fbba2774188c3d776f4c437bfd573a53e586771  Tests/KnitNoteCoreTests/SyncBootstrapOwnedPhysicalHistoryTests.swift
630204d12a7ed339eb0d3fdb67d3ebe40d4bfa246c402dbffe583028752b1dd9  Tests/KnitNoteCoreTests/SyncBootstrapOwnedSourceMatrixTests.swift
97a39a2bed20a950fd33bf603cae4568c60aaa4bb5c4a6db9c23f680e01a08ea  Tests/KnitNoteCoreTests/SyncBootstrapOwnedSelectorRecoveryTests.swift
```

Separate unapproved gates remain App/transport activation, live multi-device/cloud acceptance, exact release-candidate authorization, signing/export, push, upload and App Store submission. This internal Core checkpoint cannot establish those outcomes.
