# Legacy 匯入持久交易與原生安裝設計

日期：2026-09-10。基準：`378478c4dc1387ef63320db621f67c6f5a43a49a`。

狀態：使用者已確認沿用原生交易、恢復規則及寫入順序；最後驗收段提出後，使用者表示「我出門了，你來決行」。控制者據此代決行本文件與本機驗證順序，不另等待逐段確認。這不是正式啟用或發布批准。

## 1. 範圍

沿用 `SyncBootstrapOwnedTransaction` 的受控輸出、安裝、journal commit、回復及 handoff；不建立第二套搬檔交易。新增 legacy 匯入所需的必填內容綁定與來源能力，普通 bootstrap 保持原有語義。

上位契約：`2026-09-09-legacy-local-import-safety-design.md`。來源觀察與一次性確認已完成的範圍以 `../reports/2026-09-09-legacy-import-source-observation-verification.md` 為準。本文件不追認歷史測試為當前候選證據。

## 2. 不變量

- 版本維持 1.7.0 (13)；最低 iOS 18、macOS 15、watchOS 11。
- 無新增套件、帳號、網路傳輸、CloudKit schema、Keychain 或真實使用者資料操作。
- shipping、screenshot、Watch 與 Share 啟動不接入新匯入能力。
- 原始內容、成功備份及復原證據不因取消、失敗或空間不足而刪除。
- caller Boolean、URL、帳號 hash、UUID、可解碼紀錄都不是來源／安裝／清理權限。
- 本機提交與雲端同步是不同狀態；不宣稱已推送、上傳、送審或發布。

## 3. 實際原生邊界

`SyncBootstrapSourceAccess` 僅能在原生 account owner 下讀取該帳號 working set；不可把 global legacy 路徑塞進此 API。`LegacyImportPreparationCoordinator.confirm` 的 Bool 僅代表意圖，不能作為安裝入口。

`SyncBootstrapOwnedTransaction.InstallOwner.commit` 的順序是完整 journal program、驗證 prefix、讀取 receipt、`afterReceipt`、再次驗證 prefix，最後才持久化 `.committed`。因此 receipt 存在但 phase 仍為 installed 時，重啟應回復，不能發布 handoff。

目前 V3 decoder 檢查欄位與版本；來源 proof 表示目的帳號原始 working set，不可替換成外部 legacy digest。新匯入需要分開記錄兩種來源意義。

## 4. 格式決策

新匯入使用 owned manifest **version 4**，同一原生 selector namespace 與原子出版機制。V3 普通交易讀寫維持既有規則；不在 V3 放 optional legacy 欄位，也不把新 binding 放在未被 manifest 納管的旁檔。

V4 根節點沿用 V3 的 id、context、livePath、journalPath、sourceProof、original、historyHead、body，新增必填 `operation = "legacyImport"` 與必填 `legacyImport`。所有未知欄位、未知版本、缺失、null、非法長度或交叉綁定不符均拒絕。V4 不提供 ordinary 分支；普通 bootstrap 仍用 V3。

`legacyImport` 內容的 version 固定 1，欄位如下：

| 欄位 | 規則 |
| --- | --- |
| transactionID | 與 manifest.id 完全相同的 UUID |
| targetAccountIDHash | 與原生 context.accountIDHash 完全相同的 64 位小寫十六進位 hash |
| sourceContentSHA256 | 32 bytes，原生 legacy source observation 的內容投影 |
| backupContentSHA256 | 32 bytes，受驗證 backup 的同一內容投影，必須等於 sourceContentSHA256 |
| backupManifestSHA256 | 32 bytes，實際備份 manifest bytes 的 hash，不冒充內容投影 |
| preparationID | 当次隔離準備 UUID，僅供關聯，不授權重啟後繼續未提交匯入 |

來源與備份的原始路徑、Apple ID 郵件及可重播的「同意 true」不寫入此 wire binding。來源 session、target epoch 與 freeze 是當前操作驗證的一部分，歷史值不會簽發新權限。

binding 必須被準備摘要、immutable output、每次 phase 出版、history terminal envelope、account inventory、authenticated recovery、committed handoff 全部涵蓋。任何一路仍僅接受 V3 時，新交易禁止發出，而非在該處降級。

