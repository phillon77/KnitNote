# Watch 同步發布驗證

驗證日期：2026-07-22（Asia/Taipei）

## 環境

- Git 分支：`codex/watch-sync-release`
- Xcode：26.6（17F113）
- macOS：26.5.2（25F84），Apple Silicon
- SDK：iOS／iOS Simulator 26.5、macOS 26.5、watchOS／watchOS Simulator 26.5
- 實體 iPhone：iPhone 17 Pro Max，iOS 26.5.2（23F84），已連線
- 實體 Apple Watch：Apple Watch Ultra 2，watchOS 26.5（23T570），已配對、Developer Mode 已啟用
- iOS bundle ID：`com.phillon.KnitNote`
- Watch bundle ID：`com.phillon.KnitNote.watch`
- 版本／build：`1.0.0`／`1`
- Team：`9CFPAUL5N5`

## 自動化驗證

下列命令均在 2026-07-22 執行並捕捉 exit status。Release build 使用 `-quiet`，所以成功時沒有標準輸出；表內的 `exit 0` 是各程序的直接完成狀態，不是由檔案存在推測。

| 項目 | 完整命令 | 捕捉結果 |
| --- | --- | --- |
| SwiftPM 全套測試 | `swift test` | exit 0；503 tests／34 suites（可靠結構快照競態與 ABA 邊界修正後重跑） |
| iOS Simulator Release | `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteReliableReleaseMatrixFinal/ios-sim clean build` | exit 0；成功時無輸出 |
| Generic iOS Release | `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteReliableReleaseMatrixFinal/ios-device clean build` | exit 0；成功時無輸出 |
| macOS Release | `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteReliableReleaseMatrixFinal/macos clean build` | exit 0；成功時無輸出 |
| watchOS Simulator Release | `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Release -destination 'generic/platform=watchOS Simulator' -derivedDataPath /tmp/KnitNoteReliableReleaseMatrixFinal/watch-sim clean build` | exit 0；成功時無輸出 |
| Generic watchOS Release | `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Release -destination 'generic/platform=watchOS' -derivedDataPath /tmp/KnitNoteReliableReleaseMatrixFinal/watch-device clean build` | exit 0；成功時無輸出 |

完整測試的結尾輸出：

```text
Test run with 503 tests in 34 suites passed after 1.084 seconds.
```

本次可靠快照競態與 ABA 邊界修正後的最終 Release build 使用獨立的 `/tmp/KnitNoteReliableReleaseMatrixFinal/*` DerivedData。較早第一次平行建立 macOS archive 時，共用預設 DerivedData 造成 `build.db` locked（exit 70）；改用獨立 DerivedData 後，重跑成功。

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
- 修正版完整測試：503 tests／34 suites；本次發布驗證直接重跑並捕捉 exit 0。
- 修正版 signed archive 通過 strict deep codesign。
- `xcrun devicectl device install app ... KnitNote.app`：exit 0，實體 iPhone 安裝成功。
- `xcrun devicectl device process launch ... com.phillon.KnitNote`：exit 0，實體 iPhone 啟動成功。
- 最終可靠同步修正版：`/tmp/KnitNote-ReliableSync-Final.xcarchive`；12:41 重新由目前原始碼建立，archive exit 0，內嵌 Watch metadata 正確，`codesign --verify --deep --strict` exit 0。

## 實體配對 iPhone／Apple Watch 功能清單

2026-07-22 使用者啟用 Apple Watch Developer Mode 後，`devicectl device info details` 顯示 `developerModeStatus: enabled`、`ddiServicesAvailable: true`。舊 archive 的開發 provisioning profile 只列出 iPad 與 iPhone UDID，直接安裝 Watch App 因 `0xe8008012` 被拒；使用 `-allowProvisioningDeviceRegistration` 登錄此 Watch 並產生 `com.phillon.KnitNote.watch` 專用 profile 後，實體 Watch Debug build、安裝與啟動均 exit 0。Xcode Devices 顯示已安裝 bundle `com.phillon.KnitNote.watch`、build `1`。

初次啟動的實體 Watch 截圖顯示「尚無作品」。iPhone 同時安裝舊開發 bundle `com.example.KnitNote` 與發行 bundle `com.phillon.KnitNote`；兩者資料容器彼此隔離，而 Watch companion 正確連結後者。發行 bundle 中建立合成作品「毛衣」後，iPhone ApplicationContext 與 Watch `watch-sync-cache.json` 均含相同作品 ID、選取計數器 ID 與六組計數器。09:52 的實體 Watch 截圖顯示作品列表中的「毛衣」；09:55 與 09:56 的截圖分別顯示計數器 1／2 與計數器 5／6。

使用者在實體 Watch 點按計數器 1 一次後，直接從 `com.phillon.KnitNote` 資料容器重新取得的 `projects-v1.json` 顯示第一組 value `0 → 1`、mutationRevision `0 → 1`，其餘五組保持 0；Watch 畫面同時顯示計數器 1 為 1。

