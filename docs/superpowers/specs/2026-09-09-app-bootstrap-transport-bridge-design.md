# App 初始化傳輸與核心安裝橋接

日期：2026-09-09。版本維持 **1.7.0 (13)**。

狀態：使用者已確認本書面規格，並同意依六階段計畫以子代理逐項實作與審查；實作進行中，尚未完成橋接驗收。基準提交為 `d68b557b4bfa7fbd90f0bcdb84adf2a19c0eb9ba`，工作樹為 `.worktrees/cross-device-sync-design`，分支為 `docs/cross-device-sync-design`。先前 Core、App 測試與建置結果只屬於該基準，不是本橋接的驗收證據。

## 1. 目標與本次範圍

解除「沒有 canonical store 就不能啟動一般傳輸，但初始化又需要雲端資料」的依賴循環。先完成可注入、可隔離測試的帳號初始化橋接，再接正式啟動及產品流程。

本次涵蓋：已確認帳號、已由 storage 開啟的帳號根目錄、既有 custom zone 的完整讀取、必要附件驗證、owned bootstrap 安裝，以及同一帳號 App domain 的交接。可用既有已驗證 archive，或真實 fresh/restored/rollback absence 作為來源；不能自行建立空 archive 冒充來源。

後續正式啟動階段才處理：未綁帳號的舊本機資料首次收納、首次 custom zone 建立、App live factory／帳號通知接線、完整設定與錯誤 UI，以及 Watch 跨帳號啟用。真實 CloudKit、Keychain、簽署安裝、雙裝置驗證及發布另需候選與授權。本次測試不得呼叫這些正式服務。

沿用上位規格：

- `2026-09-02-cross-device-icloud-sync-design.md` 的 UUID／欄位合併、首次資料保留及刪除規則。
- `2026-09-06-cloud-sync-app-session-lifecycle-design.md` 的身分未知、離線使用、generation、停止／排空與本機可用性規則。
- `2026-09-08-account-source-provenance-design.md` 與 `2026-09-08-owned-bootstrap-integration-design.md` 的來源、安裝、歷史與封存權威。

不改遠端 record、journal、publication 或已完成的 owned v3 格式；不新增合併策略、清除策略或容量豁免。

## 2. 現況與選擇

目前 `AppAccountDomainLifecycle.install` 在沒有 canonical/handoff 時回報 `bootstrapRequired`；`CloudAccountTransitionCoordinator.openDestination` 在 install 成功後才建立一般 transport。`KnitNoteApp` 仍組裝既有非同步本機 store。這些都是尚未啟用的界線，不是已發生的資料損毀。

`CloudInitialFetchReceipt` 證明一般傳輸的 fetched batches 已完成 durable commit/ACK，不攜帶完整遠端資料集。`SyncBootstrapRemoteSnapshot.isComplete` 是可由呼叫者提供的 Boolean，不能作為正式 App 的全量來源證據。

採用初始化專用的短生命週期讀取 adapter，再交還既有 `CKSyncEngineTransport`。它只取得資料，不另建同步佇列、衝突引擎或正常 ACK 機制。相較之下，在現有大型 transport 加入初始化／正常雙模式會牽涉既有 state、ACK 與自動同步切換；本次不選此路徑。直接提早啟動一般 transport 也不成立，因為其目前會載入增量 state、重播 incoming 並排入 zone 建立。

## 3. 元件與責任

### 初始化讀取 adapter

新增 App CloudSync 內部元件（建議名稱 `CloudBootstrapSnapshotReader`），只接收已確認帳號、固定 zone、當次請求及可撤銷的 session 驗證。正常 App factory 不在本次啟用；測試必須注入受控 operation driver。

正式實作使用 `CKFetchRecordZoneChangesOperation`，單一 private custom zone，從 nil server change token 開始；以明確逐頁模式處理 token 與 `moreComing`。只使用當次讀取的 token，不讀寫 `FileCloudSyncEngineStateStore`，不將這種 token 當成 CKSyncEngine serialization。

同一讀取只允許一個 active page operation。每頁的 record callback、zone result、operation result 都屬於同一 request/account/zone/session；只有當頁完整成功後才接受下一頁 token。任何 record-level、zone-level、operation-level failure 均使整次讀取失效。最終證據要求正確 zone 的成功 terminal result、`moreComing == false`、operation 成功完成及所有已接受回呼排空；callback 排空前不得完成 continuation。

### 完整快照權能

reader 私有建立不可由一般 caller 拼裝的已驗證結果（建議名稱 `CloudBootstrapSnapshotLease`）。它綁定帳號/container/zone、request、session generation、遠端快照內容摘要、附件版本與驗證來源，以及失效 latch。成功空 zone 也有 terminal 證據；空陣列、nil token、callback 數量或一般 fetch receipt 都不是替代品。

