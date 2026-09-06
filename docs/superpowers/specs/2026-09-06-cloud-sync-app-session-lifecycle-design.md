# KnitNote 同步第 4A 階段：App 會話與帳號生命週期

日期：2026-09-06

狀態：單一會話管理器、離線重啟例外與本書面規格已由使用者確認。正在拆分實作計畫；尚未開始實作，不代表同步已啟用或實機驗收完成。

文件基準：`0f483ea4a68a425012dd230fec65e9b94229f9d3`；其中已驗證的原始碼提交為 `0860960270db87f23a1f4c238f84241599e10da1`。工作目錄 `.worktrees/cross-device-sync-design`，分支 `docs/cross-device-sync-design`，版本維持 **1.7.0 (13)**。

## 1. 目標與範圍

把已完成的本機同步、復原與帳號隔離元件接到 App 的單一生命週期，使畫面、匯入與 Watch 不會在帳號切換後繼續使用舊帳號資料庫。本階段先建立可測試的會話組裝、啟動、停止、隔離與狀態投影，不一次包辦第 4 階段全部產品功能。

上位文件：

- `docs/superpowers/specs/2026-09-02-cross-device-icloud-sync-design.md`
- `docs/superpowers/plans/2026-09-02-cross-device-sync-4-product-release.md`
- `docs/superpowers/reports/2026-09-06-server-record-conflict-verification.md`

本文件細化原第 4 階段 Task 1，並納入其不可分割的舊 UI／匯入／Watch 停用邊界。原計畫後續的完整設定頁、最近刪除及附件整理 UI、備份匯入產品流程、Watch 跨帳號協定驗收、完整本地化、真實 CloudKit、實機及發布驗收仍須另行完成；不能因本階段通過而宣稱整個跨裝置同步完成。

不修改同步 record／journal／publication 格式、合併規則、購買、語言偏好或開發故事。保持 100,000,000-byte 檔案／authority 上限、64 MiB journal metadata 上限、不可變版本、完整 FIFO、durable ACK、account epoch 與既有復原證據。文件與測試資料不是正式資料操作授權。

## 2. 已確認的方向與取捨

採用一個由 App 持有的會話管理器，統一管理當前帳號資料庫及其相依元件。不採「只替換同步引擎」：現有畫面、`PatternInboxProcessor` 與 `PhoneWatchSyncCoordinator` 都保留原 store 參照，只替換引擎不能解除舊資料入口。也不全面改寫核心資料層。

**已確認的離線例外：** App 完全結束後重新開啟，若無法確認目前 iCloud 帳號，先隱藏並禁止編輯先前帳號資料，待身分確認後恢復；不因查詢失敗刪除、搬移、上傳或改綁資料。這會暫時限制該次離線重啟的既有內容編輯。

已確認帳號、且沒有帳號失效事件的使用中會話，遇到網路中斷或容量不足仍可本機編輯，成功寫入後保留 durable journal，不能因雲端失敗而關閉本機工作階段。

上述例外是對原「離線所有編輯照常保存」的明確限縮，只適用於不能確認帳號身分的啟動／重新確認狀態；不得擴大成每次前景刷新或網路錯誤都鎖住資料。

## 3. 現有接點與必須修正的整合落差

- `KnitNote/App/KnitNoteApp.swift` 目前在 init 建立固定 `JSONProjectStore`、匯入處理器及 Watch coordinator，正常啟動即啟動 Watch；尚無正式同步 session owner。
- `KnitNote/CloudSync/CloudAccountTransitionCoordinator.swift` 已具備 seal-before-cleanup 與復原流程，透過 `CloudAccountDomainLifecycle` 要求產品端 stop/hide、freeze、install、resume；目前缺少正式 App 實作。
- 同一 coordinator 現在於首次 fetch receipt 後呼叫 `resumePublishing()`。實作時必須區分「已驗證本機可用」與「本輪雲端完整收送完成」，否則把所有 reopen 當首次初始化會再次阻斷離線使用。
- `JSONProjectStore` 的 sink、路徑及權限相依於建構時決定。不得把原 store 改指到另一帳號目錄，或對外公開任意交換 journal 的捷徑。
- 現有 Watch 與非同步匯入工作持有 store。取消 Task 或移除畫面本身，不足以證明其延遲完成結果不能再次寫入或顯示。

## 4. 元件責任

### App session owner

由 `KnitNoteApp` 在 App 層級持有一份；所有視窗共享。持有當前 session generation、身分確認狀態、當前可見的會話及非敏感狀態投影。View render 不建立 engine；重複 `.task`、視窗或 foreground event 不建立第二個帳號 session。

每個 session 包含不可改綁的帳號／本機模式、store、mutation admission、匯入工作、Watch 綁定及同步相依。切換時替換整個 session，不讓不同 generation 的元件混搭。SwiftUI 子樹、選取項目、sheet／preview 及訂閱按 session generation 隔離；換帳號不保留舊資料預覽。

### 身分查詢 adapter

