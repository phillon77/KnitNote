# 同步 4A.2：備份工作撤銷與停止邊界

日期：2026-09-06

狀態：使用者已確認本書面規格；實作計畫已建立，尚未實作。計畫：`docs/superpowers/plans/2026-09-06-backup-session-drain.md`。

基準：`74c850237d7ea7f84846c3f7229d785e9925e313`；工作樹 `.worktrees/cross-device-sync-design`，分支 `docs/cross-device-sync-design`，版本 **1.7.0 (13)**。

上位規格：`docs/superpowers/specs/2026-09-06-cloud-sync-app-session-lifecycle-design.md` 第 6、7 節。前置工作：`2026-09-06-cloud-sync-session-write-admission.md`；測試排程修正證據：`docs/superpowers/reports/2026-09-06-backup-handshake-verification.md`。

## 1. 目標與非目標

讓單一 store 的備份工作在會話撤銷後不再接受新工作，並能等待已接受的工作真正結束。撤銷後不把舊工作、結果或檔案改綁新 store。這只是備份子系統的停止邊界，不是完整 store freeze、account epoch、資料可安全清理或新帳號可開啟的證明。

不啟用真實帳號切換、CloudKit、Keychain、Watch 或正式 App factories。不改備份格式、原有成功還原語意、同步 journal／publication 格式、購買政策或語言。保留 100,000,000-byte 檔案／authority 與 64 MiB journal metadata 上限。無簽署、安裝、資料遷移、實際使用者清理、merge、push、上傳或送審授權。

## 2. 已核對的實際流程

- `JSONProjectStore.exportBackup`：同步取得資料操作入口，等待 detached `createPackage`，最後解除資料操作狀態。
- `prepareBackupRestore`：取得來源 security scope，等待 detached `stagePackage`，再釋放 scope；目前未經會話撤銷入口。
- `restoreBackup`：入口檢查後等待 detached `install`，同步 reload；reload 失敗時等待 detached `rollback` 並重讀原資料；成功時等待 detached `commit`，再做縮圖清理及通知。
- `KnitNoteBackupService.install`／`rollback` 有既有 replacement journal 與復原流程，不能以新計數器或 Task cancellation 取代。
- `commit` 不拋錯，清理失敗可能留下 journal／rollback／cleanup 檔案；方法返回不是所有持久證據已清除的證明。
- `cancelBackupRestore`／`cleanupBackupArtifact` 會刪除經現有路徑規則驗證的自有暫存備份；晚到呼叫也必須受停止邊界限制。
- `reloadFromDiskDuringDataOperation` 不是純讀取，還包含 migration／recovery／媒體整理。還原工作必須涵蓋這些後續工作才算結束。

## 3. 選定方案與替代方案

採用 **store 私有、逐工作登記、單向關閉的備份工作追蹤器**。它只追蹤備份子系統，使用原 store 的不可改綁相依與原有交易。MainActor 負責接納、撤銷與工作終結的排序；等待以可取消的非阻塞等待器實作，不跨 await 持有同步鎖。

未採用的方案：只取消 Task 無法證明 detached 寫入已結束；把備份全部改成可中斷交易則會擴大至已有的持久復原機制。此階段不重寫後者。

## 4. 接納、撤銷與工作歸屬

1. 匯出、準備還原與執行還原都在第一個相關副作用前檢查原 store 的會話寫入權限，並同步登記工作；兩步之間不得 suspend。prepare 的 security scope 也在成功接納後取得。
2. 現有 `revokeSessionWrites()` 同步關閉備份接納，不新增重開權限的 API。撤銷後的新 throwing 工作回傳既有 `StoreSessionAccessError.revoked`，不冒充購買拒絕。
3. 工作在接納時取得僅屬於該 store 的一次性內部登記。登記持續到 detached 工作、必要 reload／rollback／commit 與其同步收尾完成，不因呼叫者取消或畫面移除而提早解除。
4. 已接納且已派送的工作可以依原有交易完成於舊 store；不在 install 與 rollback 中間插入任意撤銷錯誤，把可靠回復變成半套交易。撤銷阻止新工作，不追溯撤回已開始的原子步驟。
5. 若撤銷時正在產生匯出或 staged 還原結果，先等待工作終結，再阻止結果以可用成果回傳給已失效會話。保存自有產物與來源檔案，對呼叫者回傳 revoked；不得為掩蓋晚到結果而自行刪除檔案。原始服務失敗仍保留原始錯誤。
6. 已接納的還原回傳其真實成功／原資料保留／rollbackFailed 結果，不因晚到撤銷捏造回復成功。這個結果仍屬舊 store，不得使新會話或已隱藏的 UI 恢復。正式 UI 的 generation 過濾仍是後續 App 工作。
7. 對外的非 throwing `cancelBackupRestore`／`cleanupBackupArtifact` 在撤銷後無副作用返回。撤銷前仍執行原本的自有路徑驗證，不能刪除正在使用的 staged／export 產物；執行中的產物使用／清理衝突須由工作登記中的 ownership 檢查拒絕。已接納交易內的必要原生清理屬同一工作，不被誤當作新的使用者清理請求。

