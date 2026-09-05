# 雲端接收批次的安全提交設計

日期：2026-09-05

狀態：使用者已確認方向；本書面規格待審閱。尚未開始實作。

基準：`6db2302c7d6ade12bae71b5024c5fdc0fd022c71`，版本 **1.7.0（13）**。基準完整 Core 測試 2,311 項／170 組通過；這不是未來實作或真機的驗收結果。

## 1. 目的與邊界

完成可由正式 App 使用的「接收遠端批次 → 合併 → 本機持久提交 → 允許確認接收」核心，沿用既有 canonical checkpoint、發布交易及恢復機制。不能因雲端批次只有部分資料而清空其他本機內容，也不能因準備期間發生新編輯而覆蓋較新的版本。

本階段以隔離資料和實際 Core／CloudSync 原始碼驗證。不建立正式 CloudKit 連線、不存取正式 Keychain 或使用者資料、不啟動 App 宿主，不改設定畫面、購買、語系、版本、簽名或發布設定。帳號生命週期的正式 UI 凍結、首次移轉接線、完整遠端刪除媒體重取及真機驗收仍是後續關卡。

## 2. 已確認的現況

- `KnitNoteCloudSyncCoordinator.handleFetched` 目前先讀取部分本機 records 與 pending journal，合併後呼叫 `SyncFetchedBatchCommitting`；成功後才排程 pending 並確認批次。
- `requiredLocalRecords` 只讀取遠端涉及、被刪除及 pending 的 IDs，因此它的合併結果不是完整 canonical snapshot。
- `JSONProjectStore.activateSyncCanonicalState` 已可驗證、恢復及啟用完整同步狀態，但尚無正式遠端批次提交接線。
- `ProjectArchiveSyncMapper.materialize` 消費完整 records 與已暫存附件，會檢查資料關係；不能把部分 merge result 當作完整輸入。
- `CloudSyncAccountEpoch.withCurrent` 是帳號失效與最終同步寫入的排序邊界，不能用較早的一次帳號檢查取代。

## 3. 方案選擇

採用：在既有集中交易／恢復機制增加遠端來源的提交入口，App 層只做帳號 epoch 與 transport 介面轉接。

不採用獨立的第二套 archive writer，避免本機編輯與遠端寫入各自擁有不一致的交易規則。也不採用逐筆呼叫 UI 編輯 API，因為這會重新發行版本、產生不必要上傳，且無法保證整批資料的關係一致性。

## 4. 輸入與一致性

1. 接收輸入必須包含原始遠端 records、刪除 IDs、batch ID 與帳號 epoch，不能只交付缺乏來源的預先計算 merge result。批次身分亦須綁定已驗證內容摘要；同 ID、不同內容必須拒絕。
2. Core 準備階段使用完整已啟用 canonical 狀態、目前 archive、精確 pending FIFO、Watch 準備／處理證據及附件來源。未啟用、待修復、錯帳號或資料不符時不能開始一般提交。
3. 在完整前驅上重新合併原始批次，保留未涉及 records、墓碑、歷史附件版本、既有精確 mutations 與本機未同步修改。不能重新配置遠端已有的版本或把單純下載變成新的本機編輯。
4. 準備工作可非同步，但提交前必須核對 canonical／archive／pending／相關 Watch 與附件 authority 的前驅證據。若變動，丟棄過時候選並在新的完整狀態上重算；不能只核對畫面值或 batch ID。
5. 檢查前驅與最終寫入之間不得插入其他本機或遠端 writer。帳號 epoch 的 `withCurrent` 與既有所有權／寫入互斥共同保護最終同步提交；持鎖區間不得 await。持續競爭時有界返回可重試狀態，不能無限占用 UI 執行緒。

## 5. 附件、刪除與輸出

- 先在隔離 staging 驗證必要附件的版本、大小、摘要及檔案身分，安裝時再次驗證。保留已有的 100,000,000-byte 上限與禁止符號連結等檔案限制；交易完整編碼亦須在變更正式資料之前通過上限檢查。
- 需要的附件、父關係或刪除保留證據不足時，保留 incoming 批次並報可重試／需處理狀態，不能確認接收或默默省略資料。
- 原始 CloudKit 刪除 ID 本身不是任意刪除本機資料的授權。只處理可由既有墓碑／永久標記／legacy cleanup 契約證明的刪除；缺乏證據的情況明確阻擋。完整墓碑媒體下載及永久標記傳輸不在此階段偷偷補作或繞過。
- 只有合併規則確實要求的 mutations 才加入待上傳隊列；不清空或改寫無關 pending，不從目前顯示資料重新生成既有 immutable payload。
- 無 domain 變動的同步 metadata 提交仍可合法完成，但不能觸發多餘的畫面／Watch 發布。

