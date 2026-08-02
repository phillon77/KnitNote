# KnitNote 織圖頁面縮圖 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 iPhone、iPad 與 Mac 的多頁 PDF 織圖上方加入精簡、可水平滑動及點選跳頁的縮圖列。

**Architecture:** 延伸現有 `PatternThumbnailFileService`，以 asset ID、asset SHA-256 與 PDF 頁碼建立可丟棄的逐頁 JPEG 快取；`JSONProjectStore` 提供只讀非同步入口。新的 `PatternPageThumbnailStrip` 只負責顯示、延遲載入與呼叫既有 `PDFPageNavigator`，不建立第二套閱讀狀態或換頁流程。

**Tech Stack:** Swift 6、SwiftUI、PDFKit/CoreGraphics、Swift Testing、XcodeGen、iOS/iPadOS/macOS。

## Global Constraints

- 縮圖列只在多頁 PDF 顯示；單頁 PDF、圖片織圖與手寫模式不顯示。
- 目前頁必須有莓紅色外框、頁碼與 selected trait，不能只靠顏色。
- 所有縮圖點選必須呼叫既有 `PDFPageNavigator.go(to:)`，沿用目前的頁面保存、回滾、共用寬度與高亮流程。
- 只延遲渲染實際出現在 LazyHStack 的頁面，並預載目前頁前後各一頁；reader 消失或請求失效時不得發布舊結果。
- 逐頁快取鍵必須包含 asset ID、asset SHA-256 與零起算頁碼；快取不進主 JSON、手動備份或 App bundle。
- 新文字同時提供繁體中文與英文；點擊區至少 44 × 44 pt，VoiceOver 說出「第 X 頁，共 Y 頁」及目前頁狀態。
- 不修改 archive schema、版本／Build、App Store 資料、織圖連結、高亮、筆記、手寫或 PDF 寬度資料。
- 既有 `PatternThumbnailView` 的封面縮圖行為保持不變。

---

