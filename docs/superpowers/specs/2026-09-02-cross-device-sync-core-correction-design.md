# KnitNote 跨裝置同步核心矯正設計

日期：2026-09-02

狀態：設計已確認，待書面規格審閱

基準提交：`af0b38356585c381d9bb2a57e36909d55f4ba3e3`

上位規格：`docs/superpowers/specs/2026-09-02-cross-device-icloud-sync-design.md`

## 目標與範圍

在進入 CloudKit 傳輸層前，關閉第一階段複審留下的五個資料正確性、安全性與擴展性缺陷：附件不可變版本身分、計數器／提醒原子合併、因果修訂與裝置身分、安全檔案讀取，以及非二次方成長的 journal／附件發布路徑。

本矯正保留既有本機 archive、`JSONProjectStore`、同步 record schema 的其他已驗證部分，以及 WatchConnectivity 邊界。它不加入 CloudKit、帳號生命週期、衝突 UI、遠端安裝、最近刪除清理或完整備份還原發布；那些仍屬後續計畫。

## 不變條件

- 支援 iOS 18.0、macOS 15.0 與 watchOS 11.0；`CloudSync` 核心不得 import CloudKit。
- 本機 archive 成功提交後才可發布同步 mutation；不確定寫入不得被當作可發布成功。
- 使用者建立或匯入的文字與附件位元組保持原樣；不翻譯、不建立空白替代檔。
- 解除「使用毛線」只刪除 link，永遠不刪除 `Yarn`。
- Apple Watch 不直接接觸 CloudKit；計數器與提醒合併後仍必須遵守現有 revision、prepared command、occurrence 與 processed ledger 規則。
- 相同 mutation stamp 對應不同 payload 是損毀，不得任意選擇其中一方。
- 本規格完成及整體審查通過前，不得開始 CloudKit 第二階段。

## 方案

採取「保留核心、替換五個不可靠邊界」的方案。這比在現有分支上逐點打補丁更能建立一致的不變量，又避免全面重寫同步核心及既有測試。

### 1. 持久化裝置身分與因果修訂

新增 CloudKit-independent 的 `SyncInstallationIdentityStore`。首次建立時以系統安全隨機來源產生 128-bit UUID，原子保存於 Application Support 的同步 metadata 目錄；之後同一 app 安裝與同一 account working set 的所有 store factory 分支都讀取相同值。不得從 store URL、主機名稱、裝置名稱、檔案內容或牆鐘推導 device ID。

新增持久化 `SyncRevisionLedger`，以 `SyncEntityID` 保存下一個可發出的 logical revision。每次本機成功 mutation 的發布交易先配置嚴格遞增 revision，再把配置結果與 publication marker 一起持久化。重啟、寫入不確定及重試必須重用同一 mutation 已配置的 revision；新 mutation 才配置更大的值。遠端看見更高 revision 後，本機下一次配置至少是 `remoteRevision + 1`。

revision ledger 的 durable write 與 publication marker 必須具有可恢復的順序：任何 crash point 都只能得到「未配置」或「已配置且可重播」兩種狀態，不能重複配置較小 revision。牆鐘只保留顯示及次要排序用途；device ID 只作確定性最終 tie-break。

### 2. 附件 slot 與不可變版本分離

附件模型明確分成：

- `slotID`：穩定表示 owner 之下的一個語意位置，例如某一張標籤照片或某一頁 markup。不同合法照片／頁面必須有不同 slot。
- `versionID`：每次建立或替換時配置的新 UUID。即使新內容 hash 與歷史版本相同，也不得重用 version ID。
- `contentHash`：只驗證 bytes，不作實體身分。
- `replacesVersionID`：指向同一 slot 的直接前一版本；建立後不可修改。
- `conflictGroupID`：以 slot 為範圍識別並行分支，不跨合法 slot 聚合。

每一個 version snapshot 的身分、lineage、timestamp、media metadata 與 staged bytes 都不可變。A→B→A 會產生三個 version IDs；第三版可具有與第一版相同的 content hash，但 lineage 不同。journal acknowledgement 前不得刪除其 staged bytes。

