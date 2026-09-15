# 棒針織法字典 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付可離線搜尋英文縮寫、瀏覽日韓常見符號並閱讀操作分解圖的 15 條目棒針字典。

**Architecture:** Core 提供版本化唯讀目錄、資料驗證及純搜尋函式；SwiftUI 共用首頁、詳情及向量圖。資料與所有圖形隨 App 打包，只有來源連結需要連網；既有工具清單與設定工具區導向同一字典。

**Tech Stack:** Swift 6、SwiftUI、Foundation Codable、Swift Testing、String Catalog、XcodeGen；iOS 18、macOS 15，沿用現有專案設定。

**Spec:** `docs/superpowers/specs/2026-09-15-knitting-stitch-dictionary-design.md`，2026-09-15 使用者已回覆「通過」。

## Global Constraints

- 支援 iPhone、iPad、macOS；不新增 Watch 介面。不更動專案資料格式、計數器、同步或付費權限規則。
- 先完成獨立字典，再另行接入織圖閱讀畫面。
- 第一版不解析複合指令或整段文字。
- 介面與操作說明須覆蓋目前 13 個支援語言：da、de、el、en、fi、fr、ja、ko、nb、nl、sv、zh-Hans、zh-Hant。
- 無論介面語言為何，都能查中文、英文、日文與韓文名稱。
- 無法查證的特定符號變體不得以確定內容出現；四語名稱的完整審核仍是第一版交付條件。
- 示意圖採自製向量線圖，獨立於字串翻譯，配上本地化文字和無障礙描述。
- 不以本設計指定發布版本。Git 推送、上傳與送審屬另外的明確授權範圍。
- 不建立新任務、不自動啟用子代理；執行方式在交接時由使用者選擇。保持既有未追蹤的 `.superpowers/absent-source-design-progress.md` 原樣。

## 檢查到的程式結構

規劃基準：本地 `main` 的 `bd7fd5b`。實作前重新確認 HEAD 與未提交變更。本次只寫計畫，沒有執行建置或 App 測試。

- `Package.swift` 已將 `Sources/KnitNoteCore/Resources` 設為 process 資源。
- `project.yml` 的 App 直接編譯 `Sources/KnitNoteCore`，不是匯入 Swift Package；資源載入必須同時涵蓋 SPM 與 App bundle。
- `KnitNote/Calculators/KnittingCalculatorsView.swift` 有專案工具頁卡片。
- `KnitNote/Settings/SettingsView.swift` 有各自的 macOS 與 iOS 工具區；兩處一起新增入口，避免沒有專案就無法查字典。
- `Sources/KnitNoteCore/Localization/LocaleAwareText.swift` 可依 App 內選擇的語言解析動態字串鍵。
- `KnitNote/Localization/Localizable.xcstrings` 為既有字串目錄。
- App scheme 為 `KnitNote`，單元測試 target 為 `KnitNoteAppTests`；Core 使用 `swift test`。

## 檔案責任與介面

新建 Core 檔案（均在 `Sources/KnitNoteCore/StitchDictionary/`）：

| 檔案 | 責任 |
|---|---|
| StitchEntry.swift | Codable、Sendable、Equatable 的條目、來源、步驟與符號模型 |
| StitchCatalog.swift | JSON 載入、schema 版本、資料檢查及 ID 查找 |
| StitchSearch.swift | 正規化、排序、分類與 kN/pN 查詢 |
| StitchDiagram.swift | 與 SwiftUI 無關的向量座標與繪圖指令模型 |

新建 App 檔案（均在 `KnitNote/StitchDictionary/`）：

| 檔案 | 責任 |
|---|---|
| StitchDictionaryView.swift | 載入狀態、搜尋、分類、列表／圖表與導覽 |
| StitchDetailView.swift | 固定順序的內容、步驟圖、來源與相關織法 |
| StitchDiagramView.swift | 以 Path/Canvas 繪製線圖並提供替代文字 |
| StitchSymbolGrid.swift | 每一個符號變體各自成卡，不合併不同來源 |