明確回傳「已確認的帳號」、「已確認未登入」或「無法判定」。暫時無網路／服務失敗不得被當成登出。快取的上次帳號、非 nil 的一般可用性狀態或資料夾名稱都不能單獨證明目前帳號。

每次查詢帶 session/request generation；較舊查詢晚到不能覆蓋較新帳號事件。首次啟動必須確認身分才打開舊帳號內容。使用中會話的單次網路失敗不等於身分已失效；明確帳號變更事件則立即撤銷其權限。具體系統 API 的有效證據及測試替身，須在實作計畫中綁定，不推測離線查詢一定成功。

### Domain lifecycle adapter

實作現有 `CloudAccountDomainLifecycle`，由 session owner 協調，復用原本 account storage、bootstrap、vault、canonical hydration、remote batch/conflict durable committer。不得新增第二套帳號搬移、清理或合併權威。

### 狀態投影

分開呈現：本機資料是否可讀寫、帳號生命週期是否就緒、同步是否仍有 pending／錯誤。身分確認中顯示不含舊資料的原因及重試入口，不冒充空白資料庫，也不把 blocked 顯示為「已同步」。只有 journal 為空、本輪必要 fetch/send 完成、沒有未完成安裝或阻擋，才允許「已同步」。

## 5. 啟動與恢復資料流

| 情況 | 本機資料 | 同步行為 |
| --- | --- | --- |
| 截圖／隔離 fixture | 只開明確 fixture 路徑 | 不建構 live CloudKit、Keychain 或 Watch 依賴 |
| 有證據確認從未綁帳號的本機資料、尚未完成首次綁定 | 維持既有本機使用，不把既有帳號資料誤認為 legacy | 未登入或身分未知時不傳輸；首次綁定依既有 bootstrap 規則 |
| 已綁帳號資料、目前身分無法判定 | 隱藏且不可編輯，原檔保留 | 不開啟舊帳號工作階段，不傳輸，不啟動 cleanup |
| 確認同帳號、已完成遷移且本機證據完整 | 完成必要本機復原／驗證後可編輯 | 背景抓取與排送；尚未完成雲端收送不宣稱已同步 |
| 首次綁定或尚未完成 bootstrap | 不發布半套合併結果，保留原始資料與備份 | 依既有 bootstrap 取得必要雲端資料，驗證並原子安裝後再啟用新 session |
| 確認不同帳號或登出 | 立即隱藏並停止舊入口 | 進入原有封存、清理及隔離流程，不把舊內容匯入新帳號 |

「同帳號本機可用」必須有經驗證的帳號綁定、canonical checkpoint、journal 及必要媒體 authority，且無未解決的遷移／publication／account recovery 意圖。不是只檢查 archive 檔案存在。若新 session 有必要復原，先依其真實流程復原，不偽造成功 receipt。

首次綁定等待網路時，不得以等待 fetch 為由禁止原本可安全使用的未綁定本機資料編輯。準備期間有新編輯，安裝前必須重驗完整本機 authority 並重新準備，不能拿舊快照覆蓋新資料；只有實際安裝的必要提交區間才停止寫入。此規則不允許把已綁帳號或身分不明的舊帳號資料降級成 legacy。

確認登出後，即使另提供獨立本機使用，也不得使用、複製或改稱舊帳號的 working set。本階段不新增「把帳號資料轉為本機」或「自動匯入另一帳號」操作。帳號未明期間不得默默建立空白 store 替代舊內容或處理 inbox。

## 6. 切換與非同步工作邊界

1. 接獲權威帳號失效事件，先在同步的 UI/寫入入口邊界撤銷當前 session generation、停止接受新 mutation、移除舊資料畫面與 Watch／匯入訂閱，再進入可能 suspend 的工作。
2. 停止舊 engine，讓舊 cloud continuation 失效。既有 account epoch 是 cloud durable write 權威，App generation 不能取代它。
3. 對正在進行的本機工作建立可證明的停止／排空邊界；只取消 Task 不算完成。已開始的原子提交要有明確結果，尚未取得提交權限的舊工作不得再 commit。
4. freeze 完成後才擷取完整 recovery inventory。依既有交易先 seal、驗證持久證據，再執行原本允許的清理；失敗保留權威資料，不為了讓新帳號顯示而強制清空。
5. 原會話關閉完成後，開啟新帳號自己的路徑、journal、engine state 及 store；完成必要復原與安裝條件，才發布新 session。
6. 每個 await 回來與實際 publish/commit 邊界都驗證 generation／帳號權限；舊結果不能更新新 session 的畫面、狀態、進度或檔案。

禁止跨 await 持有同步 ownership lock；本機最終寫入及 cloud 最終 epoch/CAS 延用各自可線性排序的同步提交邊界。管理器只協調，不自行跳過 native validation 或增加無限制重試。

## 7. UI、匯入、備份及 Watch 的邊界

UI 元件不自行尋找「目前 store」後繼續舊工作；操作必須綁定來源 session。失效 store 即使仍被 closure、sheet、圖片工作或外部呼叫者持有，也必須拒絕新的 domain 寫入。付費授權仍照原規則執行，不挪用購買拒絕錯誤冒充帳號切換。

