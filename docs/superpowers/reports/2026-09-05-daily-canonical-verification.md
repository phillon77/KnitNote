# Daily canonical durability verification — 2026-09-05

## 中文交接摘要

日常同步狀態的持久化、交易整合與重開恢復，四個任務及最後整合審查均已通過；沒有 Critical／Important 程式問題。最終程式提交為 `a4f87e19302ed2b5ab321245e712807efffee81d`，版本維持 **1.7.0（13）**。後續文件提交不改變這個受測程式版本。

最新完整 Core 測試 **2,311 項／170 組全部通過**，耗時 1,270.373 秒，程序 exit 0。先前的語系來源掃描解析器崩潰，已用使用者核准的測試工具限定參數避開，並通過回歸測試與獨立程式審查；沒有變更產品程式或正式編譯設定。先前的 476 項相關測試及停用簽名的 macOS `build-for-testing` 結果仍保留，下方也保留歷次失敗／逾時紀錄。**Core 全套驗證已通過，不等於完整同步功能、真機驗收或送審準備完成。**

最後審查保留一項非阻擋的測試改善：帳號 B 拒絕帳號 A 資料的測試應增加更明確的錯誤斷言／正向對照，避免缺少 archive 也讓測試通過。產品的帳號檢查與既有儲存層拒絕測試仍在，沒有發現對應產品漏洞。

下一步接第四階段剩餘的正式 domain／UI／雲端重取流程及多裝置驗收。保留目前分支與工作樹；沒有合併、推送、封存上傳或送審。

## 執行期間的範圍裁定

這些裁定與完整審查紀錄仍保存在本計畫 SDD 工作目錄，未刪除。

| 裁定 | 理由與若判斷錯誤的代價 |
| --- | --- |
| 第一項 brief 補入計畫的完整介面與共同限制 | 避免抽取工具遺漏上文；錯誤時需修正交接文件。 |
| 第四項允許必要的內部故障 hook 與帳號分類來源修改 | 原檔案清單省略實作位置；代價是較大的受審查差異。 |
| 各項跑相關測試，全套保留至最後一次有界嘗試 | 避免每個提交重跑耗時整套；可能較晚發現不相關回歸，未解除最終驗證關卡。 |
| 固定暫存檔內容不完整或不明時保留並拒絕 | 儲存層沒有清除未知資料的交易依據；代價是需要另行可驗證恢復，而非自動修補。 |
| 補上 checkpoint store 的內部目錄／帳號綁定驗證 | 防止注入另一個有效資料目錄；代價是跨任務的少量介面改動。 |
| 無提醒的分組缺值視為空陣列 | 原比較會重配未修改計數器版本；代價是既有投影邏輯的小範圍修正與回歸。 |
| 驗證所有存活附件分支與待同步來源；豁免已被替代的歷史本機 URL 內容讀取 | 舊照片檔名可被正常回收，但識別不能改寫；錯誤會漏驗必要附件，因此有缺失分支／待同步回歸。 |
| 最後整合審查覆蓋本子計畫四項提交 | 不重做同分支中先前已審查的其他計畫；未重新審查其全部未改動歷史。 |
| Watch 僅在首次配置處理時間戳時匹配既有編碼表示 | 真實傳輸診斷只剩時間戳不同；不修改既有指令或證據。較廣的 metadata／prepared 正規化提議在實作前已撤回；舊不相符歷史仍拒絕。 |
| 刪除／第 29 天復原測試沿用 canonical fixture | 避免重複建置同一測試資料；代價是與原列示測試檔案位置不同，不是省略行為驗證。 |

整套測試結束後的只讀程序檢查未發現仍在執行的相關 Swift 測試、發行稽核或本次建置程序。

## Candidate and boundaries

Task 4 extends reviewed Task 3 commit `c55702dd0ee5113eac447ba5bde2970b317c92e0` in `.worktrees/cross-device-sync-design`. Version remains **1.7.0 (13)**. The tested source/test/project patch SHA-256 is `63d9d8f2908079134531252446386756b8a000cb9f06cfe112937f330284298a` (six scoped files, excluding this report). Final commit identity is recorded in the Task 4 worker report.

No App test host was launched. All runtime tests use isolated temporary fixtures. No live CloudKit, Keychain, user data, UI, signing, schema deployment, upload, submission, or push was performed.

## Verified contracts

