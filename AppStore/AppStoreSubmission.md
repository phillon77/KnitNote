# KnitNote App Store 提交狀態

最後更新：2026-07-24

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

- [x] SwiftPM 537 項測試與 iOS、macOS、watchOS、Release build 目的地通過
- [x] iOS／Watch 與 macOS Build 2 signed archives 建立成功
- [x] 主 App、Watch App 與 macOS App 都已打包經稽核的 `PrivacyInfo.xcprivacy`
- [x] Build 1 修正後 archive 通過 Xcode Organizer Validate App
- [x] Build 2 最終 archive 通過 Xcode Organizer Validate App
- [x] 完成 App Store Connect metadata、隱私、截圖與 build 對照
- [x] 使用者已於 2026-07-23 明確授權繼續送審

Build 2 已上傳並選入 iOS／Watch 與 macOS 版本。繁體中文與英文 metadata、28 張截圖、審核資訊、年齡分級、內容版權、出口法規、雙語隱私網址與隱私問卷均已完成。iOS 1.0 已於 2026-07-24 送出並顯示「等待審查」；macOS 1.0 保持「準備提交」，等待目前的 iOS 審查提交離開作用中狀態後再建立下一份提交。App Store Connect 實際狀態見 `Verification/AppStoreConnectSubmissionVerification.md`。

## Commercial configuration／商業設定

- `VERIFIED`：一次買斷，首發美國 US$2.99、台灣 NT$90，無訂閱與 App 內購買。
- `VERIFIED`：175 個國家或地區供應；正式上架後第 31 天調整美國基準價為 US$4.99。

## Builds／建置版本

- `VERIFIED`：iOS／iPadOS／watchOS 與 macOS 版本 `1.0.0`、Build `2`。
- `VERIFIED`：iOS／Watch Build 2 已通過 Xcode Organizer Validate App。
- `UPLOADED`：iOS／iPadOS／Watch 與 macOS Build 2 均已由 Xcode Organizer 上傳至 Apple；等待 App Store Connect 完成後續處理。

## Localizations／在地化

- `READY`：繁體中文 metadata 已通過欄位長度、關鍵字與禁語檢查。
- `READY`：English (U.S.) metadata 已通過欄位長度、關鍵字與禁語檢查。
- `SAVED`：iOS／macOS 繁體中文與英文（美國）版本 metadata 已儲存至 App Store Connect。
- `SAVED`：英文商店名稱為 `KnitNote: Knitting Companion`。
- `VERIFIED`：雙語支援／隱私網站已通過本機內容、連結、手機與桌面版面檢查。
- `VERIFIED`：公開支援、行銷與隱私網址均以 HTTPS 回傳 200；證據見 `Verification/PublicSiteVerification.md`。

## Privacy／隱私

- `VERIFIED`：不追蹤、不含廣告／分析 SDK、不傳送使用資料到開發者伺服器。
- `VERIFIED`：主 App、Watch 與 macOS archive 均含經稽核的隱私權清單。
- `READY`：雙語公開隱私權政策來源已完成。
- `PUBLISHED`：App Store Connect「App 隱私權」問卷已發佈為「不收集資料」。
- `SAVED`：繁體中文與英文（美國）的公開隱私權政策 URL 均已儲存並重新讀取確認。

## Screenshots／截圖

- `VERIFIED`：繁中與英文 iPhone、iPad、Apple Watch、Mac 共 28 張最終截圖已產出，尺寸與格式自動驗證全部通過。
- `VERIFIED`：Debug 截圖模式已在四種平台執行；隔離的合成資料可由正式資料儲存層讀取，不會開啟正式 Application Support。
- `VERIFIED`：兩份 contact sheet 與織圖、高亮、手寫、頁面筆記、六組計數器等重點畫面已逐張目視檢查；英文 iPad 系統日期與介面語言一致。
- `UPLOADED`：繁中 iPhone 5 張、iPad 4 張、Apple Watch 2 張與 Mac 3 張截圖已依核准順序上傳。
- `UPLOADED`：英文 iPhone 5 張、iPad 4 張、Apple Watch 2 張與 Mac 3 張截圖已依核准順序上傳。

## Review information／審核資訊

- `READY`：公開聯絡信箱 `lzz.1999@icloud.com`。
- `SAVED`：iOS 與 macOS 均設定免登入、審核聯絡人與測試步驟。
- `SAVED`：全球年齡分級 4+，主要類別「生活風格」、次要類別「工具程式」。
- `SAVED`：內容版權聲明為 App 可存取使用者選擇的第三方內容，且具必要權利。
- `SAVED`：iOS／Watch 與 macOS Build 2 均完成出口法規答案，不使用需申報的加密演算法。

## Manual release／手動發佈

- `READY`：審核通過後由帳號持有人手動發佈，不自動上架。

## Final approval boundary／最終批准界線

- `AUTHORIZED`：使用者已明確要求繼續送審。
- `SUBMITTED`：iOS 1.0／Build 2 已送出，App Store Connect 顯示「等待審查」。
- `READY`：macOS 1.0／Build 2 的雙語資料與截圖均完成，仍顯示「準備提交」。
- `EXTERNAL WAIT`：作用中的 iOS 提交存在時，macOS「新增以供審查」不會建立第二份草稿；保留 iOS 有效提交，不撤回。
