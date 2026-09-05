# 雲端接收批次耐久提交驗證報告

日期：2026-09-06

## 結論與邊界

最終 whole-plan review 在 `b672060a82b01abc2963b1a3d45b1b23254b8635` 找到合法 live attachment metadata-only 更新的 Important 問題；本次最終修正已改 production source。**下列原 Task 6 完整 Core／macOS／iOS 成功均為 cf0dd9d 的歷史證據，不能驗證修正後候選。修正後的 scoped re-review、fresh full Core 與平台建置仍待完成。** 最終修正的獨立來源／測試綁定與 focused 結果另列於後段。

本輪已用實際 Core／CloudSync 原始碼、檔案、canonical checkpoint、mutation journal、Watch 證據、刪除保留 ledger 與隔離 attachment staging 完成組合驗收。新增的 3 項 Core 組合測試、1 項無宿主 coordinator 組合測試及 5 組實際來源無宿主回歸均已通過。

第一次完整 Core 在 managed sandbox 中完成但不通過：2,366 tests／174 suites、45 issues。問題只來自 3 個測試：兩個 Xcode build-settings 測試因 sandbox 禁止預設 DerivedData/PIFCache 寫入而得到空 settings（44 issues），一個 Unix socket fixture 在進入 reader assertion 前因 bind 被 sandbox 以 EPERM 拒絕（1 issue）。當前候選的直接對照已證實此分類：相同 3 項測試在 sandbox 外通過，沒有修改 production source。第 22 項 controller 裁決因此允許凍結候選再執行一次 sandbox 外完整 Core；下列結果保留兩次執行的完整證據，不刪除或改寫第一次失敗。

Controller 核准的 sandbox 外完整 Core 已在未改動候選上通過：2,366 tests／174 suites，test time 1,197.455s、runner elapsed 1,198.741s、exit 0、無 timeout。原 managed-sandbox 失敗仍是驗證歷史的一部分；sandbox 外完整綠燈補足本候選的完整 Core 證據，但不把原失敗重寫成成功。

這不是 production-ready 或 release-ready 宣告。正式同步開關維持停用；沒有啟動 App 宿主、連線正式 CloudKit、存取 Keychain／使用者資料、簽章、安裝、archive／export、push、upload 或送審。

## 驗證候選身分

- Task 6 開始 HEAD／production source commit：cf0dd9da5081e6c3922011a4d56dee6e071fccb2
- 該 commit 的完整 tree：5012c6015a7df014b609036e4ab626c319585a18
- Sources tree：126fac016c69a1620f5a30bdda3d03fb15db8e3a
- KnitNote/CloudSync tree：7f395352e5142f8d635af03e7a2c45106986dee2
- 從 144a1dc 到 cf0dd9d 的 12 個 production/project changed-file SHA-256 manifest：118bd74765a09124eea6f7fce9e51bbd2b91dec5dbaed5959c7451541bd05db1；逐檔清單保存在 /tmp/remote-batch-task6-production-files.sha256。
- 完整 Core 兩次執行當時的 Core 組合測試檔 SHA-256：f424d9b701d27275a299c7e21d5b9a3ba07966031956a543df3166c5a6650992
- 完整 Core 兩次執行當時的 App 組合測試檔 SHA-256：8528efd3ef49e8450e49357b51f0f96e9e57649e68efa305cc00cb7cb6e4e7e7
- Review fix round 1 最終 focused/no-host 快照的 Core 組合測試檔 SHA-256：6094e505ba6b6ad76d75ee6cc6c9ce797d4bcd4d20779cb26a75e778f537fe94
- Review fix round 1 最終 focused/no-host 快照的 App 組合測試檔 SHA-256：09cc3ad674b786de95d7df9fb4c92eda2be9c1e30304d262dc145b19be3e506a
- 上述新 test-file hashes 只由 fix-round focused/no-host 執行驗證；不回溯宣稱它們參與既有的完整 Core 執行。完整 Core 仍綁定前兩個原始 hashes 與未改 production source cf0dd9d。
- Task 6 在 production commit 後只改測試與本報告；Sources、KnitNote、KnitNoteWatch、KnitNoteShare 與 project.pbxproj 對該 commit 沒有 Task 6 diff。此敘述限於 Task 6／review fix round 1；本次最終 production 修正另行綁定，不能套用原完整驗證。
- 版本／build 保持 1.7.0（13）。

