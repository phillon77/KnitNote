# KnitNote Build 2 封存驗證

驗證日期：2026-07-23（Asia/Taipei）

## 候選版本

- 版本：`1.0.0`
- Build：`2`
- iOS／macOS bundle ID：`com.phillon.KnitNote`
- Watch bundle ID：`com.phillon.KnitNote.watch`
- Watch companion bundle ID：`com.phillon.KnitNote`
- Team：`9CFPAUL5N5`

## 測試與 Release 建置

- `swift test --disable-sandbox`：522 tests／39 suites，通過。
- iOS Simulator Release：通過。
- Generic iOS Release：由本次 signed archive 完整建置，通過。
- macOS Release：由本次 signed archive 完整建置，通過。
- watchOS Simulator Release：通過。
- Generic watchOS Release：內嵌於本次 iOS signed archive 完整建置，通過。

所有同時執行的 Xcode 建置均使用獨立 DerivedData，避免不同平台爭用同一份 build database。

## Signed archives

### iOS 與 Watch

- Archive：`/tmp/KnitNoteRelease-Build2/KnitNote-iOS-Privacy.xcarchive`
- iOS processed Info.plist：`com.phillon.KnitNote`，`1.0.0`，build `2`。
- 內嵌 Watch processed Info.plist：`com.phillon.KnitNote.watch`，`1.0.0`，build `2`，companion `com.phillon.KnitNote`。
- `codesign --verify --deep --strict`：通過。
- 主 App 隱私權清單：`KnitNote.app/PrivacyInfo.xcprivacy`，`plutil -lint` 通過。
- Watch 隱私權清單：`KnitNote.app/Watch/KnitNoteWatch.app/PrivacyInfo.xcprivacy`，`plutil -lint` 通過。

### macOS

- Archive：`/tmp/KnitNoteRelease-Build2/KnitNote-macOS-Privacy.xcarchive`
- processed Info.plist：`com.phillon.KnitNote`，`1.0.0`，build `2`。
- `codesign --verify --deep --strict`：通過。
- 隱私權清單：`KnitNote.app/Contents/Resources/PrivacyInfo.xcprivacy`，`plutil -lint` 通過。

## 隱私權清單

主 App 宣告經原始碼與 release binary 稽核確認的 File Timestamp `C617.1`、`3B52.1`，以及 User Defaults `CA92.1`。Watch 只宣告其 app-container 檔案行為所需的 File Timestamp `C617.1`。兩者均宣告不追蹤、不收集資料；完整依據見 `PrivacyAudit.md`。

## App Store Connect 驗證

2026-07-23 06:41（Asia/Taipei）在 Xcode Organizer 對 iOS／Watch archive 執行建議設定的 Validate App。Xcode 回報：

```text
App validation complete:
KnitNote 1.0.0 (2) validated
Your app successfully passed all validation checks.
```

Organizer archive 狀態顯示 `Validation succeeded`，Submission Status 顯示 `Validated`、Build Number `2`。本節記錄的驗證當下尚未執行 Distribute App；後續上傳結果見 `AppStoreConnectUploadVerification.md`。

## 結論與下一門檻

Build 2 已通過本機測試、Release 建置、封存內容、隱私權清單位置、嚴格簽章驗證，以及 Xcode Organizer 的 App Store Connect 驗證。兩個平台的 Build 2 已於後續流程上傳；下一步是完成 App Store Connect metadata、隱私問卷、截圖與 Build 2 對照。送審仍需使用者另外明確批准。
