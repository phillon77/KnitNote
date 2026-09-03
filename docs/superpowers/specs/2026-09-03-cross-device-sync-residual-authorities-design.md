# KnitNote 跨裝置同步殘留權威修正設計

日期：2026-09-03

狀態：設計已確認，待書面規格審閱

基準提交：`be09f1625ee43badcf94fcc6b8da442f25fe6f41`

上位規格：`docs/superpowers/specs/2026-09-02-cross-device-sync-core-correction-design.md`

## 目標與範圍

在 CloudKit 傳輸層及 `1.6.1 (13)` 發布工作開始前，關閉最終複審仍未通過的三個承重契約：不存在 project／counter 的 Watch 拒絕證據必須可跨設備驗證；journal 的附件歷史證據必須綁定完整不可變 snapshot；revision receipt 在長期縮放後仍必須對歷史 mutation ID 保持永久冪等。

本規格只修正上述三項權威來源與必要的持久化／遷移邊界。不加入 CloudKit transport、伺服器 schema、帳號生命週期、衝突 UI、同步排程、版本號修改、封存、推送或 App Store Connect 送審。

## 全域不變條件

- 支援 iOS 18.0、macOS 15.0 與 watchOS 11.0；`CloudSync` 核心不得 import CloudKit。
- 相同 mutation ID 必須永久重用完全相同的 entity、logical revision 與 device ID；歷史增長不得讓重試取得新 revision。
- 相同 attachment version ID 必須永久代表完全相同的不可變 snapshot；刪除狀態是可附加的 overlay，不得改變 snapshot 身分。
- 無法從舊資料證明 attachment lineage 或 immutable snapshot 時必須 fail closed，保留原 bytes，不得猜測。
- Watch command 一旦取得接受或拒絕結果，任何新設備、重啟或本機 ledger 清理都不得再次執行同一 command ID。
- 本機 archive 與同步 sidecar 的成功回報必須符合既有 durable-write、marker 與恢復順序。
- 使用者資料、附件 bytes、「使用毛線」語意及多提醒規則維持不變。
- 三項修正通過整體審查、完整測試及 iOS／Watch build 前，不得開始 CloudKit 第二階段或 `1.6.1 (13)` 發布流程。

## 方案總覽

採用「不可變證據權威分離」方案：只為無法附著於現存 aggregate 的 Watch rejection 建立 orphan authority；附件 proof 保存 canonical immutable-snapshot digest；revision receipt 以 mutation ID 為鍵保存不可變 authority，current entity head 則維持獨立的小型 ledger。三者都讓歷史正確性不依賴可清理的 cache。

不採用停止 compaction 的單一大 revision ledger，因為它保留冪等性但重新引入無界重寫。不採用統一重寫所有同步事件的 event log，因為它超出三項殘留缺口並增加 `1.6.1` 風險。

## 1. Watch orphan rejection proof

### 權威模型

現存 counter 的 accepted／rejected command proof 仍由 `SyncCounterReminderState` 原子承載。只有在 command 指向不存在的 project 或 counter、因而無法產生 `.projectCounter` mutation 時，才建立 immutable orphan rejection proof。

每一筆 orphan proof 必須包含：

- command ID；
- schema-independent command identity，至少含 project ID、counter ID、command kind 與必要 payload digest；
- rejection reason，只允許不會產生 counter effect 的 missing-project 或 missing-counter 類型；
- processing stamp／裝置證據，足以偵測同一 command ID 的分歧結果；
- deterministic record identity，以 command ID 為唯一鍵。

Orphan proof 是同步 authority，不是本機 processed-ledger cache。它必須由 projector 無條件納入 publication，即使 archive 中不存在目標 project 或 counter。新設備合併時先驗證 command identity 與 proof 一致；相同 command ID 的不同 identity、接受／拒絕分歧或不同 rejection reason 都是 corruption。

若 project 或 counter 日後重新出現，orphan proof 仍保留且可阻止 command 重播。不得因 aggregate 重新建立而移除 proof；若實作選擇把 proof 複製進 counter aggregate，orphan record 仍是該 missing-target 結果的不可變來源，兩者必須完全一致。

### 持久化與恢復

