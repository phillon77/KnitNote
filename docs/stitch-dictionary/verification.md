# 棒針織法字典驗證記錄

日期：2026-09-15。分支 `feature/knitting-stitch-dictionary`，工作目錄 `.worktrees/main-mac-share-merge`。功能基準 HEAD `640c08e337130531b42ad682ce889cec4b7f0364`；本次測試另包含 App 資源測試、Xcode 專案測試檔案登錄、刪除未使用的 `sectionKeys`／對應鏡像斷言、17 個字串修正與明列 185 個新增鍵的 oracle 允許清單。不是發布或實機驗收記錄。

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

Controller 另以已建置的修正後執行檔執行完整 aggregate：`PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH PYTHONPATH=/private/tmp/knitnote-stitch-python-fixture swift test --scratch-path /private/tmp/knitnote-stitch-catalog --skip-build --no-parallel`。證據 `/private/tmp/knitnote-stitch-corrected-core.log`；完整執行 exit 0，2992 tests／220 suites，2206.305 秒，全部通過。執行檔為上述 96 contracts 修正驗證建置的最新版本；之後沒有功能／資料變更。
