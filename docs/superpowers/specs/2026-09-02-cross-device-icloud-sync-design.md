# KnitNote 跨裝置 iCloud 同步設計

日期：2026-09-02

狀態：已完成互動式設計確認，待使用者審閱書面規格

基準：KnitNote 1.6.0 Build 12，提交 `8a0374fe8bc35777eb9ddf7c5b0a431364f9bdd3`

## 目標

讓使用同一 Apple ID 的 iPhone、iPad 與 Mac 自動同步 KnitNote 的完整創作資料，同時維持離線可編輯、避免無聲資料遺失，並保留既有 Apple Watch 配對同步與本機備份／還原能力。

同步不是畫面的直接資料來源。畫面永遠讀寫本機資料；CloudKit 在背景交換變更，本機合併及驗證成功後才發布遠端結果。網路、iCloud 登入或容量問題不得阻止使用者記錄編織進度。

## 已確認的產品決定

- iPhone、iPad 與 Mac 使用同一 Apple ID 的 CloudKit 私有資料庫同步。
- Apple Watch 不直接連接 CloudKit，繼續透過配對 iPhone 的 WatchConnectivity 同步。
- 同步專案、計數器、排數筆記、提醒、日誌、毛線、照片、毛線標籤、織圖 PDF／圖片、織圖關聯及標註等完整創作資料。
- App 語言、介面偏好、購買狀態及可重建快取不同步。
- 不同欄位的並行修改自動合併；同一欄位採確定性的較新版本；大型附件衝突保留兩份。
- 首次升級合併每台設備既有資料。相同 UUID 視為同一筆；不同 UUID 即使名稱相似也先並存並標示，不自動刪除。
- 離線時所有編輯照常保存，恢復條件後自動重試同步。
- 刪除同步至所有設備，使用者內容保留在「最近刪除」30 天。
- iCloud 帳號切換時嚴格隔離資料；尚未同步內容進入僅原帳號可復原的加密保險庫，保留 30 天。
- 不建立 KnitNote 帳號，不加入多人協作、CloudKit sharing、Web 或 Android 同步。

## 現有架構與變更理由

目前 `JSONProjectStore` 將結構化資料保存於 Application Support 下的 `projects-v1.json`，並以獨立目錄保存作品照片、毛線照片、毛線標籤照片、日誌照片、織圖資產及標註。備份服務具備暫存、驗證、原子替換及回復流程。Apple Watch 已有獨立的 snapshot、command、acknowledgement、revision、去重 ledger 及 schema 相容規則。

把整份 JSON 或整個資料目錄放進 iCloud Drive 只能做粗粒度檔案同步，無法可靠支援欄位級合併。全面改寫成 SwiftData／Core Data 則會把資料層重寫、舊資料遷移、附件遷移與同步同時綁在一版，回歸範圍過大。

本設計保留既有本機 store，新增以 `CKSyncEngine` 為核心的 CloudKit 私有資料庫同步層。結構化項目拆成獨立 records，大型內容使用 `CKAsset`；同步層透過明確 adapter 與本機 store 溝通，不讓 CloudKit 型別滲入畫面或核心產品模型。

## 系統架構

```text
SwiftUI views
    ↓
JSONProjectStore and existing file services
    ↓ successful local commit
SyncMutationJournal
    ↓
KnitNoteCloudSyncCoordinator
    ├── CloudRecordMapper
    ├── CloudMergeEngine
    ├── SyncStagingInstaller
    ├── SyncAccountVault
    └── CKSyncEngine adapter
             ↕
       CloudKit private database

Merged phone state
    ↓
existing PhoneWatchSyncCoordinator
    ↕
paired Apple Watch
```

### 邊界與責任

- `JSONProjectStore`：維持本機資料的權威讀寫介面；每次 mutation 先完成現有原子儲存，成功後才發布同步變更。
- `SyncMutationJournal`：保存尚未確認送達 CloudKit 的 record save／delete 意圖。它不依賴 CKSyncEngine 的記憶體佇列，並可跨啟動與帳號事件恢復。
- `CloudRecordMapper`：在 KnitNote domain snapshot 與 versioned CloudKit record schema 間轉換；不得直接修改 store。
- `CloudMergeEngine`：純函式式合併結構化 records，輸入相同即產生相同結果及衝突清單。
- `SyncStagingInstaller`：在隔離暫存區驗證結構化資料、關聯及附件，通過後才使用現有原子替換概念安裝。
- `SyncAccountVault`：依 CloudKit user record ID 隔離本機 working set、journal、CKSyncEngine serialized state 及帳號復原保險庫。
- `KnitNoteCloudSyncCoordinator`：處理啟動、前景刷新、CKSyncEngine delegate events、批次、狀態投影及重試。
- `PhoneWatchSyncCoordinator`：只接收已合併且已提交的手機本機狀態，不知道 CloudKit 實作。

