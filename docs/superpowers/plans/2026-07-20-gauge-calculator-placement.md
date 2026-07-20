# Gauge Calculator Placement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the existing project gauge calculator card below the counter grid and above the notes/pattern controls.

**Architecture:** Preserve the existing views, navigation, localization, and data flow. Change only the declaration order inside `ProjectDetailView` and lock that order with a source contract test.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing.

## Global Constraints

- Preserve the existing full Watercolor gauge calculator card and its navigation behavior.
- Preserve the Settings gauge calculator entry.
- The project order must be `CounterSelectorGrid` → `GaugeCalculatorView()` → `notes.edit` / `patterns.open`.
- Do not modify calculation logic, localization, project models, or persistence.

---

### Task 1: Reorder the project gauge calculator entry

**Files:**
- Modify: `Tests/KnitNoteCoreTests/GaugeCalculatorViewContractTests.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`

**Interfaces:**
- Consumes: existing `CounterSelectorGrid`, `GaugeCalculatorView`, and supporting buttons.
- Produces: the approved visual ordering with unchanged navigation behavior.

- [ ] **Step 1: Write the failing source-order test**

Add this test to `GaugeCalculatorViewContractTests`:

```swift
@Test func projectPlacesGaugeCalculatorBetweenCountersAndNotes() throws {
    let project = try appSource("KnitNote/Projects/ProjectDetailView.swift")
    let counters = try #require(project.range(of: "CounterSelectorGrid("))
    let gauge = try #require(project.range(of: "GaugeCalculatorView()"))
    let notes = try #require(project.range(of: "\"notes.edit\""))

    #expect(counters.lowerBound < gauge.lowerBound)
    #expect(gauge.lowerBound < notes.lowerBound)
}
```

- [ ] **Step 2: Run the focused test and confirm RED**

Run: `swift test --filter projectPlacesGaugeCalculatorBetweenCountersAndNotes`
Expected: FAIL because `GaugeCalculatorView()` currently appears before `CounterSelectorGrid`.

- [ ] **Step 3: Move the existing card without changing it**

In `ProjectDetailView`, move this existing block from above the counter card to immediately below it:

```swift
WatercolorCard {
    NavigationLink {
        GaugeCalculatorView()
    } label: {
        Label("calculator.gauge.title", systemImage: "ruler")
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

The following `HStack` containing `notes.edit` and `patterns.open` must remain immediately after the gauge card.

- [ ] **Step 4: Run focused and full tests**

Run: `swift test --filter GaugeCalculatorViewContractTests && swift test --disable-sandbox -Xswiftc -module-cache-path -Xswiftc /tmp/knitnote-gauge-placement-cache`
Expected: gauge contract suite and all project tests PASS.

- [ ] **Step 5: Verify build and scope**

Run: `git diff --check && xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteGaugePlacement CODE_SIGNING_ALLOWED=NO build`
Expected: no whitespace errors and build exit code 0. Confirm the scoped diff changes only the order block and its new contract test.

