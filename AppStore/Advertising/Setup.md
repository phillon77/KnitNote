# Knitting Calculator 廣告設定

狀態（2026-09-17 更新）：AdMob 帳號與 Calculator 首頁橫幅已建立，影片與自動更新已停用；正式 ID 已接入本機，但廣告啟用旗標仍為 NO。根目錄 app-ads.txt 已發布且 HTTP 200，但 AdMob 驗證仍未通過；商店缺少開發者網站（行銷網址），已在 1.2.0 準備提交草稿的全部 13 種語言補上，需待新版公開生效。帳號審核及隱私發布尚未完成，尚無收益啟用證據。詳見 AccountSetup-2026-09-17.md。

## 帳號設定步驟（1–5 已完成並讀回，6 待完成）

1. 開啟 https://admob.google.com/ ，用你要收取收入的 Google 帳號註冊。所在地、身分、付款與稅務資料請依自己的實際情況填寫；密碼、驗證碼與銀行資料不需要傳到對話。
2. 在「應用程式」新增 iOS App，選擇 App Store 上的 Knitting Calculator。核對開發者與 `com.phillon.KnittingCalculator`，避免選到同名 App。
3. 建立 **Banner／橫幅** 廣告單元，名稱可用 `Calculator Home Banner`。
4. 進階設定只保留 **Text, image & rich media**，取消 **Video**。先關閉自動重新整理，避免廣告頻繁變換；平台可能仍提供動畫素材。
5. 不建立插頁、獎勵影片、App 開啟廣告。不啟用可收合橫幅或子母畫面廣告，也先不串接其他廣告聯播網。
6. 在「隱私權與訊息」完成適用地區的訊息設定；程式端會依 UMP 的結果判斷是否可請求廣告。必須在真機驗證同意與變更選擇流程。

## 完成後提供的非機密識別資料

- **AdMob App ID**：格式 `ca-app-pub-…~…`。
- **首頁 Banner Ad Unit ID**：格式 `ca-app-pub-…/…`。
- **app-ads.txt 的 Google 個人化代碼片段**：由 AdMob 畫面複製，不自行猜測 publisher ID。

影片停用、訊息設定與 App 驗證狀態也需要讀回確認。取得 ID 不表示廣告已可正式供應。

## 開發與發布分工

開發期間只使用 Google 測試廣告。正式版本維持停用，直到正式 ID、後台設定、隱私揭露與裝置驗證完成。Google SDK 接入後，不可繼續沿用「不含廣告 SDK／完全不蒐集資料」的舊版文字。

現有支援網址在 `https://phillon77.github.io/KnitNote/`。app-ads.txt 是依網站主機根目錄尋找，不能只把檔案放到 `/KnitNote/app-ads.txt` 就當作完成。需要確認 `https://phillon77.github.io/app-ads.txt` 的發布位置與 App Store 的 Developer Website／Marketing URL，再另行準備發布。

第一階段只有首頁小橫幅。永久移除廣告的價格與內購另做下一階段，不在這次預先建立收費商品。

## 開發設定

- Debug 一般啟動不請求廣告；啟動參數 `-calculatorTestAds` 使用 Google 固定尺寸測試 Banner。
- `-calculatorBannerPreview` 只顯示本機版面示意，不做廣告網路請求。
- 截圖模式與 XCTest 禁止廣告；截圖根畫面另外注入停用物件。
- Release 的 `CALCULATOR_ADS_READY` 保持 `NO`，App ID 與 Banner ID 已換成此帳號正式值；Debug 另行覆寫成 Google 測試 App 與測試 Banner ID。網站驗證、隱私設定與發布驗收通過後才啟用正式廣告。
- 橫幅影片由 Google 預設靜音，但正式單元仍必須停用 Video。Google 的全域靜音 API 要配合 App 使用者的靜音控制，本 App 沒有這個控制，因此不濫用該 API。
- 既有 `knitting_calculator_release_audit.sh` 是 1.1.0 (4) 的無廣告發布稽核，會拒絕新增 Google 套件。廣告版本的封存稽核必須在發布準備時更新，不能用舊版通過紀錄宣稱新版本通過。

## 發布前紀錄

- [ ] 真正的 App ID 與首頁 Banner ID 已核對。
- [ ] Video 關閉，自動重新整理關閉，沒有其他廣告聯播網。
- [ ] UMP 訊息與隱私選項入口完成，拒絕或離線時仍能計算。
- [ ] iPhone/iPad 確认沒有聲音、畫面覆蓋或誤觸；進入計算工具後不顯示橫幅。
- [ ] Google App 驗證、app-ads.txt 與帳號狀態完成。
- [ ] 新版隱私政策與 App Store 資料揭露依實際 SDK 行為確認。
- [ ] Release 沒有測試 ID，Screenshot 模式不會啟動廣告。
- [ ] 由使用者另外批准發布；此設定文件本身不授權送審或上線。

官方參考（2026-09-17 查閱）：

- [建立橫幅廣告單元](https://support.google.com/admob/answer/7311346?hl=en)
- [隱私訊息整合](https://developers.google.com/admob/ios/privacy)
- [SDK 資料揭露](https://developers.google.com/admob/ios/privacy/data-disclosure)
- [app-ads.txt 設定](https://support.google.com/admob/answer/9363762?hl=en)

## Publisher consent QA mode

The European message Calculator European Privacy was published on 2026-09-17 and its list status read back as 已發布. UI says propagation may take up to one hour.

For a dedicated Debug build only, override CALCULATOR_ADMOB_APP_ID with the real publisher App ID while retaining Google's sample Banner ID and CALCULATOR_ADS_READY=NO. Launch with -calculatorTestAds -calculatorConsentTest and supply CALCULATOR_UMP_TEST_DEVICE via environment using the identifier printed by UMP for that test device. Optional -calculatorResetConsent clears only UMP consent before the first update in that app session. Do not use it on the subsequent persistence test launch. Simulator debug identifiers are accepted automatically by UMP; the explicit environment variable is still required by our QA guard.

QA overrides compile only in Debug, require test-ad configuration and an explicit flag/nonempty device identifier, and are ignored by Release. No test device identifier is committed. Normal Debug continues to use Google's sample App ID; real-App-ID overrides are build-command arguments only.
