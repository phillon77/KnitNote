# Six Project Counters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every knitting project six editable, independent counters with independent per-row notes, synchronized between Project Detail and Pattern Reader.

**Architecture:** Add a `ProjectCounter` value type and make a six-item collection plus selected identifier authoritative in `StoredProject`. Keep legacy decoding inside `StoredProject`, expose explicit counter-ID mutations through `JSONProjectStore`, and share focused SwiftUI counter components between Project Detail and Pattern Reader.

**Tech Stack:** Swift 6, SwiftUI, Foundation Codable, Observation through `ObservableObject`, Swift Testing, String Catalog localization.

## Global Constraints

- Every project owns exactly six counters in stable order.
- New localized names are `計數器 1` through `計數器 6` and `Counter 1` through `Counter 6`.
- Counter values never fall below zero.
- Each counter has an independent row-note namespace.
- Legacy `currentRow` and `rowNotes` migrate to Counter 1 without losing unrelated project data.
- Project Detail and Pattern Reader operate on the same persisted `StoredProject` state.
- Pattern Reader controls stay inside the safe area and do not reset PDF, highlight, or markup state.
- Traditional Chinese and English ship together; counter identity never depends on translated text.
- Do not add counter reordering, deletion, formulas, targets, colors, or Watch UI.

---

### Task 1: Six-Counter Domain Model and Legacy Migration

**Files:**
- Create: `Sources/KnitNoteCore/Projects/ProjectCounter.swift`
- Modify: `Sources/KnitNoteCore/Projects/StoredProject.swift`
- Test: `Tests/KnitNoteCoreTests/ProjectCounterTests.swift`
- Test: `Tests/KnitNoteCoreTests/RowNoteTests.swift`

**Interfaces:**
- Produces: `ProjectCounter`, `StoredProject.counters`, `selectedCounterID`, `selectedCounter`, `selectCounter(id:)`, `incrementCounter(id:)`, `decrementCounter(id:)`, `renameCounter(id:to:)`, `note(counterID:row:)`, and `saveNote(counterID:row:text:)`.
- Compatibility: `currentRow`, `rowNotes`, `sortedNotes`, `completeRow()`, `undoRow()`, and legacy note methods delegate to the selected counter until all call sites migrate.

- [ ] **Step 1: Write failing counter and migration tests**

```swift
@Test func newProjectHasSixIndependentCounters() throws {
    var project = try StoredProject(name: "Sweater")
    #expect(project.counters.count == 6)
    #expect(project.counters.map(\.defaultOrdinal) == Array(1...6))
    let second = project.counters[1].id
    project.incrementCounter(id: second)
    #expect(project.counters[0].value == 0)
    #expect(project.counters[1].value == 1)
    project.decrementCounter(id: second)
    project.decrementCounter(id: second)
    #expect(project.counters[1].value == 0)
}

@Test func equalRowsOnDifferentCountersKeepIndependentNotes() throws {
    var project = try StoredProject(name: "Cable")
    let first = project.counters[0].id
    let second = project.counters[1].id
    try project.saveNote(counterID: first, row: 4, text: "left cable")
    try project.saveNote(counterID: second, row: 4, text: "right cable")
    #expect(project.note(counterID: first, row: 4)?.text == "left cable")
    #expect(project.note(counterID: second, row: 4)?.text == "right cable")
}
```

