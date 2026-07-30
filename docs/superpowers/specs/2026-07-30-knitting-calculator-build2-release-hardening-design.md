# 編織計算器 Build 2 發佈強化設計

日期：2026-07-30  
狀態：使用者已選定 `A + L1 + H1`

## 目標與停止邊界

以目前獨立的「編織計算器」為基礎，建立可追溯、可重現且與實際
Release App 一致的 `1.0.0 (2)` 候選版本，取代無法完整綁定來源 SHA 的
Build 1。

本輪完成：

- 建立並上傳 Build 2。
- 把英文（美國）設為 App Store Connect 主要語言。
- 重新產生及替換真實、可重現的繁中與英文截圖。
- 建立不含私人 Email、裝置 UDID 或 CoreDevice ID 的乾淨本機發佈分支。
- 重新記錄 Build、截圖、App Store Connect 與實機驗收證據。

本輪不會：

- 按下「加入以供審查」。
- 建立 App Review submission。
- 送審、核准、公開或發佈 App。
- 合併或推送任何分支。
- 刪除目前的工作分支或使用者本地素材。

## 候選版本與來源追溯

- Marketing version 維持 `1.0.0`。
- Build number 由 `1` 提升為 `2`。
- Build 2 必須由乾淨 tracked worktree 的單一 Git SHA 建立。
- Archive、exported IPA、內含 App executable 與 `Info.plist` 都記錄
  SHA-256。
- 證據分開記錄：
  - Build source SHA；
  - screenshot package SHA；
  - evidence HEAD；
  - App Store Connect 選定的 Build。
- App Store Connect 必須顯示並選定 `1.0.0 (2)`；Build 1 保留歷史，
  但不再作為送審候選。
- 若 archive、IPA、Git SHA、App Store Connect 或實機安裝版本任一不一致，
  立即停止，不以推測補足。

## Release 真實截圖

### 真實狀態原則

截圖模式只能：

- 導航到使用者可到達的頁面；
- 預填可由使用者輸入的值；
- 展開可由使用者點開的結果或說明；
- 捲動到可由使用者到達的位置。

截圖模式不得隱藏、移除或新增 Release App 的控制項。特別是
KnitNote 推廣元件的存在與否必須與 Release 一致。

前四張截圖仍不宣傳 KnitNote。達成方式是使用真實捲動位置與 compositor
裁切可見的真實 App 區域，而不是從 SwiftUI hierarchy 移除推廣元件。
最後一張才以真實 Release 畫面呈現 KnitNote 是另一款獨立 App。

### 可重現環境

- capture manifest 固定精確 iOS runtime、device type、locale、orientation
  與 scene。
- capture script 在任何 erase、boot 或安裝前先驗證兩台模擬器的 runtime
  與 device type。
- 禁止以名稱 substring 接受不同裝置或不同 runtime。
- 狀態列時間固定；iPad 的系統日曆日期不得進入最終素材。若 simulator
  無法固定日期，compositor 會一致裁掉狀態列，而不是修圖替換日期。
- 同一 committed raw input 與 manifest 重跑 compositor，輸出位元必須一致。

### 截圖數量

| 語言 | iPhone | iPad |
| --- | ---: | ---: |
| 繁體中文 | 5 | 4 |
| 英文（美國） | 5 | 4 |

Validator 必須驗證：

- exact locale/platform/scene/filename matrix；
- PNG 完整 decode，而非只讀 header；
- 尺寸、數量、檔名、順序與 SHA-256；
- input/output path containment；
- 拒絕 symlinked output parent；
- manifest path traversal；
- 相同輸入可重現相同輸出。

## App Store Connect

- Primary language 改為 English (U.S.)，並重新讀回確認。
- 繁中與英文名稱、副標題、描述、關鍵字、支援 URL、隱私 URL 與版權皆
  由 repository metadata 作為唯一來源。
- 上傳並選定 Build `1.0.0 (2)`。
- 重新上傳 18 張修正後截圖並逐語言、逐平台確認順序。
- 維持：
  - Free；
  - 175 個國家或地區；
  - Public；
  - Data Not Collected；
  - 不需要登入；
  - Game Center off；
  - Apple silicon Mac off；
  - Apple Vision Pro off；
  - Manually release this version。
- 「加入以供審查」可以顯示，但不得點擊。
- App Review submissions 必須仍無新提交。

## Release audit 強化

計算器 audit 另外鎖定：

- Apple ID `6795877892`；
- exact bundle、version 與 Build 2；
- production linked package 的 network／analytics／tracking／commerce
  dependency boundary；
- 計算器專屬的公開 privacy wording；
- 兩份 metadata 都含一致版權；
- screenshot exact scene matrix 與完整 PNG decode。

這些強化只適用於獨立計算器，不修改 KnitNote 的 metadata 或其既有
keyword audit。先前使用者核准的 Plan B 仍有效：完整 repository suite
若只剩既有 KnitNote keyword-duplication failure，必須誠實記錄，不能宣稱
全綠。

## 實機驗收

Build 2 上傳前，至少在既有實體 iPhone 與 iPad：

- 安裝 exact archived/exported candidate；
- 確認 app identity 與 `1.0.0 (2)`；
- 啟動後滿版且沒有裁切；
- 密度計算與單排／跨排加減針各跑一個既有已知案例；
- 旋轉、背景／前景與重新開啟正常；
- KnitNote 連結仍標示為另一款 App；
- 沒有非預期權限提示。

使用者實機觀察仍是接受門檻。機器 build、simulator 或 screenshot 不能取代
實機確認。

## 乾淨發佈分支

目前工作分支保留為本機備份，不改寫、不刪除。

Build 2、本地與遠端驗證完成後：

1. 從已驗證且包含公開支援頁面的主線基準建立新的本機發佈分支。
2. 將最終 calculator net change 以乾淨 squash commit 帶入。
3. 在建立 commit 前移除證據中的私人 Email、UDID、CoreDevice ID、
   provisioning UUID、安裝容器路徑與程序 PID。
4. 保留非敏感的裝置型號、OS 版本、測試結果、Git SHA 與 artifact hash。
5. 掃描整個新分支歷史，確認敏感值不存在。
6. 不 push、不 merge；另行取得使用者授權後才整合。

Raw screenshot sources、brainstorm 與 cache 目錄維持本機、不納入候選或
乾淨分支。

## 測試與失敗處理

所有程式與 script 修正採 TDD：

1. 先新增會因目前缺陷失敗的行為測試。
2. 確認失敗原因正確。
3. 實作最小修正。
4. 跑 focused tests、screenshot validator、calculator static audit。
5. 重跑完整 `swift test`，如實記錄既有 KnitNote Plan B 例外。

任何下列情況都停止遠端候選替換：

- Build 2 無法綁定唯一 SHA；
- 截圖 validator 或視覺檢查失敗；
- Release 畫面與截圖不一致；
- 實機驗收失敗；
- App Store Connect 顯示的 Build、語言或截圖與證據不同；
- 敏感資料仍存在於乾淨發佈分支歷史。
