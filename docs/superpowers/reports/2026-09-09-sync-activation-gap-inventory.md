# 正式同步啟用前的缺口盤點

2026-09-09 19:06–19:10 Asia/Taipei；唯讀程式盤點，沒有實作或正式啟用。

實際基準：`docs/cross-device-sync-design`，`1ca60ef2322e0bd024695b223d2654f23becff34`。開始時僅有使用者既有未追蹤 `.superpowers/absent-source-design-progress.md`，未修改它。已完成代理均為 completed；本輪不重派工、不重跑完整驗證。程序列表 ps 被沙箱拒絕，因此未宣稱已確認全機沒有 compiler；本輪沒有啟動 compiler，後續需要編譯前須再核對。

## 已有與仍缺的邊界

| 項目 | 實際證據 | 後續必要條件 |
| --- | --- | --- |
| 正常啟動 | `KnitNote/App/AppSessionComposition.swift:69` 的 makeLaunch 選 screenshot 或 makeLocal；`KnitNote/App/KnitNoteApp.swift:158` 明言這不是已驗證帳號接入結果 | 在接入與首次 zone 路徑齊備前，不切換正常入口 |
| 舊本機資料首次接入 | `Sources/KnitNoteCore/CloudSync/SyncAccountStorage.swift:87` 明言 open 不搬移 legacy global storage；`SyncAccountSourceState.swift` 現有 origin 是 freshAllocation/restoredSelection/bootstrapRollback | 不能把 legacy global store 當 fresh account root；先設計可證明未綁定、保留原始資料及可重開的接入權威 |
| 新雲端區域 | 已核准 bridge 規格第91行明確不在錯誤處建立 zone；對 KnitNote/Core 搜尋 CKModifyRecordZonesOperation、recordZonesToSave 與 CKAccountChanged 未找到接線 | 把 zone 不存在與既有空 zone 分開，先定義隔離 driver 與帳號世代/取消邊界；真實建立仍需授權 |
| 帳號事件 | `AppAccountSessionController.swift:5` 是不建構系統 observer 的可注入 runtime；start/accountDidChange/foreground 已有入口 | 後續用單一 App owner 接系統事件，不讓每個視窗建立 controller；真實 identity query 不在本轮呼叫 |
| Watch | `KnitNote/App/KnitNoteApp.swift:166` 仍在正常本機發布後啟動原本 local-only Watch route | 不把現有停止/drain 測試當成跨帳號實機驗收；必須獨立接線與驗收 |

這份清單不把「搜尋未找到」當成已證明整個 repository 絕無相關工具；它描述實際正式入口及已核准規格的缺口。沒有修改 wire、資料來源權威或 cleanup 政策。

## 建議執行順序與取捨

1. **優先：舊本機資料接入的隔離設計。** 先完整閱讀上位2026-09-02同步規格與2026-09-06生命週期規格，追蹤既有 local root、備份、寫入停止及首次 bootstrap 接點。最小第一切片限於來源資格、穩定快照與再驗證契約；不能只新增 caller Boolean 宣告未綁定。接入安裝、持久權威格式及 crash recovery 是獨立架構審查範圍。
2. **其次：首次 zone 的受控本機測試設計。** 不先呼叫 CloudKit；釐清 same-account、取消、already-existing 與完整 zone read 之間的契約。實際 Apple API 行為在設計時查官方來源，不從本盤點推定。
3. **最後：正式 composition、狀態 UI、Watch 與實機矩陣。** 舊資料、新帳號及正常 reopen 都有完整路徑後才準備啟用候選。真正啟用、資料搬移、Keychain、設備、schema、簽署及商店操作需具體授權。

直接接正式 factory 雖改動表面較少，會跳過旧資料與新 zone 的顯式門檻，不採用。先做 zone 可以獨立驗證，但無法解決既有使用者資料進入帳號根目錄的問題，因此接入設計優先。這是技術排序建議，不是自動批准新的持久格式或正式資料搬移。

## 不得退讓的接入驗收條件

- 從未綁定需有正面證據，不能僅依目錄/標記不存在、檔案名稱或 cached account 推定。
- 等待網路時保留原本合法的本機編輯；準備後新編輯使舊快照失效，不能覆蓋。
- 合併遵守既有 UUID/欄位規則，不因相似名稱刪除資料；原始完整備份、附件與待同步資料保留。
- 帳號失效、取消、部分寫入與程序突然結束都要同一路徑復原，不用重新播種 fixture 掩蓋問題。
- 通過設計與本機測試不等於已啟用；真實多設備及 Watch 驗收不得填入模擬結果。

## 本輪交接

沒有程式變更、測試或外部服務操作。前一份 bootstrap verification report 仍是已完成候選的證據，不因本盤點而重跑。下一輪從上述第一切片的完整上位規格與 local root 實際程式追蹤開始；brainstorming 架構設計尚未通過，不得直接進入 implementation。委任仍遵守今晚回來/取消或午夜停止條件。

## 19:11 後續唯讀追蹤：接入不是單純搬目錄

已完整閱讀 `2026-09-02-cross-device-icloud-sync-design.md` 與 `2026-09-06-cloud-sync-app-session-lifecycle-design.md`。前者既定策略是自動合併既有 UUID、先完整備份、驗證後原子安裝及保留 migration receipt；後者已確認未綁定本機在等待網路時仍可編輯、只在最終提交必要區間停止寫入。這些不是本輪重新決定的產品政策。

