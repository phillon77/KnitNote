# KnitNote 會話撤銷後的 store 背景寫入收尾

日期：2026-09-06

狀態：依使用者「明早前你幫我決行」的授權，代行本地實作方向決策並整理本規格；尚未實作。不是同步啟用、完整 freeze、實機或發布驗收。

觀察基準：`7a1964b24e8eab1af4092a54194c9a1bb99d2558`，版本 **1.7.0 (13)**。該候選的完整 Core／平台驗證另行記錄，不以本文取代。本文撰寫期間未修改候選 Sources、Tests 或 PBX。

## 1. 範圍與上位規則

細化已確認的 `2026-09-06-cloud-sync-app-session-lifecycle-design.md` 第 6、7 節。備份收尾實作見 `2026-09-06-backup-session-drain-design.md`；本次補齊 `JSONProjectStore` 內已辨認的圖樣匯入／inbox、日誌照片及縮圖背景工作，不接 App owner、CloudKit、Keychain、Watch 或 account lifecycle 的真正 freeze。

不改資料／備份／同步 record／journal／publication 格式、購買規則、語言或開發故事；保留 100,000,000-byte 檔案／authority 與 64 MiB journal metadata 上限。所有測試只使用獨立 fixture。不得改綁 store 路徑、刪除原始匯入來源，或把舊操作移交新帳號。

## 2. 方案決策

採用一個具工作分類的 store 內部追蹤器，延伸已驗證的備份 token／等待者模型，避免每個子系統複製一套 continuation 邏輯。分類只用於精確等待及既有備份產物保護，不建立新的持久交易權威。

不採只等待現有 photo/pattern 計數器：縮圖未被涵蓋，且 photo 計數歸零之後仍有同步 reconcile。也不採只取消 Task：detached 工作與原生 rollback／cleanup 仍可能繼續。

代價：追蹤器本身的分類及喚醒行為需要新增回歸，原有備份測試必須重跑；好處是維持單一 token 身分、取消隔離與多等待者演算法。

## 3. 介面與責任

- 將內部 `BackupSessionWorkTracker` 演進為 `StoreSessionWorkTracker`。工作種類為 backup、pattern、journalPhoto、thumbnail。每個 token 仍綁定追蹤器實例，只能完成一次。
- `close()` 在 `revokeSessionWrites()` 同一 MainActor 同步邊界關閉所有新工作登記，且不可重開。
- 等待者記錄其工作種類集合；只有該集合內沒有未終結工作時才完成。取消單一等待者不修改工作或其他等待者。不得跨 await 持有同步鎖。
- `waitForBackupOperationsAfterRevocation()` 保持只等待 backup，保留既有公開 `BackupSessionDrainError.sessionStillActive` 與 cancellation 語意，不因其他背景工作而意外擴大等待。
- 新增 `waitForTrackedBackgroundWritesAfterRevocation() async throws -> Void`，等待上述四類已登記工作；未撤銷時拋出 `StoreSessionDrainError.sessionStillActive`。
- 備份保護根目錄仍只屬 backup token；其他種類不擴張 `cleanupBackupArtifact` 的刪除權限或產物所有權。
- 新等待結果不是完整 store freeze、資料健康、inventory、seal、cleanup 或新帳號可開啟的 receipt。App 外部生產者、Watch、engine、UI generation、建構期 recovery 與真實 authority 驗證仍是獨立門檻。

## 4. 原生工作邊界

### 圖樣匯入與 inbox

追蹤直接 `importPattern` 及 `withActivePatternTransaction` 的真正非同步生命週期，涵蓋 enqueue、reconcile、prepare、publish 和既有 catch／defer 清理。wrapper 不得先宣告終結再啟動下一段 native 工作。

入口在第一次可產生背景副作用的工作前驗證會話；每個 await 回來，開始下一段 prepare／recovery／publication 前重新驗證。撤銷後 `pendingPatternInboxItems` 不再啟動 recovery，也不回傳晚到的舊資料。它不是純讀取：現有 reconcile 會修復及清理收據。

