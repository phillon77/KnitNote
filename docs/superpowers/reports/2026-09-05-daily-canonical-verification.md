# Daily canonical durability verification — 2026-09-05

## 中文交接摘要

日常同步狀態的持久化、交易整合與重開恢復，四個任務及最後整合審查均已通過；沒有 Critical／Important 程式問題。最終程式提交為 `a4f87e19302ed2b5ab321245e712807efffee81d`，版本維持 **1.7.0（13）**。後續文件提交不改變這個受測程式版本。

相關測試 **476 項／31 組通過**，停用簽名的 macOS `build-for-testing` 成功，未啟動 App。完整 Core 測試在 900 秒上限終止，記錄到 4 項失敗／46 個問題，沒有最終總結，因此**全套驗證未完成，不可合併或送審**。細節與失敗分類列於下方，不能用單項重跑成功取代整套結果。

最後審查保留一項非阻擋的測試改善：帳號 B 拒絕帳號 A 資料的測試應增加更明確的錯誤斷言／正向對照，避免缺少 archive 也讓測試通過。產品的帳號檢查與既有儲存層拒絕測試仍在，沒有發現對應產品漏洞。

下一步先處理全套驗證的環境／socket 診斷與執行時限，再接第四階段剩餘的正式 domain／UI／雲端重取流程及多裝置驗收。保留目前分支與工作樹；沒有合併、推送、封存上傳或送審。

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

## Remaining acceptance gates

Injected exceptions and in-process object replacement do not establish sudden power-loss or real process-termination durability. A macOS build does not establish iPhone, iPad, Mac, Watch or extension physical acceptance. Live account transitions, remote refetch completion, CloudKit transport, actual caller freeze/ownership integration and complete-device validation remain separate gates. Pending-only account recovery intentionally cannot reconstruct acknowledged full canonical history. No release readiness is claimed.
