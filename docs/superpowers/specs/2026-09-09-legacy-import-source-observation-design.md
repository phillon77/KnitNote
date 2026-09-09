# 舊資料匯入：真實來源觀察與備份比對

日期：2026-09-09。版本 1.7.0 (13)。基準 `0f5a6a4a984fa17a0405860f2374df3e5e1d1ae6`，branch `docs/cross-device-sync-design`。

狀態：使用者確認本規格後委任執行；三項隔離實作、個別審查、整體審查與最後修正複審已完成。2026-09-10 對原始碼候選 cdd7a5e 由主代理重新驗證，165 個相關測試／9 個套件通過。沒有正式資料、安裝、CloudKit、推送或送審操作；證據見 ../reports/2026-09-09-legacy-import-source-observation-verification.md。

## 1. 交付範圍

將前一切片由測試直接提供的 sourceDigest／backupDigest，改由對實際測試檔案的受限讀取與備份比對產生。輸出證明特定觀察時的內容相符，不證明歷史帳號歸屬、不簽發資料讀寫或安裝權限。

本切片新增原生唯讀 inventory／比對與一次準備的協調邊界；備份副本只寫入明確擁有的隔離工作目錄。正常 App、Watch、CloudKit、Keychain、正式來源資格 issuer、持久 receipt、匯入安裝與 crash recovery 不在本切片接線。

上位規格 `2026-09-09-legacy-local-import-safety-design.md` 繼續約束來源可讀資格、帳號隔離、Watch 保留及提交。現有 `LegacyLocalImportConsentModel` 不重寫，其 Bool 結果仍不得授予安裝權限。

選擇重用備份服務的原生讀取／列舉契約，不另建一套隨意掃描目錄的匯出器；也不直接把 `SyncBootstrapSourceAccess` 的 account-scoped ownership 擴充成接受任意 legacy URL。前者減少格式及附件漏項風險，後者保留既有帳號來源權威。

## 2. 已核對的程式事實

- `KnitNoteBackupService.createPackage` 讀取 archive、列舉參照檔案、做容量預檢、分塊複製並產生逐檔 manifest，最後呼叫 inspectPackage。
- `inspectPackage` 回傳 preview；preview 的項目數量不是來源指紋。`StagedKnitNoteBackup` 也不是帳號資格。
- `KnitNoteBackupManifest` 現行 format 2，逐檔含 relativePath、byteCount、SHA256，含 createdAt 等非內容欄位。
- 同檔內 `KnitNoteBackupLimits`：manifest 1,000,000 bytes、archive 20,000,000、markup 2,000,000、一般 file 200,000,000、package 4,000,000,000。
- `JSONProjectStore.exportBackup` 開始與結束檢查 write access，透過 beginDataOperation 協調既有操作。這不證明所有跨程序寫入已凍結；不能由該旗標推導全域 snapshot isolation。
- `SyncBootstrapSourceAccess` 要求 native account ownership 且註明 producer freeze 由 caller 負責，不能拿它替代 legacy 來源資格。

這些是設計接點，不是新功能已通過的證據。

## 3. 觀察資料與比對

新增 internal、不可序列化的來源觀察結果，僅由本切片的原生讀取器建立；測試可注入讀取故障，但正式輸出不接受 caller 提供的摘要直接冒充實際讀取結果。

來源觀察包含根目錄的實際 device/inode 身分、archive 與完整參照附件集合的安全相對路徑、各檔 byteCount／SHA256／device/inode，以及當次來源會話與 preparation identity。根與子路徑驗證遵守既有安全檔案規則；拒絕 symlink、非一般檔案、越界／別名碰撞及讀取中替換，不以 standardized path 字串比較代替原生檔案驗證。

內容摘要採固定版本標籤與無歧義編碼：逐檔以 UTF-8 路徑 bytes 排序，長度前綴編碼路徑、固定寬度 byteCount 與 32-byte SHA256。必須有 archive entry，重複路徑或不合法摘要拒絕，不依檔案列舉順序或 Swift Hasher 產生跨觀察摘要。

備份內容摘要使用相同的內容投影，排除 package 路徑、createdAt、App 顯示版本及裝置 inode。來源實體身分另行比較，不混入備份內容摘要，因副本必然有不同 inode。備份 manifest 的宣告值須以實際備份內容重新驗證後才納入投影；不能只 hash manifest 就宣稱附件正確。

`sourceDigest` 代表來源內容投影；來源根／檔案 identity 由準備證據另持有並在重驗比較；`backupDigest` 代表經驗證的備份內容投影。二者內容相符才能提供這次確認的觀察值。不得把 portable backup 未涵蓋的 journal／Watch／復原證據當成已驗證或可清除。

## 4. 準備流程與失效

1. 在受控制的來源會話與工作目錄下，取得來源觀察 S0；來源目前可讀資格必須由未來合法會話整合提供，本切片不根據 URL 或缺 marker 判斷歷史資格。
2. 重用現有備份流程產生本次副本；不得先永久 revoke 來源會話再呼叫 exportBackup。
3. 驗證副本 B 的完整內容，重新取得來源觀察 S1；要求 S0、S1 的內容、集合與實體身分相符，B 與 S1 的內容投影一致。
4. 檢查原會話、目的帳號觀察與 preparation 仍是同一嘗試，才建立供確認的準備結果；帳號無法確認時不建立可確認結果。
5. 每個 await 之後重驗對應會話／嘗試；呈現與消費確認前另重新讀取來源及備份，與保留的準備觀察比較。舊嘗試晚到不能取消、覆寫或刪除新嘗試資料；重複請求由單一 owner 序列化。
6. 觀察到或收到通知的來源／附件／帳號／會話變更，或比對、讀取、容量驗證失敗，使本次結果與確認失效。保留來源，不自動改綁或繞過錯誤重試。

