# KnitNote 1.0 HISTORICAL 定價與上架執行紀錄

> **DO NOT USE FOR 1.2**
>
> 本檔以下內容只保存 1.0 付費下載的歷史紀錄，不能作為 1.2 的
> App 或 IAP 設定來源。1.2 將 App 改為免費下載（free app），並使用
> non-consumable `com.phillon.KnitNote.lifetimeUnlock`：launch price
> US$2.99，later price US$4.99。唯一可執行的 1.2 checklist 位於
> [`AppStoreSubmission.md`](AppStoreSubmission.md)，所有 App Store
> Connect 寫入目前仍為 `PENDING`。
>
> **SAFETY GATE:** 修復版 binary 與第一個 non-consumable IAP 均獲
> Apple 核准前，不得把目前付費下載的 App 改為免費，也不得執行任何
> free-app price change。

最後更新：2026-07-24

## 1.0 HISTORICAL 已決定的商業模式

- 販售方式：付費下載、一次買斷
- 訂閱：v1 不提供
- App 內購買：v1 不提供
- 首發優惠：美國商店 US$2.99，其他地區採 Apple 對應價格
- 正式價格：美國商店 US$4.99，其他地區採 Apple 對應價格
- 優惠期間：App 公開上架日起 30 天
- 第 31 天起：調整為 US$4.99
- 未來 AI 功能若產生持續成本，另行設計付費方案，不影響 v1 一次買斷內容

## 1.0 HISTORICAL App Store Connect 設定

- [x] 建立 KnitNote App 紀錄（Apple ID `6793023054`）
- [x] 註冊並確認 Bundle ID 為 `com.phillon.KnitNote`
- [x] 設定 SKU 為 `KNITNOTE-2026-001`
- [x] 建立 iOS 與 macOS 1.0 版本
- [x] 確認「付費 App 合約」有效（2026-07-21 至 2027-07-02）
- [x] 確認銀行帳戶狀態為「使用中」
- [x] 確認台灣稅務表格、美國外國受益人證明及 W-8BEN 均已完成
- [x] 確認歐盟《數位服務法》合規已通過審查
- [x] 將初始 App 價格設為以美國為基準的 US$2.99
- [x] 確認台灣自動換算價格為 NT$90
- [x] 設定在所有 175 個國家或地區於 App 發佈時供應
- [x] 送出 iOS App 審核
- [x] 確認實際公開上架日期
- [x] 排定公開上架第 31 天調整為以美國為基準的 US$4.99
- [ ] 檢查是否符合並已加入 App Store Small Business Program

2026-07-24 已由 Apple 公開查詢資料確認 iOS 1.0 上架；首發價格為美國 US$2.99、台灣 NT$90，並於 175 個國家或地區供應。App Store Connect 已排定 2026-08-23 起永久調整為美國 US$4.99、台灣 NT$150，其餘地區採 Apple 同等價格。

## 1.0 HISTORICAL 調價日期記錄

- 實際公開上架時間：2026-07-24 18:24:59（Asia/Taipei）
- 首發優惠第 30 天：2026-08-22
- US$4.99 生效日：2026-08-23
- 台灣對應正式價格：NT$150

公開上架日計為優惠第 1 天；加 29 個日曆日為第 30 天，下一個日曆日開始套用正式價格。

## 1.0 HISTORICAL 對外文案原則

- 清楚標示「一次買斷，無訂閱」。
- 首發優惠期間可標示「首發價 US$2.99（依地區顯示當地價格）」。
- 不承諾尚未完成或需持續付費服務的 AI 功能。
- 價格、促銷期間與商店實際顯示保持一致。

## 1.0 HISTORICAL 注意事項

- App Store Connect 的價格設定不需要修改 App 程式碼。
- 接受付費 App 合約屬法律行為，必須由帳號持有人親自完成。
- Apple 允許設定 App 價格與排程價格變更；實際可用欄位取決於合約狀態與 App 的送審狀態。