App 啟動時即建立 CKSyncEngine。正常情況由系統排程收送；App 進入前景、使用者按「立即同步」或完成重要本機 mutation 後，可要求送出或抓取，但介面不得承諾即時完成。

## CloudKit 拓撲

- 使用單一 CloudKit container 的 private database。
- 使用單一 custom record zone 保存使用者 KnitNote 資料，讓變更 token、zone reset 與原子操作邊界可管理。
- production schema 必須在發行前由開發環境明確部署；App 不得依賴 production 動態新增 record type 或 field。
- CKSyncEngine serialized state 依本機設備及 CloudKit account 保存，不跨設備同步。
- 啟用 CloudKit 與 remote notification entitlements；環境與 container identity 加入 release contract tests。

CloudKit record 的非 asset 欄位總量必須遠低於 1 MB。PDF、圖片、標註文件及其他超過數 KB 的二進位內容使用 `CKAsset`，不把大型 Data 塞入一般欄位。批次需能在 limit-exceeded 時拆分重試；不得假設固定最大批次永遠有效。

## Record schema

每一種可獨立新增、編輯、刪除或合併的 domain entity 使用獨立 record。第一版至少包含：

- `Project`
- `ProjectCounter`
- `RowNote`
- `KnittingReminder`
- `ProjectJournalEntry`
- `Yarn`
- `ProjectYarnLink`
- `PatternFolder`
- `Pattern`
- `PatternUsage`
- `Attachment`
- `DeletionMarker`

不得把完整 `StoredProject`、全部 yarns 或整份 archive 編碼成單一 record blob。集合項目使用各自 UUID 作 record name；關聯使用穩定 UUID 欄位或同 zone references，解碼後仍由 domain validator 驗證。

### 共通 metadata

每筆結構化 record 至少包含：

- `schemaVersion`
- 穩定 entity UUID
- `createdAt`
- `modifiedAt`
- 來源 device ID
- entity logical revision
- 各可獨立合併欄位的 mutation stamp
- `deletedAt` 或對應 deletion marker identity

Mutation stamp 由邏輯修訂、牆鐘時間及穩定 device ID 組成。邏輯修訂是主要排序依據，時間用於使用者語意及補充排序，device ID 只作最終確定性 tie-break。所有設備必須對同一組 stamps 得到相同結果；不得只依可能錯誤的設備時鐘決定勝負。

### 附件

附件實體內容採不可變版本。`Attachment` record 保存：

- attachment UUID、owner type 與 owner UUID
- semantic role，例如 project photo、yarn photo、label photo、journal photo、pattern source 或 markup
- content hash、byte count、media type、原始顯示檔名
- 建立與修改 metadata
- CKAsset
- replacement lineage 與 conflict group ID

替換附件會建立新版本，待引用它的結構化 record 成功同步後才使舊版本符合清理資格。同一 semantic slot 發生並行替換時，兩個版本都保留並加入同一 conflict group；UI 顯示於「需要整理」。可重建 PDF page thumbnails、preview thumbnails 及其他 cache 不上傳。

## 關聯與產品不變量

- `ProjectYarnLink` 是一級同步 entity。解除「使用毛線」只刪除 link，永遠不刪除 `Yarn`。
- 刪除 project 時，其專用 counters、notes、reminders、journal entries、links 及專用 attachments 一起進入最近刪除。
- Yarn 或 pattern asset 若仍被其他 project／usage 引用，不得因單一 project 刪除而清除。
- 使用者建立或匯入的名稱、筆記、毛線文字與織圖內容原樣同步，不翻譯。
- 數值、編織縮寫及 reminder semantics 不因 App 顯示語言改變。
- 結構化 record 缺少必要 parent、schema 不支援或破壞 domain invariant 時，必須隔離，不得自行猜測 parent 或部分發布。

## 合併規則

### 一般 scalar 欄位

- 只有一方改變：採用改變方。
- 雙方修改不同欄位：逐欄合併。
- 雙方修改同一欄位：比較 mutation stamp，採確定性較新值。
- 完全相同 mutation stamp 卻有不同 payload：視為資料損毀／協定錯誤，隔離並記錄，不任意選擇。

### 集合項目

Row note、journal entry、reminder、counter、yarn、pattern 等以 UUID 做集合聯集。名稱或內容相似但 UUID 不同，不自動合併；可加入疑似重複清單供使用者整理。

### 計數器與 Watch 指令