S0/S1/B 相符是樂觀觀察，不是不可變來源或全域原子快照的證明。兩次讀取間的 ABA 或未受控跨程序寫入，不能靠「兩個 hash 相同」宣稱不存在。結果不得直接進入安裝；未來原生提交仍須證明所有相關 producer 的停止邊界，在該邊界內完整重驗。這個限制必須出現在型別註解與驗證報告，不只藏在文件。

為避免新增一個無效的權威入口，本切片只在隔離測試中把實際來源觀察轉成既有確認模型輸入；正常 App 的呼叫數必須保持零。不能把測試的會話標記當作 production 來源認證。

## 5. 容量、保留與取消

沿用既有 backup 限制，不改 portable backup 的使用者相容行為。本同步準備入口額外遵守既定 100,000,000-byte 檔案／authority 界線：單檔採既有 backup 該類限制與同步限制的較小值；超出即拒絕同步準備，不宣稱備份本身損毀。manifest 1,000,000、archive 20,000,000、markup 2,000,000 的較嚴限制照舊。

package 的既有 4,000,000,000-byte 總量上限不是可一次載入記憶體的預算。逐檔串流雜湊／複製、使用有溢位檢查的累加，inventory 及其編碼亦受明確上限約束（本入口內容投影預算 1,000,000 bytes，不接受無限制檔案陣列；達此預算即停止新增 entry）。不把 SyncRegularFileReader 全檔 Data 結果全部留在記憶體形成總包大小配置。

實作審查補充：原生備份 preflight 逐筆列舉，檔案 inventory 沿用上述投影預算；目錄 inventory 另以 4,000,000 bytes 限制，每筆收取 48 + UTF-8 路徑長度。最大 Data 相對目錄深度 4（現行最深合法形狀 Patterns/<project>/Markup/<pattern>），開啟子目錄前檢查。package 根只接受兩個 schema 項目。這些限制不套用一般 portable backup，未來 schema 增深需同步更新此契約。

取消只撤銷本次結果；等待已開始的受管工作結束後才能回報排空。既有 createPackage 的失敗清理只處理自己尚未完成的 package，不能移用來刪除原資料、成功備份或已被未完成交易引用的證據。若取消發生在備份成功後，保留成功副本並回傳安全的待處理狀態；本切片不新增自動清理期限或清理既有工作目錄。

## 6. 必要測試

使用真實檔案及原生備份／reader，根目錄全部由測試建立，帳號與會話事件可控制；不讀正式使用者資料。

| 案例 | 必須觀察 |
| --- | --- |
| archive 加完整參照照片、標籤、日誌、PDF、markup | S0/S1/B 相符，逐檔實際 bytes/hash 可核對，來源未被寫入 |
| 備份時間、輸出根不同但內容相同 | 內容摘要相同；不同來源 inode 仍使來源身分重驗失敗 |
| 相同大小／mtime 的內容修改 | 摘要變動，舊確認失效 |
| 缺檔、symlink、hardlink／非一般檔、路徑別名或替換 | 按原生安全規則拒絕；不補空檔、不授予結果 |
| 備份檔被改、manifest 宣告不符、未知格式 | 比對拒絕；不能只憑 preview 數量成功 |
| archive、markup、一般檔、manifest／總量邊界 | 恰等上限依原規則驗證，超限在複製或配置超預算前拒絕；較大正常 portable backup 不被誤稱損毀 |
| S0後、複製中、S1前後來源修改 | 已觀察到的內容／身分變化失效，沒有正式安裝；不宣稱所有 ABA 已被排除 |
| 取消、會話失效、A→B→A、舊結果晚到 | 舊結果無法呈現或確認，新結果與副本不受舊 callback 改動 |
| 備份成功後取消、重新開啟測試協調器 | 保留成功副本、不復活記憶體確認、不假裝已有持久 recovery |
| 來源帶同步／Watch控制檔 | portable 比對不簽發其保留／搬移能力，不清理、不改綁；未證明的完整匯入仍被阻擋 |

TDD 先跑實際缺口 RED，再做最小改動、相關 backup／reader／consent 回歸與審查。這些測試通過不等於完整來源認證、原子安裝、突然終止復原或實機同步完成。

## 7. 完成與交接

完成此切片的條件：實際檔案觀察、備份內容一致性、受限讀取與會話失效具體可測；沒有改動正常 App 或擴張原生帳號能力。下一步才是精確持久匯入交易／最終 producer freeze 與原生安裝契約，需另行設計與確認。

本規格整份確認後，以 writing-plans 將原生 inventory seam、備份比對與隔離協調器拆成實作任務。正式來源資格、Watch wire、zone provisioning、啟用與發布門檻保持未完成；不重新執行已完成的純確認模型計畫。
