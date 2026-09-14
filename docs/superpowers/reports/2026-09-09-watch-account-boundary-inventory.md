# Watch 跨帳號啟用門檻

2026-09-09 19:31 Asia/Taipei；基準1ca60ef2322e0bd024695b223d2654f23becff34。唯讀盤點，沒有協定改動或實機操作。

## 已核對的實際邊界

- `Sources/KnitNoteCore/WatchSync/WatchConnectivityEnvelope.swift:11` 包含 snapshotRequest、snapshot、command、acknowledgement、queueHandshake；handshake payload 是 UUID array，不是帳號/會話綁定證據。
- `WatchSyncModels.swift:267` 的 snapshot schema4 含生成時間、entitlement、projects、language；command 的欄位在`:329` 起是 command/project/counter UUID、操作、reminder payload、createdAt。這兩個 wire 模型沒有 account binding 或 epoch；acknowledgement 在`:429` 也只有 commandID/rejection/snapshot。
- `KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift:63` 以 isStopped、callback gate、取消訂閱/工作和 native drain 停止舊 coordinator；`:234` 的 enqueue/handle 會拒絕已停止實例。這是有效的本機停止邊界，不是新實例收到指令時的來源認證。
- `PhoneWatchSyncCoordinator.swift:281` 把收到的 command 交給固定 projectStore 的 durable apply；`:343` 的 queue handshake 以 UUID 清单進行既有 persistence recovery。不能藉 project UUID 相同、時間較新或成功握手推定它屬於新帳號。
- `KnitNoteWatch/Sync/WatchSyncCoordinator.swift:278` 經 optimistic state 驗證 ACK，保存 candidate cache 後才移除 delivery；`:300` 的 handshake 送 pending command IDs。這些耐久性與重播規則必須保留，但目前不是跨帳號協定。

本輪沒有重跑測試，也沒有宣稱實際發生跨帳號誤寫。正常 App 仍是 local-only Watch route，已核准上位生命週期規格本來就禁止在新協定證據完成前開放真實跨帳號路徑。

## 必須由下一個架構設計涵蓋

1. phone 簽發且持久保存的 opaque binding/epoch、Watch 實際接收並保存的證據，以及 command/snapshot/ACK/handshake 全鏈條的 exact binding。不能傳原始 Apple ID，不能把隨機 token 本身叫作加密認證。
2. 舊版 Watch cache/佇列無 binding 時不自動補上目前帳號；新 phone/舊 Watch、舊 phone/新 Watch、同版本重開及 A→B→A 的明確相容策略。
3. 帳號失效時 phone 本機立即 stop；手錶離線時無法證明遠端內容清空，不能顯示已清除或丟棄原帳號未確認指令。
4. 重連握手需確認對應 binding，再開放新 commands；舊帳號 snapshot/ACK/command 遲到不得覆蓋新 cache 或解除新隊列。原帳號待送資料如何保留/恢復不能靠 UUID 猜測。
5. 新 wire/schema、cache migration 與使用者可見的未配對/待更新狀態，需要獨立規格、實作計畫及候選驗收，不能納入小型 stop helper 修正而略過。

## 必要隔離與實機矩陣

| 情境 | 必要證據 |
| --- | --- |
| A 的 command 在 B 的新 coordinator 才送達 | B store/journal 完全不變，A pending 不被假 ACK 移除 |
| A 舊 snapshot/ACK 晚於 B 握手 | B cache/queue 不退回 A |
| 同帳號重開與重送 | 原有 exactly-once、revision、reminder 規則保留 |
| 混合版本/無 binding 舊佇列 | 明確不可寫狀態，不改綁、不靜默清空 |
| phone 切帳號時 Watch 離線 | 不聲稱已遠端清除；重連才取得新狀態證據 |
| 真實 iPhone/Watch 加上 iPad/Mac 變更 | 同一候選實機驗收，不用 mock pass 代替 |

## 結論

此項需要新的跨裝置協定與舊版相容設計，已超出前一個不改 wire 的 bootstrap bridge 切片。可自行做的唯讀盤點已完成；不能僅把既有 Watch coordinator 接進 account factory 就宣稱完成。保留為重要設計確認項，不在無具體授權下修改 wire、設備或正式資料。
