# KnitNote App Store 提交與商業狀態

最後更新：2026-07-31（Asia/Taipei）

## App identity

- App：KnitNote
- Apple ID：`6793023054`
- iOS／macOS bundle ID：`com.phillon.KnitNote`
- Watch bundle ID：`com.phillon.KnitNote.watch`
- Share extension bundle ID：`com.phillon.KnitNote.share`
- 公開版本：iOS／macOS `1.2.1`
- Lifetime Unlock：`com.phillon.KnitNote.lifetimeUnlock`

版本、build、archive、提交 ID 與 Git SHA 都是 release-specific evidence；
每次發佈必須重新填入
[`Verification/CommercialReleaseChecklist.md`](Verification/CommercialReleaseChecklist.md)。

## Current commercial state

2026-07-31 已觀察並核對：

- App 本體在 App Store Connect 的 175 個 storefronts 價格均為 0。
- United States App 本體價格為 US$0.00。
- Taiwan App 本體價格為 NT$0。
- App 本體沒有未來價格調整。
- Lifetime Unlock 為已核准的 non-consumable。
- Lifetime Unlock 價格為 United States US$4.99、Taiwan NT$150。
- Taiwan 公開商店顯示「免費 · App內購買」。
- United States 公開商店顯示「Free · In-App Purchases」。

這是 2026-07-31 的時間點證據，不得代替下一次 release 或 re-listing 的
即時檢查。

## Commercial release boundary

目前唯一商業設定來源：
[`CommercialConfiguration.json`](CommercialConfiguration.json)。

每次發佈、停售或重新供應都必須：

1. 完成離線商業設定檢查；
2. 確認 App 本體 175 個 storefronts 皆免費；
3. 確認沒有未來 App 價格排程；
4. 另行確認 Lifetime Unlock 的核准狀態與價格；
5. 恢復 availability 後確認台灣與美國公開商店；
6. 完成公開版本的試用、購買、重開與回復購買；
7. 完成 iOS acceptance 與 macOS acceptance；
8. 全部完成前維持 advertising hold。

任何 App Store Connect 寫入、價格變更、availability 變更、送審、發佈、
廣告投放或 Git push，仍需使用者針對該動作明確授權。

## Current acceptance evidence

- 已觀察 iOS TestFlight 的 Lifetime Unlock 購買流程、US$4.99／NT$150
  價格與重開後權益保留。
- TestFlight 證據不能代替重新上架後的公開版本下載與跨平台驗收。
- 公開 iOS／macOS 的完整 free-download → seven-day trial → purchase →
  relaunch → restore 流程，必須在 checklist 中留下候選版本專屬證據。

## Historical records

1.0、1.2.0、1.2.1 Build 3／4／5 的歷史 build、審核與驗證紀錄保留在
`AppStore/Verification/` 與 Git 歷史。歷史狀態不得覆蓋本文件的 current
commercial state。