missing-target rejection 的本機流程必須先建立 durable proof，然後才能把 command 視為已完成。publication marker 必須涵蓋 proof sidecar 與 journal enqueue；任何中斷都只能導致安全重播同一 proof，不得重新執行 command。

本機 ledger 的 1,000 筆／90 天清理不得刪除 orphan authority。權威可採每-command immutable record 加持久化索引；hot path 只能讀取本次 command 所需的 proof 與小型索引，不得每次重寫全部歷史。

## 2. Attachment canonical immutable-snapshot proof

### Canonical digest

為每一個 attachment version ID 保存 `immutableSnapshotSHA256`。digest 必須由 deterministic encoding 計算，涵蓋所有建立後不可修改的欄位，包括：

- record schema version、record ID、createdAt 與 entity revision；
- attachment slot、version ID、`replacesVersionID`、content hash、byte count 與 media metadata；
- owner relationship 及其他屬於該 immutable version 的 relationships／fields；
- 原規格定義為 immutable identity 的其他欄位。

digest 明確排除 deletion overlay 的 value 與 stamp；因此同一 immutable version 的 live record 與 tombstone 具有相同 snapshot digest。任何其他欄位差異都必須被視為 divergent reuse。

### Journal proof 與跨記錄驗證

新版 `SyncMutationDuplicateProof` 必須同時保存完整 record-version hash（mutation 去重用途）及 `immutableSnapshotSHA256`（version identity 用途）。enqueue、checkpoint load、segment replay、legacy migration 與 acknowledged-history 驗證都必須以 version ID 聚合並比較 canonical digest，再驗證 same-slot parent、acyclic lineage 與 tombstone 單調性。

已 acknowledge 的 attachment proof 不得因 pending queue 壓縮而失去 version ID、slot、parent、canonical digest 或 deletion overlay 證據。後續 mutation 引用 predecessor 時，必須能驗證 predecessor 存在且屬於同一 slot。

### 舊版 proof 遷移

具有完整 record bytes 的 legacy envelope 可在寫入新 layout 前計算 canonical digest；只有驗證成功才可遷移。

v1 proof shard 若沒有足以重建 canonical snapshot 的資料，必須被標記為 opaque historical authority。後續任何 mutation 若重用其 attachment record/version ID，或把它列為 predecessor，都必須 fail closed；不得以目前 mutation 的資料回填或猜測舊 snapshot。拒絕時保留原 shard、checkpoint、segment 與 legacy bytes。

## 3. Durable mutation receipt authority

### 分離 receipt 與 entity head

`SyncRevisionLedger` 分成兩個責任：

- immutable receipt authority：以 mutation ID 查詢永久 receipt；
- compact entity-head ledger：只保存每個 entity 已配置的最高 revision。

每個 receipt 的 entity ID、mutation ID、logical revision 與 device ID 建立後不可修改。推薦使用按 mutation ID 分片目錄保存的 immutable receipt file；查詢一個歷史 mutation 不需要掃描或解碼全部 receipt。目錄至少使用 UUID 前綴分片，避免單一目錄無界膨脹。

批次配置在同一跨 process exclusive lock 下進行：

1. 讀取每個 requested mutation 的 immutable receipt；存在時驗證 entity 並原樣重用。
2. 為新 mutation 依 compact entity head 與 observed remote floor 配置 revision。
3. durable 寫入交易 marker，列出新 receipts 與目標 entity heads。
4. 建立每個 immutable receipt file，檔案同步並同步相關 parent directory；已存在且內容不同時報 corruption。
5. 一次 durable 更新 compact entity-head ledger。
6. 移除 marker 並同步 metadata directory。

Crash recovery 只需重播 marker 列出的 bounded batch。若 crash 發生在 receipt 已 durable、head 尚未更新之間，恢復必須把 head 提升至 receipt revision；不得配置第二個 revision。若 marker 遺失但 receipt 存在，該 mutation 的查詢仍必須回傳原 receipt。

現有單檔 ledger 遷移必須先驗證所有 receipts 與 issued heads，再建立 immutable files；成功完成及 directory sync 前保留原檔。遷移可重入，重啟不得重編 revision。

### 縮放界線

