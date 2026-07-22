# Project Content Color Indicators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Color the Pattern, Notes, and Knitting Journal labels berry when their corresponding project content exists, while empty states remain primary-colored.

**Architecture:** `ProjectDetailView` derives Pattern and all-counter Notes state from the current `StoredProject`, then passes the state into its existing action-card helper. `ProjectJournalSection` derives Journal state directly from `journalEntries`. Styling stays local to the labels and adds no stored state.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, existing `WatercolorTheme` design tokens.

## Global Constraints

- Empty content uses the current primary foreground color.
- Populated content uses `WatercolorTheme.actionBerry`.
- Notes are populated when any of the six counters contains at least one row note.
- Completed projects with existing journal entries retain the populated journal color.
- Do not add persisted fields, migrations, localization keys, badges, counts, dots, animations, card-background changes, or settings.
- Existing accessibility labels, traits, navigation, and storage behavior remain unchanged.

---

### Task 1: Add content-aware label colors

**Files:**
- Modify: `Tests/KnitNoteCoreTests/ProjectDetailLayoutContractTests.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `KnitNote/Projects/ProjectJournalSection.swift`

**Interfaces:**
- Consumes: `StoredProject.patterns`, `StoredProject.counters`, `ProjectCounter.rowNotes`, `StoredProject.journalEntries`, and `WatercolorTheme.actionBerry`.
- Produces: `projectActionCard(_:icon:isPopulated:action:) -> some View`, with label-only content-aware foreground styling.

- [ ] **Step 1: Write the failing source-contract test**

Add a focused Swift Testing case to `ProjectDetailLayoutContractTests.swift` that loads both production files and requires these exact behaviors:

```swift
@Test func populatedProjectContentUsesBerryLabels() throws {
    let detail = try String(
        contentsOf: packageRoot.appendingPathComponent("KnitNote/Projects/ProjectDetailView.swift"),
        encoding: .utf8
    )
    let journal = try String(
        contentsOf: packageRoot.appendingPathComponent("KnitNote/Projects/ProjectJournalSection.swift"),
        encoding: .utf8
    )

    #expect(detail.contains("isPopulated: !project.patterns.isEmpty"))
    #expect(detail.contains("project.counters.contains { !$0.rowNotes.isEmpty }"))
    #expect(detail.contains("isPopulated: Bool"))
    #expect(detail.contains("isPopulated ? WatercolorTheme.actionBerry : Color.primary"))
    #expect(journal.contains("project.journalEntries.isEmpty ? Color.primary : WatercolorTheme.actionBerry"))
}
```

Use the test file's existing package-root helper if it has one; otherwise add the same `URL(fileURLWithPath: #filePath).deletingLastPathComponent()` traversal used by neighboring contract tests.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter ProjectDetailLayoutContractTests
```

Expected: the new test fails because the state arguments and conditional foreground styles do not exist yet.

- [ ] **Step 3: Implement Pattern and Notes label state**

Change the two action-card calls in `ProjectDetailView` to pass the derived states:

```swift
projectActionCard(
    "patterns.open",
    icon: "doc.text.image",
    isPopulated: !project.patterns.isEmpty
) {
    showingPatterns = true
}

projectActionCard(
    "notes.edit",
    icon: "note.text",
    isPopulated: project.counters.contains { !$0.rowNotes.isEmpty }
) {
    editingNote = CounterRowSelection(
        counterID: project.selectedCounterID,
        row: project.selectedCounter.value
    )
}
```

Extend the existing helper and style only its label:

```swift
private func projectActionCard(
    _ title: LocalizedStringKey,
    icon: String,
    isPopulated: Bool,
    action: @escaping () -> Void
) -> some View {
    WatercolorCard {
        Button(action: action) {
            Label(title, systemImage: icon)
                .foregroundStyle(isPopulated ? WatercolorTheme.actionBerry : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 4: Implement Journal title state**

In `ProjectJournalSection`, style only the title:

```swift
Text("journal.title")
    .font(.headline)
    .foregroundStyle(
        project.journalEntries.isEmpty ? Color.primary : WatercolorTheme.actionBerry
    )
```

- [ ] **Step 5: Run the focused test and verify GREEN**

Run:

```bash
swift test --filter ProjectDetailLayoutContractTests
```

Expected: all `ProjectDetailLayoutContractTests` pass.

- [ ] **Step 6: Run complete verification**

Run:

```bash
swift test
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteContentIndicatorsiOS build
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteContentIndicatorsMac build
git diff --check
```

Expected: 0 test failures, both builds exit 0, and the diff check emits no errors.

- [ ] **Step 7: Inspect and commit only scoped files**

Run:

```bash
git diff -- KnitNote/Projects/ProjectDetailView.swift KnitNote/Projects/ProjectJournalSection.swift Tests/KnitNoteCoreTests/ProjectDetailLayoutContractTests.swift
git add KnitNote/Projects/ProjectDetailView.swift KnitNote/Projects/ProjectJournalSection.swift Tests/KnitNoteCoreTests/ProjectDetailLayoutContractTests.swift docs/superpowers/specs/2026-07-22-project-content-color-indicators-design.md docs/superpowers/plans/2026-07-22-project-content-color-indicators.md
git commit -m "Show color for populated project content"
```

Expected: the diff contains only the three content-color behavior changes, their regression test, and the two documentation files. If repository lock permissions still prevent Git writes, leave the verified scoped changes unstaged and report that limitation without touching unrelated files.
