# Cloud Asset Staging App-Sandbox Design

日期：2026-09-04

狀態：待使用者審閱書面規格

基準：`a9adb92ad1f781ce05ce34fb69eac5b1a62b0f7b`

## 目標

以可維護、可測試且儲存空間有界的方式，為 KnitNote CloudKit 附件提供不可變上傳暫存、下載驗證、精確 acknowledgement 清理及重啟恢復。這份設計取代目前 Task 4 的退休證據鏈；既有 Task 1–3 的 record、journal、transport 與 coordinator 邊界維持不變。

## 威脅模型

### 必須防範

- App 或 extension 在寫入任一步驟崩潰、被終止或重新啟動。
- 多個 KnitNote 程序同時存取同一 account staging root；所有合法寫入者必須遵守同一個 kernel file lock。
- 磁碟上的 manifest 或檔案缺失、截斷、非 canonical、checksum 錯誤或內容與 metadata 不符。
- 啟動前已存在的 symlink、hard-link、FIFO、device、socket、非預期目錄、路徑穿越及不屬於目前 effective user 的 lock file。
- 外部輸入在開啟及讀取期間改變；讀取必須綁定已開啟 descriptor，並在讀取前後驗證 identity、大小及 hash。
- 不同 CloudKit account 的檔案或 manifest 相互讀取、重用或清理。

### 明確不防範

- 同一 macOS 使用者或具有 App container 寫入權限的惡意程序，在已完成 descriptor 驗證後、下一個 filesystem syscall 前刻意替換 pathname 或就地修改 inode。
- 不遵守 KnitNote account lock 的第三方寫入者。
- 已取得程序記憶體、簽章身分或裝置 root 權限的攻擊者。

這是 Apple App Sandbox 內的協作程序模型。檔案鎖、no-follow、descriptor 驗證與 checksum 用來處理產品實際會遇到的並行、崩潰及損毀；不以不可能原子化的「驗證後仍可遭同使用者惡意替換」要求換取無界證據檔案。

## 不變量

- 使用既有 `SyncAttachmentVersion` 與 `SyncAttachmentSource`；不得新增第二份 attachment metadata authority。
- 每個 upload mutation 擁有獨立的 immutable staged file，檔名由 mutation ID 與 version ID 決定。不同 mutation 不共享同一 staged inode，因此 acknowledgement 不需要猜測引用計數。
- staged file 與 journal source 都必須存活到 exact `(recordID, mutationID)` server acknowledgement。Cloud staging service 永遠不刪除 journal 或原始來源檔案。
- 每次 CloudKit save attempt 都以穩定 staged URL 建立新的 `CKAsset` instance；不得跨 attempt 或 record 重用 CKAsset object。
- manifest 是目前 account staging references 的唯一清理權威。manifest 不可信或缺失且磁碟仍有 final upload files 時，服務 fail closed 並保留所有 bytes。
- 正常使用不得建立永久 retirement/evidence inode；acknowledged 或 orphan cleanup 完成後，metadata 與檔案數量只與目前 pending、installed 及 bounded quarantine 狀態相關。
- 每個讀取先以 `fstat` 比對宣告大小，再最多讀取宣告大小加一個 overrun byte；單一附件上限沿用 `SyncPublicationFileLimits.maximumAttachmentBytes == 100_000_000`。

## 儲存配置

```text
CloudAssetStaging/
  Accounts/
    <sha256(account identifier)>/
      .lock
      manifest.json
      Uploads/
        <mutation UUID>-<version UUID>.asset
      Installed/
        <version UUID>.asset
      Quarantine/
        manifest.json
        <diagnostic UUID>.asset
```

Account identifier 不直接出現在 pathname。建立或開啟 root、Accounts、account 及三個子目錄時使用 descriptor-relative no-follow 操作，驗證每層都是預期 owner 的目錄。`.lock` 必須是 regular、單一 link、由目前 effective user 擁有；所有 manifest 與檔案 mutation 均在持有同一 account kernel lock 時執行。

合法程序在操作結束前重驗 root→Accounts→account→child 的 descriptor/path identity。若協作環境出現替換，當次操作失敗；不建立永久 forensic evidence 鏈。

## Upload manifest

Manifest 使用 versioned、canonical sorted-key JSON envelope：

- payload 包含 schema version 及依 `(mutationID, versionID)` 排序的 upload entries。
- 每個 entry 保存完整 `SyncAttachmentVersion`、mutation ID、相對 staged filename、byte count 與 SHA-256。
- envelope 保存 domain-separated SHA-256 checksum，涵蓋 canonical payload bytes。
- decode 後必須重新 canonical encode 並逐欄驗證；duplicate mutation、duplicate filename、absolute path、未知 version 或 metadata/source 不一致均視為 corrupt。
- 每次 manifest 寫入採同目錄 unique temp、完整 write、file fsync、atomic rename、directory fsync。協作程序由 account lock 序列化，不再建立 manifest retirement history。

如果 manifest 缺失且 `Uploads` 為空，可初始化空 manifest；如果 manifest 缺失／損毀而存在 final uploads，服務 fail closed，不清理也不覆寫。

## 上傳資料流

### Stage

1. 驗證 `SyncAttachmentVersion` 與 `SyncAttachmentSource` 的 version ID、hash、byte count 及 owner/slot binding。
2. 在 account lock 內載入並驗證 manifest。
3. 若 exact mutation entry 已存在，驗證 staged bytes 後 idempotently 回傳；任一 immutable 欄位分歧即 fail closed。
4. 以 descriptor 綁定讀取 source；大小不符時在 payload allocation 前拒絕。
5. 寫入 `Uploads` unique temp，驗證 hash/size，fsync 後以 no-clobber rename 發布 exact final filename，再 fsync Uploads。
6. 寫入包含新 entry 的 manifest。若 manifest commit 失敗，final file 成為可辨識 orphan；舊 manifest 仍是權威。