批次 N 個 mutation 最多一次 head-ledger durable rewrite，receipt work 與 N 線性。重試一個歷史 mutation 的查詢量與總 receipt 數無關。不得以刪除 receipt 換取有界空間；未來若需要清理，必須先有不會破壞 mutation-ID idempotence 的等價不可變 authority，且不屬本規格。

## 錯誤與損毀行為

- Orphan proof 分歧、attachment canonical digest 分歧、跨 slot predecessor、cycle、receipt immutable file 分歧皆回傳現有 typed corruption 邊界或新增等價 typed error。
- 不確定 durable write 保留 recovery marker；不得回報 publication 成功。
- Legacy migration 驗證失敗不得建立部分新 layout、刪除舊檔或截斷 journal。
- 所有安全拒絕都保留足夠診斷資訊，但不得記錄使用者附件 bytes 或敏感內容。

## 元件邊界

- `SyncRecord.swift`／`SyncRecordValidation.swift`：orphan rejection record schema、proof invariant 與 attachment canonical snapshot 定義。
- `SyncPublicationProjection.swift`：即使 project／counter 不存在仍投影 orphan proof；現存 aggregate 規則維持不變。
- `SyncMergeEngine.swift`：orphan proof 去重／分歧驗證，並讓 proof 在目標日後重建時仍阻止重播。
- `PreparedWatchCommand.swift`／`JSONProjectStore.swift`：missing-target rejection 的 durable proof、marker 與 publication 串接。
- `SyncMutationJournal.swift`：canonical snapshot proof、opaque v1 authority、collective validation 與遷移。
- `SyncRevisionLedger.swift`：immutable receipt store、compact heads、batch transaction marker 與 legacy migration。

不得在 `JSONProjectStore.swift` 重複實作 canonical digest、receipt file protocol 或 journal lineage validator。

## 驗收測試

### Watch

- missing project rejection 在本機 ledger 清理後仍會發布 proof，fresh device 可驗證並拒絕同一 command。
- missing counter deletion race 產生同樣結果；counter 日後重建也不會重播。
- 同一 command ID 的 identity 或 rejection reason 分歧會 fail closed。
- crash 位於 proof durable write、journal enqueue 與 marker removal 各邊界時，重啟只重播同一 proof。

### Attachment journal

- 相同 version ID、相同 nested attachment metadata，但 createdAt、entity revision、relationship 或 immutable field 不同時被拒絕。
- tombstone overlay 改變不會改變 canonical digest，且 live-after-tombstone 仍被拒絕。
- 新 replacement 引用 metadata 不完整的 v1 acknowledged proof 時 fail closed。
- corrupt legacy migration 不改變原 bytes 或 layout。

### Revision receipt

- 配置 A；配置 B、C 且 batch 不含 A；重啟；以更高 observed floor 重試 A，必須取得 A 原本完全相同的 receipt。
- crash 於 marker、receipt files、head ledger 與 marker removal 各階段後皆可恢復，且下一個 mutation revision 嚴格遞增。
- 兩個 store instance／process 對同一 metadata directory 並行配置時不產生重複 revision 或分歧 receipt。
- 大量 receipt 後，單一歷史 retry 的檔案讀取／寫入計數與總歷史量無關；批次只更新一次 head ledger。
- 舊單檔 ledger 遷移可重入；損毀時保留原檔並 fail closed。

## 完成與發布閘門

三個實作 task 各自需遵守 RED／GREEN、提交、規格及品質審查。完成後執行一次整體分支審查；若有 findings，只允許一次集中 final-fix wave 與一次 scoped re-review。

只有以下全部成立才可把本分支視為同步 Phase 1 完成：

- 最終整體審查無 Critical 或 Important；
- 新增聚焦測試與完整 `swift test` 皆 exit 0；
- generic iOS 與 Watch build 皆成功；
- `git diff --check` 無錯誤；
- 所有 reviewer 延後項目已關閉或以非承重 ruling 明確記錄。

即使上述通過，也只代表程式候選可進入 `1.6.1 (13)` 發布準備；仍需在相同 immutable candidate 上完成 iPhone、iPad、Mac 與 Watch 實體驗收，核對版本／build、簽章、archive、App Store Connect metadata／compliance／selected build，才可依使用者已給的最終授權推送並送審。