匯入／OCR／檔案選擇／備份還原等跨 await 工作，在準備與最終提交都要有 session 證據。晚到的舊操作不得重試到新帳號。無法判定歸屬的 inbox 內容保留待處理，不自動改綁；不刪除使用者原始匯入檔案。既有成功備份流程不重寫，新雲端 import transaction 的產品整合仍屬後續第 4 階段工作。

Watch 仍只連配對 iPhone。本階段必須提供可驗證的停止／解除訂閱及 session 邊界：舊指令不能寫入新 store，舊快照不能因遲到 callback 再被本機送出。已送至 Watch 的內容無法藉取消手機 Task 證明已撤回；不得宣稱 Watch 已清空。跨帳號的指令歸屬、重新握手及遠端清除／更新證據是後續 Watch 整合的啟用門檻；若現有 wire 無法證明指令屬於目前 session，先拒絕套用，不能只靠 UUID 或收到時間猜測。完成該門檻前不得開放真實跨帳號 Watch 路徑。

## 8. 錯誤、重試與安全狀態

- 網路／quota 錯誤不撤銷一個仍有效的使用中帳號 session，也不丟棄本機 pending。
- 身分未知停在可重試的遮蔽狀態，不能 timeout 後自動信任上次帳號。
- seal／復原／驗證／清理失敗停在具體 blocked 狀態；保留證據，不假裝完成，不切回可能已失效的舊 UI。
- 相同啟動／foreground／重試請求合併，禁止多套 engine 或多個互相競爭的 account transition。新帳號事件不能被舊查詢完成覆蓋。
- 跨帳號診斷只含安全分類與計數，不含 Apple ID、record name、路徑、檔名或使用者內容。
- 不新增日期驅動的自動永久清理；既有 30 天復原／刪除條件與權威證據保持不變。

## 9. 驗收矩陣

先用實際 store/journal/交易元件搭配可控制的身分與 transport 測試替身，所有磁碟內容置於測試專屬暫存根目錄。不用 production CloudKit 或真實使用者 store 證明行為。

必須具備能觀察行為及權威資料的案例：

1. 多視窗／重複啟動／foreground 只產生一份 active session；截圖模式沒有任何 live factory 呼叫。
2. 既有帳號離線冷啟動、身分查詢未知：舊資料不可見／不可寫，原始檔案與 journal 不變，無傳輸或清理。
3. 同帳號使用中斷網仍成功本機保存及排入 journal；身分已確認且本機完整的 reopen 不需等成功 fetch 才能使用本機資料。
4. 未完成 bootstrap／損壞 checkpoint／未完成復原不得假裝 local-ready；恢復後從原始 authority 繼續。
5. A→B→A、登出、查詢亂序、切換中的再次切換：不混帳號，不遺失 pending，不讓舊回呼恢復 UI。
6. UI、匯入、備份提交與 Watch 指令在切換各 await 邊界前後完成：舊操作不得更動新 store；保留原始資料與可靠提交結果。
7. freeze 之前已開始的原子寫入與 inventory capture 的順序有可觀察證據；取消並非唯一斷言。
8. seal/cleanup/install 的失敗與重啟：沒有未授權刪除，沒有半套新 session；只有真實成功證據才開放對應能力。
9. pending 非零／安裝阻擋／首次 fetch 未完成時不得顯示「已同步」；舊帳號的成功時間不沿用到新帳號。
10. Watch 停止後不再送出舊快照或套用舊指令；不能判定來源的跨帳號指令拒絕；既有去重、提醒、revision、prepared-command 測試保留。
11. 首次綁定等待 fetch 時的本機新編輯會使舊準備失效；不覆蓋新資料，不以資料夾存在或不存在猜測 legacy 身分。

每個新增行為先有可重現失敗，再做最小修正。完成實作後，先跑受影響的 Core、App no-host 與 Watch／匯入測試、獨立 review，再凍結候選執行完整 Core 及未簽署平台建置。既有 2,467/179 全套結果僅屬 0860960，不可沿用成新串接的通過證據。任何警告、未執行或環境限制如實記錄。

## 10. 啟用與後續界線

本階段的正式依賴組裝程式可被實作與隔離測試，但正常發行設定仍不自動啟用 CloudKit；測試入口只能使用明確隔離的依賴／資料目錄。一般 App-host smoke test 不能暗中啟動正式 factories。真正的開發環境啟用、Keychain、簽署安裝、iPhone／iPad／Mac／Watch 驗收另綁定候選與授權。

本階段完成定義：單一 session、冷啟動隱私例外、帳號切換的本機入口與背景工作隔離、可用性／同步狀態分離均有實際測試，且舊資料權威與 core 不變量不退步。後續完整 UI、Watch 跨帳號行為、備份、真實雲端、容量／保留成本及實機門檻仍顯式列為未完成。

未授權前不部署 production schema、不簽署或上傳候選、不送審、不 merge/push、不清理工作目錄。書面規格確認後，下一步才以目前實際介面撰寫本子階段實作計畫。
