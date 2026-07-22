# KnitNote App Store 提交狀態

最後更新：2026-07-23

## 版本

- App：KnitNote
- Apple ID：`6793023054`
- iOS／macOS bundle ID：`com.phillon.KnitNote`
- Watch bundle ID：`com.phillon.KnitNote.watch`
- 版本：`1.0.0`
- Build：`2`
- Team：`9CFPAUL5N5`
- 價格：首發 US$2.99，一次買斷；詳細紀錄見 `KnitNotePricing.md`

## Watch companion 狀態

- [x] iOS-only Embed Watch Content
- [x] `WKCompanionAppBundleIdentifier = com.phillon.KnitNote`
- [x] `WKApplication = true`
- [x] iPhone／Watch 版本與 build 一致
- [x] Build 2 release candidate `/tmp/KnitNoteRelease-Build2/KnitNote-iOS-Privacy.xcarchive` 包含 Watch App，且 strict codesign 通過
- [x] 該修正版成功安裝並啟動於實體 iPhone
- [x] Apple Watch Developer Mode、裝置登錄、實機安裝與啟動
- [x] 實體 Apple Watch 功能與 VoiceOver 驗收

## 發布門檻

- [x] SwiftPM 522 項測試與五個 Release build 目的地通過
- [x] iOS／Watch 與 macOS Build 2 signed archives 建立成功
- [x] 主 App、Watch App 與 macOS App 都已打包經稽核的 `PrivacyInfo.xcprivacy`
- [x] Build 1 修正後 archive 通過 Xcode Organizer Validate App
- [x] Build 2 最終 archive 通過 Xcode Organizer Validate App
- [ ] 完成 App Store Connect metadata、隱私、截圖與 build 對照
- [ ] 使用者明確批准後才可提交 App Review

目前尚未上傳或送審。下一個門檻是完成 App Store Connect metadata、隱私問卷、截圖與 Build 2 對照，並在送審前取得使用者明確批准。Build 2 驗收見 `Verification/Build2ArchiveVerification.md`，隱私稽核見 `Verification/PrivacyAudit.md`，Watch 實機證據見 `Verification/WatchSyncVerification.md`。

## Commercial configuration／商業設定

- `VERIFIED`：一次買斷，首發美國 US$2.99、台灣 NT$90，無訂閱與 App 內購買。
- `VERIFIED`：175 個國家或地區供應；正式上架後第 31 天調整美國基準價為 US$4.99。

## Builds／建置版本

- `VERIFIED`：iOS／iPadOS／watchOS 與 macOS 版本 `1.0.0`、Build `2`。
- `VERIFIED`：iOS／Watch Build 2 已通過 Xcode Organizer Validate App。
- `NOT STARTED`：將 Build 2 上傳並等待 App Store Connect 處理完成。

## Localizations／在地化

- `NOT STARTED`：繁體中文 metadata。
- `NOT STARTED`：English (U.S.) metadata。
- `NOT STARTED`：公開支援與隱私網址。

## Privacy／隱私

- `VERIFIED`：不追蹤、不含廣告／分析 SDK、不傳送使用資料到開發者伺服器。
- `VERIFIED`：主 App、Watch 與 macOS archive 均含經稽核的隱私權清單。
- `NOT STARTED`：App Store Connect「App 隱私權」問卷。

## Screenshots／截圖

- `NOT STARTED`：繁中與英文 iPhone、iPad、Apple Watch、Mac 截圖。
- `BLOCKED`：只可使用合成示範資料；不得出現家庭照片、個人檔名或真實裝置資料。

## Review information／審核資訊

- `READY`：公開聯絡信箱 `lzz.1999@icloud.com`。
- `NOT STARTED`：審核備註、電話、年齡分級與出口法規答案。

## Manual release／手動發佈

- `READY`：審核通過後由帳號持有人手動發佈，不自動上架。

## Final approval boundary／最終批准界線

- `BLOCKED`：沒有使用者在完整上架頁面核對後另行明確批准，不得點擊 Add for Review、Submit for Review 或同等送審控制項。
