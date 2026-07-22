# KnitNote App Store 提交狀態

最後更新：2026-07-22

## 版本

- App：KnitNote
- Apple ID：`6793023054`
- iOS／macOS bundle ID：`com.phillon.KnitNote`
- Watch bundle ID：`com.phillon.KnitNote.watch`
- 版本：`1.0.0`
- Build：`1`
- Team：`9CFPAUL5N5`
- 價格：首發 US$2.99，一次買斷；詳細紀錄見 `KnitNotePricing.md`

## Watch companion 狀態

- [x] iOS-only Embed Watch Content
- [x] `WKCompanionAppBundleIdentifier = com.phillon.KnitNote`
- [x] `WKApplication = true`
- [x] iPhone／Watch 版本與 build 一致
- [x] 修正後 release candidate `/tmp/KnitNote-WatchCheck-Application.xcarchive` 包含 Watch App，且 strict codesign 通過
- [x] 該修正版成功安裝並啟動於實體 iPhone
- [ ] 實體 Apple Watch 功能與 VoiceOver 驗收

## 發布門檻

- [x] SwiftPM 測試與五個 Release build 目的地通過
- [x] iOS 與 macOS signed archives 建立成功
- [ ] Xcode Organizer Validate App 成功
- [ ] 完成 App Store Connect metadata、隱私、截圖與 build 對照
- [ ] 使用者明確批准後才可提交 App Review

目前不得上傳或送審。詳細 Watch 證據與阻塞原因見 `Verification/WatchSyncVerification.md`。