## 5. 來源能力與證據保留

來源讀取必須由合法現行本機 store/session owner 發出不可公開構造的受控能力。能力使用時重驗 owner、路徑與檔案身分、內容投影及 session generation；它不證明「歷史從未綁帳號」。目前來源 observation 沒有這種 issuer，不能直接升格。

準備成功的備份內容複製到原生交易納管的不可變證據角色；新增角色 `LegacyBackup` 納入輸出 allocation、容量預算、exact inventory、abort freeze、history 及 authenticated archive。副本必須經實際 manifest／payload 驗證並匹配 binding；原成功備份仍保留。來源同步 journal、Watch pending/prepared/ACK、key、epoch 不複製為目的帳號權限。

只有全部來源能力、V4 原生讀寫、證據角色、容量及恢復路徑完成後才可發出 V4 preparing。不是先寫準備 marker，再補權限。初期只允許隔離 fixture owner；正式 issuer 需另外驗證 App session/帳號整合。

若現有 pending Watch/counter 狀態無法安全分離，拒絕這次匯入並保留來源，不默默改綁或清空。完整圖、UUID、欄位合併、附件衝突、刪除證據與 counter/reminder 規則不變。

## 6. 寫入順序

1. 合法來源觀察、完整備份、目的帳號隔離合併；不移動目的 live 或撤銷原本可用的來源編輯。
2. 目的帳號原生 owner 必須在 plan／preparing 前已持有有效 target epoch／freeze，並在 prepare／install／commit 全程重驗；不是只填入 freeze UUID。建立包含必填 binding 及輸出預算的 preparing，透過既有同步／原子 selector 出版；完成不可變 LegacyBackup 與 staging、whole-graph 驗證後出版 prepared。此目的端凍結不等於提前永久撤銷來源 legacy store。
3. 使用者確認僅在本程序當前 proposal／source／backup／target generation 下有效。進入提交前對 legacy 來源停止 producer、等待實際工作排空，再重驗來源、備份及仍有效的目的帳號凍結。來源改變則不安裝，不因目的已 prepared 而跳過重新確認。
4. 原生 install 執行 source spend（若目的原本 absent）、live→Displaced、staged→live、installed。Original 是準備時已建立的不可變副本，不是 live rename 目的地；回復由 Displaced 還原 live。來源 legacy 本體與原成功備份不參與搬移。
5. 原生 commit 在既有 native lock 下執行 journal program。receipt 的新版本必須含 manifest 的 binding digest，並保留原 transaction/account/sourceProof 對應；舊 receipt decoder 不得把它當舊格式成功讀取。完整 prefix 和持久 phase 同時驗證後才是 committed。
6. 原生 handoff 再驗證 committed manifest、binding、LegacyBackup、receipt、canonical、journal、附件與 source-control/history。當前帳號仍有效才發布新 session。

receipt 新 wire 明確使用必填 `formatVersion: 3`（不是 `version`），根欄位只有 `formatVersion`、`transactionID`、`accountIDHash`、`sourceProof`、`legacyImportSHA256`。`sourceProof` 使用與 manifest 相同的 tagged object：archive 為 `kind: "archive"` 加 `sha256`；missingArchive 為 `kind: "missingArchive"` 加 `treeSHA256`，不混用舊 receipt 的扁平欄位。`legacyImportSHA256` 為 32 bytes，值為 canonical encoded legacyImport object 的 SHA-256。所有欄位必填，未知／缺失／null 欄位、錯誤摘要或與 V4 不匹配均拒絕。歷史 receipt 版本 1/2 僅供既有非 V4 路徑，保持其現有格式：版本 1 沒有 formatVersion，版本 2 才明寫 formatVersion。binding canonical encoding 沿用 OwnedBootstrapCodec 的 sorted-key JSON 規則，Data 為 base64、UUID 為標準 UUID 編碼；digest 是完整性關聯，不是簽章或認證。

## 7. 中斷、取消與重開

