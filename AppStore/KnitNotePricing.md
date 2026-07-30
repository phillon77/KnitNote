# KnitNote 商業設定

最後更新：2026-07-31

## 唯一執行來源

可執行的商業設定只存在於
[`AppStore/CommercialConfiguration.json`](CommercialConfiguration.json)。
本文件負責解釋設定，不得自行建立另一組價格、排程或產品 ID。

## Current commercial contract

- App download: Free
- Storefronts: 175
- Future App price changes: None
- Trial: 7 天完整功能試用，狀態保存在本機
- Lifetime Unlock product ID:
  `com.phillon.KnitNote.lifetimeUnlock`
- Lifetime Unlock type: non-consumable
- Lifetime Unlock price:
  - United States: US$4.99
  - Taiwan: NT$150
- Subscription: None
- 已驗證的永久權益：StoreKit 暫時不可用時仍必須保留

App 下載價格與 Lifetime Unlock 是兩個不同商品。App 本體必須免費；
US$4.99／NT$150 只屬於 Lifetime Unlock，不得套用到 App 本體。

## Mandatory release order

每次新版本發佈或停售後重新供應，必須依序完成：

1. 固定 Git SHA、version、build、iOS archive 與 macOS archive。
2. 執行完整 release audit 與離線商業設定檢查。
3. 確認 Lifetime Unlock 的產品 ID、類型、核准狀態與價格。
4. 在 App 尚未供應時，展開 App 本體「目前價格」：
   - 175 個 storefronts 全部為 0；
   - United States 為 US$0.00；
   - Taiwan 為 NT$0；
   - Future App price changes: None。
5. 完成第 1–4 步後才可恢復 App availability。
6. 等公開台灣與美國商店顯示免費下載及 App 內購買。
7. 以公開版本完成 7 天試用、購買、重開、回復購買、iOS 與 macOS
   實機驗收。
8. 所有證據寫入
   [`Verification/CommercialReleaseChecklist.md`](Verification/CommercialReleaseChecklist.md)
   後，才可開始廣告。

停售或取消 storefront availability 不會清除 App 目前價格，也不會刪除
未來價格排程。重新供應前必須重新展開兩者確認，不能沿用上次畫面或記憶。

## Commands

離線檢查：

```sh
python3 AppStore/Verification/commercial_release_check.py --offline
```

台灣與美國公開商店檢查：

```sh
python3 AppStore/Verification/commercial_release_check.py --live
```

Live 檢查只能證明公開 App 下載價格與 App 內購買標示；不能取代
App Store Connect 內部價格排程、Lifetime Unlock 價格或實機 StoreKit
驗收。

## Historical — KnitNote 1.0 paid-download record

**NOT EXECUTABLE. DO NOT COPY TO APP STORE CONNECT.**

KnitNote 1.0 曾採用付費下載：

- 首發 App 價格：United States US$2.99、Taiwan NT$90。
- 曾排定 2026-08-23 將 App 本體調整為 United States US$4.99、
  Taiwan NT$150。
- 2026-07-31 已刪除該未來 App 價格排程，並將 App 本體改為全球免費。

這些價格只保存事故脈絡，不是目前或未來的操作指示。
