# KnitNote App Store 提交狀態

最後更新：2026-07-28

## 版本

- App：KnitNote
- Apple ID：`6793023054`
- iOS／macOS bundle ID：`com.phillon.KnitNote`
- Watch bundle ID：`com.phillon.KnitNote.watch`
- Share extension bundle ID：`com.phillon.KnitNote.share`
- 下一版 release candidate：`1.2.0`
- Build：`2`
- Team：`9CFPAUL5N5`
- App 價格：免費下載（free app price）
- 終身解鎖 IAP：`com.phillon.KnitNote.lifetimeUnlock`
- IAP 類型：非消耗型（non-consumable）
- IAP 規劃：首發 US$2.99，之後調整為 US$4.99；實際排程仍須在 App Store Connect 另行確認

## 1.2 試用與終身解鎖 release candidate

- `IMPLEMENTED`：完整功能試用 7 天；只瀏覽不開始試用，建立第一件作品或匯入第一份織圖才開始。
- `IMPLEMENTED`：試用到期後進入唯讀；既有作品、織圖、筆記、日記、毛線資料及備份仍可查看或匯出。
- `IMPLEMENTED`：one purchase 可在同一 Apple Account 的 iPhone、iPad、Mac 與配對 Apple Watch 解鎖。
- `IMPLEMENTED`：可在解鎖畫面 restore purchases；Watch 不顯示獨立購買流程。
- `IMPLEMENTED`：legacy paid owner 依 1.2.0 既定版本界線自動保留完整功能，不顯示 paywall。
- `IMPLEMENTED`：App 不要求登入（no account）、不含廣告、不追蹤（no tracking），購買狀態由 Apple StoreKit 管理。
- `NOT CONFIGURED EXTERNALLY`：本文件只準備 submission checklist；尚未建立 App Store Connect IAP、價格排程、促銷代碼或送審資料。

## 1.2 織圖庫 release candidate

- `IMPLEMENTED`：織圖可獨立收藏，並可連結多個作品。
- `IMPLEMENTED`：iOS Share Extension `KnitNoteShare` 可將一份 PDF 或支援的圖片送入待處理匣。
- `IMPLEMENTED`：既有作品資料升級至 project archive schema 10。
- `IMPLEMENTED`：完整備份使用 backup manifest 2，且保留舊格式還原相容性。
- `VERIFIED LOCALLY`：完整 Swift 測試 831 項、靜態 release audit、iOS／macOS／Watch／Share clean builds 與 Share／Watch 嵌入稽核均通過；詳細證據見 `Verification/PatternLibraryVerification.md`。
- `VERIFIED ON DEVICE`：簽章版本已在 iPhone 17 Pro Max 完成 Files PDF Share Sheet 顯示、匯入與重複匯入驗收；詳細證據見 `Verification/ShareExtensionActivationVerification.md`。
- `MANUAL ACCEPTANCE INCOMPLETE`：iPhone 其餘織圖庫操作、iPad 直橫向 PDF 閱讀與標註、macOS、備份還原及 VoiceOver 的 1.2 完整人工矩陣仍待執行。
- `NOT SUBMITTED`：1.2.0 尚未 archive、Validate、上傳或送審；完成本機 release verification 不代表已取得送審授權。

## Watch companion 狀態（1.0 歷史紀錄）

- [x] iOS-only Embed Watch Content
- [x] `WKCompanionAppBundleIdentifier = com.phillon.KnitNote`
- [x] `WKApplication = true`
- [x] iPhone／Watch 版本與 build 一致
- [x] Build 2 release candidate `/tmp/KnitNoteRelease-Build2/KnitNote-iOS-Privacy.xcarchive` 包含 Watch App，且 strict codesign 通過
- [x] 該修正版成功安裝並啟動於實體 iPhone
- [x] Apple Watch Developer Mode、裝置登錄、實機安裝與啟動
- [x] 實體 Apple Watch 功能與 VoiceOver 驗收

## 1.0 發布門檻（歷史紀錄）

- [x] SwiftPM 537 項測試與 iOS、macOS、watchOS、Release build 目的地通過
- [x] iOS／Watch 與 macOS Build 2 signed archives 建立成功
- [x] 主 App、Watch App 與 macOS App 都已打包經稽核的 `PrivacyInfo.xcprivacy`
- [x] Build 1 修正後 archive 通過 Xcode Organizer Validate App
- [x] Build 2 最終 archive 通過 Xcode Organizer Validate App
- [x] 完成 App Store Connect metadata、隱私、截圖與 build 對照
- [x] 使用者已於 2026-07-23 明確授權繼續送審