## 5. 停止結果不等於可切換權限

備份停止等待的前置條件是此 store 已撤銷；未撤銷時拒絕該等待請求，避免返回後又接受新工作。

- 已撤銷、無進行中工作：可以返回「備份工作已結束」。
- 已撤銷、仍有工作：只在最後一個已接納工作真正終結後通知所有仍等待的呼叫者。
- 等待者取消：該等待者以取消結束；不移除工作、不重新開啟接納、不向其他等待者偽造成功。
- 工作永遠不返回：停止仍未完成；上層時限只能回報阻擋，不能製造停止成功。測試另有外層程序時限。
- 工作失敗：登記在實際收尾後終結，但保留原始錯誤及持久復原證據。不得把 active count 為零等同資料健康。

不暴露名為完整 `waitForDrain` 或可用來授權 inventory／seal／cleanup 的通用 receipt。備份專屬停止結果最多證明本節追蹤的備份工作不再執行。上層 lifecycle 仍須等待其他寫入來源，並使用既有原生 authority 驗證 replacement journal、canonical、publication 與必要媒體狀態。

尤其 `commit` 吞下清理錯誤的情況，不改原本成功還原 API 的結果；保留證據，由後續原生 recovery／validation 判定是否可繼續。此階段不為取得「乾淨」結果而呼叫會改檔的 recovery 或刪除 rollback。

## 6. 範圍與檔案責任

預計在 `Sources/KnitNoteCore/Backup/` 放置私有或 module-internal 的備份工作追蹤元件；`JSONProjectStore.swift` 負責入口、結果與工作壽命串接。精確型別與方法在實作計畫中綁定，不公開任意建立成功證據的 constructor。

`KnitNoteBackupService` 的 install／rollback／commit 順序與格式保留；需要的測試替身優先使用現有 replacement hooks 與暫存 fixture，不加入正式服務的測試專用開關。

`JSONProjectStoreTests.swift` 中既有備份互斥／回復測試及新備份 session 測試驗證整合；小型追蹤器另外驗證多等待者、取消、一次性終結及接納／撤銷排序。若 Xcode 明列新增檔案，只補必要 target membership，不執行全專案生成重寫。

仍不涵蓋獨立啟動的 inbox／圖片／縮圖／Watch 寫入與 constructor-time recovery。還原工作所同步呼叫的 reload 與收尾屬本工作，但不能據此宣稱其他獨立來源也已停止。

## 7. 驗收矩陣

所有磁碟資料使用測試專屬暫存目錄；以事件同步觀察時序，不以排程延遲猜測工作完成。

1. 撤銷前保持正常匯出、prepare 與還原結果；原有購買與 operationInProgress 規則不退步。
2. 撤銷後三個入口皆拒絕，無 service 呼叫、security scope 取得、檔案寫入或交易證據變更；外部 cleanup 無副作用。
3. 在 createPackage／stagePackage hook 阻擋時撤銷：停止等待不提早完成；解除後終結，晚到產物不發布、不刪來源，產物仍留在原 workRoot。
4. 在 install 的 live move 前後及 staged move 後撤銷：停止等待涵蓋實際安裝、reload 及 commit，原始 store 的最終資料符合原生交易結果。
5. reload 失敗：停止等待涵蓋 rollback 及重讀；原資料完整恢復才回報相應結果。
6. rollback 失敗、commit 部分清理失敗：保留真實錯誤／journal／rollback 或 cleanup 證據；不得把工作終結當作 lifecycle-ready，也不得開始封存／清理。
7. 取消呼叫者或一個停止等待者不能讓尚在執行的工作消失；其他等待者仍等到真正終結；無等待者洩漏、重複通知或重開接納。
8. 多個 prepare 工作均被追蹤；完成第一個不能提前放行。外部產物清理不能與正在使用該產物的工作競爭。
9. A、B 兩個獨立 store：A 撤銷不關閉 B；A 的晚到工作不改 B 的 archive、journal、媒體或備份目錄。
10. 以 mutation RED 證明移除入口／提早終結追蹤會使測試失敗；延後啟動仍保留已修正的非阻塞測試握手及外層時限。

先 RED／GREEN 與受影響並行 Core／備份／同步／Watch 回歸，再獨立審查；凍結新候選後執行完整 Core 及 macOS／iOS 未簽署建置。819 項並行通過只屬 `74c8502` 的測試變更，不能作為本功能的驗證。

## 8. 完成與交接

完成只表示備份子系統的接納關閉、工作終結等待與失敗證據保留已驗證；沒有完整 freeze 或真實帳號切換的啟用權限。下一個子系統仍須補齊自己的非同步寫入邊界，之後才組裝單一 App session owner。

書面規格確認後，以目前實際介面撰寫獨立實作計畫。不得將本文件提交描述成程式或驗收通過。