## 組合驗收覆蓋

1. 六個計數器各套用一個真實 Watch command，以完整 command identity／processed proof 作 oracle；另一作品的部分遠端更新只替換精確 record，不改六個計數器、其他 records、Watch ledger bytes 與既有 pending FIFO。
2. 先建立兩個本機照片歷史 head，再以合法 mapper lineage 產生遠端附件與父作品。測試從 verified staging 安裝精確 bytes，保留歷史 attachment payload，並從預先保留的 canonical candidate 推導唯一 dependent project save 的 record ID、intent、完整 payload 與合法 version。同批重送後 mutation identity／payload、checkpoint、archive 與 installed/staged bytes 均不變。
3. 真實本機刪除先建立 deletion-ledger retention 與完整 exact-removal versions；有證據的 tombstones 可提交且 retained ledger/files/FIFO 不變。只含 raw deleted ID、沒有保留證據的另一作品被明確拒絕；checkpoint、archive、journal authority、ledger bytes 與 retained files 全部精確保留。
4. 先安裝 4,096 個未退休 Core receipts；新批次在 intent／archive／FIFO 任何改變前以 receiptCapacity 拒絕。只有 transport 可驗證 ACK 後才耐久退休一個精確 receipt。
5. 遠端批次在 Core 提交後注入 ACK failure，再新增本機編輯；duplicate delivery 只完成 ACK／finish。本機值、從 canonical candidate 推導的唯一 pending mutation record ID／intent／完整 saved-record version、FIFO identity、archive 與 checkpoint 都不回退、不重複。

這些測試沒有複製 Tasks 1–5 的每個故障案例；它們聚焦多個已審契約同時存在時的真實狀態交互與精確 authority 保留。

## 測試與建置證據

| 項目 | 結果 | 證據 |
| --- | --- | --- |
| Fix round 1 前的 Core 組合測試快照 | exit 0，3 tests／1 suite，2.310s，無 warning | /tmp/remote-batch-task6-core-combined-final.log |
| Fix round 1 前的 App 組合測試快照 | exit 0，1 test／1 suite，16.899s，無 warning | /tmp/remote-batch-task6-app-combined-final.log |
| 無宿主 discovery | exit 0；swift test list 發現 required 5 suites 皆非空；無 deprecated/unhandled-source 或 compiler warning | /tmp/remote-batch-task6-discovery.log |
| 實際來源無宿主 5-suite 回歸 | exit 0，136 tests／5 suites，22.899s，無 warning/error | /tmp/remote-batch-task6-app-focused-final.log |
| managed-sandbox 完整 Core | exit 1，2,366 tests／174 suites，1,217.628s，45 issues；runner 1,286.695s，無 timeout；編譯階段 82 行 `warning:` | /tmp/remote-batch-task6-full-core.log |
| sandbox 內 xcodebuild build-settings 對照 | 8/8 命令 exit 0，但 JSON settings 全空並附 Code 513/PIFCache EPERM | /tmp/remote-batch-task6-buildsettings-sandbox-status.log 及對應 .json/.stderr |
| Unix socket 實際 errno 對照 | sandbox 內 bind=-1, errno=1；sandbox 外 bind=0 | /tmp/task6-socket-diagnostic.swift、/tmp/remote-batch-task6-socket-outside.log |
| sandbox 外失敗項精確對照 | exit 0，3 tests／2 suites，10.786s | /tmp/remote-batch-task6-full-failure-outside-diagnostic.log |
| controller 核准的 sandbox 外完整 Core | exit 0，2,366 tests／174 suites，1,197.455s；runner 1,198.741s，無 timeout | /tmp/remote-batch-task6-full-core-outside.log |
| macOS arm64 build-for-testing，CODE_SIGNING_ALLOWED=NO | exit 0，33.998s，TEST BUILD SUCCEEDED | /tmp/remote-batch-task6-macos-build.log |
| generic iOS build，CODE_SIGNING_ALLOWED=NO | exit 0，38.504s，BUILD SUCCEEDED | /tmp/remote-batch-task6-ios-build.log |
| project plist | plutil -lint：OK | 直接命令輸出 |
| 最終 diff 檢查 | clean，exit 0 | git diff --check |