`1.0 HISTORICAL`：Build 2 已上傳並選入 iOS／Watch 與 macOS 版本。繁體中文與英文 metadata、28 張截圖、審核資訊、年齡分級、內容版權、出口法規、雙語隱私網址與隱私問卷均已完成。iOS 1.0 已於 2026-07-24 18:24:59（Asia/Taipei）公開上架；macOS 1.0 已於 2026-07-24 21:44（Asia/Taipei）正式提交，目前「正在等待審查」。App Store Connect 實際狀態見 `Verification/AppStoreConnectSubmissionVerification.md`。

## Commercial configuration／商業設定

- `REPOSITORY READY`：終身解鎖為 non-consumable IAP `com.phillon.KnitNote.lifetimeUnlock`，沒有訂閱。
- `PENDING`：將 App 本體價格確認為免費（verify the free app price before release）。
- `PENDING`：建立 non-consumable IAP，名稱為 Lifetime Unlock。
- `PENDING`：為 IAP attach its review screenshot。
- `PENDING`：首次建立 IAP 時，submit the first IAP with the new app version。
- `PENDING`：configure US$2.99 launch pricing then US$4.99；日期與各地等值價格須在 App Store Connect 重新核對。
- `PENDING`：create 20 free codes；產生後必須以未解鎖帳號實測 redeem 流程。
- `PENDING`：以真實 1.0 付費安裝升級，validate legacy paid owner behavior。
- `NOT AUTHORIZED`：以上均為外部寫入，尚未執行；不得將舊版 App 售價排程視為新 IAP 的價格設定。

## Builds／建置版本

- `CANDIDATE`：iOS／iPadOS／watchOS、Share Extension 與 macOS 的設定版本均為 `1.2.0`、Build `2`。
- `VERIFIED LOCALLY`：1.2.0 generic iOS／macOS clean build、Share embed、Watch embed 與 fresh Watch／Share target build 均通過，證據記錄於 `Verification/PatternLibraryVerification.md`。
- `NOT UPLOADED`：1.2.0／Build 2 尚未上傳 App Store Connect。
- `VERIFIED`：iOS／iPadOS／watchOS 與 macOS 版本 `1.0.0`、Build `2`。
- `VERIFIED`：iOS／Watch Build 2 已通過 Xcode Organizer Validate App。
- `UPLOADED`：iOS／iPadOS／Watch 與 macOS Build 2 均已由 Xcode Organizer 上傳至 Apple；等待 App Store Connect 完成後續處理。

## Localizations／在地化

- `READY`：繁體中文 metadata 已通過欄位長度、關鍵字與禁語檢查。
- `READY`：English (U.S.) metadata 已通過欄位長度、關鍵字與禁語檢查。
- `REPOSITORY READY`：1.2 英文名稱為 `KnitNote: Row Counter & PDF`，副標題為 `Knitting with Apple Watch`。
- `NOT SAVED EXTERNALLY`：1.2 雙語 metadata 尚未寫入 App Store Connect；下方舊版儲存狀態不代表新文案已上傳。
- `VERIFIED`：雙語支援／隱私網站已通過本機內容、連結、手機與桌面版面檢查。
- `VERIFIED`：公開支援、行銷與隱私網址均以 HTTPS 回傳 200；證據見 `Verification/PublicSiteVerification.md`。

## Privacy／隱私

- `VERIFIED LOCALLY`：1.2.0 主 App、Watch 與 `KnitNoteShare` 的 `PrivacyInfo.xcprivacy` 已通過靜態 release audit、實際 build-product 存在性與 `plutil -lint` 稽核。
- `VERIFIED`：不追蹤、不含廣告／分析 SDK、不傳送使用資料到開發者伺服器。
- `VERIFIED`：主 App、Watch 與 macOS archive 均含經稽核的隱私權清單。
- `READY`：雙語公開隱私權政策來源已完成。
- `PUBLISHED`：App Store Connect「App 隱私權」問卷已發佈為「不收集資料」。
- `SAVED`：繁體中文與英文（美國）的公開隱私權政策 URL 均已儲存並重新讀取確認。

## Screenshots／截圖

- `APPROVED 1.2 STORYBOARD`：新版六張主敘事採以下固定順序，Watch-first 原始素材也必須先擷取：
  1. `Count from your wrist. Keep knitting.`
  2. `Read patterns. Keep every count in sync.`
  3. `Six counters. One calm workspace.`
  4. `Try everything free for 7 days.`
  5. `Projects, yarn, notes—all together.`
  6. `One purchase. All your Apple devices.`