Add a legacy JSON test that removes `counters` and `selectedCounterID`, retains `currentRow: 8` and one legacy note, decodes, and expects exactly six counters with both values migrated only to Counter 1.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --disable-sandbox --filter 'ProjectCounterTests|RowNoteTests'`

Expected: compilation fails because `ProjectCounter`, `counters`, and counter-ID methods do not exist.

- [ ] **Step 3: Add the counter type and authoritative project storage**

```swift
public struct ProjectCounter: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let defaultOrdinal: Int
    public private(set) var customName: String?
    public private(set) var value: Int
    public private(set) var rowNotes: [RowNote]

    public init(id: UUID = UUID(), defaultOrdinal: Int, customName: String? = nil,
                value: Int = 0, rowNotes: [RowNote] = []) {
        let cleanName = customName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.defaultOrdinal = defaultOrdinal
        self.customName = cleanName?.isEmpty == false ? cleanName : nil
        self.value = max(0, value)
        self.rowNotes = rowNotes
    }
}
```

Store six counters and a selected ID in `StoredProject`. Decode `counters` when present; otherwise construct six counters and seed Counter 1 from decoded legacy `currentRow` and `rowNotes`. Encode the new fields and retain legacy fields during one compatibility release. Normalize malformed decoded arrays to six stable slots without duplicating existing identifiers.

- [ ] **Step 4: Implement explicit mutations and compatibility adapters**

Implement mutations by identifier, trim custom names, turn blank names into `nil`, preserve notes during rename, and update `updatedAt` only when a real change occurs. Compatibility `currentRow` and note accessors must refer to `selectedCounter` rather than a duplicated stored integer.

- [ ] **Step 5: Run focused and full core tests**

Run: `swift test --disable-sandbox --filter 'ProjectCounterTests|RowNoteTests'`

Expected: new counter, note-isolation, rename, zero-clamp, selection, Codable, and legacy migration tests pass.

Run: `swift test --disable-sandbox`

Expected: all existing tests pass with compatibility adapters.

- [ ] **Step 6: Commit the domain model**

```bash
git add Sources/KnitNoteCore/Projects/ProjectCounter.swift Sources/KnitNoteCore/Projects/StoredProject.swift Tests/KnitNoteCoreTests/ProjectCounterTests.swift Tests/KnitNoteCoreTests/RowNoteTests.swift
git commit -m 'Add six counters to knitting projects'
```

### Task 2: Persistent Store Counter APIs and Archive Version

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Test: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Consumes: counter-ID mutations from Task 1.
- Produces: `selectCounter(projectID:counterID:)`, `incrementCounter(projectID:counterID:)`, `decrementCounter(projectID:counterID:)`, `renameCounter(projectID:counterID:name:)`, `saveNote(projectID:counterID:row:text:)`, and `deleteNote(projectID:counterID:row:)`.

- [ ] **Step 1: Write failing persistence tests**

```swift
@MainActor @Test func storePersistsSixCounterMutationsAndNotes() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Cardigan")
    let project = try #require(store.projects.first)
    let counterID = project.counters[2].id
    try store.selectCounter(projectID: project.id, counterID: counterID)
    try store.renameCounter(projectID: project.id, counterID: counterID, name: "Sleeve A")
    try store.incrementCounter(projectID: project.id, counterID: counterID)
    try store.saveNote(projectID: project.id, counterID: counterID, row: 1, text: "increase")
    let reloaded = try #require(JSONProjectStore(url: url).projects.first)
    #expect(reloaded.selectedCounterID == counterID)
    #expect(reloaded.selectedCounter.customName == "Sleeve A")
    #expect(reloaded.selectedCounter.value == 1)
    #expect(reloaded.note(counterID: counterID, row: 1)?.text == "increase")
}
```

Update the archive test to expect version `7`.

- [ ] **Step 2: Run store tests and verify RED**

Run: `swift test --disable-sandbox --filter JSONProjectStoreTests`

Expected: compilation fails on the new store API and archive version remains 6.

- [ ] **Step 3: Add store mutations and advance archive version**

Each public method calls the existing transactional `mutate(id:_:)`; no view receives an in-memory-only mutation. Change `ProjectArchive(version: 6, ...)` to version 7. Keep old `completeRow`, `undoRow`, and legacy note methods as selected-counter adapters until UI migration completes.

- [ ] **Step 4: Verify persistence and regression suite**

Run: `swift test --disable-sandbox --filter JSONProjectStoreTests`

Expected: all store tests pass and the written archive reports version 7.

Run: `swift test --disable-sandbox`

Expected: full suite passes.

- [ ] **Step 5: Commit the store layer**

```bash
git add Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift
git commit -m 'Persist project counter operations'
```

### Task 3: Localized Counter Names and Shared Counter Components

**Files:**
- Create: `KnitNote/Projects/ProjectCounterName.swift`
- Create: `KnitNote/Projects/CounterSelectorGrid.swift`
- Create: `KnitNote/Projects/EditCounterNameView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `KnitNote.xcodeproj/project.pbxproj`
- Test: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`

**Interfaces:**
- Consumes: `ProjectCounter.defaultOrdinal`, `customName`, `value`, and ID-based store APIs.
- Produces: `projectCounterDisplayName(_:)`, `CounterSelectorGrid`, and `EditCounterNameView` for both project and pattern screens.

- [ ] **Step 1: Write localization source-contract tests**

Assert that the string catalog contains English and Traditional Chinese values for `counter.defaultName`, `counter.rename`, `counter.expand`, `counter.collapse`, `counter.increment`, and `counter.decrement`, and that `counter.defaultName` contains a numeric substitution in both languages.

- [ ] **Step 2: Run the localization test and verify RED**

Run: `swift test --disable-sandbox --filter LocalizationContractTests`

Expected: missing localization keys fail the test.

- [ ] **Step 3: Add localization and name resolution**

```swift
func projectCounterDisplayName(_ counter: ProjectCounter) -> String {
    counter.customName ?? String(
        format: String(localized: "counter.defaultName"),
        locale: .current,
        counter.defaultOrdinal
    )
}
```

English uses `Counter %lld`; Traditional Chinese uses `計數器 %lld`. Add localized labels for editing, expanding, collapsing, incrementing, decrementing, and the six-counter accessibility summary.

- [ ] **Step 4: Build reusable selector and rename UI**

`CounterSelectorGrid` receives `[ProjectCounter]`, `selectedCounterID`, adaptive column count, and closures for select, increment, decrement, rename, and note. Each cell exposes the localized display name and monospaced value with 44-point controls. `EditCounterNameView` seeds the current display name, trims on save, and passes an empty string to restore the default.

- [ ] **Step 5: Verify localization and compile components**

Run: `swift test --disable-sandbox --filter LocalizationContractTests`

Expected: localization contract passes.

Run: `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteSixCounters CODE_SIGNING_ALLOWED=NO build`

Expected: build succeeds.

- [ ] **Step 6: Commit shared counter UI**

```bash
git add KnitNote/Projects/ProjectCounterName.swift KnitNote/Projects/CounterSelectorGrid.swift KnitNote/Projects/EditCounterNameView.swift KnitNote/Localization/Localizable.xcstrings KnitNote.xcodeproj/project.pbxproj Tests/KnitNoteCoreTests/LocalizationContractTests.swift
git commit -m 'Add localized project counter controls'
```

### Task 4: Project Detail and Per-Counter Notes

**Files:**
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `KnitNote/Projects/ProjectCard.swift`
- Modify: `KnitNote/Projects/EditRowNoteView.swift`
- Modify: `KnitNote/Projects/AllNotesView.swift`
- Test: `Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift`

**Interfaces:**
- Consumes: shared counter components and ID-based store APIs.
- Produces: a selected-counter primary display and `(counterID, row)` note editing throughout Project Detail.

- [ ] **Step 1: Write failing Project Detail source-contract tests**

Verify `ProjectDetailView` renders `CounterSelectorGrid`, derives the large value from `selectedCounter`, and passes a counter ID plus row to note editing. Verify `ProjectCard` uses the selected counter display name and value instead of the legacy `project.currentRow` label.

- [ ] **Step 2: Run contract tests and verify RED**

Run: `swift test --disable-sandbox --filter ProjectCounterViewContractTests`

Expected: tests fail because the existing views use one integer and row-only note identity.

- [ ] **Step 3: Migrate note editing to composite identity**

Introduce a small `CounterRowSelection: Identifiable` carrying `counterID` and `row`. Update `EditRowNoteView` to load and save through `note(counterID:row:)` and `saveNote(projectID:counterID:row:text:)`. Update `AllNotesView` to receive the selected counter ID and list only that counter's sorted notes.

- [ ] **Step 4: Rebuild Project Detail around the selected counter**

Keep the large number and primary `+1` button. Display the selected counter name above it, route Undo and Notes to that counter, place `CounterSelectorGrid` below the supporting actions, and present rename and note sheets through identifiable selections. Preserve the existing glint animation and watercolor styling.

- [ ] **Step 5: Update Project Card and verify UI build**

Show `projectCounterDisplayName(project.selectedCounter)` and the selected value. Run:

`swift test --disable-sandbox --filter ProjectCounterViewContractTests`

Expected: contract tests pass.

`xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteSixCounters CODE_SIGNING_ALLOWED=NO build`

Expected: build succeeds.

- [ ] **Step 6: Commit Project Detail integration**

```bash
git add KnitNote/Projects/ProjectDetailView.swift KnitNote/Projects/ProjectCard.swift KnitNote/Projects/EditRowNoteView.swift KnitNote/Projects/AllNotesView.swift Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift
git commit -m 'Show six counters on project details'
```

### Task 5: Collapsible Six-Counter Pattern Reader Panel

**Files:**
- Modify: `KnitNote/Patterns/PatternReaderControls.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Test: `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`