資源：`Sources/KnitNoteCore/Resources/stitch-dictionary-v1.json`、`stitch-diagrams-v1.json`。文字鍵統一 `stitchDictionary.` 前綴。圖的指令包含左右針、工作線、舊／新線圈與箭頭，不用文字字元充當教學圖。

共用介面合約（Task 1 建立模型，Task 2 完成資料與驗證，Task 3 完成搜尋）：

```swift
public enum StitchCategory: String, Codable, CaseIterable, Sendable {
    case basic, increase, decrease, cable
}
public struct StitchSource: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let checkedOn: String // ISO 8601 calendar date
    public let scope: String // author-facing audit description
}
public struct StitchStep: Codable, Equatable, Sendable {
    public let textKey: String
    public let diagramID: String
    public let accessibilityKey: String
}
public struct StitchSymbol: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let diagramID: String
    public let traditionKey: String
    public let conditionKey: String
    public let sourceIDs: [String]
}
public struct StitchEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let category: StitchCategory
    public let order: Int
    public let names: [String: String] // zh-Hant, zh-Hans, en, ja, ko
    public let aliases: [String]
    public let titleKey: String
    public let summaryKey: String
    public let steps: [StitchStep]
    public let consumes: Int
    public let produces: Int
    public let noteKeys: [String]
    public let relatedIDs: [String]
    public let sourceIDs: [String]
    public let symbols: [StitchSymbol]
}
public struct StitchCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sources: [StitchSource]
    public let entries: [StitchEntry]
    public func entry(id: String) -> StitchEntry?
    public static func decode(_ data: Data) throws -> StitchCatalog
    public static func bundled() throws -> StitchCatalog
    public func validate(diagramIDs: Set<String>, localizedKeys: Set<String>) throws
}
public struct StitchSearchResult: Equatable, Sendable {
    public let entryID: String
    public let repetitions: Int?
}
public enum StitchSearch {
    public static func normalize(_ text: String) -> String
    public static func results(query: String, category: StitchCategory?,
                               in catalog: StitchCatalog) -> [StitchSearchResult]
}
```

`StitchCatalogError` 實作為 `Error, Equatable` enum，cases：`missingResource`、`unsupportedVersion(Int)`、`duplicateID(String)`、`invalidEntry(String)`、`missingReference(String)`。JSONDecoder 錯誤向呼叫端傳遞；UI 統一顯示本地化載入失敗，不顯示內部路徑。維持 UI 可注入 `Result<StitchCatalog, Error>`，供錯誤狀態測試。

## Task 1：可核對的下針條目與圖形樣本

**Files:** 新建 `docs/stitch-dictionary/content-review.md`、上述 `StitchEntry.swift`／`StitchDiagram.swift`／`StitchDiagramView.swift`；新建兩個 JSON 資源；新建 `Tests/KnitNoteCoreTests/StitchDiagramTests.swift`。

**Consumes:** 已通過的 spec 及其原始來源入口。**Produces:** 可離線解碼的下針條目 `knit` 與每步原創圖；向量模型 `StitchDiagram`。

- [ ] 實作前依 using-git-worktrees 檢查目前分支及隔離；禁止在共用 main 混入功能實作。確認工具與 SDK：`xcodebuild -version`、`xcodegen --version`、`git status --short`。基線跑 `swift test --no-parallel`，保存既有失敗以便區分。
- [ ] 查閱 CYC 下針說明與日本出版社教學，搜尋韓國原始教學 `대바늘 겉뜨기 기호 뜨는 방법`。逐一打開來源核對，不以搜尋摘要確認針目方向。把每項主張、URL、查閱日期、四語名稱與圖形對應記入 content-review.md；缺乏韓文證據時繼續研究，不能虛構來源或宣稱第一條目通過。
- [ ] 確定樣本採右手持工作線的操作法，四幅圖依序表現插針、繞線、拉出新圈、移除舊圈；核對同一線圈在相鄰步驟的位置。原創圖不能只有 V 字與通用箭頭。
- [ ] 建立純向量模型：`DiagramPoint(x: Double, y: Double)`；`DiagramCommand` 為 Codable enum，cases `move(DiagramPoint)`、`line(DiagramPoint)`、`curve(to: DiagramPoint, control1: DiagramPoint, control2: DiagramPoint)`、`close`；`DiagramStroke` 有 `role: DiagramRole`、`commands: [DiagramCommand]`；`DiagramRole` cases `leftNeedle, rightNeedle, workingYarn, oldLoop, newLoop, arrow`；`StitchDiagram` 有 `id: String, strokes: [DiagramStroke]`。座標範圍為 0...1，圖案不依賴翻譯字寬。
- [ ] 先寫測試，加入 `StitchDiagram.validate() throws` 的契約：拒絕非有限值、範圍外座標、空 strokes、缺少起始 move。測試例：

