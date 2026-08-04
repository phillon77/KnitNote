# KnitNote 1.3.1 YouTube 織圖連結設計

日期：2026-08-04  
狀態：使用者已確認設計，等待書面規格審閱

## 目標

讓使用者能在 KnitNote 的織圖檔案匣收藏 YouTube 教學或織圖影片連結，再把同一個連結連結到零個、一個或多個作品。點擊影片後交由 YouTube App 或系統預設瀏覽器開啟，不在 KnitNote 內嵌播放。

本功能納入 KnitNote 1.3.1，支援 iPhone、iPad 與 Mac；Apple Watch 不在本次範圍。

## 已確認產品決策

- YouTube 連結是織圖檔案匣內的新織圖類型，不建立獨立「影片庫」。
- 一個 YouTube 織圖可連結多個作品，沿用現有 `PatternProjectUsage` 關係。
- 影片點擊後從 YouTube App 或預設瀏覽器外部開啟，不使用 WebView、內嵌播放器或 YouTube API key。
- 貼上連結後嘗試自動取得標題與縮圖，使用者儲存前可編輯標題。
- 自動取得資料失敗時，仍允許手動輸入標題並以預設 YouTube 圖示保存。
- 只儲存必要的連結與文字資料；縮圖為可重建快取，不納入備份。
- 繁體中文與英文同步支援。

## 使用流程

### 從織圖檔案匣新增

織圖首頁右上角的「＋」改為簡單選單，只提供兩個主要選項：

1. 「匯入 PDF 或圖片」：沿用現有檔案選擇器。
2. 「加入 YouTube 連結」：開啟輕量新增畫面。

YouTube 新增畫面流程：

1. 貼上 YouTube 網址。
2. 按「讀取資料」，驗證網址並在背景取得標題與縮圖。
3. 顯示可編輯標題、縮圖或預設 YouTube 圖示。
4. 按「加入」後才寫入織圖檔案匣。

「加入」在網址無效或標題為空時維持停用。關閉畫面不建立任何資料。

### 重複連結

同一個 YouTube 影片以正規化後的 video ID 判斷重複，不以使用者貼上的完整字串判斷。

- 若織圖檔案匣已有同一影片，不建立新項目，改為提示並允許開啟已有項目。
- 若從作品內新增同一影片，使用已有織圖並建立或恢復該作品的連結。
- `youtu.be` 短網址、`youtube.com/watch?v=`、`youtube.com/shorts/`、`youtube.com/live/` 及其行動版網域只要指向同一 video ID，都視為同一影片。
- 有 `v` 參數的播放清單網址只使用 video ID；只有播放清單而沒有影片的網址不接受。

### 從織圖檔案匣與作品開啟

- 織圖清單列顯示縮圖、完整標題、「YouTube 影片」類型及已連結作品數。
- 織圖詳細頁顯示標題、備註、連結網址、連結的作品及「在 YouTube 開啟」。
- 作品內的織圖清單沿用同一列樣式；點擊 YouTube 項目時直接對外開啟，不進入 `PatternReaderView`。
- 已完成作品仍可開啟連結，但連結與解除規則維持現有作品政策。
- 外部開啟使用正規 YouTube HTTPS 網址。iPhone 或 iPad 已安裝 YouTube App 時可由系統以 Universal Link 開啟；否則使用預設瀏覽器。Mac 使用預設瀏覽器。

## 資料架構

### 沿用織圖類型

`PatternKind` 新增 `.youtube`。YouTube 項目仍遵守現有三層邊界：

- `PatternAsset`：代表可重用的 YouTube 連結資產。
- `StoredPattern`：保存使用者看到的標題、備註、建立日期與最近開啟日期。
- `PatternProjectUsage`：維持一個織圖與一個作品的連結，允許同一影片連結多個作品。

YouTube `PatternAsset` 的 `storedFilename` 指向小型 JSON 側寫檔，而不是影片檔。側寫檔只包含：

