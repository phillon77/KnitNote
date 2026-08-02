# KnitNote Mac Window Sizing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent KnitNote's Mac main window from opening or restoring at an unusably small size while preserving normal resizing and every iPhone/iPad layout.

**Architecture:** A platform-neutral pure sizing policy owns the approved numbers. The Mac app scene consumes that policy through a Mac-only scene modifier and root minimum content frame; the iOS scene remains unchanged. Verification measures the launched Mac candidate rather than changing PDF zoom behavior.

**Tech Stack:** Swift 6, SwiftUI scenes, Swift Testing, Xcode/macOS Computer Use.

## Global Constraints

- Mac default window size is exactly 1100 by 760 points.
- Mac minimum usable content size is exactly 850 by 600 points.
- Users can resize larger and use full screen.
- iPhone and iPad layout and reader behavior must not change.
- Do not change PDF zoom, fit-width, viewport, highlight, markup, or appearance code.
- Do not merge, push, upload, or change app version/build metadata.

---

### Task 1: Add and Wire the Mac Window Sizing Policy

**Files:**
- Create: `Sources/KnitNoteCore/App/KnitNoteMacWindowSizingPolicy.swift`
- Modify: `KnitNote/App/KnitNoteApp.swift`
- Test: `Tests/KnitNoteCoreTests/KnitNoteMacWindowSizingPolicyTests.swift`

**Interfaces:**
- Produces: `KnitNoteMacWindowSizingPolicy.defaultWidth`, `defaultHeight`, `minimumWidth`, and `minimumHeight` as `Double` values.
- Consumes: SwiftUI `Scene.defaultSize(width:height:)` and `.windowResizability(.contentMinSize)` on macOS only.

- [ ] **Step 1: Write the failing policy tests**

```swift
import Testing
@testable import KnitNoteCore

@Suite struct KnitNoteMacWindowSizingPolicyTests {
    @Test func approvedDefaultAndMinimumWindowSizesRemainUsable() {
        #expect(KnitNoteMacWindowSizingPolicy.defaultWidth == 1100)
        #expect(KnitNoteMacWindowSizingPolicy.defaultHeight == 760)
        #expect(KnitNoteMacWindowSizingPolicy.minimumWidth == 850)
        #expect(KnitNoteMacWindowSizingPolicy.minimumHeight == 600)
        #expect(KnitNoteMacWindowSizingPolicy.defaultWidth >= KnitNoteMacWindowSizingPolicy.minimumWidth)
        #expect(KnitNoteMacWindowSizingPolicy.defaultHeight >= KnitNoteMacWindowSizingPolicy.minimumHeight)
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter KnitNoteMacWindowSizingPolicyTests`

Expected: compilation fails because `KnitNoteMacWindowSizingPolicy` does not exist.

- [ ] **Step 3: Add the minimal pure policy**

```swift
public enum KnitNoteMacWindowSizingPolicy {
    public static let defaultWidth = 1100.0
    public static let defaultHeight = 760.0
    public static let minimumWidth = 850.0
    public static let minimumHeight = 600.0
}
```

- [ ] **Step 4: Wire the Mac-only scene behavior**

Keep one `WindowGroup`. Add these file-private cross-platform wrappers to `KnitNoteApp.swift`:

```swift
private struct MacMinimumWindowContentSizeModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
#if os(macOS)
        content.frame(
            minWidth: CGFloat(KnitNoteMacWindowSizingPolicy.minimumWidth),
            minHeight: CGFloat(KnitNoteMacWindowSizingPolicy.minimumHeight)
        )
#else
        content
#endif
    }
}

private extension View {
    func knitNoteMacMinimumWindowContentSize() -> some View {
        modifier(MacMinimumWindowContentSizeModifier())
    }
}

private extension Scene {
    @SceneBuilder
    func knitNoteMacWindowSizing() -> some Scene {
#if os(macOS)
        self
            .defaultSize(
                width: CGFloat(KnitNoteMacWindowSizingPolicy.defaultWidth),
                height: CGFloat(KnitNoteMacWindowSizingPolicy.defaultHeight)
            )
            .windowResizability(.contentMinSize)
#else
        self
#endif
    }
}
```

Apply `.knitNoteMacMinimumWindowContentSize()` to the existing root view modifier chain and `.knitNoteMacWindowSizing()` to the existing `WindowGroup`. Do not add any sizing modifier inside `PatternReaderView` or `PDFReaderView`.

- [ ] **Step 5: Verify focused tests and both platforms**

Run:

```bash
swift test --filter KnitNoteMacWindowSizingPolicyTests
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteMacWindowSizing-iOS CODE_SIGNING_ALLOWED=NO build -quiet
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteMacWindowSizing-Mac CODE_SIGNING_ALLOWED=NO build -quiet
```

Expected: all exit 0; iOS compiles without inheriting Mac sizing.

- [ ] **Step 6: Commit**

```bash
git add Sources/KnitNoteCore/App/KnitNoteMacWindowSizingPolicy.swift Tests/KnitNoteCoreTests/KnitNoteMacWindowSizingPolicyTests.swift KnitNote/App/KnitNoteApp.swift
git commit -m "fix: keep Mac window at a usable size"
```

### Task 2: Full and Physical Mac Verification

**Files:**
- Verify only; do not modify production files unless a concrete failure returns Task 1 to RED/GREEN.

**Interfaces:**
- Consumes: exact Task 1 candidate SHA and `/tmp/KnitNoteMacWindowSizing-Mac/Build/Products/Debug/KnitNote.app`.
- Produces: recorded automated and Mac visual acceptance evidence.

- [ ] **Step 1: Run repository hygiene and full tests**

```bash
git status --short
git diff --check
swift test
```

Expected: clean worktree and at least 1,064 tests passing.

- [ ] **Step 2: Launch and measure the exact Mac candidate**

Launch the Task 1 artifact. Use Computer Use to capture only the KnitNote window. Confirm the captured window is at least 850 by 600 and that a fresh usable window is approximately 1100 by 760, not the previous roughly 180 by 110 state.

- [ ] **Step 3: Exercise the Mac pattern flow**

Open a library pattern and verify the reader is readable; switch light/dark appearance; toggle original colors; zoom, scroll, and change pages. Confirm controls, thumbnails, highlights, and markup remain outside the document color transform and the window remains freely resizable above the minimum.

- [ ] **Step 4: Stop at the integration boundary**

Record exact SHA, test/build evidence, measured window dimensions, and Mac interaction result. Do not merge, push, upload, or change version/build metadata.
