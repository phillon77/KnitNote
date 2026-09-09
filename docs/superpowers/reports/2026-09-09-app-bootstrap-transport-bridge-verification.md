# App bootstrap transport bridge — frozen local verification

Date: 2026-09-09. Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`. Branch: `docs/cross-device-sync-design`.

**Complete: reviewed source set14 passed the full local serial verification chain.** The initial full Core sandbox failure is preserved and diagnosed below; the complete unchanged-source rerun passed. This is an internal implementation checkpoint, not device acceptance, production activation, merge or release approval.

## Reviewed candidate and scope

Planning base `19acf71e20ad6fb63495516e0946936531a06c37`; Tasks1–5 committed through `06ab1fd8d162feb49362d401b8495021327e2c14`; Task6 remains the reviewed uncommitted nine-file set14. The task review and sole coherent-unit review both approved with no findings. No code change followed those approvals.

The implementation provides native read-only source capture, prospective asset capacity admission, session-bound full-zone reader/private lease, owned installation/recovery handoff, and optional lifecycle/ordinary-transport composition. It does not activate the shipping App factory. The nil-by-default factory, current local startup, ordinary ACK/send proof, account authority, native retained-history/cleanup/cap policies, wire formats, Watch behavior, version and deployment floors remain unchanged.

Task3's Important remote-only whole-graph finding was corrected and scoped re-reviewed; final combined local/remote/pending/Watch validation remains native before prepare. Tasks1,2,4,5 and Task6 final reviews have no unresolved findings. Task1's deferred absent-head retained immutable/Watch-history case and redundant nonoptional assertion warning were addressed in Task6.

Task6 found a real native drain defect: a completed canceled CKOperation can remain SDK-retained with configured callbacks. The approved gate consumer release happens under its existing lock after admitted synchronous callback work and before continuation/waiters resume. The reader independently retains collector/lease evidence; late/duplicate callbacks still invalidate. No SDK callback clearing, forced storage close, weakened drain proof or native policy change was used.

Review artifacts:

- `.superpowers/sdd/2026-09-09-app-bootstrap-transport-bridge/task-6-review.md`: SHA256 `ad9dedd47a9b79bf927823b730e74d243493ba648bb0860ec865858d643cf939`.
- `.superpowers/sdd/2026-09-09-app-bootstrap-transport-bridge/coherent-review.md`: SHA256 `69fc37a1188c2cfaa5427149f0eb680c68399d2a35a8e8d049f683d5899fb5a6`.
- Whole-unit review diff:439,977 bytes, SHA256 `7903d22e8064737cffa606f21d3fb6285ec4899a73aeaefcb04a0bf0173416dc`.

## Frozen inputs and harness provenance

The pre-review set14 full source manifest pins608 actual files under Sources/Tests/KnitNote plus PBX:
`/tmp/bootstrap-task6-phase1-full-source-sha256-14.txt`, SHA256 `291206e3dbc0f04e28c599ebbd21d4cdaeddd48530fd46b62c1cafb091748d2e`.
Nine changed-file manifest: `/tmp/bootstrap-task6-phase1-changed-source-sha256-14.txt`, SHA256 `023204f1cd29e78926d63eb8232407339c4bbe30f3c5904fe8164a20e3469e3f`.
Both verified608/608 and9/9 immediately before phase2.

Account harness `/tmp/knitnote-account-domain-jnjVrd`:215 source/test links, all resolved to this exact worktree. Root harness `/tmp/knitnote-app-root-kbh3SM`:26 links, all current. Existing ordinary staging-service/upload tests were missing links in phase1; those two exact links were added before final full App execution, with no source/manifest changes. No Core-importing test entered the App Xcode target.

Infrastructure SHA256:

```text
be651083b0427f1d2067dbc2b4fe0e6f1248d46211ff0d125baf7ef7d3c3f04b /tmp/knitnote-account-domain-jnjVrd/Package.swift
9d80d3ca53ffbb96203f5cb590a54dac7a095a102d5bba3148afa4eb828e89eb /tmp/knitnote-app-root-kbh3SM/Package.swift
c9fbdb35fa3743e27a7fbf63a1a0cbabfb02ca10e299167c214841a915faec0b /tmp/task4-run-bounded.py
```

## Final serial chain

Using `superpowers:verification-before-completion`: fresh complete output and actual exits, not prior targeted results, determine each lane's status. One compiler lane; no source edits during verification; no filters/test omissions in the full runs. Core budget3600 seconds, other lanes900. All commands run from the worktree above, with each expanded compiler command/start/exit/elapsed captured by the unchanged bounded runner. Environment assignments are explicitly included below; live CloudKit integration remains disabled.

| Lane | Log | Exit/result |
| --- | --- | --- |
| Full Core, initial sandboxed | `/tmp/bootstrap-task6-phase2-full-core-17.log` | EXIT1;2866 tests/207 suites;45 issues;2597.440s elapsed,2595.882s test time |
| Full Core, verified local execution environment | `/tmp/bootstrap-task6-phase2-full-core-escalated-21.log` | EXIT0;2866 tests/207 suites;2240.783s elapsed,2239.513s test time |
| Full App215 | `/tmp/bootstrap-task6-phase2-full-app-22.log` | EXIT0;348 tests/21 suites;360.703s elapsed,358.113s test time |
| Root26 | `/tmp/bootstrap-task6-phase2-root-23.log` | EXIT0;73 Swift Testing tests/7 suites;16.424s elapsed,0.754s test time; XCTest shell0 tests |
| Unsigned macOS arm64 build-for-testing | `/tmp/bootstrap-task6-phase2-macos-24.log` | EXIT0;TEST BUILD SUCCEEDED;58.701s |
| Unsigned generic iOS build | `/tmp/bootstrap-task6-phase2-ios-25.log` | EXIT0;BUILD SUCCEEDED;51.898s |

Core command:

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/task4-run-bounded.py 3600 arch -arm64 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --no-parallel > /tmp/bootstrap-task6-phase2-full-core-17.log 2>&1
```