- Five internal no-op-by-default publication hooks observe completed intent, archive/artifact, journal and checkpoint writes, and the boundary before intent removal. They do not replace disk operations or introduce another recovery coordinator/file.
- The real fixture fails once at each phase, releases its used store/journal instances, and activates fresh instances twice. Before archive commit the exact predecessor survives; after commit the exact marker candidate survives. Assertions compare complete records, commit UUID, exact pending mutation array and unique mutation identities.
- Checkpoint file-sync, rename and parent-directory-sync failures are retried with another failure, then repaired. The original transaction and exact journal identities survive both failures and two successful reopens. Existing unprovable-state tests continue to require marker retention.
- Recovery inventory binds the real canonical file digest/length, but pending packets contain only unacknowledged mutations. The fixed `.canonical-next.json` slot, including partial bytes or a directory, blocks cleanup authorization. Authenticated unchanged selection is required to remove `canonical.json`; refused cleanup retains ciphertext and plaintext. Torn and complete pending-only replay both refuse canonical activation without full authority. Account B refuses account A's checkpoint unchanged.
- Six actual wire-decoded Watch commands with subsecond timestamps preserve all six counter states/proofs through ACK, two reopens and duplicate replay. Prepared/archive/ledger interruption recovery retains the exact command identity and does not increment again.
- Both legacy and usage markup paths preserve the original PDF attachment identity and bytes, exact checkpoint records, and no-op behavior through two reopens. Usage markup legitimately advances the archive's optimistic-lock revision; legacy artifact-only markup does not change archive bytes.
- Acknowledged project deletion retains tombstones. Day-29 restoration followed by another reopen restores the original photo bytes and live domain records while preserving superseded attachment tombstones.
- Both checkpoint sources are explicitly members of the same app and Watch Core consumer targets as `SyncBootstrapTransaction.swift`. No unrelated project settings or Watch CloudKit contract changed.

## Watch precision correction

A newly allocated processing stamp could differ from its Watch-file roundtrip by one floating-point unit. With a real wire-decoded command, only `processingStamp.modifiedAt` differed (`800000010.000002` versus `800000010.0000019` seconds since reference date); command identity, prepared command and effect proof matched. A second increment failed in both canonical and pre-canonical modes.

The bounded correction allocates **new** processing timestamps using the existing codec's millisecond-Double representation before first issuance. It does not round to integer milliseconds, change logical revision/device ID, normalize received command identity, modify prepared commands, or rewrite retained proofs. Three repeated actual codec cycles, sequential commands, replay and interrupted recovery cover stability. Existing mismatched issued history remains fail-closed; no migration or tolerance comparison is introduced.

## Execution evidence

All Swift runs use `CLANG_MODULE_CACHE_PATH=/tmp/daily-canonical-clang-cache` and task-owned `--cache-path /tmp/task4-swift-cache --config-path /tmp/task4-swift-config --security-path /tmp/task4-swift-security`, with `--disable-sandbox`. HOME and CODEX_HOME were not changed. The existing `.build` scratch is reused.

The bounded runner records the exact command, start, exit status and elapsed time in each log, terminates the process group after 900 seconds, and reports timeout as **incomplete**, never PASS.

| Validation | Result | Evidence |
| --- | --- | --- |
| Fixed canonical temporary RED | Exit 1; 1 test / 2 cases / 2 issues | `/tmp/task4-account-red-01.log` |
| Publication hook behavioral RED | Exit 1; 1 test / 5 cases / 11 issues | `/tmp/task4-boundary-red-04.log` |
| Wire-decoded Watch processing-stamp RED | Exit 1; 1 test / 2 modes / 4 issues | `/tmp/task4-watch-wire-red-01.log` |
| Watch precision/replay/interruption GREEN | Exit 0; 3 tests / 1 suite; 2.070 s | `/tmp/task4-watch-green-02.log` |
| Repeated checkpoint faults and reserved directory | Exit 0; 2 tests / 2 suites; 0.709 s | `/tmp/task4-retry-green-01.log` |
| Final focused Core + Watch | Exit 0; 476 tests / 31 suites; 29.109 s (137.476 s including rebuild) | `/tmp/task4-focused-final-01.log` |
| Full Core, exactly one bounded run | **INCOMPLETE, exit 124 at 900.011 s; 4 failed tests / 46 issues recorded** | `/tmp/task4-full-core-01.log` |
| Signing-disabled macOS build-for-testing | Exit 0; TEST BUILD SUCCEEDED; 56.139 s | `/tmp/task4-macos-build-for-testing-01.log` |
| Single isolated Share timeout diagnostic after full exit | Exit 0; 1 test / 1 suite; 0.001 s | `/tmp/task4-share-isolated-01.log` |
| Whitespace/project syntax | `git diff --check` and `plutil -lint` passed during self-review | Final readback recorded in worker report |