租約是當次程序內的權能，不新增磁碟格式。程序中止後重新讀取，不能靠快取旗標恢復租約。成功 reader 的正常排空不撤銷仍屬目前 session 的租約；帳號失效、取消、來源被替換或完成交接才使它不可再用。核心已選定的 preparing/prepared/terminal 則先走既有 owned recovery，不能以重新讀取覆蓋尚未處理的安裝。

### App 初始化橋接

新增小型內部協調元件（建議名稱 `AppAccountBootstrapBridge`），負責選路、取得完整快照、取得真實來源／pending、建立 owned transaction、安裝與取得真實 handoff；不自行寫 archive、搬移 working set、模擬 journal 或刪除暫存證據。

`AppAccountDomainContext` 可增加實際 storage／短生命週期來源存取接點，但不得公開 arbitrary root、可偽造的 ready Boolean 或長存 RecoveryAccess。session 身分驗證與 storage 鎖內驗證分開；不能在已持有 storage ownership 時重入會再次取鎖的 App validator。

`AppAccountDomainLifecycle` 接受橋接的真實 handoff，沿用 `AppAccountDomainFactory`、`AppSessionOwner` 與既有 record provider／remote committer。正常 canonical reopen 不走全量初始化。

## 4. 資料流與交接

1. 確認目前帳號，撤銷／停止舊 session，排空 App producer 與舊傳輸；沿用現有 recovery restore/consume 或同步 absence 步驟。
2. 檢查非終止 bootstrap；存在時先以 owned/legacy 的正確原生路徑恢復，再重驗 namespace。不能把任意解析錯誤當成「沒有資料」。
3. 已有有效 canonical 就走原本 install／local-ready／背景同步。沒有 canonical 且沒有 committed handoff 才進入初始化橋接。
4. 在已確認且保持有效的帳號 session 下開始完整遠端讀取；一般 transport 尚未啟動，不寫一般 engine state、incoming ACK 或上傳佇列。
5. 全量資料、附件與終止證據完整後，短暫固定來源／pending／context。透過原生 snapshot/export/deletion/mapper 流程取得輸入；不得用 `journal.pending()` 的非預期格式遷移改變凍結基準。遠端租約與所有來源在 preparing 之前再次驗證。
6. 同步呼叫 owned `prepare → install → commit → recover/handoff`；使用已完成的精確來源、history、容量及 no-delete 證據。任何失敗保留既有來源與已發出的 owned 證據，讓原生 recovery 決定後續。
7. factory 成功安裝 canonical、附件 resolver 及 session resources 後，才發布 App session。接著建立原來的一般 transport/coordinator；初始化 reader 必須已完成並排空，不能同時繼續發出舊 callback。
8. 一般 transport 從自己的既有合法 state 啟動並走原本 initial fetch、durable commit/ACK 與 send gate。初始化 lease 不可偽裝成 `CloudInitialFetchReceipt`，也不能直接開啟上傳或顯示「已同步」。

遠端快照只代表當次讀取完成的變更邊界，不是對其他裝置的全域鎖。交接後仍須一般同步吸收後續遠端變更並使用現有衝突規則。

## 5. Records、附件與容量

- 每個 record 使用現有 `CloudRecordCodec` 與 `SyncRecordValidator`；固定完整 zone ID 與 record ID/type 綁定。未知／不支援／錯帳號資料不能跳過後仍宣布完整。
- 按同一次 scan 的原生順序彙整 record 修改與實體刪除；最終每個 SyncEntityID 至多一份記錄，不依 dictionary 的任意順序取勝。保留 deletedAt tombstones 及仍需處理的版本／關聯，不把實體刪除回呼合成新的 domain tombstone，也不修改本機 pending。
- 相同 ID 的版本彙整遵守既有 merge 與不可變版本驗證；晚到舊版本不得覆蓋較新內容，相同不可變版本的不同 bytes 必須拒絕。回呼順序不能取代版本證據。
- 完整結果仍須通過既有 mapper／domain／deletion 驗證；不能表示或缺少必要關聯的遠端結果在 prepare 前拒絕，不補造 records 或空媒體。
- 必要附件包含完整有效版本與衝突分支，不只畫面顯示的勝出版本。使用現有下載安裝／驗證 primitive，確認大小、內容 hash、版本綁定與檔案身分；CKAsset 臨時 URL 本身不是可長存的來源權威。
- 附件來源保留至核心不再依賴它；任何快取替換、帳號失效或回呼晚到都必須使原租約拒絕使用。不得借用普通 cache reconcile 清掉 pending/recovery 已引用的檔案。
- 在每次資料累積或附件寫入前做有界容量檢查。沿用 record 非 asset payload 256 KiB、檔案／bootstrap／canonical 100,000,000 bytes、journal 64 MiB、incoming 128 batches／16 MiB、control 8192 bytes 與既有封存 aggregate cap。初始化在記憶體保留的 metadata（含刪除與收集證據）上限16 MiB，最多128頁；上限不足時回報容量阻擋，不截斷、不 ACK、不默默提高限制。
- 新下載若放入 account staging，必須在寫入前證明既有資料加上該寫入的原生 inventory／封存大小仍可接受；不能先填滿帳號根目錄，等 prepare 失敗後才發現無法封存。沿用原生 codec/accounting，不另造較寬鬆 DTO；無法證明就不寫入。
- 完整 bootstrap program 的 prospective recovery budget 仍由核心最後檢查。讀取快取的容量通過不授予核心輸出或清理權威。