### Task 1: 建立逐頁 PDF 縮圖快取

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/PatternThumbnailFileService.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternThumbnailFileServiceTests.swift`

**Interfaces:**
- Consumes: `PatternAsset.id`, `PatternAsset.sha256`, `PatternAsset.kind`, PDF source URL。
- Produces: `cachedPageURL(asset:pageIndex:) -> URL` and `thumbnailURL(asset:sourceURL:pageIndex:) throws -> URL`。

- [ ] **Step 1: Write failing tests for page selection, cache identity, reuse, and deletion**

新增以三頁不同純色 PDF 為 fixture 的測試，手工斷言第 0、1、2 頁中心像素不同；另斷言同一頁重複請求回傳相同 URL，不同 SHA 或頁碼回傳不同 URL，`delete(assetID:)` 同時刪除封面與該 asset 的所有逐頁縮圖。

```swift
@Test func pageThumbnailRendersTheRequestedPDFPageAndUsesVersionedCacheKeys() throws {
    let service = PatternThumbnailFileService(directory: cache, maxPixelSize: 240)
    let first = try service.thumbnailURL(asset: asset, sourceURL: pdf, pageIndex: 0)
    let second = try service.thumbnailURL(asset: asset, sourceURL: pdf, pageIndex: 1)

    #expect(first != second)
    #expect(try centerRGB(first) == RGB(red: 255, green: 0, blue: 0))
    #expect(try centerRGB(second) == RGB(red: 0, green: 255, blue: 0))
    #expect(first == service.cachedPageURL(asset: asset, pageIndex: 0))
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter PatternThumbnailFileServiceTests
```

Expected: compile failure because the page-index APIs do not exist.

- [ ] **Step 3: Implement the minimal versioned page cache**

保持現有封面 API 不變，新增以下 API；頁碼公開介面使用零起算，傳給 `CGPDFDocument.page(at:)` 時加一。

```swift
public func cachedPageURL(asset: PatternAsset, pageIndex: Int) -> URL

public func thumbnailURL(
    asset: PatternAsset,
    sourceURL: URL,
    pageIndex: Int
) throws -> URL
```

快取檔名使用：

```swift
"\(asset.id.uuidString)-\(safeSHA)-page-\(max(0, pageIndex)).jpg"
```

`safeSHA` 只接受十六進位字元；無效值使用 `unknown`，但 asset ID 仍避免跨 asset 衝突。非 PDF、負頁碼或不存在頁面拋出 `PatternThumbnailFileError.unreadableSource`。渲染、旋轉與 JPEG 編碼沿用現有 helper，不建立第二套影像管線。

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter PatternThumbnailFileServiceTests
```

Expected: all `PatternThumbnailFileServiceTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/KnitNoteCore/Patterns/PatternThumbnailFileService.swift Tests/KnitNoteCoreTests/PatternThumbnailFileServiceTests.swift
git commit -m "feat: render cached PDF page thumbnails"
```

---

### Task 2: 提供 Store 入口與預載視窗策略

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternPageThumbnailPolicy.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Create: `Tests/KnitNoteCoreTests/PatternPageThumbnailPolicyTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternLibraryModelTests.swift`

**Interfaces:**
- Consumes: `assetID`, `pageIndex`, store generation and Task cancellation。
- Produces: `PatternPageThumbnailPolicy.preloadIndices(pageCount:currentPage:) -> [Int]` and `JSONProjectStore.patternPDFPageThumbnailURL(assetID:pageIndex:) async -> URL?`。

- [ ] **Step 1: Write failing behavior tests**

用 literal 預期值測試預載視窗邊界：

```swift
@Test func preloadWindowContainsCurrentAndImmediateNeighborsOnly() {
    #expect(PatternPageThumbnailPolicy.preloadIndices(pageCount: 10, currentPage: 5) == [4, 5, 6])
    #expect(PatternPageThumbnailPolicy.preloadIndices(pageCount: 10, currentPage: 0) == [0, 1])
    #expect(PatternPageThumbnailPolicy.preloadIndices(pageCount: 1, currentPage: 0) == [])
}
```

Store 測試建立真實三頁 PDF asset，呼叫第 1 頁 API，斷言 URL 存在且與 service 的 versioned URL 相同；圖片 asset、越界頁碼與已取消 Task 回傳 nil／不發布結果。

- [ ] **Step 2: Run focused tests and verify RED**

```bash
swift test --filter PatternPageThumbnailPolicyTests
swift test --filter PatternLibraryModelTests
```

Expected: compile failure for the missing policy and store API.

- [ ] **Step 3: Implement the pure policy and store boundary**

```swift
public enum PatternPageThumbnailPolicy {
    public static func shouldShow(kind: PatternKind, pageCount: Int, markupMode: Bool) -> Bool
    public static func preloadIndices(pageCount: Int, currentPage: Int) -> [Int]
}
```

```swift
public func patternPDFPageThumbnailURL(
    assetID: UUID,
    pageIndex: Int
) async -> URL? {
    guard !Task.isCancelled,
          let asset = patternAssets.first(where: { $0.id == assetID }),
          asset.kind == .pdf,
          let pageCount = asset.pageCount,
          pageIndex >= 0,
          pageIndex < pageCount,
          let sourceURL = try? requiredPatternFileService().assetURL(asset)
    else { return nil }
    let service = patternThumbnailService
    return await Task.detached(priority: .utility) {
        guard !Task.isCancelled else { return nil }
        return try? service.thumbnailURL(asset: asset, sourceURL: sourceURL, pageIndex: pageIndex)
    }.value
}
```

呼叫端在 await 後仍必須再檢查 cancellation；store API 不修改 archive 或 `dataGeneration`。

- [ ] **Step 4: Run focused tests and verify GREEN**

```bash
swift test --filter PatternPageThumbnailPolicyTests
swift test --filter PatternLibraryModelTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/KnitNoteCore/Patterns/PatternPageThumbnailPolicy.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/PatternPageThumbnailPolicyTests.swift Tests/KnitNoteCoreTests/PatternLibraryModelTests.swift
git commit -m "feat: expose lazy PDF page thumbnails"
```

---

### Task 3: 建立跨平台縮圖列元件

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternPageThumbnailPresentation.swift`
- Create: `KnitNote/Patterns/PatternPageThumbnailStrip.swift`
- Create: `Tests/KnitNoteCoreTests/PatternPageThumbnailPresentationTests.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj` (generated by XcodeGen)

**Interfaces:**
- Consumes: `assetID`, `pageCount`, `selectedPage`, `store.dataGeneration`, `onSelect(Int)`。
- Produces: `PatternPageThumbnailStrip` with lazy cells, selection presentation, placeholder and auto-scroll。

- [ ] **Step 1: Write failing presentation-model tests**

在 `KnitNoteCore` 建立可獨立測試、可被 App view 消費的 presentation model：

```swift
@Test func pageItemUsesOneBasedLabelsAndSelectedState() {
    let item = PatternPageThumbnailPresentation(pageIndex: 2, pageCount: 8, selectedPage: 2)
    #expect(item.pageNumber == 3)
    #expect(item.isSelected)
    #expect(item.accessibilityArguments == [3, 8])
}
```

另測越界 selected page 不會選中任何 item，並測試最小 hit target／strip height policy 在 phone、pad、Mac 與 accessibility dynamic type 下均不小於 44 pt。

- [ ] **Step 2: Run the new test and verify RED**

```bash
swift test --filter PatternPageThumbnailPresentationTests
```

Expected: compile failure because the presentation types do not exist.

- [ ] **Step 3: Implement the presentation model and SwiftUI strip**

元件介面：

```swift
struct PatternPageThumbnailStrip: View {
    let assetID: UUID
    let pageCount: Int
    let selectedPage: Int
    let onSelect: (Int) -> Void
}
```

使用 `ScrollView(.horizontal)` + `LazyHStack` + `ScrollViewReader`。每個 cell 的 `.task(id:)` 只載入自身頁碼；strip 的 `.task(id: selectedPage)` 呼叫 `preloadIndices` 預載目前頁前後各一頁。所有非同步回傳在寫入 `@State` 前檢查 `Task.isCancelled` 與 request identity。

點選目前頁只更新縮圖列可見位置，不呼叫 `onSelect`。其他頁呼叫一次 `onSelect(pageIndex)`。`onChange(of: selectedPage)` 使用無動畫或短動畫 `proxy.scrollTo(selectedPage, anchor: .center)`，不得重載 PDF。

縮圖失敗顯示 `doc.richtext` 與頁碼；選中外框使用 `WatercolorTheme.actionBerry`，並加 `.accessibilityAddTraits(.isSelected)`。每個 cell 使用本地化 accessibility label 的兩個數字參數。

- [ ] **Step 4: Generate the Xcode project and run tests/build**

```bash
xcodegen generate
swift test --filter PatternPageThumbnailPresentationTests
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' build
```

Expected: focused tests and Mac build pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/KnitNoteCore/Patterns/PatternPageThumbnailPresentation.swift KnitNote/Patterns/PatternPageThumbnailStrip.swift Tests/KnitNoteCoreTests/PatternPageThumbnailPresentationTests.swift KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: add accessible pattern page thumbnail strip"
```

---

### Task 4: 將縮圖列接入唯一 PDF 換頁流程

**Files:**
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/PatternReaderPageTransitionTests.swift`
- Create: `Tests/KnitNoteCoreTests/PatternReaderThumbnailIntegrationTests.swift`

**Interfaces:**
- Consumes: Task 3 `PatternPageThumbnailStrip` and existing `PDFPageNavigator.go(to:)`。
- Produces: multi-page-only strip above PDF; thumbnail, bottom control and native swipe converge on the existing transition state.

- [ ] **Step 1: Write failing integration behavior tests**

新增純行為 helper，讓按縮圖與按上一／下一頁共用同一個 target resolver：

```swift
@Test func thumbnailSelectionUsesTheSameClampedPageTargetAsOtherControls() {
    #expect(PatternReaderPageTarget.resolve(requested: 7, current: 2, pageCount: 5) == 4)
    #expect(PatternReaderPageTarget.resolve(requested: 2, current: 2, pageCount: 5) == nil)
}
```

另測 `PatternPageThumbnailPolicy.shouldShow`：只有 PDF、pageCount > 1、非 markup mode 才為 true。既有 `PatternReaderPageTransitionTests` 加入快速縮圖跳頁仍保留 original rollback page 的案例。

- [ ] **Step 2: Run focused tests and verify RED**

```bash
swift test --filter PatternReaderThumbnailIntegrationTests
swift test --filter PatternReaderPageTransitionTests
```

Expected: compile failure for `PatternReaderPageTarget` or failure because thumbnail target behavior is absent.

- [ ] **Step 3: Integrate the strip without creating a new page state**

在 `GeometryReader` 內、`readerCanvas` 正上方加入：

```swift
if PatternPageThumbnailPolicy.shouldShow(
    kind: content.kind,
    pageCount: pageCount,
    markupMode: markupMode
) {
    PatternPageThumbnailStrip(
        assetID: content.assetID,
        pageCount: pageCount,
        selectedPage: state.pageIndex,
        onSelect: navigatePDF(to:)
    )
}
```

新增 `navigatePDF(to requestedPage: Int)`，使用 `PatternReaderPageTarget.resolve` 後只呼叫 `pdfNavigator.go(to:)`；`navigatePDF(by:)` 改為計算 requested page 後呼叫同一方法。不可直接改 `state.pageIndex`、不可清 `pdfWidthScaleRatio`、不可自行保存 page state。

- [ ] **Step 4: Add Traditional Chinese and English localization**

新增 string catalog key：

- `patterns.reader.thumbnail.accessibility.format`
  - zh-Hant: `第 %1$lld 頁，共 %2$lld 頁`
  - en: `Page %1$lld of %2$lld`
- `patterns.reader.thumbnail.current`
  - zh-Hant: `目前頁`
  - en: `Current page`

selected cell 的 accessibility label 由頁面格式加上目前頁文字；視覺頁碼使用數字，不新增重複標題。

- [ ] **Step 5: Run focused tests, localization tests and builds**

```bash
swift test --filter PatternReaderThumbnailIntegrationTests
swift test --filter PatternReaderPageTransitionTests
swift test --filter LocalizationContractTests
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' build
```

Expected: all commands pass.

- [ ] **Step 6: Commit**

```bash
git add KnitNote/Patterns/PatternReaderView.swift KnitNote/Localization/Localizable.xcstrings Tests/KnitNoteCoreTests/PatternReaderPageTransitionTests.swift Tests/KnitNoteCoreTests/PatternReaderThumbnailIntegrationTests.swift
git commit -m "feat: navigate PDF patterns from page thumbnails"
```

---

### Task 5: 完整回歸、審查與唯一候選實機驗收

**Files:**
- Modify only if verification reveals a test-backed defect.

**Interfaces:**
- Consumes: Tasks 1–4 committed candidate.
- Produces: one reviewed commit candidate ready for user physical acceptance; no merge/push/release action.

- [ ] **Step 1: Run the full automated suite**

```bash
swift test
git diff --check
```

Expected: all tests pass and no whitespace errors.

- [ ] **Step 2: Build all affected platforms**

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' build
```

若連接已知 iPad，再對同一 candidate 執行 signed device build；不能用較舊 DerivedData app 驗收。

- [ ] **Step 3: Review the final diff**

檢查：

- 快速連點縮圖不會發布舊頁結果。
- 點目前頁不會觸發 PDF reload、寬度重設或 page-state 保存。
- 每頁縮圖錯誤只顯示 placeholder。
- 刪除 asset／清除快取會刪除逐頁縮圖。
- 縮圖檔未出現在 backup manifest、主 JSON 或 bundle resources。
- 單頁 PDF、圖片、markup mode 的原始畫面高度不變。

- [ ] **Step 4: Install the exact signed candidate and request physical acceptance**

iPad：多頁 PDF 快速點縮圖、滑動縮圖列、底部按鈕、原生滑頁、旋轉、放大、離開重開及 VoiceOver。iPhone：直／橫向不當機且 PDF 不被縮圖或底部控制遮住。Mac：縮圖列可水平捲動、鍵盤／VoiceOver 選頁正常。

- [ ] **Step 5: Stop at the acceptance gate**

不得自行修改版本／Build、合併、推送、上傳或送審。使用者實機通過後，才使用 `superpowers:finishing-a-development-branch` 提供整合選項。
