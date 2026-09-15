# 棒針織法字典驗證記錄

日期：2026-09-15。分支 `feature/knitting-stitch-dictionary`，工作目錄 `.worktrees/main-mac-share-merge`。功能基準 HEAD `640c08e337130531b42ad682ce889cec4b7f0364`；本次測試另包含 App 資源測試、Xcode 專案測試檔案登錄、刪除未使用的 `sectionKeys`／對應鏡像斷言、17 個字串修正與明列 185 個新增鍵的 oracle 允許清單。不是發布或實機驗收記錄。文末「final review fixwave」記錄在 `8f3e709d1bf6f570501e09cbc1cc0c5c490afbf9` 之後的縮寫 metadata／標題／測試修正；前面的完整 Core aggregate 是該基準的歷史證據。

## 命令與結果

Xcode 26.6 (17F113)，macOS destination；停用程式碼簽署。所有 Xcode 命令從上述工作目錄執行。

| 驗證 | 命令 | exit | 證據／結果 |
|---|---|---:|---|
| Python 完整資料與反例 | `/usr/bin/python3 scripts/validate_stitch_dictionary.py --self-test` | 0 | `/private/tmp/knitnote-stitch-validator-final.log`；15 operations、61 diagrams、185 keys × 13 翻譯。有效 fixture exit 0；缺韓文步驟、格式型別錯誤、缺圖、空白翻譯、錯誤座標五個 fixture 均 exit 1。 |
| App focused tests | `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /private/tmp/knitnote-stitch-mac -only-testing:KnitNoteAppTests/StitchDictionaryPresentationTests -only-testing:KnitNoteAppTests/StitchDictionaryResourceTests test CODE_SIGNING_ALLOWED=NO` | 0 | `/private/tmp/knitnote-stitch-app-final-tests.log`；6 tests／2 suites，0.967 秒。xcresult：`/private/tmp/knitnote-stitch-mac/Logs/Test/Test-KnitNote-2026.09.15_14-52-38-+0800.xcresult`。 |
| macOS build | `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /private/tmp/knitnote-stitch-mac build CODE_SIGNING_ALLOWED=NO` | 0 | `/private/tmp/knitnote-stitch-mac-final-build.log`，BUILD SUCCEEDED。 |
| iOS Simulator build | `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/knitnote-stitch-ios build CODE_SIGNING_ALLOWED=NO` | 0 | Controller 回報修正後 `/private/tmp/knitnote-stitch-ios-repair-build.log` exit 0，BUILD SUCCEEDED（line 628）；包含 17 字串修正與 sectionKeys 刪除的凍結工作樹。 |

App 測試從實際 hosted `Bundle.main` 載入 JSON，不用 repo 檔案替代 App bundle。確認 15 條目、61 個唯一圖 ID、每張圖的座標與 Path 結構、條目／來源／步驟／符號引用完整。逐一讀取 13 個實際 `lproj/Localizable.strings` 的非空鍵，再驗證資料引用；因此英文 fallback 不會掩蓋缺少的資料翻譯。另有缺圖引用反例，以及現有載入錯誤、搜尋／分類／清除／重複次数和 hosted SwiftUI 控制內容測試。

首次新檔案未經 XcodeGen 登錄的 only-testing 命令 exit 0 但執行 0 tests，不能作為成功證據。`xcodegen generate` 登錄後，測試側將預期條目數暫設 16；實際 15 使該斷言失敗，2 tests／1 issue，exit 65，`/private/tmp/knitnote-stitch-app-resource-red.log`。這是斷言敏感度檢查，不是既有產品缺陷或行為 TDD。還原正確預期 15 後取得上表 GREEN；未改動產品 JSON 或圖形資源。

Xcode logs 有既有 `AppIntents` metadata extraction skipped warning（沒有 AppIntents.framework dependency）、`com.apple.linkd.autoShortcut` connection／registry 訊息，以及未簽署時的 strip-bitcode 提示。這些是工具鏈／系統服務雜訊，focused tests 與 build 仍 exit 0；結果並非無警告輸出。

## 內容審查

詳見 `content-review.md` 與 `previews/full/`。Task 4 作者及獨立 reviewer 完成 15 條目 × zh-Hant／zh-Hans／en／ja／ko 的 75 名稱，所有符號變體、61 張資料向量圖對應的 32 張明／暗預覽，並對照記錄的主要來源。13 語介面與操作內容已結構驗證並獨立檢閱。圖為原創操作狀態示意，不聲稱證明完整三維線圈拓撲。外部母語編織編輯審閱未執行；不是額外新增的合約 gate。

## Runtime 與未驗證範圍