- metadata schema version。
- YouTube video ID。
- 正規網址 `https://www.youtube.com/watch?v=<videoID>`。

`sha256` 為正規網址 UTF-8 資料的 SHA-256，作為現有重複偵測與完整性邊界。`byteCount` 是側寫檔實際大小，`pageCount` 固定為 `nil`。

`PatternProjectUsage.readingState` 對 YouTube 類型維持預設值且不使用。YouTube 項目不具有頁碼、縮放、高亮、頁面筆記或手寫標記。

### 網址解析與資訊取得

建立無 UI 依賴的網址解析器，只負責：

- 驗證 HTTPS 且 host 為可接受的 YouTube 網域。
- 取出並驗證 video ID。
- 產生唯一正規網址。

影片標題與縮圖使用 Apple `LPMetadataProvider` 嘗試取得，並藉由可注入的小型 metadata-fetching 邊界集中處理 timeout、取消與失敗。核心模型與網址解析不匯入 LinkPresentation，以保持可測試性。

縮圖只寫入現有可重建縮圖快取，不寫入 archive、`StoredPattern`、UserDefaults 或備份。使用者修改後的標題保存在 `StoredPattern.displayName`，後續重新取得 metadata 不得覆蓋。

### 資料版本與相容性

`ProjectArchive.currentVersion` 從 11 提升到 12。版本 1 至 11 升級到 12 時不產生 YouTube 資料，只保留原有專案、織圖、閱讀狀態、毛線與備份行為。

這個版本提升使舊版 App 能拒絕不支援的新 archive，而不會因無法解碼 `.youtube` 而部分讀取或丟失資料。

## 備份、還原與空間

備份包含：

- YouTube JSON 側寫檔。
- `StoredPattern` 的標題、備註與日期。
- 所有啟用與停用中的作品連結。

備份不包含：

- YouTube 影片內容。
- 縮圖快取。
- `LPLinkMetadata` 物件或其系統快取。

還原後在離線狀態仍可顯示已保存標題與預設 YouTube 圖示。下次有網路且畫面需要縮圖時再以低優先權重建，失敗不影響還原成功。

每個 YouTube 項目的正式資料只是小型 JSON 與 archive 內幾個文字欄位，不儲存影片，因此不會顯著增加 App 或備份體積。縮圖快取必須可被安全清理與重建。

## 錯誤與降級行為

- 無效 host、缺少 video ID、只有播放清單或非 HTTPS 網址時，顯示本地化錯誤且不允許儲存。
- metadata 取得 timeout、斷網或沒有縮圖時，顯示非阻斷說明，改由使用者輸入標題，並使用預設 YouTube 圖示。
- 保存資料或 JSON 側寫檔失敗時，整筆交易失敗，不發布半完成織圖。
- 縮圖快取寫入失敗不回滾已成功保存的連結。
- 對外開啟失敗時，保留連結並顯示本地化錯誤，不自動刪除項目。
- YouTube 影片日後被刪除、轉為私人或限制地區時，KnitNote 只能繼續保存連結和標題，不保證外部內容可用。

## 多語系與輔助使用

- 新增介面文字與錯誤訊息同步提供繁體中文與英文。
- 列表的 VoiceOver 摘要讀出標題、「YouTube 影片」與連結作品數。
- 「讀取資料」、「加入」與「在 YouTube 開啟」有明確本地化 VoiceOver 名稱與狀態。
- 取得 metadata 時宣告進度；成功、降級為手動輸入或發生錯誤時均提供可讀訊息。
- 操作不只靠縮圖或顏色表達類型與狀態。
- 動態字級放大時，網址、標題、錯誤和主要操作不得被截斷或推離可視區域。

## 測試策略

### 核心單元測試