Final focused command:

```sh
swift test --disable-sandbox --cache-path /tmp/task4-swift-cache --config-path /tmp/task4-swift-config --security-path /tmp/task4-swift-security --filter 'SyncCanonical|JSONProjectStoreCanonical|SyncBootstrap|SyncAccountRecovery|SyncPublication|JSONProjectStoreSyncDeletion|Watch'
```

Full Core removes only the filter. Build command:

```sh
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/daily-canonical-derived CODE_SIGNING_ALLOWED=NO build-for-testing
```

Output is not warning-free: the Swift rebuild reported the existing deprecated `String(contentsOf:)` use in `HighlightOverlayContractTests`; Xcode reported unavailable CoreSimulator services and skipped AppIntents metadata extraction for targets without that framework. The native macOS build nevertheless completed successfully. None of these diagnostics authorized a host launch or live-data workaround.

The full run has **no final test-run summary**. Its log records 2,280 test functions started, 2,275 passing summaries and 4 failing summaries (46 issues); 170 suites started, 166 passing and 3 failing summaries. These are observed partial counts, not a full-suite PASS or configured-total claim. `ReleaseAuditLocalizationTests.provenanceRequiresBothRetainedArchivesAndTheirInfoPlists` has no completion summary before the timeout; the final buffered output contains a missing fixture `Info.plist` traceback. No second full run was attempted.

The four recorded failures are:

- `generatedReleaseBuildSettingsUseAutomaticDevelopmentSigningWithoutProfiles`: 28 missing-field issues.
- `generatedDebugBuildSettingsUseAutomaticDevelopmentSigningWithoutProfiles`: 16 missing-field issues. A single read-only settings diagnostic returned exit 0 but JSON reported PIFCache/DerivedData permission failure and omitted the required fields (`/tmp/task4-buildsettings-diagnostic-01.log`). The settings gate therefore remains unverified in this sandbox.
- `unixSocketIsRejectedWithoutOpeningIt`: fixture socket creation/bind threw generic EIO before the reader ran. Sandbox restriction is suspected; the fixture discarded the actual errno, so the cause is not confirmed.
- `cancelDuringProcessingSuppressesLatePublication`: a 10-second semaphore wait timed out under full-suite load. Its only isolated rerun, after the full process ended and with unchanged source/settings, passed in 0.001 seconds. This supports a transient/load-related failure but does not erase the failed full-run result.

## Follow-up full-suite diagnostics — 2026-09-05

These diagnostics ran on unchanged product source `a4f87e19302ed2b5ab321245e712807efffee81d`, checkout HEAD `45cfce0d4b9e8119d35c9ababd8e2277bc833fd7` (documentation only). The preceding full-run account is historical; this section records the subsequent attempt without replacing its failures.

- The four previously failing functions passed outside the sandbox. The first diagnostic process still exited 1 because its empty XCTest harness selected x86_64 for the arm64 bundle; this run is not an overall PASS (`/tmp/daily-canonical-validation-diagnostic-01.log`). Explicit `/usr/bin/arch -arm64 /usr/bin/swift` resolved that harness mismatch: all 4 tests / 3 suites passed in 10.786 s, process exit 0, elapsed 11.778 s (`/tmp/daily-canonical-validation-diagnostic-arm64-01.log`). No signing or product changes were required.
- The full arm64 run used `--skip-build --disable-sandbox --no-parallel`, the same temporary cache/config/security paths, and an approved sandbox-external execution with an 1,800-second owned-process-group bound. It completed normally with **exit 1, 2,310 tests / 170 suites, 1 issue, 1,221.454 s test time / 1,222.219 s process elapsed** (`/tmp/daily-canonical-full-arm64-serial-01.log`). There were 2,309 passing test summaries and one failed test function. The prior four failing functions did not fail in this run.
- The sole failure was `RuntimeLocalizationSourceContractTests.shippingUISourcesUseTheRuntimeLocaleAwareBoundary`. Its `swiftc -frontend -dump-parse` subprocess crashed while processing `KnitNote/CloudSync/CloudSyncEngineTransport.swift`, in initializer/superclass lookup requests under Swift 6.3.3. This is a parser-process failure, not a reported direct-localization assertion violation. It still blocks complete validation.
- A direct, bounded parse of that same source returned exit 0 in 0.256 s (`/tmp/daily-canonical-parser-repro-01.log`). A sandbox-external, explicit-arm64 isolated rerun of the entire localization suite passed **9 tests / 1 suite in 9.985 s**, exit 0, elapsed 11.254 s (`/tmp/daily-canonical-localization-isolated-01.log`). The crash was not reproduced; its precise trigger is unresolved. Neither an environment/load hypothesis nor this focused PASS establishes full-suite success.