```swift
@Test func rejectsOutOfBoundsPoint() throws {
    let diagram = StitchDiagram(id: "bad", strokes: [
        DiagramStroke(role: .workingYarn, commands: [.move(.init(x: 2, y: 0))])
    ])
    #expect(throws: (any Error).self) { try diagram.validate() }
}
```

- [ ] 執行 `swift test --filter StitchDiagramTests`，確認測試因尚無驗證實作而失敗；完成座標驗證再跑到通過。新增 `StitchDiagram.loadBundled() throws -> [StitchDiagram]`，資源載入方式遵循 Task 2。
- [ ] `StitchDiagramView(diagram: StitchDiagram, accessibilityText: String)` 將座標乘可用尺寸畫 Path；role 決定線寬、虛實及顏色。用 `.accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: accessibilityText))` 提供文字替代。
- [ ] 渲染樣本，在 content-review.md 記錄四語來源與四步圖逐張核對結果，保存預覽圖片到 `docs/stitch-dictionary/previews/`。只有來源核對與圖形審閱完成才能把樣本標示 verified；這不是額外的使用者批准關卡。
- [ ] 本地提交本 task 的精確檔案，訊息 `feat: add verified knit stitch reference and diagram foundation`。

## Task 2：目錄載入與資料完整性

**Files:** 新建 `StitchCatalog.swift`、`Tests/KnitNoteCoreTests/StitchCatalogTests.swift`；修改 `project.yml`、再生成 `KnitNote.xcodeproj/project.pbxproj`。

**Consumes:** Task 1 模型、JSON 及圖形 ID。**Produces:** 上述 `StitchCatalog` 介面、`StitchCatalogError`；可在 SPM 與 App 載入同一資料。

- [ ] 先加入載入與失敗測試，例：

```swift
@Test func rejectsUnknownSchema() {
    let data = Data(#"{"schemaVersion":99,"sources":[],"entries":[]}"#.utf8)
    #expect(throws: StitchCatalogError.unsupportedVersion(99)) {
        try StitchCatalog.decode(data)
    }
}
@Test func containsTheVerifiedSample() throws {
    #expect(try StitchCatalog.bundled().entry(id: "knit") != nil)
}
```

- [ ] `swift test --filter StitchCatalogTests` 先驗證失敗。實作 decode 後校驗 schemaVersion == 1；查找用 ID 不用顯示名稱。
- [ ] 載入 bundle 採以下分支；diagram loader 用同一規則，不另寫網路 fallback：

```swift
#if SWIFT_PACKAGE
let bundle = Bundle.module
#else
let bundle = Bundle.main
#endif
guard let url = bundle.url(forResource: "stitch-dictionary-v1", withExtension: "json")
else { throw StitchCatalogError.missingResource }
return try decode(Data(contentsOf: url))
```

- [ ] 驗證重複 entry/source/symbol ID、空 steps、缺少四語名稱（繁簡中文皆需）、消耗／產生負數、找不到 related/source/diagram ID、缺少文字鍵、空符號條件、來源非 https 或日期格式錯誤。每類以修改 JSON 的故障資料測試，避免僅對正常資源做鏡像測試。
- [ ] 在 App `project.yml` 的 Sources/KnitNoteCore source entry 排除 `Resources`，再將 `Sources/KnitNoteCore/Resources` 明確加入 `buildPhase: resources`。檢查 Share target 是否同樣引用 Core，避免為無使用處新增字典資源。執行 `xcodegen generate`，審查差異只涉及所需檔案與資源；不接受版本、簽章或其他 target 的意外變更。
- [ ] 重跑 `swift test --filter StitchCatalogTests`；App 資源會在 Task 6 的實際 bundle 測試核對。本地提交 `feat: load and validate bundled stitch catalog`。