### Retry

`assetForUpload` 只接受 manifest 中的 exact mutation/version reference。它重新驗證 staged file，並在每次呼叫建立一個新的 `CKAsset(fileURL:)`。URL 穩定到 matching acknowledgement。

### Acknowledge

1. 只接受 exact `(recordID/versionID, mutationID)`；未知或 divergent acknowledgement 不改變狀態。
2. 先原子提交移除該 entry 的 manifest，並 fsync account directory。
3. manifest 成功後，在 account lock 內重驗 exact staged regular file 並移除；directory fsync 完成清理。
4. 若移除或 fsync 失敗，manifest 已不再引用該檔；重啟 reconciliation 將它視為 orphan 再清理。重試 acknowledgement 保持 idempotent。

因每個 mutation 使用獨立 staged file，清理不會刪除其他 mutation 或 version 仍引用的 bytes。

## Reconciliation

每次 service 初始化及公開 mutation 前，在 account lock 內執行：

- manifest 有效時，逐一驗證所有 referenced upload files；任一缺失或內容不符即 fail closed。
- 只清除符合 exact service filename grammar、regular、單一 link、目前 owner，且未出現在 manifest 的 upload temp/final orphan。
- 不符合 grammar 或型別的未知 artifact 一律保留並回報錯誤，不將它解讀為可清理檔案。
- 清理後 fsync 對應 directory。
- 此流程不建立 retirement/evidence 檔；正常掃描成本為目前 pending entries 加有限 orphan 數量。

因 Task 4 尚未出貨，本分支既有 `Retired/.zero-retirement-evidence` 實作沒有 production migration contract；新版實作與測試移除該未發布格式，而不是把它變成永久相容權威。

## Download 與 quarantine

`installDownload` 接受 canonical `SyncAttachmentVersion` 及 CKAsset/source URL：

1. descriptor-relative/no-follow 開啟 source，先驗證 regular file 與宣告 byte count。
2. 最多讀取宣告大小加一 byte，計算 SHA-256；大小或 hash 不符不得變更既有 installed file。
3. 將驗證成功 bytes 寫入 Installed unique temp，fsync，再以 no-clobber rename 安裝 `<versionID>.asset`，最後 fsync Installed。
4. exact destination 已存在時驗證完整 immutable identity並 idempotently 回傳；不同 bytes 不覆寫。

Mismatch quarantine 保存診斷 metadata 與最多原附件大小的已開啟 descriptor 內容，不重新以 pathname 無界讀取。Quarantine manifest 同樣 checksummed；每個 account 最多保留 4 件、總 bytes 不超過 400,000,000，超限時在 account lock 內先提交移除最舊 entry，再清理其檔案。無法安全清理時停止新增 quarantine，但仍拒絕錯誤 download，絕不影響已安裝內容。

## 錯誤與狀態

- manifest corruption、referenced file missing/mismatch、unsafe filesystem object、account identity mismatch：blocking error，不做自動重建或清理。
- source hash/size mismatch：拒絕 operation，留下 bounded quarantine 診斷；不修改 installed destination。
- manifest commit 或 directory fsync 失敗：回報 durable failure；重啟依最後一份有效 manifest reconciliation。
- exact duplicate stage/ack/install：idempotent success。
- divergent duplicate identity：blocking immutable-identity error。

錯誤不得被無關成功清除；由 Task 3 coordinator 或 Task 5 integration 將 blocking 狀態投影為 `needsAttention`。

## 程式邊界

目前超過兩千行的 staging service 不保留。實作拆為：

- `CloudAssetStagingService.swift`：公開 stage、asset、acknowledge、install、quarantine workflow。
- `CloudAssetManifestStore.swift`：checksummed upload/quarantine manifest、canonical encode/decode 與 atomic commit。
- `CloudAssetFileStore.swift`：account lock、descriptor-relative directory/file operations、bounded verified copy、reconciliation。

測試亦依 workflow、manifest/recovery、filesystem safety 分檔，避免單一測試檔再次膨脹。Core 的 `SyncRegularFileReader` 僅保留通用 declared-size bounded-read 修正；CloudKit 型別不得進入 `KnitNoteCore` 或 Watch target。

## 驗證門檻

- Stage/retry/ack：exact idempotency、divergent identity、source survival、fresh CKAsset、兩程序遵守同一 lock。
- Crash matrix：file publish 前後、manifest commit 前後、ack manifest commit 後／file cleanup 前、directory fsync 失敗與重啟 reconciliation。
- Corruption：canonical checksum、valid-JSON mutation、missing manifest with uploads、missing/mismatched referenced file。
- Filesystem：symlink、hard-link、FIFO、wrong owner、traversal、oversize、descriptor read-time growth、account isolation。
- Download：hash/size mismatch、existing destination preservation、no-clobber immutable install、bounded quarantine eviction。
- Sustained test：至少 10,000 次 stage→ack 後，Uploads 與 manifest entries 回到 0，沒有 Retired/evidence 目錄，account metadata 檔案數保持常數；測試 runtime 不以真實 100 MB payload 放大。
- Task 4 focused suites、附件／備份／pattern／yarn-photo 相關 Core suites、完整 Swift package、generic iOS build 及 project membership/static checks全數通過。

## 不在本設計範圍

- CloudKit container、entitlements、production schema、實際網路整合與 App lifecycle wiring；這些仍屬 Task 5 或後續整合。
- 同一使用者惡意 filesystem actor 的 syscall 間競態保證。
- 既有使用者資料 migration；目前 Task 4 code 尚未出貨。
- push、archive、upload、TestFlight、App Store Connect 送審或實機驗收。