No tests were skipped or weakened, no product code was modified, and no further full rerun was started in this diagnostic turn. Subsequent work should investigate reproducibility before choosing a test-tool change. The full-suite gate remains open, independently of the broader integration/device gates below.

## Parser reproducibility investigation — 2026-09-05

The next diagnostic turn reproduced the failure without running the test suite: 60 sequential invocations of the original `xcrun swiftc -frontend -dump-parse` command against the absolute transport source path produced **10 failures (status 138) and 50 successes**. Logs are retained in `/tmp/knitnote-parser-repeat.rBnxUg/`. Failed run 3 shows the same initializer/superclass lookup requests as the full-suite failure, ending in `getAdjustedFormalAccess` while looking up `CloudSyncTransport`. Therefore full-suite load is not a necessary trigger; the underlying compiler defect is not yet reduced to a minimal reproducer.

A single-variable experiment added `-disable-access-control` **only to the standalone source-scanning command**, not any build command. All **60 of 60 invocations exited 0** (`/tmp/knitnote-parser-access.ZON6tw/`). The installed frontend documents this flag as ignoring access-control restrictions. After normalizing printed memory addresses, the successful baseline run 1 and experimental run 1 AST dumps were identical. A temporary private-protocol/actor initializer fixture still emitted all three prohibited localization-call forms, including inside private code; comment/string lookalikes did not produce call expressions (`/tmp/knitnote-localization-parser-oracle.swift`, `/tmp/knitnote-localization-parser-oracle.log`).

This supports a narrow proposed workaround in the localization syntax scanner, whose contract is call detection rather than access checking. It is not proof that the compiler itself is fixed. No repository test helper or product code has been changed yet. Before adopting the flag, add regression coverage for private actor initialization and retained call detection, run the localization suite, then rerun the complete Core suite. Do not add retries, ignore parser failures, exclude files, or change shipping compiler access checks.

## Approved scanner-only workaround — complete Core verification passed

The user approved adopting the bounded workaround. Only `Tests/KnitNoteCoreTests/RuntimeLocalizationSourceContractTests.swift` changes: the syntax-scanning frontend invocation adds `-disable-access-control`, the detector fixture exercises a private actor initializer (including comment/string negative controls), and a characterization test requires 60 independent parses of the original transport source to succeed. There are no retries: the first parser failure still throws. Shipping compiler settings, source enumeration and localization violation rules are unchanged.

- **RED:** before the flag change, the new repeated-parse test failed with the original `.parseFailed` compiler crash. Two selected tests ran with one issue; process exit 1 (`/tmp/localization-scanner-red.log`, 77.730 s including rebuild).
- **GREEN:** after the flag change, all 10 localization source-contract tests passed in 15.297 s; process exit 0, 33.766 s including rebuild (`/tmp/localization-scanner-green.log`).
- **Full Core PASS:** explicit arm64, no parallelism, `--skip-build`, sandbox-external execution and the same 1,800-second bound completed with **2,311 tests / 170 suites passed in 1,270.373 s**, process **exit 0**, 1,271.317 s elapsed (`/tmp/localization-scanner-full-core.log`). No tests were excluded. This is the first complete successful full-suite result in this verification arc.
- Independent read-only review of the scanner diff found no Critical, Important or Minor issues. The review confirmed scanner-only flag scope, private actor call detection, negative controls, all-60-success semantics, and unchanged error propagation. Review approval is not release approval.
- The tested scanner file SHA-256 is `ca7f7f19b7b77af997a2ae629eed21e761ccc0e3ca945ae1396fc988143463f6`; product source remains `a4f87e19302ed2b5ab321245e712807efffee81d`. Only this test file and this report changed from checkout HEAD `45cfce0d4b9e8119d35c9ababd8e2277bc833fd7`. `git diff --check` passed after validation.

## Remaining acceptance gates

Injected exceptions and in-process object replacement do not establish sudden power-loss or real process-termination durability. A macOS build does not establish iPhone, iPad, Mac, Watch or extension physical acceptance. Live account transitions, remote refetch completion, CloudKit transport, actual caller freeze/ownership integration and complete-device validation remain separate gates. Pending-only account recovery intentionally cannot reconstruct acknowledged full canonical history. No release readiness is claimed.