Full App22 command (explicit local execution escalation; no filter):

```sh
KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0 CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --package-path /tmp/knitnote-account-domain-jnjVrd --no-parallel > /tmp/bootstrap-task6-phase2-full-app-22.log 2>&1
```

Full Core21 SHA256: `69fb159d49f45bad537d43422b8437ecacdf5e6ebd7ceebe83d4ce99cd02fb0e`. No compiler warnings/errors or failed Swift Testing result lines. All207 suites passed, including both previously sandbox-limited suites. Expected fixture subprocess tracebacks from release artifact rejection tests are retained in the log and are not test failures. No test was omitted to obtain this full pass.

Root23 and macOS24 exact commands (explicit local execution escalation):

```sh
KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0 CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --package-path /tmp/knitnote-app-root-kbh3SM --no-parallel > /tmp/bootstrap-task6-phase2-root-23.log 2>&1
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/app-bootstrap-bridge-macos-phase2-24 CODE_SIGNING_ALLOWED=NO build-for-testing > /tmp/bootstrap-task6-phase2-macos-24.log 2>&1
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/app-bootstrap-bridge-ios-phase2-25 CODE_SIGNING_ALLOWED=NO build > /tmp/bootstrap-task6-phase2-ios-25.log 2>&1
```

Full App22 and root23 have no compiler warning/error or failed test result. App22's one explicitly opt-in Development-container integration test is skipped with `NOT RUN unless explicitly opted into an available Development container`; this is the required no-live-service boundary, not a hidden reduction of the local suite. The full App command has no filter. Root's XCTest compatibility shell reports0 tests, followed by the actual73-test Swift Testing run; do not misreport that shell as the harness result.

```text
ef4a6d2fdc26c5f9c4bfa2b559e8bd5bd4bc3d6405d58840f7764765fd817d9b /tmp/bootstrap-task6-phase2-full-app-22.log
bd4e8dbba4b8e16b8d1de665c304d8fd44ccde861ea618177dab278609432656 /tmp/bootstrap-task6-phase2-root-23.log
b472d867a9823a77cba9d6a4b571c3d46a865df5d1243579e6cb08cdd0f83d73 /tmp/bootstrap-task6-phase2-macos-24.log
cb200daa2387f937750196bb713638ecc91dbeb8f22112ac1ce0f1a5c676a8d4 /tmp/bootstrap-task6-phase2-ios-25.log
```

