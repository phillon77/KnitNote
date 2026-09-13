# iOS 使用資格設定區塊

日期：2026-09-13。基底：`0f679d96c0ff6935f249c2ad044fb88bbdc59934`。
本文件記錄未提交的開發變更，不代表既有 1.7.0（14）已包含此功能。

## 範圍

- iPhone／iPad 設定固定顯示使用資格、試用剩餘天數及到期時間。
- 永久解鎖與舊版付費用戶亦保留「恢復購買」，並顯示成功、查無購買或失敗。
- 購買入口沿用 RootView 的既有 UnlockSheet；已解鎖或無法驗證購買時不顯示。
- 保留現有 StoreKit、資格協調器、價格、試用及資料保存規則；未修改 macOS 設定頁。
- 新增 12 個文案鍵，各有 13 語系。格式參數一致，保留歷史文案 oracle。

## 已執行驗證

- 既有 UnlockPresentationTests：8 項通過。
- 新模型初次紅燈：AccessStatusPresentation 尚未存在；實作後 13 項相關測試通過。
- 審查發現離線試用狀態仍可顯示購買；新增測試先觀察三組預期失敗，再修正。
- 最終相關 Core／語系／權限回歸：112 項、5 組通過。
  日誌 `/tmp/knitnote-access-final-core.log`。
- EntitlementCoordinatorTests：32 項通過（含參數化測試共 33 次執行），無失敗或略過。
  結果 `/private/tmp/knitnote-access-coordinator.xcresult`。
- iOS Simulator 編譯通過；唯讀程式審查的離線購買 P2 已修正並複查。

## 介面驗證注意事項

- 第一次 UI 測試使用截圖專用 projects scene，沒有設定分頁；該失敗不是設定頁故障。
- 正常啟動的未簽署模擬器版缺 App Group 權限，顯示資料庫不可用，不能當作資料損毀證據。
- 後續改用模擬器本機簽署；Simulated.xcent 已讀回正確的 App Group。
- 新建的兩個 QA 模擬器未刪除任何既有資料；首次開機測試中止，不算有效 UI 驗證。
- 設定頁 UI 測試僅驗證顯示、按鈕可達及本地化，不主動呼叫真實 StoreKit 恢復。
  真實兌換碼權益、恢復購買及其他商業實機驗收，仍須新的 TestFlight 候選補測。
- 最終 iPhone：1 項 UI 測試通過，退出 0；結果
  `/private/tmp/knitnote-access-signed-iphone.xcresult`。
- 原 iPad 模擬器仍有既存資料／匯入錯誤，未清除或修復其資料。
  改用新 iPad 模擬器後：1 項 UI 測試通過，退出 0；結果
  `/private/tmp/knitnote-access-ipad-clean-final.xcresult`。
- iPhone／iPad 截圖已匯出供視覺檢查；模擬器未能確認 StoreKit 購買，
  因此畫面顯示本機試用狀態與驗證不可用說明，不能代表使用者實機資格。

## 發布邊界

未變更 build 編號、未封存／上傳、未修改商店草稿、未送審、未提交或推送 Git。
原 build 14 固定候選副本保持不動。現有其他未提交的驗證文件不屬於本次變更。