計數器不得只套用一般 last-writer-wins。Cloud merge 必須保留現有 counter mutation revision、Watch command ID、prepared command、processed ledger、occurrence 與 exactly-once 不變量。過期 revision、重播或已處理 Watch command 不得讓計數器倒退或重複處理提醒。

如果兩個非 Watch 裝置從同一基準離線設定同一計數器為不同絕對值，採 mutation stamp 較新版本並保留衝突診斷；此情況不把兩個絕對值相加。

### 附件與標註

大型附件及 markup 同時變更時不丟棄任何版本。系統保留兩份、選定確定性的 active version 供現有畫面繼續運作，並在「需要整理」顯示比較與選擇。使用者選擇後建立新的 resolution mutation；未選版本保留到 resolution 已同步且安全清理期限通過。

### 刪除與修改

刪除是可同步 mutation，不是本機立即移除。刪除與並行修改相遇時，項目進入最近刪除並保留修改版本，讓復原能取回最新合併內容。介面不得因遠端刪除直接永久抹掉尚未同步的本機修改。

## 首次啟用與既有資料匯入

每台設備第一次啟用同步時依序執行：

1. 確認本機 archive 可完整載入，並建立可還原的完整備份。
2. 為現有 entities 產生同步 metadata，不改 UUID、內容或檔案。
3. 建立 account-scoped staging area，先抓取該 CloudKit 帳號的現有 records。
4. 合併本機與雲端結構化資料，下載必要附件，驗證 schema、hash、關聯及 domain invariants。
5. 驗證通過後原子安裝 merged working set。
6. 將本機獨有或合併後需要發布的變更加入 journal。
7. 保留 migration receipt，避免重啟後重複匯入。

相同 UUID 視為同一 entity 並依欄位規則合併。不同 UUID 一律並存；可用 normalized name、建立時間、附件 hash 等只產生「可能重複」提示，不執行自動刪除或合併。

任一步失敗時維持升級前 live data，保留診斷及可安全清除的 staging data。不得發布半套 archive、空附件 placeholder 或只完成部分關聯的資料。

## 日常資料流

### 本機變更

1. UI 呼叫既有 store mutation。
2. Store 完成本機原子寫入與 domain 驗證。
3. 成功後以同一 mutation identity 寫入 durable journal。
4. Coordinator 把 journal entries 登記為 CKSyncEngine pending changes。
5. CloudKit 確認成功後才從 journal 標記完成；asset staging file 在確認前不可刪除。

若第 2 步失敗，不產生同步 mutation。若第 3 步失敗，產品 mutation 必須回復或進入明確的「本機已保存但同步 journal 受損」阻斷狀態；不得安靜遺漏同步。

### 遠端變更

1. CKSyncEngine 提供 fetched record changes 或 deletions。
2. Mapper 解碼到 staging representation；未知 schema 或損壞資料逐筆隔離。
3. Merge engine 對照 live snapshot 與尚未送出的本機 journal 計算結果。
4. Installer 驗證 attachment hash、parent links、archive invariants 及 reminder／counter rules。
5. 驗證通過後原子提交本機資料，更新 UI generation。
6. 若結果影響 Watch snapshot，再由既有 phone coordinator 發送新 snapshot。

Remote batch 的到達順序不具產品語意。Child record 早於 parent 或 attachment 尚未可用時先保留於 staging，等待後續變更或主動補抓，不把缺失解讀成刪除。

## 刪除、最近刪除與永久清理

- 使用者刪除 entity 時寫入 `deletedAt` 與 deletion mutation，項目從一般列表移至「最近刪除」。
- 所有設備同步相同刪除狀態與復原期限。
- 30 天內復原會清除 deleted state、恢復必要關聯，並產生新的同步 mutation。
- 30 天後先確認刪除 mutation 已傳至雲端，才清除使用者內容及無引用 attachments。
- 清除內容後保留不含使用者內容的精簡 deletion marker。marker 的保留期不得短於 App 支援的最長離線／升級相容窗口，避免長期離線舊設備重新上傳已刪資料。
- 清理工作必須可重入、可中斷且引用安全；任何仍被 live entity 引用的 attachment 不得刪除。

## iCloud 帳號生命週期

CKSyncEngine account-change event 是硬資料邊界。

### Sign in

- 建立或開啟 current user record ID 對應的 account vault。
- 若有從未綁定帳號的 legacy local data，執行首次啟用合併流程。
- 若有同一帳號未到期的 recovery vault，驗證後把尚未同步 journal 恢復到該帳號，不與其他帳號混用。

### Sign out 或 switch accounts