Platform warnings: exactly3 per build, all `Metadata extraction skipped. No AppIntents.framework dependency found.` from `appintentsmetadataprocessor`; no Swift compiler warning/error. The macOS build explicitly compiled `AppBootstrapTransitionIntegrationTests.swift` and `AppAccountDomainLifecycleTests.swift` in KnitNoteAppTests, covering the actual test-only `weak let` lifetime assertions and child-runner guards under the Xcode test target. iOS build compiled the actual bridge/driver/reader/lifecycle production paths; it is not an iOS test run or iOS test-target compilation claim.

Both derived-data directories were absent before their respective fresh build. No platform test bundle was launched on a simulator/device. Actual main binaries are arm64. Read-only `codesign -dv` reports iOS not signed at all; macOS contains only the linker-generated ad-hoc marker (`adhoc,linker-signed`, no TeamIdentifier or sealed resources). `CODE_SIGNING_ALLOWED=NO` was used throughout; no identity/distribution signing or `codesign` mutation occurred.

## Built identity and final hash closure

Actual built Info.plist readback is1.7.0/13 for macOS main App, iOS main App, embedded Share extension and embedded Watch App. This does not claim Watch behavioral acceptance. Xcode's own UI test runner/framework bundle versions are not shipping App versions.

```text
82e3fe03a811548dff392700488afcfdedb22b884ccf22a38a913144ac287d9a /tmp/app-bootstrap-bridge-macos-phase2-24/Build/Products/Debug/KnitNote.app/Contents/Info.plist
c483799d9f2bc8f0ab6b9dcb79374a0f5d975f1fe788c6ad1f68472f460d011d /tmp/app-bootstrap-bridge-ios-phase2-25/Build/Products/Debug-iphoneos/KnitNote.app/Info.plist
```

After the chain, all608 source hashes and9 changed-file hashes matched set14; all215 account and26 root source/test links still resolve to this worktree. Both manifest hashes, runner hash and phase1 report hash remain unchanged. PBX `plutil -lint` and `git diff --check` passed. The exact new App test has one file-reference/buildfile/group/source-phase membership and no Core-only import. HEAD remains `06ab1fd8d162feb49362d401b8495021327e2c14`. No source edit, staging or commit occurred during phase2. The unrelated one-line plan recordType edit and `.superpowers/absent-source-design-progress.md` remain outside this agent's changes.

Exact Task6 source/test/PBX files for controller verification:

```text
b00465e0b9685af62de9a9ee586c80e13f8f828de923ce2dc40309b5cd055a46 KnitNote/CloudSync/CloudBootstrapPageDriver.swift
f81a4c26e4b83ef6faa50461fe697923a25d6f4c4c28b7d3a52537ae4338f5ce KnitNote.xcodeproj/project.pbxproj
8390b42e90c2a08aa40738951cf2540c881af2a09d1dd401b6273a6ba1dfd7a1 Tests/KnitNoteAppTests/AppBootstrapTransitionIntegrationTests.swift
a193e90c1491611de578fd1c0b9eda03e2d822f604f9f19071bdca88209eb33a Tests/KnitNoteAppTests/AppAccountDomainLifecycleTests.swift
e46245bc59abdb2401bfad4d2f39426e0cff87ec05426bd455327c8906cfce8b Tests/KnitNoteAppTests/CloudBootstrapPageDriverTests.swift
89304b294713b6ab985e52490824cf1c63ce1519d4897976de4fb77e285c136c Tests/KnitNoteAppTests/CloudBootstrapSnapshotReaderTests.swift
dc725e564dc9edf6573bf3cbe28a904db72931b01e332fd25e5ff74b8cb984af Tests/KnitNoteCoreTests/SyncBootstrapSourceAccessTests.swift
16580514d130973dcc966b9b72643f2490ffa6f71d46671b3f4b5d4ee71202e5 Tests/KnitNoteCoreTests/SyncBootstrapDownloadBudgetTests.swift
fffcb05de1d5f5b74a7bd913d469764c3c29277d4a8bef0903d1f3ff85c9bf88 Tests/KnitNoteCoreTests/JSONProjectStoreCanonicalDurabilityTests.swift
```

