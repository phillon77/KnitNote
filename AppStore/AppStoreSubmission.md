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
- [ ] Build 2 最終 archive 通過 Xcode Organizer Validate App
- [ ] 完成 App Store Connect metadata、隱私、截圖與 build 對照
- [ ] 使用者明確批准後才可提交 App Review

目前先不要上傳或送審；下一個門檻是用 Xcode Organizer 驗證 Build 2，之後再完成 App Store Connect metadata、隱私問卷、截圖與 build 對照。Build 2 靜態驗收見 `Verification/Build2ArchiveVerification.md`，隱私稽核見 `Verification/PrivacyAudit.md`，Watch 實機證據見 `Verification/WatchSyncVerification.md`。
