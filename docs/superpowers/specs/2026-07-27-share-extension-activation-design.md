# KnitNote Share Extension 顯示修正設計

## 問題與目標

KnitNote 1.2 的 Share Extension 已正確嵌入、簽章，App 與 Extension 也使用相同 App Group；但在實機 iPhone 的「檔案」PDF 分享表單中，KnitNote 不會出現。重裝 App 後問題仍可穩定重現，因此不能視為單純的 iOS 快取問題。

本次修正的成功標準是：

- 從 iPhone「檔案」App 開啟單一 PDF 並點分享時，可以看到 KnitNote。
- 選擇 KnitNote 後，PDF 能進入既有的織圖匯入流程。
- PNG、JPEG、HEIC 仍維持支援。
- 不改動既有織圖、作品、連結、筆記、計數器或備份資料格式。
- 不把寬鬆的診斷設定帶入正式程式碼或提交。

## 根因診斷

目前的 `NSExtensionActivationRule` 使用直接索引：

`extensionItems[0].attachments`

這個條件能通過本機 Foundation 的模擬物件測試，但實機分享表單沒有註冊 KnitNote。現有測試只證明 Predicate 對人工建構資料成立，不能證明 iOS Extension Discovery 會以相同方式解讀它。

診斷分兩階段，且一次只改一個變因：

1. 建立不提交的 `TRUEPREDICATE` 診斷版並安裝到實機。
2. 若 KnitNote 出現，根因即限定在 Activation Rule；若仍不出現，停止修改規則，改查 Extension registration、principal class 與系統註冊狀態。

`TRUEPREDICATE` 僅供診斷，驗證後立即移除，不進入 Git 提交。

## 正式修正

若診斷確認 Activation Rule 是根因，正式規則改用 Apple 文件採用的雙層 `SUBQUERY` 形式：

- 外層遍歷 `extensionItems`。
- 內層遍歷每個 item 的 `attachments`。
- 僅允許一個 extension item。
- 僅允許一個 attachment。
- attachment 至少符合 PDF、PNG、JPEG、HEIC 其中一種 UTI。

`project.yml` 是 XcodeGen 的來源，因此正式規則同時更新：

- `project.yml`
- 產生後的 `KnitNoteShare/Info.plist`
- 產生後的 `KnitNote.xcodeproj`

不更改 `ShareViewController`、匯入佇列、App Group 或資料模型，避免擴大修正範圍。

## 測試策略

### 自動測試

先修改 Contract Test，要求 Activation Rule：

- 使用外層 `SUBQUERY(extensionItems, ...)`。
- 使用內層 `SUBQUERY($extensionItem.attachments, ...)`。
- 不再使用 `extensionItems[0]`。
- 接受單一 PDF、PNG、JPEG、HEIC。
- 拒絕空內容、不支援的 URL、兩個附件。

測試必須先在舊規則上失敗，再進行正式修正，完成紅綠循環。

### 建置與靜態驗證

- `plutil` 驗證 Info.plist。
- 執行 Share Extension 相關測試。
- 執行完整 Swift 測試套件。
- 建置 iOS App，確認 `KnitNoteShare.appex` 仍被嵌入。
- 建置 macOS App，確認 iOS-only Extension 沒有影響 macOS。

### 實機驗收

安裝新建置到既有 iPhone，不先刪除 App，以保留使用者資料。驗收：

1. 「檔案」App 開啟測試 PDF。
2. 分享表單可看到 KnitNote。
3. 點 KnitNote 可完成收藏。
4. 回到 KnitNote 的織圖檔案匣可看到該 PDF。
5. 重複匯入時顯示既有的重複內容處理結果，不建立損壞或空白檔案。

## 失敗分支

若 `TRUEPREDICATE` 診斷版仍不出現，Activation Rule 假設即被否定。本次不會猜測並疊加第二個修正，而會回到證據蒐集：

- 檢查實機安裝包內 Extension 的註冊資訊。
- 檢查 Extension process 是否被系統發現。
- 驗證 principal class 與 Extension point metadata。
- 比較一個最小可工作的 Share Extension target。

找到新的單一根因並取得使用者確認後，才進入另一份修正設計。

## 版本與資料安全

- 修正放在 `codex/share-extension-activation-fix` 隔離 worktree。
- 不修改主工作區現有未提交檔案。
- 不變更 1.2 的資料模型、App Group、Bundle ID、Marketing Version 或 Build Number。
- 不自動合併、推送或送審；完成驗證後由使用者決定整合方式。