### 使用者回饋後改為外部教學連結

教學連結版更新後，使用者對「設定 → 字典 → 下針，確認操作流程圖已移除，並試點 Gosyo 或日本 Vogue 教學連結」回覆「正常」。記錄為 iPad 新介面及所試外部連結的使用者驗收通過；未指定試點哪個來源，不能據此宣稱兩個網址或所有條目連結均經實機測試。原站教學需要網路，舊版內建流程圖的離線驗收不適用於外部教學內容。

使用者重新接上 iPad 後，devicectl 顯示 Lzzipadair5 available (paired)；教學連結版 install 成功（exit 0，databaseSequenceNumber 1740）。先前裝置 unavailable 的安裝阻礙已解除。新介面與外部連結仍待實機操作確認。

使用者與太太指出原操作圖無法理解，後續生成樣稿亦有穿針錯誤；前述操作／無障礙验收不構成教學正確性認可。使用者明確要求「放教學連結，不要做流程圖」。已從詳情移除整個操作步驟、流程圖與配色圖例，移除只適用於自繪操作圖的注意事項。保留名稱、縮寫、含義、來源限定的織圖符號、針數及相關織法。

詳情以「教學與參考連結」顯示原站來源（13 語標題同步修改）；下針優先加入已開啟查證的 Gosyo 表目及日本 Vogue 表目影片／插圖頁。來源包含術語、符號、書籍參考，並非所有來源都是影片。原操作圖資料暫留在內部資源供既有資料契約相容，詳情不再呈現，也未加入後續生成的錯誤樣稿。

`/usr/bin/python3 scripts/validate_stitch_dictionary.py --self-test` 完成 valid 與反例檢查，log `/private/tmp/knitnote-links-validator.log`；實機 xcodebuild exit 0、BUILD SUCCEEDED，log `/private/tmp/knitnote-links-build.log`；git diff --check 通過。嘗試更新指定 iPad 時 CoreDevice 回報找不到裝置，未安裝這次變更。需要裝置重新連線後確認新介面；不能沿用舊版實機驗收聲明。

### iPad 實機候選已安裝，等待使用者操作驗收

使用者依後續 VoiceOver 驗收步驟（開啟 VoiceOver、字典逐項移動焦點、開啟下針、朗讀名稱／步驟／圖解說明、返回列表）回覆「正常」。記錄為此 iPad Air 5 候選的 VoiceOver 流程使用者驗收通過。至此本輪安排的 iPad 離線與 VoiceOver 驗收完成；不外推至全部條目、語言、iPhone 或 macOS VoiceOver。早期段落所述這兩項待驗收狀態由本紀錄更新。

後續使用者對「確認原作品、飛航模式且 Wi-Fi 關閉、重開 App、搜尋 k1 並查看圖文與滑動」的驗收步驟回覆「正常」。記錄為此 iPad Air 5 候選的離線流程使用者驗收通過；非自動化觀察，不外推至所有條目或其他裝置。VoiceOver 仍待驗收。

使用者選擇並連接 Lzzipadair5（iPad Air 第 5 代，iPadOS 27.0），原 KnitNote 為 1.7.0（15）。功能 HEAD 838f5c8，`xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/knitnote-stitch-device build` exit 0，log `/private/tmp/knitnote-stitch-device-build.log`；codesign --verify --deep --strict 無錯誤。使用既有開發簽署與 bundle ID，版本號未變。

devicectl 第一次 install 遇連線失效；重新列舉裝置後重試成功（exit 0），未卸載或清除 App。一般 launch 成功（exit 0）。這只證明安裝與啟動命令成功，資料保留狀況及離線／VoiceOver 功能仍待使用者實際確認，不宣稱實機驗收通過。

### 最大文字尺寸與模擬器能力確認

在 signed iPad 一般模式，先讀取 content_size 為 extra-large，改設 accessibility-extra-extra-extra-large。實際截圖確認下針步驟 1 的文字完整換行、圖形可見，來源韓文換行，返回列表後搜尋欄與下針／上針摘要可讀，未見文字截斷。這是上述頁面的最大字體抽查，不外推至全條目／全語言。測試後已還原 extra-large。

開啟此 iOS 26.5 模擬器的 Settings：VoiceOver 搜尋無結果；實際進入輔助使用頁，視覺區只有懸浮文字、顯示與文字大小、動態效果、語音內容，未提供 VoiceOver。設定側邊欄亦未提供 Wi-Fi／飛航模式；沒有透過關閉宿主 Mac 網路來模擬離線。因此 VoiceOver 和實際斷網驗收仍需可提供這些能力的裝置，不能以 AX tree 或本地 Bundle 靜態檢查代替。