## Fault, child-exit and capacity evidence

### Phase2 environmental failure and unchanged-source rerun

Full Core17 completed, not timed out:44 assertions in two generated build-setting tests saw nil values, and the regular-file reader socket fixture threw generic EIO before the reader assertion. All bootstrap suites passed, but the full lane was correctly failed. Tail-only progress observations did not expose these non-tail failures promptly; subsequent progress checks scan the whole log for actual `✘` result lines as well as the tail.

Systematic diagnosis, before edits, reproduced45 issues in17 tests/2 suites with the same sandboxed command plus filter `ReleaseCandidateIdentityTests|SyncRegularFileReaderTests` (environment-red18,EXIT1/14.132s). Exact read-only `xcodebuild -project KnitNote.xcodeproj -target KnitNote -configuration Release -sdk macosx -showBuildSettings -json CODE_SIGNING_ALLOWED=NO` returned the target with empty `buildSettings`; stderr showed denied local cache/log/XPC access. Native AF_UNIX creation succeeded, but the isolated bind returned EPERM1; the existing test intentionally maps failed socket construction/bind to generic EIO. No project settings or reader behavior was changed.

The exact17-test two-suite command passed when execution was explicitly escalated out of the tool sandbox:EXIT0/19.409s (test17.637s), all45 prior issues gone. Controller approved repeating the complete unfiltered Core3600 lane under that verified environment and completing all remaining local lanes. This is an execution-environment correction, not a source fix, test omission, new ruling or review bypass. The failed full log and diagnostic logs remain preserved. Core21 uses the Core command above with output `/tmp/bootstrap-task6-phase2-full-core-escalated-21.log` and tool execution permission `require_escalated`; source set14 remains exact.

Diagnosis SHA256:

```text
4860db64de97c62e0162834fbbdf86199beaf44e53cd55b9e7ae2e8a63b27ebd /tmp/bootstrap-task6-phase2-full-core-17.log
c3aa2bee0a92fcbfb91eb74f28596be7a0973d42e896658f4e9bfd2951dda509 /tmp/bootstrap-task6-phase2-environment-red-18.log
1ab42824110396aada5f601f0264cbf240093329fa999d586e7ba63afbd0d2a3 /tmp/bootstrap-task6-phase2-settings-sandbox-19.json
558dc163dab16c60ff12fb65cb6f6aed2cc1246b9fae461bbdc4de88da26d875 /tmp/bootstrap-task6-phase2-settings-sandbox-19.stderr
f2bf45eaa7b362ea95f28d3cd34086f904499e627561d208049a0b0fb977e4dd /tmp/bootstrap-task6-phase2-socket-sandbox-19.log
c1b324aee244df2e553d17ed48b8fadbafbd3d3f92794f797d75fe4f05dd8e20 /tmp/bootstrap-task6-phase2-environment-escalated-20.log
```

Phase1 report `.superpowers/sdd/2026-09-09-app-bootstrap-transport-bridge/task-6-report.md` remains unchanged, SHA256 `bd55d93792b0cd15753e987645e4da8345056280f6fe27d47345f27be5164103`. It records exact nine-file hashes, all RED/compiler/fixture diagnosis history, final targeted App192/9, ordinary6/3 and Core47/3 exits, commands and log hashes. Those counts are tests/suites, not parameter cases and not final full-suite results.

Actual lifecycle matrix: seven bootstrap boundaries × three distinct failure kinds (cancel/account invalidation/EIO), plus ordinary-first-fetch × three. Completed lease is observed at real post-reader-await ownership validation, not scheduler completion alone. Each checks source/pending/control/output/visibility/native completion/engine/ACK/send and a separate same-root reopening with no reseed.

Two actual built SwiftPM child cuts: after-preparing and committed-before-App-publish, each exits86 from the real owned transaction. Worker filter, explicit isolated root, no nested compiler, no live environment,60-second deadline and2-second termination grace. Failed roots/logs retained; parent recovery precedes ordinary journal access; subsequent actual daily edit/reopen performs zero bootstrap reads. macOS SwiftPM-helper-only launch is explicit; iOS and Xcode-host app runners do not launch a guessed executable.