## 6. 交易與重開恢復

沿用既有發布交易骨架，增加遠端批次來源與可驗證提交證據，而不是假裝它是一次本機編輯。若需要新格式，保留舊格式精確解碼及恢復規則；不重新解釋既有磁碟證據。

提交候選包含完整 archive／canonical、附件安裝依據、精確 journal 變動及接收批次證據。資料跨多個檔案，因此「整批提交」指可恢復的交易，不宣稱多檔案單次原子 rename。

- 意圖落盤前失敗：正式資料不變，不能 ACK。
- 意圖落盤後失敗：保留可驗證前驅、候選與進度，按既有恢復邊界完成或拒絕；不得猜測成功或刪除不明部分檔案。
- archive 已替換而 journal／checkpoint 未完成：阻擋一般寫入與未完成狀態的對外發布，重開後先修復，不再次發行版本。
- 完整落盤後、transport ACK 前失敗：重送同一批次辨認已提交效果，不重複加入 mutations、不覆蓋後來編輯；重新完成確認即可。
- 已提交批次證據必須有界、可持久恢復，不能只靠 coordinator 記憶體中的 set。證據回收與 durable incoming ACK／刪除順序綁定；未確認者不能為騰空間而丟棄。達上限時安全阻擋。確認後再收到等價資料仍須由合併與既有版本規則得到冪等結果。

## 7. 對外發布與介面界線

Core 返回可驗證的 committed 結果後，coordinator 才可沿用現有流程排程 pending、確認接收及更新同步狀態。排程或 ACK 失敗不回滾已落盤資料；保留恢復／重試依據。

提供提交後的單一 generation 通知契約，供後續畫面／Watch 接線消費；只有實際相關 domain 變更才發布。重開時可重新呈現已提交 snapshot，但不得因此重做計數器命令或其他 domain 效果。不宣稱跨程序通知恰好送達一次。

現有 `SyncFetchedBatchCommitting` 同時含 `commitServerRecordChanged`。本子階段不把 fetched-batch 的追加語意套用到失敗上傳隊列替換：後者必須保留完整同 record FIFO 的 compare-and-swap 契約。若尚未實作正式替換路徑，adapter 對該入口明確拒絕、保留 pending，並保持正式啟用關卡關閉；禁止用成功 stub 交差。後續正式啟用前仍須完成它。

## 8. 驗收矩陣

測試使用真正的檔案、mapper、merge engine、journal、checkpoint 與 store；transport／帳號事件以隔離替身驅動，不以來源字串斷言取代行為測試。

1. 部分批次更新後，無關作品、六個計數器、提醒、毛線連結與附件歷史完整保留。
2. 純下載不新增上傳；需要上傳的合併只產生精確必要 mutations，無關 FIFO 不變。
3. 準備期間本機編輯、Watch 命令或 pending ACK 發生變化時，拒絕過時候選／重新合併，較新資料不回退。
4. 同批次重送、ACK 失敗後重送、連續重開兩次，不重複計數、不重複排隊；相同批次 ID 不同內容拒絕。
5. 在附件、意圖、archive、journal、checkpoint、提交證據及 ACK 邊界注入失敗，確認保留資料與準確恢復；部分檔案、目錄替換、超額輸入明確拒絕。
6. 帳號在準備前、await 後與最終提交邊界失效時，不向錯帳號寫入／確認，也不對外發布舊帳號資料。
7. 缺附件、缺父關係、不明刪除與缺少保留證據時不 ACK、不丟資料；metadata-only 及無變更批次不額外通知 Watch。
8. adapter 未支援的 server-record-changed 路徑保持失敗且原 pending 不變，不能被標記為完整同步已就緒。

驗證順序：針對性 RED／GREEN → 真實 coordinator 的無宿主整合測試 → 完整 Core → 停用簽名的相關建置 → 程式審查。最後以同一程式版本記錄結果。真實程序終止、CloudKit、各裝置／延伸功能與送審另行驗收。

## 9. 完成定義

本階段完成代表遠端批次提交核心與上述隔離契約有實作、測試及審查證據；不代表完整第四階段完成。實作計畫必須列出新舊交易格式、批次證據容量／回收、前驅 CAS、adapter 及後續未實作入口的明確工作項目。使用者審閱本規格後才編寫該計畫。
