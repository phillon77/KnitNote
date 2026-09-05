# 同筆資料上傳衝突的安全重整設計

日期：2026-09-06

狀態：使用者已確認兩段口頭設計；本書面規格待審閱。尚未編寫實作計畫或修改程式。

文件基準：`8bd1ed785dc7d09ace4b339a91e6d0f4cda9c911`，linked worktree `.worktrees/cross-device-sync-design`，branch `docs/cross-device-sync-design`。版本維持 **1.7.0（13）**。

既有完成驗證的 source/test candidate 是 `c7465f8b5282e07852afe6840a7d284c705f83ba`：完整 Core 2,369 tests／174 suites、無宿主整合 136 tests／5 suites、macOS／iOS 無簽章編譯通過。這是前一階段證據，不代表本規格已實作或通過真機驗收。

## 1. 目的與不變界線

完成上傳遇到 `serverRecordChanged` 時的「讀取伺服器紀錄 → 依既有規則合併 → 安全替換同 record 的待同步內容 → 耐久提交 → 允許重試上傳」。本機在此期間的新編輯不能被過時候選覆蓋，其他紀錄的 FIFO 不能被重排或改寫。

沿用既有 merge engine、canonical checkpoint、publication transaction 與 journal，不增加第二套 archive writer 或獨立衝突修復資料庫。一般本機 enqueue 的不可變 payload／重複 ID 防護不能因支援 rebase 而放寬。

本輪只做核心與實際來源無宿主整合。不啟動 App host、正式 CloudKit、Keychain 或使用者資料；不增加衝突畫面、UI／Watch 正式接線、完整刪除媒體／永久標記傳輸；不改購買、語系、版本、簽章或發布設定，不 merge、push、upload 或 submission。正式同步仍停用。

## 2. 已核對的現況

- `JSONProjectStoreRemoteBatchCommitter.commitServerRecordChanged` 目前明確拋出 `unsupportedConflictReplacement`。
- coordinator 已收取 failed mutation／attempt、伺服器 record，逐筆重整同 record FIFO，再交付預先合併的結果；目前 expected queue 只含 identities，重試使用無界 `while true`。
- `FileSyncMutationJournal` 的一般 enqueue 拒絕同 mutation ID 的不同完整 proof；exclusive lease 目前只提供讀取與追加，沒有正式替換操作。
- transport 已有 failed queue replacement 與 upload attempt 追蹤，但最後交給 coordinator 的成功事件只有 record／mutation ID。支援保留 mutation ID 的 rebase 後，不能假定這些 ID 單獨足以授權 ACK。
- 既有 remote publication 已提供完整前驅、候選、附件證據、鎖定與恢復；其 append 語意不能直接冒充 queue replacement。

## 3. 合併語意與方案

採用既有交易擴充衝突來源與明確的 journal CAS replacement。獨立 repair ledger 會增加多一套恢復與清理排序，因此不採用；逐筆呼叫 UI 編輯 API 則會重新發行 mutation，無法保留原 FIFO，也不採用。

既有產品規則不變：不同欄位逐欄合併；同欄位依既有完整 mutation stamp 排序，不僅依設備牆鐘；相同 stamp 卻有不同 payload 明確拒絕／隔離。計數器的絕對值不相加，Watch command／processed proof 不回退，附件保留不可變版本與既有並行衝突語意，不就地改寫照片內容。

重整處理失敗 head 及其後同 record 的每個 pending mutation，逐一以先前合併結果作為基底套用下一份不可變本機版本。不能只合併 head、只使用畫面目前值、或把多次編輯壓成最後一筆。每個項目保留 recordID、mutationID、intent 與原全域 FIFO 位置；只有具有本次證據授權的 save payload／相關已驗證附件來源能改變。

完整 domain 候選以啟用中的完整 canonical state 為基礎，結合重整結果及實際關係／附件規則；局部 server record 或預先計算的 merge result 都不是完整 archive。未涉及紀錄、墓碑、附件歷史、接收批次 receipts、永久刪除標記與 Watch 證據須保留。

## 4. 責任分界與可驗證輸入

### Coordinator／App adapter

傳遞原始 server record，而非只傳遞 `mergeResult`；輸入綁定已驗證帳號／zone、失敗上傳 attempt、失敗 mutation 的完整版本，以及完整預期同 record FIFO（包含 payload 與順序）。record ID、帳號或失敗 head 不相符時拒絕，不能用事件所附 ID 自行建立可信帳號身分。

App adapter 負責驗證 epoch、在鎖外取得必要的已驗證附件來源、呼叫 Core 準備及同步提交。Core 不依賴 CloudKit 型別；transport 繼續擁有伺服器 system fields／change tag 與 attempt 綁定，不能拿另一帳號或不相符伺服器版本的 system fields 重試。

### Core preparation／commit

Core 自己讀取完整 canonical、archive、精確全域 pending、Watch／附件／刪除 authority，驗證原始輸入並計算候選；不接受 caller 任意製造的「已合併成功」結果。準備物件不可由外部直接建構。

