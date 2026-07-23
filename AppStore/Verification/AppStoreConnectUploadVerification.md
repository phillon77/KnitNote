# App Store Connect Build 2 上傳驗證

日期：2026-07-23（Asia/Taipei）

## 上傳範圍

- iOS／iPadOS／Apple Watch：KnitNote `1.0.0 (2)`
- macOS：KnitNote `1.0.0 (2)`
- Bundle ID：`com.phillon.KnitNote`
- Team：`9CFPAUL5N5`（Chen Chung Lung）

## 上傳前驗證

- `/tmp/KnitNoteRelease-Build2/KnitNote-iOS-Privacy.xcarchive`：`ARCHIVE SUCCEEDED`
- `/tmp/KnitNoteRelease-Build2/KnitNote-macOS-Privacy.xcarchive`：`ARCHIVE SUCCEEDED`
- `AppStore/Verification/release_audit.sh --archives /tmp/KnitNoteRelease-Build2`：`METADATA CHECK: PASS`、`RELEASE AUDIT: PASS`
- SwiftPM：537 tests in 42 suites passed

## Xcode Organizer 結果

- iOS／iPadOS／Watch：Xcode 顯示 `App upload complete`，archive 狀態為 `Uploaded to Apple`，Build Number `2`。
- macOS 第一次上傳被 Apple 以錯誤 `90296` 拒絕，原因是缺少 `com.apple.security.app-sandbox`。
- 修正後的 macOS archive 實際簽章包含：
  - `com.apple.security.app-sandbox = true`
  - `com.apple.security.files.user-selected.read-write = true`
- 修正版 macOS：Xcode 顯示 `App upload complete`，archive 狀態為 `Uploaded to Apple`，Build Number `2`。

## 審核界線

本次只上傳二進位檔。未執行 Add for Review、Submit for Review 或其他送審控制項。
