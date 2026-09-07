# App session owner 整合設計補充

日期：2026-09-07。基準：`a5de526f697cb8b510ac50c3b9715683c30265e9`。狀態：依已核准 4A 規格完成目前程式接點檢查，本補充待書面確認；本輪未修改正式程式。

上位已核准規格：`docs/superpowers/specs/2026-09-06-cloud-sync-app-session-lifecycle-design.md`。其離線冷啟動例外、單一會話管理、帳號隔離、首次綁定保留新編輯、封存後才清理，以及真實服務啟用界線全部沿用，不重新決定產品政策。

## 已完成基礎與本次缺口

Store mutation admission、背景寫入 drain、匯入與 Watch coordinator stop、固定 producer group，以及 native PhoneWatchSession stop/drain 已完成。最近固定候選 `41ff8a2` 的 2520 Core / 50 no-host 測試與平台建置是既有基礎，不是本次新整合的通過證據。

目前 `KnitNoteApp.swift` 在 init 建立固定 store、inbox、Watch coordinator 並將 store 注入所有視窗，尚無 generation 級可替換的 session owner。`RootView` 持有選取與 sheet，並在 foreground 呼叫 inbox；單換 engine 無法隔離它們。

`CloudAccountTransitionCoordinator.transition` 在 await transport invalidation 後才呼叫 lifecycle.stopPublishingAndHide；App 必須在呼叫任何 async transition 前同步撤銷本機權限並隱藏資料，不能依賴該晚到的呼叫作为第一道遮蔽。

現有 lifecycle.resumePublishing 僅由首次 fetch receipt 觸發；不能直接把此點當成所有同帳號 reopen 的本機可用條件。截圖路徑目前雖不 start Watch，仍會建構 PhoneWatchSession；整合時要在 factory 建構之前分流，而不只跳過 start。

## 選擇與取捨

採單一 App owner，替換整個不可改綁的 session，而非只換同步引擎，也不把全 App 改成透過全域 currentStore 查詢。前者不足以撤銷現有 closure；後者可能讓舊操作落到新帳號。代價是移動 App 的依賴組裝及 root 注入位置，但 Core 資料與 wire 不重寫。

先隔離測試完整組裝，再保留正常發行的雲端停用界線。不採直接啟動真實 CloudKit 驗證 owner；正式服務、帳號證據與實機驗收仍須精確候選授權。

## 所有權與入口

`KnitNoteApp` App 層級持有唯一 observable owner，視窗只訂閱，不各建一份。每份 session 固定持有 generation、經驗證的帳號／未綁定本機模式、store、inbox、backup/reminder presentation、Watch coordinator 及 native adapter（適用時）。所有 session 元件不能原地改綁。

Owner 的可見 session 與內部正在收尾的 session 分開。接獲權威失效事件，在同一 MainActor 同步入口先移除可見 session、使 generation 失效、呼叫固定 producer group.stopForSessionTransition，再建立／驅動 async transition。已失效物件即使被舊 sheet 或 closure 保留也拒絕新寫入。

停止 group 必須包含 inbox、Watch coordinator 與 native adapter，而不是只登記 coordinator。保留舊 session 的強參照到各 producer 和 store 成功 drain，不能靠釋放 owner 或取消 Task 宣稱工作結束。錯誤／取消不得授權 inventory 或清理。

UI 以 generation 作為 session 子樹 identity，子樹內注入其固定 store 與 presentation 物件；切換重建 selection、sheet、preview、訂閱。付費授權與語言設定維持 App 層共享，不因換帳號重置。非敏感 blocked/確認中狀態在 session 子樹之外顯示，不冒充空白資料庫。

## 帳號事件與交易組裝

Owner 序列化啟動、身分查詢及切換。相同請求合併；每個查詢/安裝結果帶 request generation，較舊結果不得發布。新帳號事件先同步撤銷可見權限；進行中的舊交易仍須安全完成或回滾，再依最新事件重驗，不能同時呼叫兩個互相競爭的 transition。

實作既有 CloudAccountDomainLifecycle 的 App adapter。stop/hide 可重複；freeze 等待固定 producer/store 的真實 drain；discard 只釋放已關閉 session 的 App 參照，不自行刪除檔案。install 使用傳入的帳號 paths/journal 與既有 hydration/durable committer；resume 僅能發布仍屬當前 generation、已通過相應 readiness 的 session。

封存、restore、bootstrap、inventory、epoch/CAS 延用既有權威。App generation 只控制 App 存取及結果發布，不替代 cloud epoch，也不新增第二套清理、遷移或合併交易。

## 本機可用與同步狀態

將本機 access、帳號 transition phase、雲端 pending/error 分開投影。確認同帳號且本機 authority 驗證/必要復原完整時，可在背景 fetch 尚未成功前使用本機資料；首次綁定及未完成安裝則保持既有 bootstrap gate。不得以檔案存在、快取帳號或 fake receipt 開放本機存取。

已確認的使用中會話遭遇一般網路/quota 錯誤，保留本機編輯與 durable pending。已綁帳號的冷啟動身分未知則遮蔽且禁止編輯，不刪檔、不建空白替代庫。可證明未綁定的 legacy 在首次準備期間仍可安全編輯，安裝前依原 bootstrap 重驗完整 authority，不覆蓋新資料。

具體 identity adapter 的系統證據須在實作計畫綁定官方 API 契約與可控替身；不能從一般可用性布林值推定帳號身分。產品狀態不得洩漏 record name、Apple ID、路徑或內容。

## 交付與驗證顺序

1. 固定 session/owner 與 generation UI 根節點：實際 store、inbox、coordinator、native adapter 組裝，隔離重複啟動、多視窗與舊回呼；先用明確注入依賴，不呼叫真實 factory。
2. 接上 lifecycle 與 readiness：在既有 account transition/復原權威之上測 A→B→A、登出、亂序查詢、切換中再次切換、seal/install失敗、本機同帳號 reopen 與未完成 bootstrap。不能用假成功條件取代實際交易。
3. App 啟動與安全狀態投影：截圖/fixture 在 factory 前分流，generation 子樹控制舊畫面移除；測 foreground 不重建 engine、pending/blocked 不顯示已同步。正常發行雲端開關維持停用。

所有步驟先 RED/GREEN，使用本次自己的計畫與證據目錄；不重開已完成 producer/native stop 計畫。舊工作停止至 freeze/inventory 之間必須有可觀察時序；測試失敗與取消也要獨立 join 後才清理暫存資料。獨立審查後固定候選跑完整 Core、實際 App source no-host、未簽署 macOS/iOS 建置；UI 子樹隔離需對應測試，不只 source-string 斷言。

## 不變範圍與完成界線

維持1.7.0(13)，iOS18/macOS15/watchOS11；不改100,000,000-byte與64MiB上限、資料/wire格式、購買、語言偏好、開發故事或30天復原條件。完整設定頁、刪除/附件整理UI、Watch跨帳號wire、真實cloud/device與發布仍分開验收。

本次 owner 完成不代表 Watch 已撤回舊遠端內容。不能證明來源的跨帳號 Watch 指令不得套用；在後續協定門檻完成前不啟用真實跨帳號 Watch 路徑。

本輪只寫設計補充，不恢復已暫停自動化，不簽署、安裝、部署schema、合併、推送、上傳、送審或清理正式資料。書面確認後，以實際介面撰寫本次實作計畫；沿用既有政策，不再另起產品決策循環。