無宿主 harness 位於 /private/tmp/remote-batch-task6-harness，以 symlink 指向當前 worktree 的實際 Sources/KnitNoteCore 與 KnitNote/CloudSync，並明列 6 個 App test sources。CloudKitDevelopmentIntegrationTests 只編譯與 discovery，從未執行。warning 清理由受支援的 swift test list 與真實-source 布局完成，沒有省略 required suite 或隱藏 compiler warning。

第一次 5-suite 無宿主執行的 136 tests 中有 1 test／2 issues：測試錯誤假設 receipts 排序一定把新 UUID 放最後。改為比較完整精確集合、每個 retained receipt 及新 receipt 的完整 identity／commitID／domainChanged 後，最終 136 項全通過。更早 attachment 與 tombstone 失敗分別來自沒有 issued-history lineage 的非法 fixture 及不完整 deletion proof set；都改成由真實已持久 authority 推導的合法 fixture，沒有改 production behavior。這些是 fixture/oracle 修正，不冒稱 production RED。

完整 Core managed-sandbox 執行有實際編譯，其 log 含 82 行 `warning:`：共 41 個編譯診斷 header（每個又在 source annotation 重複一行），其中 20 個是 `#require` 對已知非 nil attachment source 的 redundant warning，21 個是 macOS 15 `String(contentsOf:)` deprecation warning。另含一行 CoreGraphics PDF diagnostic，以及負向 release-audit 案例預期觸發的 release_archive_manifest.py missing-artifact tracebacks；對應負向案例最後通過。這些 warning/診斷均保留，不當成成功也不隱藏。

Sandbox 外 full 也保留一行相同 CoreGraphics diagnostic、負向 release-audit 的預期 tracebacks，以及三行預期的 provenance mismatch 診斷；沒有 failed summary。該次使用 `--skip-build`，因此沒有執行 compiler，其「無 compiler warning」不能抵銷或改寫 managed full 的 82 行 warning。macOS build 有 3 行 AppIntents metadata extraction skipped warning（App、AppTests、MacUITests）；iOS build 有 3 行同類 warning（App、Watch、Share）及 2 行 No AppShortcuts found - Skipping note。兩個 build 均無 error。

因新行為在合法 fixture 上已正確，沒有製造 production bug。為確認最重要的 payload oracle，曾短暫把 dependent project save 的期望 version 改為 nil；/tmp/remote-batch-task6-oracle-mutation.log 精確記錄 1 test／1 suite 因完整 SyncRecordVersion 不等於 nil 而失敗 1 issue。隨即還原；Core 測試檔 SHA-256 回到 f424d9b701d27275a299c7e21d5b9a3ba07966031956a543df3166c5a6650992，production diff 仍為零，最終 3 個組合測試再度全數通過。

## Review fix round 1 追加驗證

Review 指出原組合測試對 changed project、new attachment/history heads、receipt retirement checkpoint 與 duplicate checkpoint 仍只比較局部欄位。本輪只加強兩個測試檔與報告，沒有 production 變更：Core 改為比較完整 expected canonical records，包含 changed project、new attachment 與每個 history head；duplicate replay 後再讀 staged URL 比對 bytes。App 對 capacity reject 後的 in-memory project 立即斷言，並以 predecessor authority、精確 batch record/archive digest/receipt 與唯一新 commit ID 組出完整 expected checkpoints，包含 account、commit metadata、records、legacy deletion IDs 與 receipts。Watch FIFO 也從只要求非空，加強為六個 command 對應的 18 筆 `[project, counter, counter]` record-ID 順序。

行為已正確，因此不製造 production RED。兩個純測試 mutation 證明新 oracle 會失敗：`/tmp/remote-batch-task6-fix1-core-records-mutation.log` 將 expected changed record 退回 predecessor 後 exit 1、1 test／1 suite、1 issue；`/tmp/remote-batch-task6-fix1-app-checkpoint-mutation.log` 將 expected duplicate-retirement archive digest 改為 32 個 zero bytes後 exit 1、1 test／1 suite、1 issue。還原後兩檔 hashes 回到上述 fix-round 快照。