已接受的原生 enqueue／recovery／discard 子交易必須真正結束才解除登記，保留其真實錯誤與證據。已完成的 discard 不因事後撤銷而假裝未完成；尚未取得後續 publication 權限的舊匯入不得繼續提交。未發布的 inbox 原件與證據保留在原歸屬，不改綁。

### 日誌照片

`addJournalEntry` 從開始處理照片前到 detached save、publication 或原生 catch delete，以及最後的 `reconcileJournalPhotos` 全部完成後才終結。沿用 child cancellation forwarding，但不得將 cancel 視為完成。成功產物晚到時仍須先驗證會話，不能發生新的 domain publication；原生錯誤／回收規則不改寫。

### 縮圖與封面

`cacheYouTubeThumbnail`、`patternThumbnailURL`、`patternPDFPageThumbnailURL`、`projectCoverURL` 的生成分支都屬實際快取生產者。撤銷後不開始新的生成工作；已接受工作涵蓋 stage、render、publish／discard 的真實終結。

YouTube stage 後撤銷時，不再發布新快取；只在原本已接受工作內按既有服務規則處理自有 stage。PDF／圖片原生生成可能在撤銷後才結束，等待必須涵蓋它；完成後不回傳舊會話的 URL。既有版本、頁數與 cancellation 驗證繼續成立。不得為達成等待而新增刪除使用者來源或強制快取清空。

`yarnLabelPhotoStorageBytes` 的服務實作只有列舉／讀取，不納入背景寫入集合；其舊 UI 回覆仍由後續 session generation 隔離處理。同步 URL getter 的 UI 隱私隔離也不由這個工作追蹤器冒充完成。

## 5. 檔案責任

- `Sources/KnitNoteCore/Projects/StoreSessionWorkTracker.swift`：分類工作、單次完成及獨立等待者；搬移既有備份追蹤能力，不保留重複演算法。
- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`：入口、各原生生命週期、晚到結果與公開等待介面。
- `Tests/KnitNoteCoreTests/StoreSessionWorkTrackerTests.swift`：分類等待、取消、跨實例及廣播；保留原備份追蹤回歸的實質斷言。
- 現有 store／匯入／照片／縮圖測試及新 session 測試：使用現有服務 hook、暫存來源與磁碟證據；不以 sleep 或任意 yield 證明時序。
- `KnitNote.xcodeproj/project.pbxproj`：依原 source membership 更新 App／Watch 參照；不改版號／簽署／entitlement。

## 6. 必要驗收

1. 備份等待在 backup 結束後可完成，即使 pattern 等其他類仍在執行；全分類等待必須繼續。最後工作結束後所有符合條件的等待者完成。
2. 類別隔離、重複／外來 token、取消前後、兩個已登記等待者及多類交錯均有實際斷言與定向 mutation RED。
3. 每個生產者在可控制 native 邊界阻擋，撤銷後不接新工作；原生工作未終結前等待不完成。取消呼叫端不是唯一證據。
4. 圖樣在 enqueue／reconcile／prepare 之後撤銷不開始未授權的後續階段；來源、inbox 與 recovery 證據遵守原歸屬及 native 結果。
5. 日誌最後一次 reconcile 仍在追蹤內；保留原生照片處理錯誤與 catch 清理結果。
6. 每種縮圖生成晚到時不回傳舊 URL、不發布撤銷後的新 YouTube 快取；等待涵蓋實際渲染及既有原生清理，版本檢查不退步。
7. A／B 獨立 fixture 比較完整磁碟證據，A 的撤銷、晚到工作與等待不能修改 B。
8. 原備份、匯入、照片、縮圖、publication、刪除、Watch 回歸保持有效；獨立審查後固定候選跑完整 Core 與未簽署平台建置。局部通過不當作整版驗收。

## 7. 明確未完成的發布門檻

本工作不啟用正式 CloudKit、Keychain、Watch 或 App factory，不產生跨帳號啟用、簽署、安裝、真實資料遷移或清理的授權。推送／上傳／送審仍須以實際整合完成、精確候選、平台及實機／商店證據判定；使用者的夜間交辦不代表這些證據已存在。
