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