- `/tmp/remote-batch-task6-fix1-core-final.log`：exit 0，3 tests／1 suite，2.223s。
- `/tmp/remote-batch-task6-fix1-app-final.log`：exit 0，1 test／1 suite，15.200s。
- `/tmp/remote-batch-task6-fix1-nohost-final.log`：exit 0，136 tests／5 suites，20.720s；required no-host suites 全部覆蓋，沒有執行 live CloudKit suite。
- `git diff --check`：exit 0。本 fix round 依指示沒有再執行 full Core；既有 full 繼續綁定 cf0dd9d 與原測試檔 hashes，新 hashes 只綁定上述 focused/no-host 證據。

## 精確驗證命令

Focused Core 與 full Core 共用前綴：

    CLANG_MODULE_CACHE_PATH=/tmp/daily-canonical-clang-cache \
      /usr/bin/arch -arm64 /usr/bin/swift test \
      --disable-sandbox --no-parallel \
      --cache-path /tmp/task6-swift-cache \
      --config-path /tmp/task6-swift-config \
      --security-path /tmp/task6-swift-security

Core 組合 filter：

    --filter 'partialRemoteProjectUpdatePreservesSixCounterWatchProofsAndExactFIFO|stagedRemoteAttachmentInstallsExactBytesAndPreservesHistoricalHeads|retainedTombstoneCommitsButUnprovenRawDeletePreservesEveryAuthority'

原 fix round 1 無宿主命令逐字抄自 task-6-report.md 的追加紀錄，working directory 為 `/private/tmp/remote-batch-task6-harness`。單一 App 組合測試：

```zsh
set -o pipefail
env CLANG_MODULE_CACHE_PATH=/tmp/daily-canonical-clang-cache /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --no-parallel --cache-path /tmp/task6-harness-cache --config-path /tmp/task6-harness-config --security-path /tmp/task6-harness-security --filter 'saturatedReceiptsNeedAcknowledgedRetirementBeforeDuplicateACKPreservesLocalFIFO' 2>&1 | tee /tmp/remote-batch-task6-fix1-app-final.log
```

原 fix round 1 必要五組無宿主回歸：

```zsh
set -o pipefail
env CLANG_MODULE_CACHE_PATH=/tmp/daily-canonical-clang-cache /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --no-parallel --cache-path /tmp/task6-harness-cache --config-path /tmp/task6-harness-config --security-path /tmp/task6-harness-security --filter 'RemoteBatchCommitterIntegrationTests|KnitNoteCloudSyncCoordinatorTests|CloudSyncEngineTransportTests|CloudAccountTransitionCoordinatorTests|CloudAssetFileStoreTests' 2>&1 | tee /tmp/remote-batch-task6-fix1-nohost-final.log
```

第一次 full 由 /tmp/task4-run-bounded.py 1800 包住完整 Core 命令。工具逾時時只對自己的 subprocess process group 送 TERM，10 秒後才送 KILL，並以 124 結束；本次沒有 timeout。第 22 項裁決核准的 sandbox 外 full 另加 --skip-build，其餘參數與 1,800 秒邊界不變。

## 完整來源 diff self-review

實作基準 144a1dc 到 production source cf0dd9d 的差異涵蓋 24 個 source/project/test files（4,089 insertions、375 deletions）。Task 6 對照已核准規格 §§1–9 與 Tasks 1–5 審閱報告：partial raw batch 在完整 canonical authority 上重合併；帳號／前驅／journal／Watch／attachment 證據的最終檢查與同步寫入邊界均存在；batch identity 綁定內容 hash；format-6 保留完整恢復證據；4,096 Core receipts 容量、100,000,000-byte authority/file 上限、incoming 128 unresolved proofs／16 MiB 上限及耐久 ACK retirement 均有測試；未支援 server-record-changed adapter 明確失敗並保留 FIFO。