- 接受各種支援的 YouTube 網址並產生相同正規網址。
- 拒絕伪裝 host、非 HTTPS、空 video ID、無影片的播放清單與不支援網址。
- 相同 video ID 不因查詢參數、短網址或路徑形式而重複建立。
- metadata 成功、沒有縮圖、timeout、取消與完全失敗均有確定狀態。
- 使用者編輯後的標題不被後續 metadata 覆蓋。

### 模型、儲存與備份測試

- `.youtube` 資產只接受安全、存在且內容符合 schema 的 JSON 側寫檔。
- 建立、重複偵測、永久刪除與清理流程維持 archive 與檔案一致。
- 一個 YouTube 項目可連結多個作品，解除與重新連結沿用現有 usage 語意。
- archive 1 至 11 可升級為 12，新 archive 的 YouTube 側寫檔參照可通過完整驗證。
- 新備份與還原往返保留連結、手動標題、備註與多作品關係，且不包含縮圖快取。
- 離線還原可顯示標題與預設圖示，不因 metadata 取得失敗判定還原失敗。

### 畫面與契約測試

- 織圖首頁的「＋」同時提供檔案匯入與 YouTube 連結。
- 新增畫面不在網址或標題無效時啟用儲存。
- 織圖清單、詳細頁、作品織圖清單與連結選擇器均正確顯示 YouTube 類型。
- 點擊 YouTube 項目只呼叫外部 URL 開啟邊界，不建立 `PatternReaderView`。
- 繁體中文與英文鍵值完整，且不存在未翻譯佔位字串。

### 實機驗收

使用同一個 1.3.1 候選 Build 驗收：

1. iPhone 線上狀態貼上正常 YouTube 連結，確認自動標題、縮圖、編輯標題與儲存。
2. iPhone 離線狀態貼上有效連結，確認可以手動輸入標題並使用預設圖示保存。
3. 使用短網址與標準網址匯入同一影片，確認只存在一個織圖項目。
4. 把同一 YouTube 織圖連結到兩個作品，確認兩邊都可開啟，解除一邊不影響另一邊。
5. iPhone 已安裝 YouTube App 時確認系統開啟 YouTube；未安裝或不可用時確認瀏覽器後備。
6. iPad 直向、橫向與分割畫面確認新增表單、長標題、縮圖、連結與外部返回都不被裁切。
7. Mac 確認網址貼上、metadata 取得、手動降級、詳細頁與預設瀏覽器開啟。
8. 建立含 YouTube 連結的完整備份，於測試資料後還原，確認連結、標題、備註與作品關係都回復，且縮圖可延遲重建。
9. 開啟 VoiceOver，確認新增畫面、織圖列、狀態與外部開啟按鈕可理解且無只靠顏色的資訊。

## 版本與發佈邊界

- 本功能屬於 KnitNote 1.3.1，與織圖內建計算機、設定頁版本／Build 顯示一起規劃。
- 不修改已上架或已核准的 1.3.0 候選 Build。
- Small Business Program 依使用者決定延後到 1.3.1 上架後才處理，不是本版實作、驗收或送審前置作業。
- 規格與計畫完成不等於功能已實作；自動測試與 build 通過也不等於實機驗收完成。
- 必須以唯一候選 commit 完成 iPhone、iPad 與 Mac 全部實機驗收後，才能討論修改版本號、Build、合併、推送、上傳或送審。
- 本規格不授權任何 App Store Connect、定價或方案申請操作。

## 不在本次範圍

- 在 KnitNote 內嵌 YouTube 播放器或 WebView。
- 下載、快取或備份 YouTube 影片內容。
- YouTube 帳號登入、播放清單匯入、訂閱頻道或搜尋 YouTube。
- YouTube Data API、API key、後端服務或使用者追蹤。
- 於 YouTube 項目中使用高亮、頁面筆記、手寫標記、頁碼或織圖計算機。
- Apple Watch YouTube 連結。
- 自訂分類、資料夾、標籤或與本功能無關的織圖檔案匣重構。