Largest representative download fixture:1,048,576-byte attachment plus genuine staged pending mutation. Five actual native IO prefixes compare native inventory and authenticated recovery envelope to admitted8,000,000 bytes. Observed inventory1,403,975–1,404,274, envelope1,872,244–1,872,644, retained staging0 or1,048,576. Full six-role media fixture (project/yarn photos, journal full/thumbnail, PDF, markup),9 source files and real pending journal, compares four owned recovery prefixes with actual admitted program bounds. Final targeted Core observed inventory12,760–242,559 and envelope17,344–323,740 within admitted35,768,875–35,772,331. Sizes vary with actual native paths/encoding; no maxima or policy was relaxed. Ordinary orphan/reference/unknown-file reconciliation is independently exercised.

Full App22 repeated both actual exit86 cases with `recoveryBeforeJournal=yes sameRoot=yes dailyReopenReader=0`, and all five download parity rows matched phase1. Retained child logs:

```text
f6a6721c04b4bbe4dfd9cbc42608760d0405b5442bfcf83a5fea35a039cf402d /var/folders/s_/ylqd3gdx2rz79ppmgsw__8qm0000gn/T/app-bootstrap-child-after-preparing-B3955EB0-9133-4688-9698-D30E2983E749.log
c44d240c54617a8e00c228c4866a7c4e075267218369b32c981b81c3af2928a3 /var/folders/s_/ylqd3gdx2rz79ppmgsw__8qm0000gn/T/app-bootstrap-child-committed-before-publish-C5D6E85F-3BF2-49C6-8B13-6877BBE8C505.log
```

Full Core21 actual six-role parity:

| Owned cut | Source files/bytes | Inventory | Envelope | Admitted |
| --- | ---: | ---: | ---: | ---: |
| after-preparing |9/3,824|12,760|17,344|35,771,295|
| prepared |9/3,823|242,559|323,740|35,769,099|
| installed |9/3,824|242,531|323,704|35,766,459|
| committed |9/3,824|194,723|259,960|35,770,371|

## Rulings, reasons and costs

These15 ledger rulings are preserved verbatim:

Ruling: Allow Task5's preliminary cold runtime to use the named native cold constructor as well as the download wrapper — Task5 must break pre-install runtime construction without reconciliation, and neither cold construction grants write authority — if wrong, runtime construction requires rework; no production activation or data mutation is authorized.

Ruling: Review uncommitted explicit task diffs before the local task commit — the accepted plan requires review before commits, overriding the skill template's commit-first packaging — costs a custom review package assembled from the exact changed files.

Ruling: Task3 controlled scheduler receives the actual configured operation and explicit shared completion adapter closure — SDK probe shows reading/calling operation.completionBlock does not invoke the assigned user closure, so tests cannot rely on that getter; live scheduler assigns the same adapter before database.add — costs test scheduler seam rework if SDK semantics differ; no fake lease or live service operation permitted.

Ruling: Replace Task3 full remote-only merge with narrow shared native record/atomic-domain reduction and preserve legacy evidence for owned combined validation — fresh local/pending counters are not available in remote-only scan, so whole-graph checks there reject valid local-preserving input; spec requires final combined validation before preparing — costs Core seam/regression work and scoped re-review; never drop local context or weaken full merge.

Ruling: Include the owned input sourceAllowance's single in-memory remote-record encoding in Task3 fix1 — existing default encoder rejects decoded legacy reminder before combined merge, so reader correction alone cannot support accepted legacy inputs; use existing native legacy-enabled deterministic encoder for this byte count and process-only reader metadata — costs narrow owned regression and scoped review; durable owned/wire encoders stay unchanged.

Ruling: Add a named bootstrap-only decode entry sharing CloudRecordCodec's complete size/field/identity parsing and existing native legacy migration validator — ordinary validator intentionally rejects standalone reminders, so preserving legacy evidence to combined migration requires this constrained read entry — costs codec regression coverage and scoped review; ordinary decode/encode stay strict and no new wire or general validation-disable flag is permitted.

Ruling: Extract reviewed Task4 routing into internal AppBootstrapRecovery in existing bridge file for Task5 lifecycle and bridge — two copies of owned/legacy dispatch would risk divergent evidence handling; preserve exact routing and native-safe vs outer App validation, plus transition revocation lifetime. Costs shared-helper and lifecycle route regressions; no native format/policy or production activation change.