**Interfaces:**
- Consumes: `CounterSelectorGrid`, composite note selection, `StoredProject.counters`, and explicit store APIs.
- Produces: collapsed selected-counter controls and an expanded six-counter panel whose expansion is local UI state.

- [ ] **Step 1: Write failing Pattern Reader contract tests**

Verify controls receive the six counters and selected ID, include an expansion binding, call ID-specific increment/decrement/select closures, and expose note and rename actions. Verify `PatternReaderView` stores only `counterPanelExpanded` locally and does not put panel state in `PatternReadingState`.

- [ ] **Step 2: Run contract tests and verify RED**

Run: `swift test --disable-sandbox --filter PatternReaderCounterContractTests`

Expected: controls still accept only `currentRow` and two row closures.

- [ ] **Step 3: Implement collapsed controls**

Replace the row-only strip with selected counter name, monospaced value, decrement, increment, note, and expand controls. Retain PDF previous/next navigation above it and preserve its current disabled boundaries.

- [ ] **Step 4: Implement expanded controls and store wiring**

When expanded, render `CounterSelectorGrid` below the collapsed strip. Route select, increment, decrement, rename, and note operations through explicit project/counter IDs. Keep `@State private var counterPanelExpanded = false` independent from page, highlight, markup, and saved PDF reading state.