合併時先依 slot 分組，再驗證 version ID 的 immutable snapshot 是否完全一致。相同 version ID 出現不同 lineage 或 metadata 必須隔離為 corruption。並行版本全部保留，active version 只依 causal stamp 確定性選取；不得把兩個不同 slot 誤報為衝突。

### 3. 計數器與提醒原子狀態

建立明確的 `SyncCounterReminderState`，將 counter value、counter revision、active reminder、prepared command、occurrence、processed command ledger 及它們的共同 mutation stamp 視為單一不可拆分值。它不得走一般 scalar field-by-field merge。

合併規則：

1. 完全相同 atomic state 與 stamp 可去重。
2. stamp 不同時先驗證兩方 domain invariants，再選 causal stamp 較新者；較舊 processed ledger 必須以 exactly-once 安全方式併入，不能重新執行 command。
3. stamp 完全相同但 atomic state 不同時回傳 corruption，結果不得因 local／remote 輸入順序改變。
4. stale counter revision、重播 command、prepared command 與 occurrence 不一致、ledger 倒退或 counter 倒退都必須被 validator 拒絕或隔離。
5. `.stopReminder` 明確回傳 `.persisted(updatedState)` 或 `.noOp(existingState)`；成功寫入 ledger 後不得無條件 throw。

測試使用現有 Watch domain fixtures 驗證 prepared→apply→ledger、stop、重播、stale revision、occurrence precedence，以及 local／remote 全排列結果。

### 4. 不阻塞且防替換的檔案讀取

所有 journal envelope、staged attachment、publication sidecar 與 archive attachment 讀取統一經過 `SyncRegularFileReader`。流程必須是：

1. 對路徑執行 `lstat`，先拒絕 symlink 與非 regular file。
2. 以 nonblocking、no-follow 選項開啟 descriptor。
3. 以 `fstat` 驗證已開啟 descriptor 仍是同一個 regular file，並在讀取前檢查 byte cap。
4. 由 descriptor 執行 bounded read，拒絕短讀以外的大小變動與超限成長。
5. 讀取結束再確認必要的 descriptor metadata；錯誤時關閉 descriptor 並回傳 typed corruption／unsafe-file error。

在 Apple 平台無法提供某個 flag 時，實作必須以 `lstat`／`open`／`fstat` identity 比對補足，而不是退回 `Data(contentsOf:)`。FIFO、socket、device、symlink、oversize、開啟前後替換及讀取中成長都必須快速失敗。測試需有 bounded timeout，證明重新啟動不會被 FIFO 卡住。

### 5. Journal checkpoint 與附件增量 manifest

Journal 改為 append-only segments 加原子 checkpoint：

- enqueue 將 versioned operation frame 追加到 active segment，frame 包含長度、schema、mutation ID 與 checksum；batch enqueue 只做一次同步邊界。
- acknowledgement 追加 ack frame，不重寫其後所有 pending mutations。
- 達到明確門檻時建立 compact checkpoint，原子取代已確認 segment；中斷後可由最後有效 frame 或 checkpoint 重播。
- 重複 mutation ID 只有 immutable intent 完全相同才接受；不同 intent 是 corruption。
- 讀取成本與 journal bytes 成線性，連續單筆確認不得造成每次重寫完整 suffix。

附件發布新增持久化 manifest，以 normalized file identity、byte count、modification metadata 與已驗證 content hash 記錄投影。沒有檔案變更的 archive persist 不重新雜湊全部附件；新增、替換、刪除或 metadata 不可信時只重算受影響項目。manifest 不可取代實際 bytes 驗證：任何 identity 不一致或準備發布新 immutable version 時都重新讀取並雜湊。

效能驗收採 operation-count instrumentation，不以脆弱的單一牆鐘秒數作唯一判準：

- 2,000 次連續 enqueue／ack 不得出現 2,000 次完整 journal suffix 重寫。
- 含至少 500 個真實小型附件的 archive 在零附件變更的第二次 persist 中，不得重新開啟或雜湊全部 500 個附件。
- 單一附件替換只重新雜湊該版本及維護所需的固定數量 metadata。
- crash recovery、partial frame、checksum failure 及 checkpoint 取代中斷均不得遺失未確認 mutation。