## Task 3：四語搜尋與安全的 kN/pN 解讀

**Files:** 新建 `StitchSearch.swift`、`Tests/KnitNoteCoreTests/StitchSearchTests.swift`。

**Consumes:** Task 2 catalog。**Produces:** `StitchSearch` 及 `StitchSearchResult`。

- [ ] 先建立獨立測試 fixture：從已驗證樣本建構最小目錄，另外加入 purl 與 k2tog 的搜尋測試 entry（測試用名稱不當成正式內容來源）。

```swift
private func fixture() throws -> StitchCatalog {
    let data = try Data(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/KnitNoteCore/Resources/stitch-dictionary-v1.json"))
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rows = try #require(object["entries"] as? [[String: Any]])
    let sample = try #require(rows.first { $0["id"] as? String == "knit" })
    object["entries"] = [
        ("knit", "k", "下針"), ("purl", "p", "上針"), ("k2tog", "k2tog", "二併一")
    ].enumerated().map { index, row in
        var entry = sample
        entry["id"] = row.0
        entry["order"] = index
        entry["aliases"] = [row.1]
        entry["names"] = ["zh-Hant": row.2, "zh-Hans": row.2,
                          "en": row.0, "ja": "test-ja-" + row.0,
                          "ko": "test-ko-" + row.0]
        entry["symbols"] = []
        entry["relatedIDs"] = []
        return entry
    }
    return try StitchCatalog.decode(JSONSerialization.data(withJSONObject: object))
}
```

此 fixture 只用於搜尋，不參與內容驗收；測試檔匯入 `Foundation`、`Testing` 與 `@testable import KnitNoteCore`。
- [ ] 加入參數化案例：

```swift
@Test(arguments: ["k1", "K 1", "ｋ１"])
func recognizesSingleKnit(_ query: String) throws {
    let result = StitchSearch.results(query: query, category: nil, in: try fixture())
    #expect(result.first == StitchSearchResult(entryID: "knit", repetitions: 1))
}
@Test func preservesWholeAbbreviation() throws {
    let result = StitchSearch.results(query: "k2tog", category: nil, in: try fixture())
    #expect(result.first == StitchSearchResult(entryID: "k2tog", repetitions: nil))
}
```

- [ ] 加入 `p3`、`k0`、`k-1`、`k1.5`、超長整數、空字串、不存在字串、分類、同分穩定順序及每種語言別名測試；完整 `sl1` 不替使用者選擇方向，可返回兩個滑針條目，repetitions 均為 nil。
- [ ] `swift test --filter StitchSearchTests` 確認紅燈，實作 normalize 使用 compatibility normalization、trim 與 en_US_POSIX lowercased。優先完整名稱／別名匹配；只在查詢完整符合 `^[kp]\\s*[0-9]+$` 時用 `Int` 解析正數。其餘以 exact、prefix、contains、order、ID 排序。
- [ ] 查詢使用「所有已收錄名稱＋別名」；多結果以 entry ID 去重。UI 只顯示 repetitions 不展開 N 份步驟，因此大但合法的數字不造成記憶體消耗。
- [ ] 重跑相關測試後本地提交 `feat: search stitch names and counted knit instructions`。

## Task 4：完成 15 個条目、全部圖形及本地化

**Files:** 修改兩個 JSON、`KnitNote/Localization/Localizable.xcstrings`、`docs/stitch-dictionary/content-review.md`；新建 `Tests/KnitNoteCoreTests/StitchDictionaryContentTests.swift`、`scripts/validate_stitch_dictionary.py`。

**Consumes:** 已核對下針樣本、Task 2 validator、Task 3 搜尋。**Produces:** 完整離線內容；13 語字串及內容審核記錄。