- [ ] **Step 5: Verify safe layout and all pattern regressions**

Run: `swift test --disable-sandbox --filter 'PatternReaderCounterContractTests|PatternDocumentTests|PatternMarkupTests'`

Expected: counter contracts and pattern state tests pass.

Run the iOS simulator build and inspect iPhone portrait plus iPad portrait/landscape. Confirm the PDF bottom remains reachable, panel scrolling does not move the PDF, and page/highlight/markup actions do not collapse or reset counters.

- [ ] **Step 6: Commit Pattern Reader integration**

```bash
git add KnitNote/Patterns/PatternReaderControls.swift KnitNote/Patterns/PatternReaderView.swift Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift
git commit -m 'Add six counters to pattern reader'
```

### Task 6: Remove Compatibility Call Sites and Complete Verification

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/StoredProject.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: tests that still intentionally reference legacy adapters
- Verify: all modified source, localization, project, and test files

**Interfaces:**
- Consumes: all Task 1–5 APIs and UI.
- Produces: production call sites that use explicit counter identity; decoding remains backward compatible.

- [ ] **Step 1: Find remaining production legacy mutations**

Run: `rg -n 'completeRow\(|undoRow\(|saveNote\(projectID: [^,]+, row:|\.currentRow|\.rowNotes' KnitNote Sources/KnitNoteCore`

Expected: only declared compatibility decoding/adapters or intentionally documented legacy boundaries remain; no Project Detail or Pattern Reader call site uses them.

- [ ] **Step 2: Remove unnecessary adapters while retaining decode migration**

Delete legacy public mutation methods once no production caller needs them. Keep only legacy `CodingKeys` and decode fallback required to import archives through version 6. Update old tests to assert selected-counter behavior through the new API.

- [ ] **Step 3: Run fresh complete verification**

Run: `swift test --disable-sandbox`

Expected: every test passes with zero failures.

Run: `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteSixCountersFinal CODE_SIGNING_ALLOWED=NO build`

Expected: iOS/iPadOS simulator build succeeds.

Run: `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteSixCountersMac CODE_SIGNING_ALLOWED=NO build`

Expected: macOS build succeeds.

Run: `git diff --check`

Expected: no whitespace errors.

- [ ] **Step 4: Perform acceptance migration and synchronization checks**

Install over an archive with an existing row value and note; confirm they appear only in Counter 1. Rename and increment different counters in Project Detail, open Pattern Reader, and confirm selection, values, and notes match. Repeat on iPhone and iPad, including PDF paging, highlight movement, markup, rotation, collapsed/expanded panel, relaunch, and large Dynamic Type.

- [ ] **Step 5: Commit final cleanup**

```bash
git add Sources/KnitNoteCore/Projects/StoredProject.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests KnitNote
git commit -m 'Complete six-counter project migration'
```