### 後續手勢與文字抽查

使用者後續回覆「可以滑動」，確認目前 signed iPad 模擬器下針教學頁可手動滑動。本項以使用者實測回報通過；先前自動 drag 無位移不再視為此頁的產品阻礙。此結果不外推至 iPhone、實機或 VoiceOver 手勢。離線、最大輔助文字尺寸及 VoiceOver 驗收仍未完成。

在 signed iPad 一般模式進入下針詳情，Raise 視窗後的自動 drag 仍未造成截圖位移。AX 點選後段圖解後，再透過 Simulator Features → Increase Preferred Text Size 放大一級，截圖已顯示步驟 2、3 與部分步驟 4；可見的文字與圖形未截斷。此結果證明後段可呈現，但不能證明觸控拖曳成功，也不是最大輔助文字尺寸驗收。

已請使用者在保留的 iPad 模擬器教學頁實際拖曳，以分辨控制工具限制與產品問題，尚待回覆。模擬器 simctl 公開命令提供 content_size，但未列出網路停用或 VoiceOver 控制；尚未執行離線／VoiceOver 驗收。原始碼仍由本機 Bundle 載入字典與圖解，這項靜態證據不代替離線裝置測試。

### iPad 一般啟動阻礙已解除

使用者批准資料庫診斷後，確認先前 QA 使用 `CODE_SIGNING_ALLOWED=NO`。iOS 的 `PatternStorageLocations.live()` 必須取得 `group.com.phillon.KnitNote`，否則拋出 appGroupUnavailable，再由 JSONProjectStore.live 轉為 archiveUnavailable。

