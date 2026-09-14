# 首次 bootstrap zone provisioning：本機設計提案

2026-09-09 19:21 Asia/Taipei。基準 `1ca60ef2322e0bd024695b223d2654f23becff34`。狀態：研究與提案，未批准實作、未呼叫真實 CloudKit。

## 精確缺口

不是缺少所有 zone 管理。`KnitNote/CloudSync/CloudSyncEngineTransport.swift:472` 已在一般 transport start 排入固定 zone 的 saveZone，`:1292` 有既有 zone reset 重排。`Tests/KnitNoteAppTests/CloudSyncEngineTransportTests.swift:2963` 附近已有固定 zone、重複 ready 與 reset gating 測試。

但 `CloudAccountTransitionCoordinator.swift:273` 在 lifecycle 安裝成功後才建一般 transport；首次 bootstrap reader 在安裝前要讀既有 zone。因此缺的是前置的 provisioning 邊界。不能提前建一般 engine 來取得 zoneSave，因為會越過已核准的 handoff、journal/ACK/send 邊界。

## 官方/API 查核

- Apple 的 [CKModifyRecordZonesOperation](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordzonesoperation) 可保存或刪除 zone；本提案只允許保存一個固定 zone，delete array 必須為 nil/空，不暴露任意 database/zone 選擇。
- [modifyRecordZonesResultBlock](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordzonesoperation/modifyrecordzonesresultblock) 是整體結果回呼；原生 operation completion 僅用於確定工作排空，不能用它取代 zone/operation 結果驗證。
- [zoneNotFound](https://developer.apple.com/documentation/cloudkit/ckerror/code/zonenotfound) 表示指定 zone 不存在；[userDeletedZone](https://developer.apple.com/documentation/cloudkit/ckerror/code/userdeletedzone) 指使用者從設定刪除 zone。兩者不能直接當成「首次安裝且雲端沒有使用者資料」的證據。

網頁主要內容受 JavaScript/markdown 擷取限制，shell curl DNS 亦被限制。本輪完整閱讀本機 Apple SDK 原始 header：`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/CloudKit.framework/Headers/CKModifyRecordZonesOperation.h`，核對 save/delete 屬性、per-zone 回呼、partial failure 與 operation completion 用途。Swift refined 屬性確切拼字仍須實作前以安裝 SDK 的 interface/typecheck 核對；本輪未編譯。未由官方證據確認的重複 save/conflict 細节，不作成功保證。

## 三種路徑與推薦

1. **推薦：独立、預設未接線的 bootstrap-only provisioning driver。** 對已確認的固定帳號/zone 與當次 scope，透過受控 scheduler 觀察真實 operation 的回呼；成功後仍跑完整 nil-token zone reader，不直接簽發 snapshot/lease。邏輯不保存 domain records、不開 ordinary engine。先只設計與隔離測試，正式呼叫另需授權。
2. 提前啟動一般 CKSyncEngine：可以重用現有 zone queue，卻必須改變安裝前無 ordinary engine 的既定權限順序，回歸範圍更大，不採用。
3. 讀取遇到任意 zoneNotFound 就建立並自動重試：表面較少入口，但已失效 reader scope、使用者刪除/重設及首次建立容易混淆，不採用通用錯誤兜底。既有一般 reset 路徑不在這個切片重寫。

## 建議契約，尚非實作批准

- 單次 request 綁定 actual scope identity、帳號 container、private database 與 exact zoneID；不可只比較帳號 hash，也不可用 cached identity 啟動。
- 先驗證 request/scope，再排程僅一個 CKModifyRecordZonesOperation。設定所有 callback 在排程之前，scheduler 同時提供真實 completion adapter，沿用 reader 已驗證的受控測試方式。
- 成功必須有 exact zone 的保存成功、整體 operation 成功、真實 operation completion，且最後 scope 仍有效。foreign zone、缺 callback、重複 callback、late callback 或 partial failure 不能產生成功。
- 取消/帳號事件立即撤銷 scope，請求原生取消後等待真正 completion；取消不表示伺服器必然沒有建立 zone。不能補償性 delete zone，亦不能將 late success 套用到另一帳號。
- 釋放持有 storage/collector 的 consumer 必須在原生排空後；不能重現前一切片已修正的 canceled operation retention 問題。任何成功值都只是當次可繼續讀取的結果，不是永久存在證明、本機移轉資格或 ACK。
- 成功之後仍須完整 reader→下載前預算→owned combined validation→安裝→handoff。zone creation 不授予 legacy local source 資格。
- 最小切片不新增持久 receipt/wire，不改 ordinary reset、資料保留、版本、production factory 或 UI。程序中斷後不能依記憶體成功值跳過驗證；重試的 server duplicate-save 語義須先核對，不以 Boolean 宣稱 idempotent。

## 隔離驗收矩陣

| 情境 | 必須觀察 |
| --- | --- |
| 正確 zone 保存/整体/native completion | 全部到齊前無成功；完成後才允許 reader |
| 少 per-zone 或少整體結果 | native completion 不能冒充成功 |
| foreign/重複/late 回呼 | 拒絕並撤銷，無新 reader/engine/ACK/send |
| partial failure/網路/帳號錯誤 | 原錯誤保留、不建 placeholder、不刪 zone |
| 排程前/執行中取消、帳號 A→B | 只等 A 原生 drain；A 成功不能授權 B |
| 真實 completed operation 被測試保留 | drain 後不額外持有帳號 storage |
| provisioning 成功而 full reader 失敗 | 無安裝、無 ordinary engine；保存本機來源 |
| normal shipping/screenshot startup | provisioning/live database factory 呼叫數為零 |

## 下一步及不可越過的關卡

這份提案可供下一步正式架構規格使用；不直接作 implementation plan。先核對 SDK refined Swift callbacks、重複保存 zone 的官方語義與現有 scope 型別，完成精確規格與必要設計批准。使用者已委任一般技術選擇，但沒有授權真實建 zone、接入含糊舊資料、正式啟用或發布。

舊資料來源認證仍是獨立 blocker，詳見同日 activation-gap-inventory。即使本提案的本機 driver 通過，也不能宣稱首次升級同步已可用。後續實機/schema/Keychain/Watch/隱私/商店候選證據仍需完成。

## 19:27 SDK 核對與提案收斂

已讀本機 SDK `CloudKit.swiftmodule/arm64e-apple-macos.swiftinterface:1123` 至1141：Swift 屬性為 `perRecordZoneSaveBlock`，參數是 exact zoneID 與 `Result<CKRecordZone, Error>`；整體是 `modifyRecordZonesResultBlock` 的 `Result<Void, Error>`。不採不存在的 perRecordZoneSaveResultBlock 名稱。這是 interface 唯讀核對，不是 compile 或 live test。

同 SDK `Headers/CKRecordZone.h:107`、`:119` 明確說明既有 zone 應以 CKFetchRecordZonesOperation 或 database fetch 取得，不應用 initializer 建立代表既有 zone 的新物件。Apple 網頁 [CKRecordZone initializer](https://developer.apple.com/documentation/cloudkit/ckrecordzone/init(zonename:)) 有相同指引。因此不能把 blind save 當成已證明的無條件 idempotent 行為。既有一般 transport 使用 CKSyncEngine pending database changes 是不同整合路徑；本輪不依此觀察判定它有 bug，也不改寫它。

推薦方案收斂為 **bootstrap-only、fetch-first**：

1. 在有效的固定帳號/zone scope 下，只取得該 zone；成功必須驗證 exact identity 及完整 native 結果/排空，既有 zone 不需重存。
2. 若確實不存在，只有明確的首次 provisioning admission 才能發出 save；zoneNotFound 本身不是「可重建曾刪除資料」授權。這個 admission 來源仍須在正式設計說清，不可留成任意 Boolean。
3. 若已發出 save 後結果不明，後續重試重新查 zone，不盲目反覆 save，也不自動刪除補償。並發建立/消失仍可能發生，fetch-first 不等於消除競爭；只能由實際結果與有效 scope 判定下一步。
4. userDeletedZone、未知來源/歷史及無法判定帳號先保留錯誤，不走新建兜底；既有已安裝帳號的 ordinary reset 規則保持原樣。本切片不得暗中改變既定 reset 產品政策。
5. 只有當次 zone 取得/保存證據通過，才進入既有完整 reader；讀取若隨後發現 zone 消失，仍是讀取失敗，不可發布空快照。

矩陣另加：既有 zone 時 save呼叫0、fetch失敗時save0、僅zoneNotFound但無admission時save0、帳號切換後save0、save結果遺失後重查、兩設備建立競爭、取得後立即刪除而reader失敗。重試不增加一般 ACK/send 或資料清除能力。

此研究階段至此已形成具體架構選擇與驗收條件，不再為排程重做相同 API 搜尋。下一步需確認正式規格的來源/admission 邊界後才能寫 implementation plan；目前保持提案，不簽發假權威、不操作正式服務。