- preparing 中斷：原生 abort 凍結已產生的實際輸出；缺檔不能被假造為完整備份。
- prepared／installed／rollingBack：依真實 placement/prefix 安全回復；保留失敗輸出及原資料。receipt 已存在也不得判成 committed。
- committed：驗證全部原生證據後恢復同一交易；不重跑 prepare/import，不增加重複 journal mutation。
- 取消／A→B／A→B→A：立即撤銷新發布與傳輸；等待實际 native 工作結果。舊 callback 不可修改新 generation。未提交嘗試重啟後重新確認，不重播記憶體同意。
- 檔案遺失、損毀、錯帳號或未知格式：拒絕接入，保留現場，不自動修補摘要或刪除紀錄。
- 不能僅以「cancel 已返回」或「臨時目錄消失」斷言交易已排空或復原成功。

## 8. 容量與舊版安全

沿用既有每檔及累積預算；新的 manifest、備份副本、history/abort/rollback 最壞 prefix 必須在開始任何输出前計入。legacy source projection 上限 1,000,000 bytes、directory inventory 上限 4,000,000 bytes；原生 recovery 單次上限 100,000,000 bytes，不因新角色調高。容量 exact 與 +1 拒絕都需實測。

2026-09-10 相容性修訂：使用者在「保留原始資料與備份，不支援舊開發測試版直接開啟新版同步資料」的建議後回覆 `go on`，確認採用此方向。修訂前的開發測試 binary 不在 V4 帳號儲存的直接降版支援範圍，不能宣稱修改新 reader 能保護已存在的舊 binary。原始 legacy 資料與成功備份仍須保留；這項決策不授權刪除、覆寫或自動把新版資料轉回舊版。

本次維護的 reader（包含仍存在的 legacy open/recovery/archive/cleanup 入口）面對未知或未完整支援的格式，必須在改寫、建立會話或清理前拒絕。單獨 decoder throws 不足；需驗證實際入口與完整檔案／目錄現場不變。完整支援 V4 的 verified 路徑才可處理 V4；不支援 owned 格式的相容入口可以直接拒絕該格式，不降級處理。如果本次維護的任一路仍能清掉未知 evidence，V4 issuer 維持停用。

本機 `v1.6.0-build12` 標籤未包含這套帳號儲存程式，但標籤不是已發佈 binary 的證明。正式接線前須核對實際升級來源；不得把上述開發版降版限制擴張成免除正式版升級或資料保留驗證。詳見 `../reports/2026-09-10-v4-integration-preflight.md`。

## 9. 驗收矩陣

真實子程序在 preparing 出版、部分 output、live move、staged move、installed、journal 各持久 prefix、receipt 後 committed 前、committed 後 handoff 前終止。父程序從同一路徑重新開啟，不重建 fixture。process termination 不等於模擬斷電，另用 write/file-sync/parent-sync 注入補測 durability。

每個 case 檢查原資料、成功備份、原生證據、journal、receipt、canonical 與結果；驗證未提交回復與提交後重開兩條路。錯帳號、缺／損毀 binding、receipt、LegacyBackup、附件、history；來源新編輯與身份替換；重複點擊、A→B→A、late callback 與 drain；容量 exact/+1；本次維護 reader 的未知格式證據保留（不宣稱歷史開發 binary 已修復）；Watch pending 不改綁。正式 factory 呼叫數維持零。

## 10. 本次先執行的原生提交邊界驗證

V4 的 source issuer 與多個原生 reader 必須整體協調，不適合先用一個 optional 欄位接線。本次可獨立完成且直接服務上述契約的工作，是在現有 V3 原生交易上補齊 receipt／committed 真實程序中斷對照，包含非空內容與 journal、同一路徑第二次重開、不重複 mutation、缺損 receipt 拒絕且保留證據。

此基準工作只新增測試，不新增安裝入口或 wire 格式，亦不代表 V4 已實作。下一份原生整合計畫必须一次涵蓋 V4 issuer、所有 reader/history/inventory、LegacyBackup 與 receipt，而不是只交付可被呼叫者構造的資料模型。

## 11. 自我審查

已核對：目的 sourceProof 與 legacy 內容證據分離；receipt 不等於 commit；確認不是能力；新版本缺失不降級；備份證據由 native inventory 納管；版本與發布界線不變。V4 僅是本文件決策，現在不發出新格式。第 10 節驗證有獨立計畫及結果記錄，與後續整合完成度分開。