本輪 scoped self-review 沒有找到需要 Task 6 production source 修正的 Critical／Important 問題。這不取代 controller 之後從 144a1dc 到最終 HEAD 的獨立 task review 與 Astra whole-plan review。

## 最終 whole-plan review 修正快照

修正基準：`b672060a82b01abc2963b1a3d45b1b23254b8635`。Important 1 已以 actual RED 重現：保留同一 immutable attachment snapshot/version/payload/bytes，只把 live `deletedAt = nil` overlay 提高 stamp，正常 commit 與 afterIntent 後 fresh reopen 都拋出 `missingAuthority`。另一個不完整 evidence-plan 測試證明原流程先寫 intent 才拒絕。

最小 production 修正只在 `JSONProjectStore.swift`：媒體計畫與 evidence 更新共用「完整 attachment record 是否改變」的判準，並在 intent 前完整套用／驗證候選 evidence。既有安裝器對相同 bytes 保留原檔與 inode；格式、所有權／CAS、100,000,000-byte 限制均保留。metadata-only 更新需保留的媒體仍受整份 intent 編碼上限限制，超限會在 intent 前安全拒絕。

新增 oracle 比較手動推導的完整 checkpoint、receipt、完整 evidence、archive bytes、非空 exact pending FIFO 與 journal 檔案 authority、媒體 bytes／device／inode。正常 commit 及 afterIntent 兩條路徑都丟棄初始 store/journal/checkpoint handles，再連續重新建立兩次 store/checkpoint/journal；重送只回 alreadyCommitted，沒有 domain generation／callback 增量。不完整 evidence 計畫必須在 intent 前拒絕且全部原 authority 保留。

Minor 2 已補固定非空 format-1 bytes：live project、deleted project 與 legacy deletion ID，驗證 byte-for-byte legacy round trip 及 receipt 升級後完整 records／IDs／account／commit／archive digest 保留。新 fixture 由本輪 legacy-format encoder 產生並固定，對照 `9214e02` 的原 format-1 wire/integrity schema；沒有冒稱是以前執行留存的資料。原先空的歷史 fixture 與 format-5 fixture 完全保留。Minor 3 已將原 no-host 省略命令改成 task-6-report.md 中的兩條實際完整命令。

本次 final-fix snapshot SHA-256（與上方原 full-run hashes 分開）：

- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`：`9deef7ca8c22cd5e809a23999214bd284cca5230a528542f9f6c6c515d09371c`
- `Tests/KnitNoteCoreTests/JSONProjectStoreRemoteBatchRecoveryTests.swift`：`4c46c32f0f5ac5bbd65c21166c2bfc9f029ad0bbd3dd564ec3ac9a0f97579231`
- `Tests/KnitNoteCoreTests/SyncRemoteBatchTransactionTests.swift`：`45ab289f9cc2d7bd207816768c8ed56863ceedefaa0a9d691da26828089a7a2a`
- 未改動的 App 組合測試檔：`09cc3ad674b786de95d7df9fb4c92eda2be9c1e30304d262dc145b19be3e506a`

| 本次驗證 | 結果 | 日誌 |
| --- | --- | --- |
| 合法 live-overlay actual RED，未改 production | exit 1；1 test／2 cases／2 issues；0.752s | /tmp/remote-batch-final-fix-red.log |
| incomplete evidence actual RED，未改 production | exit 1；1 test／1 issue；0.213s；intent 非 nil | /tmp/remote-batch-final-fix-preflight-red.log |
| 最小修正 GREEN | exit 0；2 tests／3 cases／1 suite；1.325s | /tmp/remote-batch-final-fix-green.log |
| 最終涵蓋 Core 回歸 | exit 0；79 tests／6 suites；30.725s | /tmp/remote-batch-final-fix-core.log |
| 最終實際來源無宿主回歸 | exit 0；136 tests／5 suites；20.732s | /tmp/remote-batch-final-fix-nohost.log |

上述 behavioral RED／GREEN／final logs 均無 compiler warning；初次測試 fixture 曾誤用 fileprivate `canonicalized` 而編譯失敗，修正 fixture 後才取得 actual RED，該編譯失敗不列為行為證據。最終 Core 涵蓋 `SyncRemoteBatch`、`JSONProjectStoreRemoteBatch`、`SyncPublicationEvidenceDurability`、`SyncAttachmentManifest`。no-host harness 已確認 symlinks 仍指向本 worktree 的實際 Core／CloudSync；live CloudKit suite 未執行。

最終 Core literal command，working directory `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`：

```zsh
set -o pipefail
env CLANG_MODULE_CACHE_PATH=/tmp/daily-canonical-clang-cache /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --no-parallel --cache-path /tmp/task6-swift-cache --config-path /tmp/task6-swift-config --security-path /tmp/task6-swift-security --filter 'SyncRemoteBatch|JSONProjectStoreRemoteBatch|SyncPublicationEvidenceDurability|SyncAttachmentManifest' 2>&1 | tee /tmp/remote-batch-final-fix-core.log
```

最終 no-host literal command，working directory `/private/tmp/remote-batch-task6-harness`：

```zsh
set -o pipefail
env CLANG_MODULE_CACHE_PATH=/tmp/daily-canonical-clang-cache /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --no-parallel --cache-path /tmp/task6-harness-cache --config-path /tmp/task6-harness-config --security-path /tmp/task6-harness-security --filter 'RemoteBatchCommitterIntegrationTests|KnitNoteCloudSyncCoordinatorTests|CloudSyncEngineTransportTests|CloudAccountTransitionCoordinatorTests|CloudAssetFileStoreTests' 2>&1 | tee /tmp/remote-batch-final-fix-nohost.log
```

Self-review 未發現新增 Critical／Important 問題；這是修正者自查，**scoped re-review 及修正候選 fresh full Core／macOS／iOS builds 仍未執行**。production activation／release gates 維持下列限制。

## Controller 裁決、理由與返工成本

依 ledger 的真正時間順序保留全部 23 項；後來修正早期 ACK／lock 設計的裁決仍保留，沒有從歷史刪除。

1. 將抽出 brief 時遺漏的 shared constraints/contracts 附回。理由：抽取不含前文。成本：若判斷錯誤會造成介面返工。
2. Task 2 擴到 store 與 deletion/restore carry-forward 測試。理由：receipts 必須在一般 successor 中存活。成本：Task 2 diff 變寬。
3. Task 5 擴到所有 conformers 與 no-host harness。理由：不啟動 live host 也要完整編譯真實整合。成本：integration/test-infrastructure diff 變寬。
4. 每 task 跑 focused、Task 6 跑 full Core。理由：依計畫驗證順序。成本：無關回歸到後期才發現，且不產生 release waiver。
5. 最終 broad review 從 144a1dc 開始。理由：更早 branch 工作屬已審計畫。成本：更早未改工作不在本輪重審。
6. scratch/worktree 保留到真正 merge。理由：本計畫沒有 merge 授權。成本：保留 scratch 儲存。
7. 擴充 format-6 intent 收納有界 predecessor/raw-batch/candidate/media 證據。理由：identity-only metadata 無法重建中斷寫入。成本：marker 與 format 測試變大，但不引入第二 writer，100 MB 邊界不變。
8. 新增狹義、已驗證、唯讀完整 permanent-marker query。理由：anti-resurrection 需要完整 deletion authority。成本：多一個 API／檔案／測試；preparation 不 cleanup。
9. 不偽造 acknowledged/nonpending deletion-ledger 狀態、不在本輪做 marker transport。理由：現行 schema 將 marker 與 pending versions 綁定。成本：acknowledged-marker transport 仍是 release gate。
10. 只有完整 pinned proof 存在時才允許 durable intent 後完成精確 candidate，即使 archive 尚未替換。理由：規格允許有證據完成。成本：recovery validation 更強，Task 4 sketch 需調整。
11. 對已正確 recovery 不製造 production defect。理由：Task 4 同時驗證 Task 3。成本：採 injected-failure／mutation evidence，斷言仍嚴格。
12. Task 4 只在證明真實 gap 時改 publication-format source。理由：Task 3 已實作 recovery。成本：依賴前一輪已審實作，不做 token edit。
13. 在 incoming JSON 加有界 scoped ACK evidence、retirement phase、reconciliation 與 finish。理由：absence/reset 不是 ACK，cleanup 有 crash gap。成本：protocol/compatibility/crash-order 測試增加；finished proof 後由裁決 21 精煉。
14. 只在重驗 durable ACK/root/account 後允許 absent-receipt retirement 冪等成功。理由：覆蓋 Core 退休後、transport finish 前崩潰。成本：多 Core API/test surface，仍禁無 proof 成功。
15. 將已驗證 container/account binding 傳過 epoch 與 transition construction。理由：username/zone 不足以綁定 Core identity。成本：transition/conformers 擴大，不猜預設 container。
16. 以 process lock 加 parent flock 序列化完整 incoming RMW/proof reads。理由：atomic replacement 不足。成本：lock-order/multi-instance 測試；粒度後由裁決 20 精煉。
17. 以精確 raw forwarding 與 real-store missing-authority/no-ACK 取代過時 provider-premerge 測試。理由：所有權移入 adapter。成本：斷言移位，不刪 conflict/FIFO 保證。
18. 加同步 commit-ownership wrapper，回傳後才 notify。理由：epoch lock 包 external callback 可 reentry deadlock。成本：狹義 Core API/boundary review，不提供 UI writer。
19. 以有界 conditional async wait 取代 200 次 Task.yield。理由：cleanup 在約 0.03s 假 timeout 前未排程。成本：失敗偵測變慢、helper scope 變寬，exact error/FIFO/file assertions 保留。
20. 使用一個 process-wide incoming NSLock 取代 per-URL registry，保留 parent flock。理由：安全涵蓋 aliases 且無 registry lifecycle。成本：無關 stores 亦被序列化，需後續 latency measurement。
21. 原子地把 finished ACK identity 轉移進既有 envelope，釋放 standalone proof slot，只 reconcile 未解決 proofs。理由：finished standalone proofs 會使 spillover 死鎖並產生過時 blocker。成本：phase/schema migration 測試；128 unresolved／16 MiB 上限不變。
22. 凍結未改來源，以 arm64/--skip-build 和同一 1,800 秒邊界新增一次 sandbox 外 full Core。理由：當前診斷證明 sandbox 拒絕 Xcode cache 與 Unix socket；focused green 不能建立 full success。成本：再花一次 full 時間；保留原失敗，不改 signing/source、live system 或開放無界重試。
23. 最終 production 修正與乾淨 scoped re-review 後，凍結修正候選並重新執行一次有界完整 Core 及停用簽名的 macOS／iOS 建置。理由：production source 改變使舊候選驗證不足。成本：再花一輪完整驗證時間；保留先前失敗與 hashes，不擴展 live-system 行動或無界重試。

## 未完成關卡與已知限制

- Server-record-changed CAS adapter：目前明確拒絕 unsupportedConflictReplacement 並保留 pending FIFO；尚未實作同 record FIFO compare-and-swap replacement。
- 完整 deletion media／marker transport：完整墓碑媒體重取與 acknowledged/permanent marker 傳輸未閉合，不可偽造證據。
- 真實 lifecycle ownership／freeze：正式 App 啟動、帳號移轉、寫入凍結與所有權尚未接線驗收。
- UI／Watch wiring：提交後 generation 通知的正式畫面／Watch 消費者仍屬後續。
- 全裝置驗收：iPhone、iPad、Mac、Watch、extension、真實 CloudKit 與真實程序終止／重啟不在本輪隔離測試內。
- Pre-ACK reset receipt：ACK 前 reset 可能移除 unacknowledged envelope，留下無 durable ACK proof 的有界 Core receipt；現行設計安全 fail closed、不從 absence 偽造 proof，但可能需後續手動／重取協調。
- Incoming lock granularity：process-wide NSLock 加 parent flock 會序列化不相關 stores；大型 inventory/media transaction latency 尚需實機量測。
- 最終修正後的 scoped re-review、fresh full Core 與停用簽名 macOS／iOS 建置：尚待 controller 在凍結候選上完成，原 cf0dd9d 完整結果不能替代。

在上述關卡全關閉、controller 完成獨立 task review 與 Astra whole-plan review，並在同一不可變候選完成真機／CloudKit 驗收前，production sync 必須維持停用。
