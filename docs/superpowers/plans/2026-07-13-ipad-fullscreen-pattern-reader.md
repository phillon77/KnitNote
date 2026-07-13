# iPad Full-Screen Pattern Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the entire pattern reader fill the iPad's safe screen while retaining the established reader layout on every platform.

**Architecture:** A pure core policy maps an iPad flag to sheet or full-screen presentation. A reusable SwiftUI modifier applies that policy at both pattern-reader entry points, while the incorrect internal iPad layout changes are removed.

**Tech Stack:** Swift 6, SwiftUI, UIKit device idiom, Swift Testing, Xcode 26.

## Global Constraints

- Full-screen presentation applies only to iPad, including Split View.
- iPhone and Mac retain sheet presentation.
- Restore the standard markup strip and bottom reader controls.
- Do not change PDF fitting, persistence, localization, or stored data formats.
- Keep all reader content inside navigation and bottom safe areas.

---

### Task 1: Presentation Policy and Internal Layout Rollback

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/PatternDocument.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternDocumentTests.swift`
- Modify: `KnitNote/Patterns/PatternReaderControls.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`

**Interfaces:**
- Produces: `PatternReaderPresentation.sheet`, `.fullScreen`, and `patternReaderPresentation(isPad:)`.

- [ ] **Step 1: Replace the old layout test with a failing presentation test**

```swift
@Test func onlyIPadUsesFullScreenPatternPresentation() {
    #expect(patternReaderPresentation(isPad: true) == .fullScreen)
    #expect(patternReaderPresentation(isPad: false) == .sheet)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build --filter onlyIPadUsesFullScreenPatternPresentation
```

Expected: compilation fails because the presentation policy does not exist.

- [ ] **Step 3: Add the minimal presentation policy and remove the old layout policy**

```swift
public enum PatternReaderPresentation: Sendable { case sheet, fullScreen }
public func patternReaderPresentation(isPad: Bool) -> PatternReaderPresentation {
    isPad ? .fullScreen : .sheet
}
```

- [ ] **Step 4: Restore the reader files to their pre-`f7685b8` content**

Remove `compact` and `compactControls` from `PatternReaderControls`. Remove `readerLayout`, UIKit device selection, iPad navigation-bar markup controls, and conditional markup-strip behavior from `PatternReaderView`. Restore the stable 60-point markup strip and standard two-row controls exactly as they were in `f7685b8^`.

- [ ] **Step 5: Run the focused test and verify GREEN**

Expected: one selected test passes.

### Task 2: Reusable Platform-Aware Presentation

**Files:**
- Create: `KnitNote/Patterns/PatternReaderPresentation.swift`
- Modify: `KnitNote/Patterns/ProjectPatternsView.swift`
- Modify: `KnitNote/Patterns/PatternLibraryView.swift`

**Interfaces:**
- Consumes: `patternReaderPresentation(isPad:)` from Task 1.
- Produces: `View.patternReaderPresentation(item:content:)`.

- [ ] **Step 1: Add the reusable modifier**

```swift
import SwiftUI
#if os(iOS)
import UIKit
#endif

private struct PatternReaderPresentationModifier<Item: Identifiable, Reader: View>: ViewModifier {
    @Binding var item: Item?
    @ViewBuilder let reader: (Item) -> Reader

    private var presentation: PatternReaderPresentation {
#if os(iOS)
        patternReaderPresentation(isPad: UIDevice.current.userInterfaceIdiom == .pad)
#else
        .sheet
#endif
    }

    func body(content: Content) -> some View {
        if presentation == .fullScreen {
            content.fullScreenCover(item: $item, content: reader)
        } else {
            content.sheet(item: $item, content: reader)
        }
    }
}

extension View {
    func patternReaderPresentation<Item: Identifiable, Reader: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Reader
    ) -> some View {
        modifier(PatternReaderPresentationModifier(item: item, reader: content))
    }
}
```

- [ ] **Step 2: Replace both reader sheets**

In `ProjectPatternsView` and `PatternLibraryView`, replace only the `.sheet(item: $selectedPattern)` reader presentation with `.patternReaderPresentation(item: $selectedPattern)`. Leave import and chooser sheets unchanged.

- [ ] **Step 3: Run all automated verification**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath work/DerivedData-iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath work/DerivedData-macOS CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Expected: 35 tests pass, both builds succeed, and the diff check is clean.

- [ ] **Step 4: Verify the iPad Simulator presentation**

Open a pattern from the global library and project pattern list. Confirm the reader occupies the iPad safe screen and that standard markup and bottom controls remain visible. Exercise next/previous page, highlight, markup, page note, and row count.

- [ ] **Step 5: Commit implementation**

Stage only the seven implementation and test files. Leave `KnitNote/Localization/Localizable.xcstrings` unstaged. Commit as:

```text
Present patterns full screen on iPad
```