相同功能 HEAD 838f5c8，以 `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/knitnote-stitch-ios build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 重建，exit 0、BUILD SUCCEEDED；log `/private/tmp/knitnote-stitch-ipad-signed-build.log`。生成的 KnitNote.app-Simulated.xcent 明列既有 App Group，link 命令將 simulator entitlements 嵌入 Mach-O；不能僅以 codesign 顯示空字典判斷模擬器權限。

安裝到原任務專用 iPad，未執行卸載或資料清除。一般 launch 不帶示範參數，CUA 實際看到作品空狀態，原錯誤消失；設定 → 棒針織法字典成功顯示 15 項。此次是空白 QA 環境，沒有驗證使用者資料遷移；simctl install 後容器 UUID 改變，不宣稱容器路徑相同。

本次問題由 QA 建置權限缺失造成，恢復既有模擬器簽署流程後解除，無產品程式碼修改。後續 iOS 操作驗收使用此 signed build。其餘手勢、離線、大字體、VoiceOver 等仍待驗證；以下先前資料庫阻礙文字為歷史紀錄。

### 2026-09-15 解鎖後補驗（功能 HEAD 838f5c8）

以下新觀察取代本節後方的「Mac locked」現況；後方文字保留先前驗證歷史。使用上述最新 iOS／macOS build，未改產品程式碼。

- iPhone 17 Pro：計算工具進入字典成功，列表顯示明確縮寫；搜尋 `p3` 僅回傳上針並顯示重複 3 次。進入詳情，截圖確認單一標題、五語名稱及 `p`；AX 讀到三步、來源，以及「每次操作的針數」1／1／0。AX 讀到頁尾不等於實際已捲到頁尾。
- iPad Pro 13 M4：計算工具進入字典、搜尋 `k1`、進入下針詳情成功。截圖確認重複 1 次、五語名稱、`k`、日本出版社符號與來源文字；AX 包含四步及韓國來源。搜尋後索引失效時已重新取得 AX，未當作產品故障。
- macOS：計算工具與一般模式 Settings → Stitch dictionary 入口均實際開啟。`k2tog` 搜尋後切換符號模式、點卡片進詳情成功；捲動區的 Scroll Down 動作實際移動到步驟、圖例、針數、注意事項、來源與相關織法，截圖確認。返回保留 `k2tog`／符號模式；清除後保留模式；選擇交叉針並 Return 套用後僅有左右兩卡，再清除恢復全部。切回列表搜尋 `k1` 顯示重複 1 次。
- macOS 原有計算工具回歸：密度輸入樣片 10 公分／20 針、目標 30 公分，結果 60 針、每公分 2 針；等距加針輸入 20 → 24、保留左右邊針，結果加 4 針，展開完整指示並返回成功。
- macOS 語言抽查：以隔離示範參數載入德文、芬蘭文。德文列表、SSK 長標題及第一步換行，芬蘭文列表截圖未見截斷；日韓名稱字形亦可見。這不是全部語言／視窗尺寸／裝置的排版通過聲明。

剩餘限制：iPhone 的 scroll 與 iPad 的 drag 均未造成截圖位移；macOS 同一功能可捲動，但尚無證據判定 iOS 手勢問題的原因，不能宣稱 iOS 長頁驗收通過。任務專用 iPad 不帶示範參數的一般啟動顯示「無法開啟已儲存的資料庫」，Settings／專案正常路徑未驗收；未覆寫或清除資料以繞過問題。曾誤傳 `-storeScreenshotMode NO`，依現有 resolve 契約屬 invalid，已改以不帶參數重啟，不能把該次退出算成產品缺陷。

仍待驗證：iOS 完整手勢與設定／專案雙入口、停用網路後重跑、大字體、VoiceOver、完整 macOS 鍵盤導覽、更多語言／尺寸，以及任何實機操作。一般 Mac 模式只唯讀進入設定與字典；沒有更改設定或資料。未合併、推送或上傳；Task 6 手動驗收仍未全部完成。

Controller 在先前 iPhone Simulator build 實際看到「計算器 → 字典 → 搜尋 k1 → Knit 重複 1」，AX 內容包含四步及日／韓來源。之後刪除重複導覽標題並完成新版 iOS build；不能把先前檢視視為新版全部 runtime 流程通過。

隔離 iOS 26.5 simulators：iPhone 17 Pro `ECE985CD-4DFE-4286-B541-1BC05A8D9A30`；iPad Pro 13 M4 `063BDACC-27DA-472E-9D4E-D18D46A522EF`。新版已安裝兩者並啟動 iPhone demo。後續 CUA 回報 Mac locked，無法自動解鎖，互動 QA 暫無新證據。

未驗證：iPad／macOS 完整互動、各平台設定與專案雙入口、p3／k2tog runtime 流程、符號點擊及手勢捲动、返回／清除／改分類、停用網路後重跑、大字體及長德文／芬蘭文／日韓 runtime 排版、VoiceOver、macOS 鍵盤導覽、兩個原有計算器各完整一例、任何實機測試。資源打包與純本地查詢證明架構可離線，不能替代停用網路的裝置驗收。未宣稱跨平台 runtime 全部驗收通過。

## aggregate 發現與修正

唯一 final aggregate 發現 17 issues：14 個新增字串未沿用既有 pattern 術語、English purl 的 `around` 被 round 術語的子字串檢查命中、oracle 沒有明列新增字典鍵，以及簡中 KFB 標題「针目」接「前后」意外組成禁用詞「目前」。修正 14 處圖解／Muster／patron／編み図／mønster 用語；purl 改為同義 `Wrap the yarn over the right needle`；KFB 改為「在同一针的前侧和后侧各织一下针」；沿用 oracle 的明列新鍵機制加入全部 185 個字典鍵。未縮小術語匹配範圍、修改 glossary 或放寬禁用詞規則。

修正後命令 `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH PYTHONPATH=/private/tmp/knitnote-stitch-python-fixture swift test --no-parallel --scratch-path /private/tmp/knitnote-stitch-catalog --filter 'LocalizationContractTests|KnittingTerminologyContractTests'` exit 0，96 tests／4 suites，1.593 秒。filter 同時選到另兩個相關 localization suites。證據 `/private/tmp/knitnote-stitch-contract-repair.log`。Python validator、六個 App tests 與 macOS build 於修正後重新執行，上表為最新證據。

## Core aggregate

首次完整執行 `swift test --no-parallel`（功能 HEAD 640c08e）自然完成 exit 1，2992 tests／220 suites，2231.481 秒，恰有上述 17 issues；没有額外失敗。證據 `/private/tmp/knitnote-stitch-final-core.log`。此執行沒有被中斷。

Controller 另以已建置的修正後執行檔執行完整 aggregate：`PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH PYTHONPATH=/private/tmp/knitnote-stitch-python-fixture swift test --scratch-path /private/tmp/knitnote-stitch-catalog --skip-build --no-parallel`。證據 `/private/tmp/knitnote-stitch-corrected-core.log`；完整執行 exit 0，2992 tests／220 suites，2206.305 秒，全部通過。執行檔為上述 96 contracts 修正驗證建置的最新版本；這是 `8f3e709d1bf6f570501e09cbc1cc0c5c490afbf9` 基準的完整測試證據；後續 final review fixwave 新增顯示 metadata 並修改標題，因此不能把這次完整通過描述為最終 metadata snapshot 的完整重跑。


## final review fixwave

基準 `8f3e709d1bf6f570501e09cbc1cc0c5c490afbf9`。修正列表／詳情漏掉英文縮寫、`p3` 針數沒有明列每次操作，以及缺圖反例可能因無效翻譯鍵而通過的三個 review findings。

- `StitchEntry.displayNotation` 為可省略欄位，synthetic initializer 預設 nil；既有 fixture 仍可解碼。提供時必須非空且與已記錄 alias 相符（忽略大小寫）。15 條 bundled metadata 是明確選定的現有 notation，沒有從 alias 排序推測標準。
- 列表與英文名稱區實際 Text 顯示 notation；`stitchDictionary.detail.count` 原有鍵改為明確的每次操作文字，涵蓋 13 語。重複次數與 consumes／produces／net 的原有未乘算值保持一致；圖形與操作方法未改動。
- hosted SwiftUI probe 附在實際顯示的 Text／標題 view 上；列表 summary probe 由父層移到 summary Text，避免蓋掉子層 notation preference。測試實際 `p3` 查詢結果的詳情內容，而非新增未使用的 presentation 鏡像屬性。
- 缺圖反例先以 App bundle 英文非空翻譯鍵驗證原始目錄，再移除已記錄圖 ID，精確斷言 `.missingReference(removedDiagramID)`。

RED：修改測試後、產品修正前，`swift test --no-parallel --scratch-path /private/tmp/knitnote-stitch-catalog --filter StitchCatalogTests` exit 1，12 tests／1 suite、18 issues（15 個 missing metadata 與 3 個非法 metadata 未拒絕），`/private/tmp/knitnote-stitch-final-fix-core-red.log`。App presentation hosted tests exit 65，5 tests／1 suite、7 issues，列表／詳情 notation 缺漏與新增 counted-detail semantic probe 缺漏；初始 count／repeat 的 nil 是尚未加 probe，不能解讀為原本沒有 count／repeat Text，`/private/tmp/knitnote-stitch-final-fix-app-red.log`。Python 加入 blank-notation 反例後 exit 1，因 validator 接受非法 metadata 而 self-test failed，`/private/tmp/knitnote-stitch-final-fix-validator-red.log`。皆使用正確需求預期；沒有假造錯誤預期來製造 RED。既有缺圖測試本身的精確化屬測試修正，未虛構產品 RED。

GREEN：

| 驗證 | 命令 | exit／結果 |
| --- | --- | --- |
| 四組字典與翻譯契約 | `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH PYTHONPATH=/private/tmp/knitnote-stitch-python-fixture swift test --no-parallel --scratch-path /private/tmp/knitnote-stitch-catalog --filter 'StitchCatalogTests\|StitchSearchTests\|StitchDiagramTests\|StitchDictionaryContentTests\|LocalizationContractTests\|KnittingTerminologyContractTests'` | exit 0；128 tests／8 suites，1.788 秒；`/private/tmp/knitnote-stitch-final-fix-core-green.log`。filter 亦包含兩組相關 localization suites。 |
| Python 實際內容與反例 | `/usr/bin/python3 scripts/validate_stitch_dictionary.py --self-test` | exit 0；15 operations／61 diagrams／185 keys × 13，valid fixture exit 0、原有五個與新增兩個非法 notation fixture 均 exit 1；`/private/tmp/knitnote-stitch-final-fix-validator-green.log`。 |

最終 App focused 命令沿用上表六個既有測試的 `xcodebuild` 命令，新增 counted-purl hosted 測試；exit 0，7 tests／2 suites，1.255 秒。證據 `/private/tmp/knitnote-stitch-final-fix-app-green.log`；xcresult `/private/tmp/knitnote-stitch-mac/Logs/Test/Test-KnitNote-2026.09.15_15-44-10-+0800.xcresult`。包括缺圖反例的原始目錄有效性檢查。macOS／iOS build 結果列在本節後續記錄。此次依 review 建議僅重跑受影響範圍，未重跑 37 分鐘完整 Core aggregate；前述 2992 tests／220 suites 全綠保留其 `8f3e709` 基準 provenance。Mac locked 的互動限制持續存在；hosted semantic tests 不等於 manual QA，未新增實機、VoiceOver 或全平台互動驗收聲明。


最終 macOS build：`xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /private/tmp/knitnote-stitch-mac build CODE_SIGNING_ALLOWED=NO`，exit 0，BUILD SUCCEEDED，`/private/tmp/knitnote-stitch-final-fix-mac-build.log`。Controller 最終 iOS incremental build：`xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/knitnote-stitch-ios build CODE_SIGNING_ALLOWED=NO`，session 24464 exit 0，`/private/tmp/knitnote-stitch-final-fix-ios-build-2.log` line 154 BUILD SUCCEEDED；在 summary preference 移到 Text 之後執行。`git diff --check` exit 0。