- [ ] 按下列固定 ID 順序製作：`knit, purl, slip-knitwise, slip-purlwise, yarn-over, knit-front-back, make-one-left, make-one-right, k2tog, ssk, skp, p2tog, centered-double-decrease, cable-left-two, cable-right-two`。先核對基本與加針，再减針，最後交叉針；每項分開保存來源證據與 step 圖審閱。
- [ ] 明確區分 SSK、SKP 與日韓對照是否真為同一操作；不能以傾斜方向相同作為等義證明。沒有出版品符號證據就令 symbols 為空，UI 仍可讀操作並顯示未列出對應記法。
- [ ] 先加 completeness 測試並確認在只有樣本時失敗：

```swift
@Test func shipsFifteenReviewedOperations() throws {
    let catalog = try StitchCatalog.bundled()
    #expect(catalog.entries.count == 15)
    #expect(Set(catalog.entries.map(\.id)).count == 15)
    #expect(catalog.entry(id: "ssk")?.id != catalog.entry(id: "skp")?.id)
}
```

- [ ] 對每個條目填入獨立步驟圖、四語名稱（繁簡中文分存）、相關織法與針數變化；用實際來源驗證數值，不從英文名稱自動推算。
- [ ] 13 語文字包含名稱、簡介、每步操作、每圖無障礙描述、正反面條件、注意事項與所有畫面控制。動態文字顯示使用 `LocaleAwareText.string(key, locale: locale)`；次數使用 format key 與 `%lld`，每語言型別一致，避免字串相接。
- [ ] 建立無第三方相依的 Python 驗證器，讀 JSON/xcstrings，收集所有 `*Key`／`noteKeys` 欄位；對每個 key 檢查 13 語翻譯、非空值、格式符號型別一致。以縮小 fixture 故意刪除韓文步驟、改壞格式符號及 diagram ID，證明工具非零退出；工具不以英文 fallback 當成翻譯完成。
- [ ] `python3 scripts/validate_stitch_dictionary.py` 與 `swift test --filter StitchDictionaryContentTests` 都通過後，再人工比對所有操作圖、滑針線位、交叉針持針位置及符號正反面條件。自動通過不等於內容已核實。
- [ ] 本地提交 `feat: complete multilingual knitting reference content`。

## Task 5：離線字典 UI 與兩處工具入口

**Files:** 新建前述 App 首頁／詳情／符號圖表；修改 `KnittingCalculatorsView.swift`、`Settings/SettingsView.swift`；新建 `Tests/KnitNoteAppTests/StitchDictionaryPresentationTests.swift`。

**Consumes:** Task 2 載入、Task 3 搜尋、Task 4 完整資源、Task 1 圖形 view。**Produces:** `StitchDictionaryView()`；`StitchDetailView(entry: StitchEntry, repetitions: Int?, catalog: StitchCatalog, diagrams: [StitchDiagram])`。

- [ ] 先加載入失敗與正常資料注入的 App host 測試，失敗案例傳入 `.failure(StitchCatalogError.missingResource)`，確認呈現錯誤而非 crash。測試 initializer 為 `StitchDictionaryView(catalogResult: Result<StitchCatalog, Error>)`；正式零參數 initializer 呼叫 bundled。
- [ ] 首頁 `@State` 保存 query、optional category、mode（list/symbols）。搜尋一律呼叫同一 Core 函式；清除操作同時清 query 及 category，模式切換保持 query。符號模式把結果展開為符號變體，無符號結果提供「改看列表」控制。
- [ ] 用 NavigationLink value 或 destination 打開詳情，傳遞 repetitions；詳情相關條目連結使用 catalog ID 查找。固定章節順序與 spec 一致。圖片可自適應縮放，寬度受 620 點內容框限制；窄畫面用單欄，四語名稱自動換行。
- [ ] 加入穩定 accessibilityIdentifier：`stitchDictionary.search`、`.mode`、`.category`、`.clear`、`.error`、`stitchDictionary.entry.<id>`、`stitchDictionary.symbol.<id>`。整個符號卡可點擊；提供名稱與來源，不依靠顏色。
- [ ] 現有專案工具頁新增：

```swift
calculatorLink(title: "stitchDictionary.title", systemImage: "book") {
    StitchDictionaryView()
}
```