實際接點：

- `KnitNote/App/KnitNoteApp.swift:124` 的 local route 呼叫預設 `JSONProjectStore.live`；`Sources/KnitNoteCore/Projects/JSONProjectStore.swift:2971` 預設 DisabledSyncMutationSink，取得 Application Support，再以既有 live 路徑建立 store。固定路徑與 disabled sink 只證明目前 composition，不證明磁碟內容歷史上从未綁定帳號。
- `JSONProjectStore.swift:2743` 的 revokeSessionWrites 關閉 sessionWork，沒有此入口的復原開關；`KnitNote/App/AppSessionOwner.swift:28` 的 beginTransition 會隱藏並停止舊 session。因此不能在網路準備開始時就呼叫這兩者，然後聲稱舊本機仍可編輯。
- `JSONProjectStore.swift:3209` 的 exportBackup 先要求 session write access，再註冊 backup work；返回時再次驗證。因此「先永久 revoke 再呼叫 exportBackup」在介面上就不成立。備份需在合法本機 session 下取得，並在實際安裝前重新驗證來源與備份的版本關係。
- `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift:291` 的 createPackage 已用 bounded regular-file 讀取、參照媒體列舉、大小預算與 manifest hash，最後 inspectPackage。可攜備份證明完整內容，不等同帳號資格、完整同步 metadata inventory 或持久接入 receipt，不能直接授予 bootstrap 寫入能力。
- `JSONProjectStore.swift:2756` 的 background drain 註解明確只證明已註冊工作結束，不代表完整跨程序 freeze、durable health 或 cleanup authority。

由上述證據推得的最小設計順序：先界定誰能簽發「合法未綁定來源」以及如何攔截已綁定/含糊來源；再設計來源變更偵測與保留備份的 prepare 階段；最後才加入短暫停止、完整重新驗證、原子接入及可重開 receipt。不得藉任意 caller URL/Boolean 或新寫入的空白標記繞過來源資格。

尚未解決的具體設計問題：舊版本沒有本次新接入 receipt 時，什麼既有正面證據足以簽發未綁定資格？本輪尚未證明有這種 issuer；不能把目前搜尋結果當作它不存在的全域證明。下一步限於追蹤既有 installation identity、account binding 與 bootstrap 來源 issuer，確認可重用的證據；若只能改產品規則或接受含糊來源，必須提出明確取捨讓使用者確認。沒有 implementation plan 或來源程式變更。

## 19:16 來源資格查核結論

完整閱讀 `SyncInstallationIdentity.swift`、`SyncAccountIdentity.swift`、`SyncBootstrapSourceAccess.swift`，並查核 `SyncAccountStorage.swift:191` 的 fresh allocation issuer：

| 現有證據 | 真正證明的事 | 不能推得的事 |
| --- | --- | --- |
| installation identity envelope v1 | 有效 UUID、版本及原子 no-clobber 本機建立 | 沒有 account/root/archive/history 欄位，不能證明 archive 從未屬於帳號 |
| SyncAccountIdentity | container 與精確 opaque user record name 的穩定 namespace hash | 是輸入識別值，不是舊 global store 的歷史歸屬認證 |
| freshAllocation source | native 本次確實建立 account root、驗證空 scaffold、綁定 inode/device/root/account，再同步寫入 recovery control | 只覆蓋新空 account namespace，不能用來承接已有 global archive 或聲稱它本來是空的 |
| SyncBootstrapSourceAccess | 在 exact storage/paths/account 原生 ownership 下讀取 account working set、inventory、pending 與 Watch 證據，再重驗來源 | 不接受 global local root，也不簽發 legacy adoption 資格 |

因此以上四個現有入口**均不能直接證明舊 global store 從未綁定**。這是對已讀入口的結論，不是對所有歷史版本的推測。只加 marker、呼叫 loadOrCreate、或先把資料複製到 fresh account root 都不能補上缺失的歷史證據。

### 接入設計的待確認邊界

依既定規格，先維持嚴格策略：來源含糊時不自動匯入任何帳號、不自動刪除，不改寫既有本機 startup。未來接入切片需要新的受審查來源認證/receipt 契約，或者針對無法認證的來源提供明確人工處理流程。若需放寬自動接入資格或新增人工匯入產品流程，這會改變資料安全/產品行為，須使用者確認，不能用一般技術委任自行批准。

本輪不再重複搜尋上述四個入口，也不寫「可用 caller Boolean」的空殼程式。先將此接入資格 gate 保留，下一個可獨立推進的安全工作改為首次 zone provisioning 的本機設計與官方 API 契約查核；正常 factory 仍不接線、不建立真實 zone。這可在不放寬舊資料規則的情況下繼續發布準備。完整接入實作計畫仍不得假裝已批准。

## 19:21 zone 盤點修正

後續找到 `CloudSyncEngineTransport.swift:472` 的 CKSyncEngine.PendingDatabaseChange.saveZone 與 `:1292` 的 reset 重排；所以前述未找到 CKModifyRecordZonesOperation 只代表該 API 搜尋沒有命中，不能解讀成整個程式沒有 zone 管理。真正缺口是 bootstrap 安裝前的 provisioning，而一般 engine 在安裝後才建立。已形成同目錄 `2026-09-09-bootstrap-zone-provisioning-proposal.md`，不重做既有日常 zone 管理。僅新增研究文件，沒有程式、測試或真實服務操作。