- 立即停止 UI mutation publication 與舊帳號 sync engine。
- 關閉舊 working set，從畫面清除舊帳號內容，清除任何解密後暫存。
- 把尚未確認同步的資料及 journal 移入 account-scoped encrypted recovery vault。
- 新帳號使用全新的 working set、journal 與 CKSyncEngine serialized state。
- 舊資料永遠不自動匯入或上傳到新帳號。

Recovery vault 使用 CryptoKit authenticated encryption；key 保存於 Keychain，metadata 綁定原 CloudKit user record ID。只有目前登入的 record ID 相同時才允許解密與恢復。保留 30 天後刪除密文、key 與暫存。任何解密、驗證或 identity 檢查失敗都不得降級成明文匯入。

App 必須自行保存 journal，因為 CKSyncEngine 在帳號變更時會重設內部 pending changes 與 serialized state。

## 同步狀態與介面

### 設定頁

新增「iCloud 同步」區塊，顯示：

- 已同步、等待同步、正在同步、iCloud 未登入、iCloud 空間不足或同步需要處理。
- 最近一次完整成功收送時間。
- 待同步項目數量。
- 「立即同步」動作。
- 「最近刪除」與「需要整理」入口。

「已同步」只在本機 journal 為空、最近 fetch／send 成功且沒有未解決安裝錯誤時顯示。最後成功時間不能單獨代表目前資料完整。

### 一般畫面

- 正常背景同步不顯示 toast、alert 或阻斷畫面。
- 專案列表只在有待處理問題時顯示小型狀態提示。
- 斷網與暫時性 CloudKit 錯誤不反覆警告。
- iCloud 未登入或容量不足顯示簡潔原因與系統設定指引，但不阻止編輯。
- 附件尚未下載時顯示明確下載狀態，不建立假的空白檔案。

### 需要整理

- 疑似重複 records 只提供並排比較、保留兩筆或使用者明確合併。
- 附件 conflict group 提供預覽、選擇 active version 或保留兩份。
- 所有整理動作本身都是可同步、可重試的 mutations。

## 錯誤處理與復原

- 未登入、網路中斷、服務暫停、zone busy、rate limit：保留本機 journal，交由 CKSyncEngine／coordinator 依 retry-after 與系統條件重試。
- iCloud quota exceeded：停止需要雲端空間的上傳，保留本機編輯與 assets，顯示具體狀態；不得丟棄較舊的 pending asset 來假裝成功。
- server-record-changed：取得 server version，交由 domain merge engine 解決後建立新 save；不得盲目覆蓋。
- unknown record schema／invalid payload：逐筆 quarantine，維持其他合法 records 可同步，並保留安全診斷。
- missing dependency：保留 staging 並補抓，不發布孤兒資料。
- asset unavailable／hash mismatch：不安裝，重試或標記需要處理；不得用零 bytes 覆蓋本機檔案。
- zone reset／change-token expired：重建本機 sync index 並重新抓取，但以 account working set 與 journal 合併，不把雲端快照直接覆蓋本機。
- process termination：journal、staging manifest、installation transaction 與 CKSyncEngine state 都以原子檔案保存；下次啟動可判定 commit、rollback 或 resume。

記錄同步診斷時不得包含使用者筆記、毛線文字、PDF 內容、照片資料、Apple ID、CloudKit record name 明文或其他私人 payload。使用不可逆雜湊及分類錯誤碼即可。

## 備份與還原

- 現有完整備份仍是使用者可攜、可明確還原的資料安全機制，不能由同步取代。
- 備份包含 live domain data 與原始 attachments，不需要包含 CKSyncEngine serialized state、可重建 cache 或 account encryption key。
- 還原必須先在本機 staging 完成現有驗證，再產生新的 sync import transaction。
- 還原不得逐筆邊寫本機邊上傳；整份驗證成功並安裝後才排入同步。
- 還原到已有雲端資料的帳號時採與首次啟用相同的 UUID／欄位合併規則，除非未來另行設計明確的「以備份取代全部資料」危險操作；本版不包含該操作。

## 安全與隱私

- 只使用 CloudKit private database，不建立開發者帳號資料庫或 public records。
- 不儲存 Apple ID 電子郵件；帳號分區只使用 CloudKit 提供的 user record ID。
- Recovery vault 使用 authenticated encryption、Keychain key、原帳號 identity gate 與 30 天期限。
- CloudKit container、entitlements、privacy declarations 與 App Store 說明必須在 release audit 中核對。
- 使用者內容不拿來做分析、翻譯或伺服器端處理。

## 測試策略

### 單元測試