候選包含同 record 完整前後 FIFO、全域位置、完整 domain／canonical、必要媒體與證據，以及交易來源。以確定性編碼摘要綁定全部內容；相同交易身分但不同來源或候選拒絕。帳號 scope 不由 server payload 推定。

提交時重新比對完整前驅及所有需要的 authority。一般操作的邏輯線性化順序沿用 account epoch → process coordination → journal parent flock → publication/checkpoint/evidence locks。最終檢查與持久寫入均在 `accountEpoch.withCurrent` 的同步區間；不能 await、遞迴呼叫 public journal API 或在 epoch lock 內呼叫外部通知。

### Journal

增加只供持有有效 exclusive lease 的正式 replacement 操作：精確比對 expected 同 record FIFO 的全部內容、相對／全域位置與前驅 proof，且第一筆必須是指定 failed mutation。替換一整組或拒絕，不逐筆公開半套結果。不動無關項目的內容、identity 與順序。

以原生 journal 持久化一個可驗證的 rebase transition，綁定完整前後 proof、交易身分與順序；恢復／compaction 亦保留必要的授權鏈。ordinary enqueue 仍不能以同 ID 注入另一 payload；舊前驅 proof 不能被解讀成目前版本已 ACK。重播同一已完成 transition 必須冪等，矛盾 transition 拒絕。

原有 frame／checkpoint／proof 格式保留精確解碼及嚴格驗證；新增 replacement 編碼須明確區分，不重新解釋舊 frame。新增 publication conflict source 使用明確升版格式，保留既有格式 2–6 的原解碼及恢復語意。具體 wire 欄位與 migration fixtures 必須在實作計畫列清楚，不能直接修改既有 literal fixture 使測試通過。

## 5. 競態、容量與錯誤

- 準備後若 local edit、Watch command、ACK、另一 rebase 或 canonical／archive／附件 authority 改變，返回 stale；丟棄候選並從新的完整狀態重算。不能只比 identities，也不能忽略全域交錯 FIFO。
- 每次事件處理最多嘗試 **3 次完整準備／提交／transport 協調**；共用一個預算，不讓 adapter 與 coordinator 各自三次形成九次，不保留無界 `while true`。超限保留待處理狀態；下一次明確重試或合法後續同步事件才重新取得預算，不自動自旋。
- 已失效帳號立即終止該事件，不對新帳號寫入、ACK 或發布。已不再是當前 head 的過時事件不修改任何紀錄。
- 缺 server record、父關係、必要媒體、刪除 authority、journal proof，或相同 stamp／immutable version 衝突，都不能回傳成功或排程未驗證 replacement。
- raw delete／未知刪除不得因 conflict error 就獲得額外授權；只有既有可證明的 deletion／legacy cleanup 契約可以通過。完整刪除 transport 仍是後續關卡。
- 保留現有 **100,000,000-byte** authority／verified-file 上限、journal 個別結構上限及附件檔案安全限制。完整前後 FIFO、來源、候選與媒體 evidence 必須在意圖前完成編碼／大小／一致性預檢；達界限安全拒絕，不分批暴露半個 replacement，也不丟歷史 proof 騰空間。

## 6. 耐久交易與重新開啟

交易完整性指多檔案可恢復提交，不宣稱跨 archive／journal／checkpoint 是單次原子 rename。使用既有 publication intent 保存重建所需的原始 conflict、前後 queue／proof、完整前驅／候選與媒體。只有完整已驗證證據允許完成候選。

| 中斷位置 | 必須成立的結果 |
| --- | --- |
| 意圖落盤前 | 正式 domain、queue、proof 不變；不能通知 transport 使用 replacement |
| 意圖落盤後、任何候選寫入未完成 | 保留意圖與來源；阻擋一般寫入／未完成狀態發布，重新開啟先依證據完成或拒絕 |
| journal replacement 已落盤、checkpoint 未完成 | 辨認同一 transition，不能再替換一次或把新版 proof 當作外來資料清掉 |
| Core 完整提交、transport 尚未接受 | Core 不回滾；重開後以 journal 的當前已授權版本重新建立上傳 queue，不能恢復過時 payload |
| transport 接受後收到舊事件或再次中斷 | attempt／版本驗證拒絕過時成功與失敗事件；不重複套用 domain 或刪除新版本 |

journal 不見、退回舊 checkpoint、partial frame／temp、symlink／inode 替換或不相關後續寫入，都不能被當成這筆 transaction 已完成。恢復須分辨精確前驅、精確候選及具有持久證據的合法後續 ACK／append／rebase；無證據則保留並拒絕，不猜測復原、不任意清檔。

不建立永久無界的已處理 attempt set。重複事件正確性依持久 transition／當前 mutation version 與 transport attempt 驗證，而非 coordinator 的記憶體快取。歷史證據依 journal 既有有界編碼／分段及明確 compaction 契約保存；若不能安全回收就拒絕新增，不默默淘汰未完成依據。