Mac Wi-Fi 開啟並重新建立 Watch 開發 tunnel 後，10:57 的實體 Watch 截圖顯示 iPhone 上的完整自訂名稱「領口左側長名稱測試」已同步，並在 Watch 卡片中自然換成兩行，沒有截斷；同一畫面顯示計數值 4。

使用者在實體 Watch 長按第一組計數器後執行「減 1」，10:59 截圖顯示 Watch `4 → 3`，iPhone `projects-v1.json` 同步為 value 3、mutationRevision 5。再次長按執行「歸零」後，11:01 截圖顯示 Watch 為 0，iPhone 同步為 value 0、mutationRevision 6；兩次操作均保留完整自訂名稱。

iPhone 開啟飛航模式並關閉 Wi-Fi／藍牙後，使用者在 Watch 依序執行 `+1、+1、歸零、+1`；離線狀態下強制結束並重新開啟 Watch App，第一組計數器仍顯示 1。iPhone 恢復連線後，`projects-v1.json` 顯示 value 1、mutationRevision `6 → 10`，精確對應四筆操作且保留順序。再次以 `devicectl --terminate-existing` 重新啟動 Watch App 並等待重送後，iPhone 仍為 value 1、mutationRevision 10，沒有重複計數。

iPhone 將「毛衣」標記為已完成後，Watch `watch-sync-cache.json` 顯示 `isCompleted: true`，11:49 實體截圖顯示每張計數器卡片都有鎖頭與「已完成」標示；點按第一組後畫面仍為 1，沒有新增計數。iPhone 恢復作品為進行中後，Watch 解除完成狀態；使用者在 Watch 點按第一組一次，iPhone 實際畫面同步顯示 `1 → 2`，完成狀態往返與重新啟用計數均正確。

最終可靠快照修正版重新安裝到實體 iPhone 與 Apple Watch 後，兩端冷啟動成功。12:35 取得的 Watch `watch-final-cold-launch.json` 顯示「毛衣」為進行中、第一組計數器「領口左側長名稱測試」為 2、其餘五組為 0，且 `pendingCommands` 為空；確認更新後的結構快照沒有覆蓋較新的計數值，也沒有遺留或重送指令。

- [x] 初次同步顯示 iPhone 作品快照
- [x] Watch 按一下立即 +1，iPhone 收到相同結果
- [x] iPhone 修改作品／計數器完整名稱後同步到 Watch
- [x] 每件作品顯示六組計數器
- [x] 長名稱完整換行，不截斷
- [x] 長按後減 1／歸零
- [x] 飛航模式下依序排入多筆操作，重新連線後順序一致
- [x] 重複傳送不會重複計數
- [x] 有待同步操作時強制結束 Watch App，重新開啟後佇列仍在
- [x] 作品完成後 Watch 唯讀並正確顯示狀態；恢復後可繼續操作
- [x] VoiceOver 能朗讀作品、計數器、數值、待同步／已完成狀態與三種動作

## App Store Connect Validate App

2026-07-22 第一次在 Xcode Organizer 開啟修正前的 `/tmp/KnitNoteRelease/KnitNote-iOS.xcarchive`，選擇「Validate App」與建議設定。Xcode 顯示 `KnitNote 1.0.0 (1)` 與 iOS + watchOS 內容；companion 關聯另由 processed plist 的 `WKCompanionAppBundleIdentifier` 證明。Organizer 在重新簽署階段失敗：

```text
codesign command failed
KnitNote.app: replacing existing signature
KnitNote.app: errSecInternalComponent
```

使用者允許 Xcode／codesign 存取 Apple Distribution 私鑰後，再對修正後的 `/tmp/KnitNote-WatchCheck-Application.xcarchive` 執行推薦的 Validate App。Organizer 完成 iOS 與 Watch 重新簽署並回報：

```text
App validation complete:
KnitNote 1.0.0 (1) validated
Your app successfully passed all validation checks.
```

Organizer archive 狀態顯示 `Validation succeeded`，時間為 2026-07-22 09:32（Asia/Taipei）。未執行上傳，也未送審。

完成可靠結構快照、競態與 ABA 修正後，另以 12:41 建立的 `/tmp/KnitNote-ReliableSync-Final.xcarchive` 再次執行推薦的 Validate App；12:44 Organizer 回報相同的 `KnitNote 1.0.0 (1) validated` 與 `Your app successfully passed all validation checks.`。這次驗證直接對應最終同步修正版；同樣未上傳、未送審。

## 最終靜態檢查

```text
$ git diff --check
(no output)
exit 0
```

## 發布結論

自動測試、五個 Release 目的地、iOS／macOS signed archive、內嵌 Watch metadata、嚴格簽章檢查、實體 iPhone 與 Watch 安裝／啟動、完整雙向同步清單、VoiceOver 實機朗讀，以及修正後 archive 的 Organizer Validate App 均完成。Apple Watch 同步發布驗收清單已全數通過。