## 元件與檔案邊界

- `SyncInstallationIdentity.swift`：安裝 device ID 的產生、驗證與持久化。
- `SyncRevisionLedger.swift`：entity logical revision 配置與重播收據。
- `SyncRecord.swift`：附件 slot/version/lineage immutable schema。
- `SyncMergeEngine.swift`：attachment slot grouping、equal-stamp corruption 與 atomic counter/reminder merge。
- `SyncRegularFileReader.swift`：唯一安全 bounded descriptor-read 實作。
- `SyncMutationJournal.swift`：segment、frame、ack、checkpoint 與 recovery。
- `SyncAttachmentManifest.swift`：附件投影 cache、失效與增量 hash 決策。
- `JSONProjectStore.swift`：以小型 adapter 串接上述元件；不在此檔重複實作檔案安全或 revision 邏輯。

若現有 `JSONProjectStore.swift` 的同步發布區塊過大，實作計畫應把純同步投影與 publication transaction 搬到專用檔案；不得做與同步無關的 store 重構。

## 遷移與相容性

目前尚未發布 CloudKit schema，因此新 attachment version identity、revision ledger 與 segmented journal 不需要遠端 migration。對本分支早期 phase-1 journal：

- 空 journal 可直接建立新格式。
- 有 pending mutations 的舊 envelope 必須完整解碼、驗證 immutable snapshots 與 staged bytes，再一次性轉換成新 segment/checkpoint。
- 無法證明 attachment version identity 或 revision 因果性的 pending mutation 必須進入明確阻斷狀態，保留原 bytes 供診斷；不得猜測 lineage、清空 journal 或重新發布成較新的 mutation。

既有 archive schema 14 保持可讀。新增同步 metadata 保存於獨立目錄，不改使用者資料 UUID、文字或附件內容。

## 錯誤處理與可觀察性

錯誤分類至少包含：installation identity corrupt、revision receipt corrupt、equal-stamp divergent state、immutable attachment identity mismatch、unsafe file type、file replaced during read、oversize input、journal frame corrupt、checkpoint corrupt、manifest identity mismatch。

所有這些錯誤都 fail closed：阻止該批同步發布或安裝，但不阻止本機使用者資料讀取。若本機 mutation 已提交但同步 metadata 無法持久化，保留 publication marker 與明確 `pendingRepair` 狀態；重啟後先修復，不能靜默跳過。

診斷不得包含使用者附件內容、筆記全文或安全憑證。可記錄 entity kind、匿名化 ID、錯誤分類、byte count 與 schema version。

## 驗證關卡

每個元件先以聚焦 RED/GREEN 測試實作，再執行相鄰回歸。全部任務完成後必須：

1. 執行完整 `swift test` 並取得退出碼 0。
2. 執行 generic iOS 與 Watch build；兩者均須成功。
3. 執行 `git diff --check`。
4. 由未參與實作的 reviewer 檢查本規格五個缺陷及修正 diff。
5. 若總檢仍有 Critical 或 Important，停止本階段，不進入 CloudKit 第二階段，也不把分支視為可合併。

## 完成定義

- A→B→A 附件版本具有三個不可混淆的 immutable identities，且重啟後仍能重播精確 bytes。
- 兩個 store 路徑相同的不同安裝具有不同持久 device IDs；同一安裝重啟後維持相同 ID。
- entity revision 對每個新 mutation 嚴格增加，重試重用原 revision，遠端較高 revision 會推進下一次配置。
- 相同 stamp 的不同 counter/reminder atomic states 一律隔離，所有輸入排列結果相同。
- FIFO／symlink／替換競態／oversize 無法阻塞 restart 或繞過 regular-file 驗證。
- 2,000 次 journal 操作與 500 個真實附件 fixture 證明 hot path 不再完整重寫或重雜湊全部資料。
- 完整測試、iOS build、Watch build 與整體審查全部通過。
