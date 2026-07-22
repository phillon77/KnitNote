# Watch 同步發布驗證

驗證日期：2026-07-22（Asia/Taipei）

## 環境

- Git 分支：`codex/watch-sync-release`
- Xcode：26.6（17F113）
- macOS：26.5.2（25F84），Apple Silicon
- SDK：iOS／iOS Simulator 26.5、macOS 26.5、watchOS／watchOS Simulator 26.5
- 實體 iPhone：iPhone 17 Pro Max，iOS 26.5.2（23F84），已連線
- 實體 Apple Watch：Apple Watch Ultra 2，watchOS 26.5（23T570），已連線但 Developer Mode 關閉
- iOS bundle ID：`com.phillon.KnitNote`
- Watch bundle ID：`com.phillon.KnitNote.watch`
- 版本／build：`1.0.0`／`1`
- Team：`9CFPAUL5N5`

## 自動化驗證

下列命令均在 2026-07-22 執行並捕捉 exit status。Release build 使用 `-quiet`，所以成功時沒有標準輸出；表內的 `exit 0` 是各程序的直接完成狀態，不是由檔案存在推測。

| 項目 | 完整命令 | 捕捉結果 |
| --- | --- | --- |
| SwiftPM 全套測試 | `swift test --disable-sandbox -Xswiftc -module-cache-path -Xswiftc /tmp/knitnote-module-cache` | exit 0；494 tests／32 suites（`WKApplication` 修正後重跑） |
| iOS Simulator Release | `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteReleaseMatrixFinal/ios-sim clean build` | exit 0；成功時無輸出 |
| Generic iOS Release | `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteReleaseMatrixFinal/ios-device clean build` | exit 0；成功時無輸出 |
| macOS Release | `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteReleaseMatrixFinal/macos clean build` | exit 0；成功時無輸出 |
| watchOS Simulator Release | `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Release -destination 'generic/platform=watchOS Simulator' -derivedDataPath /tmp/KnitNoteReleaseMatrixFinal/watch-sim clean build` | exit 0；成功時無輸出 |
| Generic watchOS Release | `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Release -destination 'generic/platform=watchOS' -derivedDataPath /tmp/KnitNoteReleaseMatrixFinal/watch-device clean build` | exit 0；成功時無輸出 |

完整測試的結尾輸出：

```text
Test run with 494 tests in 32 suites passed after 1.054 seconds.
```

本次最終 Release build 使用獨立的 `/tmp/KnitNoteReleaseMatrixFinal/*` DerivedData。較早第一次平行建立 macOS archive 時，共用預設 DerivedData 造成 `build.db` locked（exit 70）；改用獨立 `/tmp/KnitNoteRelease/Derived-macOS` 後，重跑成功。

## 簽署封存證據

- 修正前 iOS archive：`/tmp/KnitNoteRelease/KnitNote-iOS.xcarchive`，exit 0；下方 Organizer 嘗試使用這份 archive，因此不能代表 `WKApplication` 修正後的服務端驗證。
- macOS archive：`/tmp/KnitNoteRelease/KnitNote-macOS.xcarchive`，exit 0。
- iOS archive 包含：
  - `Products/Applications/KnitNote.app`
  - `Products/Applications/KnitNote.app/Watch/KnitNoteWatch.app`
- macOS archive 只包含 `Products/Applications/KnitNote.app`，沒有 Watch embed。
- iOS processed plist：`com.phillon.KnitNote`，版本 `1.0.0`，build `1`。
- Watch processed plist：`com.phillon.KnitNote.watch`，companion `com.phillon.KnitNote`，版本 `1.0.0`，build `1`。
- macOS processed plist：`com.phillon.KnitNote`，版本 `1.0.0`，build `1`。
- `codesign --verify --deep --strict`：iOS 與 macOS App 均 exit 0。

## 實體裝置包裝驗證

第一次將 archive 安裝到實體 iPhone 時，裝置以 `MIInstallerErrorDomain 92 / InvalidWatchKitApp` 拒絕，原因為 Watch Info.plist 缺少 `WKApplication = true`。修正並提交 `62aca7d` 後：

- 修正後 release candidate：`/tmp/KnitNote-WatchCheck-Application.xcarchive`。
- 建立命令：`xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -configuration Release -archivePath /tmp/KnitNote-WatchCheck-Application.xcarchive archive`，exit 0。
- Watch source／processed Info.plist 均含 `WKApplication = true`。
- `WatchPackagingContractTests`：7 tests passed。
- 修正版完整測試：494 tests／32 suites；本次發布驗證直接重跑並捕捉 exit 0。
- 修正版 signed archive 通過 strict deep codesign。
- `xcrun devicectl device install app ... KnitNote.app`：exit 0，實體 iPhone 安裝成功。
- `xcrun devicectl device process launch ... com.phillon.KnitNote`：exit 0，實體 iPhone 啟動成功。

## 實體配對 iPhone／Apple Watch 功能清單

以下項目尚未聲稱通過。Apple Watch Ultra 2 可被偵測，但 Developer Mode 關閉；`devicectl` 回傳 `CoreDeviceError 10005`，因此目前無法由開發工具安裝、啟動或觀察 Watch App。啟用 Developer Mode 需要使用者在實體裝置上確認，並可能重新啟動手錶。

- [ ] 初次同步顯示 iPhone 作品快照
- [ ] Watch 按一下立即 +1，iPhone 收到相同結果
- [ ] iPhone 修改作品／計數器完整名稱後同步到 Watch
- [ ] 每件作品顯示六組計數器
- [ ] 長名稱完整換行，不截斷
- [ ] 長按後減 1／歸零
- [ ] 飛航模式下依序排入多筆操作，重新連線後順序一致
- [ ] 重複傳送不會重複計數
- [ ] 有待同步操作時強制結束 Watch App，重新開啟後佇列仍在
- [ ] 作品完成後 Watch 唯讀並正確顯示錯誤；恢復後可繼續操作
- [ ] VoiceOver 能朗讀作品、計數器、數值、待同步／已完成狀態與三種動作

## App Store Connect Validate App

2026-07-22 在 Xcode Organizer 開啟修正前的 `/tmp/KnitNoteRelease/KnitNote-iOS.xcarchive`，選擇「Validate App」與建議設定。Xcode 顯示 `KnitNote 1.0.0 (1)` 與 iOS + watchOS 內容；companion 關聯另由 processed plist 的 `WKCompanionAppBundleIdentifier` 證明。Organizer 在重新簽署階段失敗：

```text
codesign command failed
KnitNote.app: replacing existing signature
KnitNote.app: errSecInternalComponent
```

本機同時存在有效的 Apple Development 與 Apple Distribution identity；CLI 對 App 副本以 Distribution identity 重新簽署也會等待私鑰授權，顯示目前阻塞在鑰匙圈私鑰存取，而非已回報的 packaging／localization／icon／privacy 驗證訊息。修正後的 `/tmp/KnitNote-WatchCheck-Application.xcarchive` 尚未完成 Organizer Validate App。未執行上傳，也未送審。

## 最終靜態檢查

```text
$ git diff --check
(no output)
exit 0
```

## 發布結論

自動測試、五個 Release 目的地、iOS／macOS signed archive、內嵌 Watch metadata、嚴格簽章檢查，以及實體 iPhone 安裝／啟動均完成。發布仍被以下兩項阻擋：

1. 在 Apple Watch 開啟 Developer Mode 後完成上述實機同步與 VoiceOver 清單。
2. 讓 Xcode 可使用 Apple Distribution 私鑰後重新執行 Organizer Validate App，記錄所有訊息並取得成功結果。