## 6. 錯誤、取消與範圍限制

| 情況 | 結果 |
| --- | --- |
| 已存在且完整成功讀取的空 zone | 可簽發空快照租約；仍須來源與核心驗證 |
| zone 不存在／被刪除、token expired、沒有最終 zone 結果 | 本次讀取失效，保留資料；不是成功空帳號 |
| quota／網路錯誤 | 不發布半套新 session，保留 pending；明確重試重新從 nil token 讀取 |
| 換帳號、generation 改變、取消 | 立即撤銷租約與回呼入口，取消並等待 driver／已接受附件工作停止；舊結果不能寫到新 session |
| 來源在等待讀取期間改變 | 舊 preparing 輸入不可使用；安裝前重新取得並驗證來源，不能覆蓋新編輯 |
| preparing 後或安裝中斷 | 保留實際選定證據，重啟先 recovery，不先開 ordinary journal 或再發起新 prepare |

本次不在錯誤處自動建立 zone。首次 zone provisioning 隨後續正式啟動階段完成；所以本橋接通過不代表全新 Apple 帳號已可直接啟用同步。已驗證同帳號的日常 canonical reopen 與離線本機可用性不因這項限制退步。

所有 await 外圍與最終 publish/commit 邊界驗證 session；不跨 await 持有同步 storage lock。相同 request 合併，較新的帳號事件優先。取消等待者不是停止 native operation 的證據。

初始化不代表舊本機資料已被安全收納到帳號根目錄。本次不得自動搬移正式 local store；後續首次收納仍須證明從未綁帳號、保留完整備份，等待網路時允許原本合法的本機編輯。

## 7. 驗收與完成定義

先測實際 adapter 的 callback→租約路徑，再測橋接的真實 store/journal/owned transaction；不以測試直接設 `isComplete = true` 代替傳輸來源證據。

必測：

1. 多頁、成功空 zone、最後頁錯誤、record error、缺少 terminal callback、operation 失敗、錯 zone/account/request、重複／晚到 callback、token expired；只有完整成功可以簽發租約。
2. nil 起始 token、逐頁 token 來源、沒有一般 engine state/ACK/send/zone 建立副作用；重啟不信任上次記憶體租約。
3. 有序重複版本／刪除／重建、tombstone、未知型別、關聯不完整，以及附件所有分支的 hash/大小/身分錯誤。錯誤保留本機來源。
4. metadata／頁數／附件／原生封存預算的邊界與溢位；拒絕前後 source、pending、控制檔相同，既有封存能力沒有被新快取破壞。
5. 真實 archive、fresh absence、authenticated restored pending、owned rollback/retry；安裝成功後由實際 factory 發布，非手製 handoff。
6. 每個 await／prepare／install／commit／publish 邊界的取消及帳號切換；晚到結果拒絕且工作排空，沒有跨帳號寫入。
7. commit 後、App publish 前中止再開啟，從真實 owned handoff 恢復；已發布後的一般 initial fetch/ACK/send gate 不接受初始化租約代替。
8. 既有 canonical 日常 reopen 不新增全量讀取，使用中 retryable/quota failure 仍可本機編輯；截圖模式沒有 live factory 呼叫。

實作循序為 reader/lease、來源與安裝 bridge、lifecycle/一般傳輸交接；同一條端到端隔離測試串起三段。新增行為須有 RED→GREEN、獨立 review 及針對修正的複審。最後固定候選，再跑受影響 Core/App 測試、完整 Core、實際 App harness、未簽署 macOS/iOS 建置，記錄退出碼、警告及來源／日誌指紋。

本次完成只表示「既有帳號來源與既有 zone 的初始化橋接」可在隔離環境正確工作。正式啟動、首次 local adoption/zone provisioning、Watch 跨帳號、真實雙裝置及發布仍是顯式後續門檻。自動委任維持關閉；本規格不授權推送、合併、簽署、上傳或送審。

## 8. API 依據與規格自檢

Apple 文件指出 nil 起始 change token 用於首次／重新讀取 zone 歷史，且逐頁模式需處理後續 token 與 moreComing。這支持專用全量讀取入口，不代表跨裝置原子快照：[zone changes operation](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation)、[zone fetch result](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation/recordzonefetchresultblock)。查閱日期2026-09-09。

自檢：初始化租約與一般 durable ACK 分離；既有 zone 空結果與 zone 不存在分離；帳號根來源與未收納 legacy 分離；快取容量與核心 preparing 權威分離；正常 App 仍未啟用。沒有新增 wire、外部服務操作或清理授權。後續實作計畫須以目前實際介面綁定 callback serialization、原生來源取得與下載前封存預算檢查，不得用替身成功來跳過這三條接點。