- `PENDING`：產出以上 1.2 六張新版成品、逐張檢查兩種語言與各裝置尺寸，並準備 IAP review screenshot。
- `1.0 HISTORICAL — VERIFIED`：繁中與英文 iPhone、iPad、Apple Watch、Mac 共 28 張最終截圖已產出，尺寸與格式自動驗證全部通過；這不是 1.2 六張新版證據。
- `1.0 HISTORICAL — VERIFIED`：Debug 截圖模式已在四種平台執行；隔離的合成資料可由正式資料儲存層讀取，不會開啟正式 Application Support。
- `1.0 HISTORICAL — VERIFIED`：兩份 contact sheet 與織圖、高亮、手寫、頁面筆記、六組計數器等重點畫面已逐張目視檢查；英文 iPad 系統日期與介面語言一致。
- `1.0 HISTORICAL — UPLOADED`：繁中 iPhone 5 張、iPad 4 張、Apple Watch 2 張與 Mac 3 張截圖已依核准順序上傳。
- `1.0 HISTORICAL — UPLOADED`：英文 iPhone 5 張、iPad 4 張、Apple Watch 2 張與 Mac 3 張截圖已依核准順序上傳。

## Review information／審核資訊

- `READY`：公開聯絡信箱 `lzz.1999@icloud.com`。
- `REVIEW NOTE`：免登入。首次建立作品或匯入織圖會開始 7-day trial；解鎖頁可 purchase、restore 或引導使用者 redeem code。Apple Watch 使用配對 iPhone 的權益快照，不提供獨立購買。
- `REVIEW NOTE`：one purchase applies to iPhone, iPad, Mac and the paired Apple Watch when the same Apple Account can restore the non-consumable purchase.
- `SAVED`：iOS 與 macOS 均設定免登入、審核聯絡人與測試步驟。
- `SAVED`：全球年齡分級 4+，主要類別「生活風格」、次要類別「工具程式」。
- `SAVED`：內容版權聲明為 App 可存取使用者選擇的第三方內容，且具必要權利。
- `SAVED`：iOS／Watch 與 macOS Build 2 均完成出口法規答案，不使用需申報的加密演算法。

## StoreKit 與實體裝置人工驗收

這一節只記錄 1.2 新商業模式的證據。舊版功能、建置成功或既有 Watch 驗收不可代替下列 StoreKit 驗收。尚未填入實際裝置、OS 與 build 的項目均視為未完成。

| 驗收項目 | 裝置／OS／Build | 結果 |
| --- | --- | --- |
| 全新 iPhone：瀏覽不開始試用；第一件作品開始 | 待填 | `NOT RUN` |
| 全新 iPad：第一份織圖開始試用 | 待填 | `NOT RUN` |
| 全新 Mac：試用到期後唯讀，backup 仍可匯出 | 待填 | `NOT RUN` |
| Sandbox purchase 解鎖 iPhone、iPad、Mac 與 paired Watch | 待填 | `NOT RUN` |
| 刪除並重裝後 restore purchase | 待填 | `NOT RUN` |
| 以 free code redeem 後恢復權益 | 待填 | `NOT RUN` |
| legacy paid 1.0 安裝升級後不出現 paywall | 待填 | `NOT RUN` |
| Apple Watch 離線命令重新連線後 reconcile | 待填 | `NOT RUN` |
| Share Extension 在已確認到期後阻擋匯入 | 待填 | `NOT RUN` |

人工驗收完成時，必須把「待填」換成真實 model、OS version、app build 與日期，並附上 sandbox 帳號狀態或可重現步驟；不得以模擬器或單元測試結果填成 `PASS`。

## Manual release／手動發佈

- `NOT SUBMITTED`：1.2.0 尚未送審或發佈。
- `RELEASED`：iOS 1.0 已由帳號持有人手動發佈，並於 2026-07-24 公開上架。
- `WAITING FOR REVIEW`：macOS 1.0 已提交審查，核准後仍採手動發佈。

## Final approval boundary／最終批准界線

- `NOT AUTHORIZED`：目前工作只涵蓋 1.2.0 release candidate 的本機驗證與文件；任何 archive 上傳、App Store Connect 編輯、送審或發佈仍需使用者另行明確授權。
- `AUTHORIZED FOR 1.0`：使用者曾明確要求繼續 1.0 送審；此授權不延伸到 1.2.0。
- `RELEASED`：iOS 1.0／Build 2 已通過審查並公開上架。
- `SUBMITTED`：macOS 1.0／Build 2 已完成雙語資料、截圖與審核資訊核對，並正式提交。
- `WAITING FOR REVIEW`：App Store Connect 的 macOS 版本頁顯示「正在等待審查」。