## 7. Transport 接續與 ACK 安全

Core 成功只代表本機交易完成，不是雲端已接收。返回完整已提交 replacements 與可核對的版本／交易依據，coordinator 才能讓 transport 接受精確新 queue。transport 接受前再次驗證當前帳號、failed attempt 與對應 queue 版本；不能只驗證 identity prefix／count 後清掉 blocker。

若 transport 在 await 前後看見不同 queue、generation 或已被取代的 failed attempt，回報 stale／明確失敗；不得把新版本與舊尾端混搭。已落盤的 Core 交易不回滾，後續從當前持久狀態接續；只有 transport 確認接受正確版本後才清除此衝突 blocker。

成功 ACK 必須綁定實際送出的 mutation 完整版本與 attempt，並由 journal 在互斥區內核對目前授權版本後才移除 pending。只帶 recordID／mutationID 的過時成功事件，不足以 ACK 已 rebase 的同 ID 新內容；必要時擴充成功事件／ack 介面及所有實際 conformers。附件 staged bytes 清理也只能在正確版本 ACK 與既有 reference-safe proof 成立後進行。

只有實際 domain 變動才在 ownership lock 釋放後發布既有 generation 通知。metadata-only、重播與 transport 重試不重新發行編輯、不重做 Watch 命令。跨程序通知不承諾恰好一次，domain 效果必須可冪等恢復。

## 8. 驗收矩陣

使用實際 store／mapper／merge engine／journal／checkpoint／附件檔案與無宿主 coordinator／transport，帳號及伺服器以隔離測試介面驅動。完整 expected records、checkpoint、pending payload／proof、檔案 bytes／身分及 callback 次數作 oracle，不只比較 ID、名稱或 item count。

1. 不同欄位與同欄位兩端修改，兩端結果遵循相同 stamp 規則；equal-stamp corruption 拒絕且原資料保留。
2. 同 record 三筆以上連續 save，穿插另一作品 mutations；每筆重整內容正確，全域位置與不相關 payload 精確不變。
3. 準備期間新編輯、Watch 命令、ACK、另一 rebase，包括 identity 不變但 payload 改變；過時 CAS 不能通過，最多三次後停止。
4. 普通 enqueue 仍拒絕同 ID 不同 payload；唯有完整授權 transition 能替換。transition 重播、compaction、ACK 後重新開啟仍正確辨認版本。
5. 舊 attempt 的成功／失敗事件晚於 replacement 到達，不 ACK／覆蓋新版；正確新版成功才移除。Core 提交後 transport 失敗、reset／recreate、重複事件均不丟資料。
6. 各 durable file／intent／archive／journal／checkpoint 邊界注入故障，丟棄全部 store/journal/checkpoint handles 後連續兩次 fresh reopen；只能精確完成原交易或保留證據拒絕。
7. 缺／舊 journal、損毀 proof、partial temp／frame、目錄或媒體替換，拒絕時完整 authority 不變。合法後續 ACK／compaction 不應被錯擋。
8. 附件 immutable history、metadata-only live overlay、並行版本／必要父關係、缺媒體及未證明刪除；不遺失 history、不改 byte cap、不越權 cleanup。
9. 帳號於準備前、await 後與最終邊界失效，對錯帳號零寫入、零 ACK、零通知；callback 不在 epoch lock 內造成重入死鎖。
10. 新舊 transaction／journal 格式固定 fixture 精確解碼、非空歷史資料遷移、容量臨界與超限預檢；未確認 proof 不為容量被淘汰。

驗證依序為針對性 RED／GREEN、實際來源無宿主整合、程式覆核與修正，最後凍結同一 source/test candidate 跑完整 Core 及 macOS／iOS 無簽章建置。完整 Core 使用 arm64、沙盒外受控執行及 1,800 秒 owned-process-group 上限，避免已知 Xcode settings／socket 沙盒限制；超時／失敗必須照實記錄。覆核後若再改 source/tests，重新綁定驗證，不能沿用舊候選宣稱成功。

## 9. 完成定義與後續關卡

本階段完成代表真實 conflict adapter、完整 queue CAS、版本綁定 ACK、可恢復交易與上述隔離驗收有證據，不再是 unsupported stub。只完成部分 journal 或使用成功替身不能結案。

仍未完成的正式 lifecycle ownership／freeze、UI／Watch 接線、完整刪除媒體／marker transport、pre-ACK reset 收據協調、效能、真實 CloudKit／程序終止／各裝置與 extension 驗收，都保持明確 release gates；不因本階段通過而啟用同步或送審。

下一步須先由使用者審閱本書面規格，再編寫具體實作計畫。計畫必須列出新舊格式／proof 遷移、raw conflict 介面、完整 FIFO CAS、ACK 版本驗證、恢復與有界重試的工作項目，以及真實 conformer／Xcode consumer／測試檔案範圍。