- [ ] Settings macOS 工具區使用既有 calculatorLink，加上適當 Divider；iOS 工具 Section 新增 NavigationLink，兩者都用相同 title key 和 view。不修改現有計算器目的地。
- [ ] `xcodegen generate` 更新檔案清單，執行 macOS focused App tests（Task 6 命令），人工確認返回、清除、分類及列表／符號來回。通過後本地提交 `feat: add offline stitch dictionary to knitting tools`。

## Task 6：跨平台、離線與內容交付驗證

**Files:** 新建 `Tests/KnitNoteAppTests/StitchDictionaryResourceTests.swift`、`docs/stitch-dictionary/verification.md`；若發現問題僅修改相關功能檔案。

**Consumes:** Task 1–5 所有交付。**Produces:** 有命令、平台、結果、限制與內容審查記錄的驗收文件。

- [ ] App test 驗證 `try StitchCatalog.bundled()` 能載入 15 條目、`StitchDiagram.loadBundled()` 不為空，並用 Task 2 validator 檢查每個實際 bundle 資源；避免只在 SPM 測試成功卻漏包 App。
- [ ] 執行 `swift test --no-parallel` 與 `python3 scripts/validate_stitch_dictionary.py`，保存結果。專案不含舊通過數的推定，本次結果須重新取得。
- [ ] 執行 macOS focused tests：

```sh
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /private/tmp/knitnote-stitch-mac -only-testing:KnitNoteAppTests/StitchDictionaryPresentationTests -only-testing:KnitNoteAppTests/StitchDictionaryResourceTests test CODE_SIGNING_ALLOWED=NO
```

- [ ] 執行 iOS Simulator 與 macOS 建置：

```sh
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/knitnote-stitch-ios build CODE_SIGNING_ALLOWED=NO
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /private/tmp/knitnote-stitch-mac build CODE_SIGNING_ALLOWED=NO
```

- [ ] 以 `xcrun simctl list devices available` 取得實際可用 iPhone/iPad destination；不要硬編不存在的 simulator。若需測試錯誤情境，使用測試 fixture，不更動使用者專案或 iCloud 資料。
- [ ] iPhone、iPad、macOS 分別從設定與專案進入；搜尋 k1/p3/k2tog、點日韓來源符號、讀所有步驟、返回、清除、改分類。關閉網路後重跑查詢與圖形流程，來源連結除外。
- [ ] 每個平台檢查大字體、長德文／芬蘭文與日韓字形；VoiceOver 讀取符號、來源、步驟；macOS 鍵盤切換及開啟。兩個原有計算器各完成一例输入／計算／返回。
- [ ] 內容審查矩陣須涵蓋 15 條目 × 四語名稱、所有符號變體及每張圖。記錄驗證來源與實際審閱结果；無證據的列不得標完成。
- [ ] 在 verification.md 記錄 HEAD、測試命令、exit code、通過／失敗、實機與模擬器區別；沒做的實機或無障礙測試列為未驗證，不能稱全部驗收通過。
- [ ] 依 verification-before-completion 與 requesting-code-review 做最終檢查；如使用者未選子代理，採本地逐項審查。只提交範圍內修正與證據，訊息 `test: verify offline stitch dictionary across platforms`；完成後交付，不推送、不上傳、不送審。

## 規格對照與自查

| Spec 要求 | 實作任務 |
|---|---|
| 棒針、15 條目、離線與四語 | 1、2、4、6 |
| 現有工具入口與水彩介面 | 5 |
| 搜尋、符號圖表、次數、錯誤 | 2、3、5 |
| 正反面、相似操作、來源差異 | 1、4、6 |
| 原創逐步圖及文字替代 | 1、4、5、6 |
| 13 語與 App 語言切換 | 4、5、6 |
| 不更動專案資料與同步 | 所有 task 的 global constraints |
| Core、App bundle、跨平台測試 | 2、3、4、6 |

規劃自查：新介面先定義再引用；SPM／App resource 分支明列；韓文證據是必做的內容工作，不以未查證翻譯冒充完成；本文件的程式碼是實作契約與測試起點，不是已寫入產品的程式碼。