Ruling: Use existing openForVerifiedAccount only for confirmed destination opening with captured validateTransition — inspected legacy open creates scaffold but no positive fresh-absence authority, so truly nonexistent destination cannot safely bootstrap via current path. Preserve old-account route and fail closed on verified-open errors; costs actual nonexistent/stale/corrupt namespace admission regressions. No inferred freshness, source migration, zone creation or new native policy.

Ruling: Add narrowly named read-only native owned runtime admission for actual existing canonical — coordinator legacy-only terminal parser rejects v3, while strict native initial terminal/archive proof correctly rejects daily edited archives. Shared parser strict entry stays unchanged; private runtime archive proof can only derive from actual on-disk validated canonical+archive under storage owner. Require committed selector/full history/Original/receipt/root/control/bootstrap-checkpoint and revalidate entries/control/context. No caller checkpoint/Boolean, no weakened source capture or new capability. Costs Core admission/evolved-canonical/retained-corruption regression tests and expanded Task5 review; fulfills normal canonical reopen, no wire/cleanup policy changes.

Ruling: For verified-owned missing-working-set placement, inspect exact native entries and recover before canonical probe — normal probe requires existing root and would block valid afterLiveMove recovery; existing verified-open native placement proof remains prerequisite. Reject aliases/non-directory entries, no inferred absence or scaffold creation. Costs actual afterLiveMove lifecycle regression, reused by Task6 crash path; no new recovery policy.

Ruling: Task6 fixes native BootstrapPageGate.complete to release its receive/collector closure after all admitted callbacks finish under existing gate lock — SDK may retain canceled completed operation, so retaining data-owner closure blocks same-root reopen despite drained work. Reader independently owns collector/lease; late/duplicate guards still revoke, no SDK callback clearing or timing waiver. Costs focused retained-op/drain/latecallback regressions plus expanded Task6/coherent review; no wire, cleanup, lifecycle authority or operation-completion policy change.

Ruling: Task4 adds internal exact composition binding checks for source/storage/paths and reader/download/scope — independently injected same-account objects cannot imply the same native owner; costs narrow cross-task helper and mismatch tests, no owner escape or validation bypass.

Ruling: Task4 includes native owned committed handoff issuance — inspected owned recover committed branch currently validates inventory then returns nil; accepted spec62/109 requires an actual recover/handoff, so pseudocode alone cannot succeed. Issuance must use full native committed evidence, exact selector/root/canonical/history/asset revalidation and legacy-equivalent allowance only for subsequent ordinary journal evolution. Costs a Core capability seam and corruption/restart/adoption regressions plus expanded task review; no wire, cleanup or production activation changes.

Ruling: Task3 deleted event retains recordType with record ID — installed SDK's recordWithIDWasDeletedBlock supplies both, and spec requires ID/type binding rather than dropping available evidence — costs a small internal driver/fixture signature change; no remote schema change.

Ruling: Extend Task1 to a narrow native frozen-source evidence-read seam in JSONProjectStore.swift and ProjectArchiveSyncMapper.swift — existing evidence load creates a lock with O_CREAT, violating read-only source capture; share the existing unlocked load body and preserve ordinary API behavior and legacy head/history validation — if wrong, evidence/mapper integration needs rework and its regressions rerun; no cleanup or wire changes authorized.

## Remaining gates and authority limits

All requested local lanes, reviewed-candidate hash closure, warnings and built identity readbacks are recorded above. No timeout occurred in the final chain; no failed run was discarded or converted to a passing claim. Both Task6 and coherent reviews remain Approved without source changes after review.

Even a successful local chain does not activate production CloudKit/bootstrap composition, implement initial local-store adoption/migration or zone provisioning, establish live account/Keychain/Watch/device behavior, or approve release. Physical device/account-switch acceptance, production activation design, local adoption, zone creation, Watch cross-account integration and release remain separate gates.

No live CloudKit/Keychain/device work, local-store migration, zone creation, signing, export, push, merge, submission or automation was performed. This agent does not stage/commit; the controller independently verifies the final report and exact files before any authorized local checkpoint.