- 每種 domain entity 與 CKRecord 的雙向映射及 schema version rejection。
- Mutation stamp 排序、不同欄位合併、同欄位衝突及跨設備確定性。
- Counter revision、Watch command 去重、prepared command、reminder occurrence 與 exactly-once 不變量。
- Project／yarn／pattern／attachment 關聯及「解除使用毛線不刪毛線」。
- Deletion／restore／30-day purge／stale-device anti-resurrection marker。
- Attachment immutable version、hash validation、conflict group 及 reference-safe cleanup。
- Account identity gate、vault encryption、expiry 與錯誤 key／錯誤帳號拒絕。

### 遷移測試

- 從 release candidate 的 archive schema 14 及所有仍支援舊 schema 升級。
- 空資料、單一 project、完整 yarn／pattern／photo／markup 資料及大型資料集。
- 本機有資料／雲端空白、兩邊都有資料、三台設備各有獨有資料。
- 相同 UUID 合併、不同 UUID 同名並存、migration receipt 重入。
- 每一個 staging／install interruption point 的 rollback 或 resume。

### 同步整合與故障測試

- Local commit → journal → CKRecord → remote fetch → merge → atomic install。
- 亂序、重複、遺漏後補到、batch 拆分、server-record-changed 與 zone reset。
- 斷網、未登入、quota exceeded、service unavailable、rate limit 與 app termination。
- Attachment metadata 先到、asset 後到、下載失敗、hash mismatch、並行 replacement。
- Account sign out、switch、switch back、CKSyncEngine pending state reset 及 recovery vault expiry。
- 備份匯出、還原與同步重新發布的完整回歸。

測試使用 protocol adapter 與 deterministic fake CloudKit transport 驗證絕大多數狀態機；另以 CloudKit development environment 執行真實 container integration tests。測試不得依賴 production user data。

## 實機驗收

發行邊界是一個不可變 release candidate 在實機矩陣全部通過，不以模擬器、單一設備、archive 成功或 thread 回報代替。

至少驗收：

- 同一 Apple ID 的一台 iPhone、一台 iPad、一台 Mac 完成首次合併、雙向及三方同步。
- 三台設備各自離線修改不同及相同欄位，恢復連線後結果一致。
- 三台設備各有升級前本機資料，首次加入後全部保留。
- 大型 PDF、照片、毛線標籤、日誌照片及 markup 的上傳、按需下載與衝突保留。
- 斷網、iCloud 未登入、容量不足及恢復後重試。
- 刪除、跨設備最近刪除、復原及以可控制測試時鐘驗證 30 天清理。
- iCloud 登出、切換帳號、舊資料不可見且不外洩、切回原帳號恢復 pending data、保險庫到期清除。
- iPhone 接收 iPad／Mac 變更後，配對 Apple Watch 收到正確 snapshot；既有 schema、queue、revision 與 exactly-once 測試不退步。
- 從已發行舊版覆蓋安裝到候選版本，project、counter、reminder、yarn links、photos、patterns、markup、backup／restore 全部保留。
- App 被終止於 upload、download、merge、asset install 及 account transition 各階段後可安全恢復。

## Release gates

- CloudKit development schema 與 production schema 差異已審核並部署。
- iOS 與 macOS target 使用同一正確 container；Watch target 沒有不必要的 CloudKit entitlement。
- Remote notification、iCloud container、bundle ID、team、environment 與 production entitlements 綁定同一候選提交。
- Privacy manifest、App Store privacy answers、localized release notes 及支援文件反映 iCloud 同步。
- 實機驗收、備份還原、舊版升級與 Watch 回歸結果綁定同一完整 SHA、版本與 build。
- 未取得明確授權前，不上傳正式 build、不部署 production schema、不提交 App Review。

## 明確不包含

- 與其他 Apple ID 分享 project 或多人協作。
- Android、Web、Windows 或第三方雲端同步。
- 自訂 KnitNote 登入、密碼、伺服器或訂閱式同步服務。
- App 設定、語言選擇、StoreKit entitlement、trial 狀態或可重建 thumbnails 的同步。
- 自動永久合併疑似重複 records。
- 以新帳號覆蓋、接收或匯入舊 Apple ID 的 account-scoped data。
- 由 Apple Watch 直接存取 CloudKit。

## 完成定義

只有當資料 schema、合併器、journal、CKSyncEngine adapter、帳號隔離、刪除復原、UI 狀態、備份相容及測試全部完成，並由同一不可變候選版本通過 iPhone／iPad／Mac／Watch 實機矩陣，才可稱為跨裝置同步完成。

背景同步排程不可預測，因此「完成」代表可靠的最終一致、清楚狀態及可復原錯誤，不代表每次編輯後所有設備立即出現變更。
