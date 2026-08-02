# Mac Project Patterns Sheet Size Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the macOS sheet opened through 「作品 → 織圖」 at the existing approved minimum size of 850 by 600 points.

**Architecture:** Add a Mac-only minimum frame at the `ProjectDetailView` sheet presentation boundary and reuse `KnitNoteMacWindowSizingPolicy`. Protect the wiring with the existing Mac layout contract suite, then verify the complete app on both Apple UI targets and inspect the exact Mac artifact.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Swift Package Manager, Xcode 26.5

## Global Constraints

- Minimum width: 850 points.
- Minimum height: 600 points.
- The sheet remains resizable above that minimum.
- iPhone and iPad presentation remains unchanged.
- The PDF reader, PDF viewport, highlights, thumbnails, project data, and pattern links remain unchanged.
- Preserve all user-owned untracked `.superpowers/`, `KnitNote 5.xcodeproj/`, `KnitNote 6.xcodeproj/`, and `knitnote-1.3-reader-viewport/` content in the original checkout.

---

### Task 1: Apply the Shared Mac Minimum Size to the Project Patterns Sheet

**Files:**
- Modify: `Tests/KnitNoteCoreTests/MacFormLayoutContractTests.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`

**Interfaces:**
- Consumes: `KnitNoteMacWindowSizingPolicy.minimumWidth: Double` and `KnitNoteMacWindowSizingPolicy.minimumHeight: Double`.
- Produces: a Mac-only minimum frame on the `ProjectPatternsView(projectID:)` sheet content.

- [ ] **Step 1: Write the failing sheet-sizing contract test**

Add this test to `MacFormLayoutContractTests`:

```swift
@Test func macProjectPatternsSheetUsesTheApprovedMinimumSize() throws {
    let source = try source(named: "ProjectDetailView.swift")
    let sheet = try #require(source.range(of: ".sheet(isPresented: $showingPatterns)"))
    let projectPatterns = try #require(
        source.range(of: "ProjectPatternsView(projectID: projectID)", range: sheet.upperBound..<source.endIndex)
    )
    let macBranch = try #require(
        source.range(of: "#if os(macOS)", range: projectPatterns.upperBound..<source.endIndex)
    )
    let macEnd = try #require(
        source.range(of: "#endif", range: macBranch.upperBound..<source.endIndex)
    )
    let macSource = String(source[macBranch.lowerBound..<macEnd.lowerBound])

    #expect(macSource.contains("KnitNoteMacWindowSizingPolicy.minimumWidth"))
    #expect(macSource.contains("KnitNoteMacWindowSizingPolicy.minimumHeight"))
}
```

Mutation caught: removing the Mac frame or either shared minimum dimension from this sheet causes the contract to fail.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter MacFormLayoutContractTests.macProjectPatternsSheetUsesTheApprovedMinimumSize
```

Expected: FAIL because the `showingPatterns` sheet currently has no `#if os(macOS)` size branch after `ProjectPatternsView`.

- [ ] **Step 3: Add the minimal Mac-only frame**

Change the sheet content in `ProjectDetailView.swift` to:

```swift
.sheet(isPresented: $showingPatterns) {
    ProjectPatternsView(projectID: projectID)
#if os(macOS)
        .frame(
            minWidth: CGFloat(KnitNoteMacWindowSizingPolicy.minimumWidth),
            minHeight: CGFloat(KnitNoteMacWindowSizingPolicy.minimumHeight)
        )
#endif
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
swift test --filter MacFormLayoutContractTests.macProjectPatternsSheetUsesTheApprovedMinimumSize
```

Expected: PASS with zero failures.

- [ ] **Step 5: Run complete automated verification**

Run:

```bash
swift test
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteMacProjectPatterns-iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteMacProjectPatterns-macOS CODE_SIGNING_ALLOWED=NO build
```

Expected: the full Swift suite and both fresh builds exit successfully with zero test failures or compiler errors.

- [ ] **Step 6: Inspect the exact Mac artifact**

Launch `/tmp/KnitNoteMacProjectPatterns-macOS/Build/Products/Debug/KnitNote.app`, open any project, select 「織圖」, and confirm:

- the sheet opens at no less than 850 by 600 points;
- the pattern list is readable;
- the sheet can grow larger;
- opening a pattern still presents the already-approved reader without layout regression.

- [ ] **Step 7: Commit the implementation**

```bash
git add Tests/KnitNoteCoreTests/MacFormLayoutContractTests.swift KnitNote/Projects/ProjectDetailView.swift
git commit -m "fix: keep Mac project patterns sheet readable"
```
