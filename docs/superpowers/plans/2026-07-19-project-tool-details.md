# Project Tool Details Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each project optionally record its crochet hook, knitting needle, or other tool type, free-form size, and notes.

**Architecture:** Store normalized optional tool details directly on `StoredProject`, because they belong to a project rather than a reusable inventory. Extend the existing atomic project update flow so the name, photo, and tool fields save together; render the same data conditionally in the edit form and detail screen.

**Tech Stack:** Swift, SwiftUI, Codable JSON archive, String Catalog localization, Swift Testing

## Global Constraints

- Do not create a tool library or new tab.
- Tool type, size, and notes are optional and do not alter the quick-create flow.
- Size and notes preserve user-entered text across app-language changes.
- Existing project archives without tool fields decode successfully.
- Support Traditional Chinese and English on iPhone and iPad.

---

### Task 1: Persist normalized project tool details

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/StoredProject.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Produces: `ProjectToolType: String, Codable, CaseIterable, Sendable`; `StoredProject.toolType`, `toolSize`, and `toolNotes`; `StoredProject.updateToolDetails(type:size:notes:now:)`; extended `JSONProjectStore.updateProject(id:name:toolType:toolSize:toolNotes:photoChange:)`.
- Consumes: Existing project Codable and atomic photo update behavior.

- [ ] **Step 1: Write failing model and persistence tests**

Add tests proving trimming, clearing, timestamps, round trips, and legacy defaults:

```swift
@MainActor @Test func projectToolDetailsNormalizeAndPersist() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Cardigan")
    let project = try #require(store.projects.first)

    try store.updateProject(
        id: project.id,
        name: project.name,
        toolType: .crochetHook,
        toolSize: "  3.5 mm  ",
        toolNotes: "  ergonomic handle  ",
        photoChange: .unchanged
    )

    let reloaded = try #require(JSONProjectStore(url: url).project(id: project.id))
    #expect(reloaded.toolType == .crochetHook)
    #expect(reloaded.toolSize == "3.5 mm")
    #expect(reloaded.toolNotes == "ergonomic handle")

    try store.updateProject(
        id: project.id,
        name: project.name,
        toolType: nil,
        toolSize: "   ",
        toolNotes: "\n",
        photoChange: .unchanged
    )
    let cleared = try #require(JSONProjectStore(url: url).project(id: project.id))
    #expect(cleared.toolType == nil)
    #expect(cleared.toolSize == nil)
    #expect(cleared.toolNotes == nil)
}

@Test func legacyProjectWithoutToolDetailsDefaultsToEmpty() throws {
    let original = try StoredProject(name: "Scarf")
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object.removeValue(forKey: "toolType")
    object.removeValue(forKey: "toolSize")
    object.removeValue(forKey: "toolNotes")
    let decoded = try JSONDecoder().decode(
        StoredProject.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(decoded.toolType == nil)
    #expect(decoded.toolSize == nil)
    #expect(decoded.toolNotes == nil)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
HOME=/tmp/knitnote-home swift test --disable-sandbox --filter projectToolDetails
HOME=/tmp/knitnote-home swift test --disable-sandbox --filter legacyProjectWithoutToolDetails
```

Expected: compilation fails because the tool types, properties, and update arguments do not exist.

- [ ] **Step 3: Implement the model fields and normalization**

Add:

```swift
public enum ProjectToolType: String, Codable, CaseIterable, Sendable {
    case crochetHook
    case knittingNeedles
    case other
}
```

Add private-set optional fields to `StoredProject`, initialize them to `nil`, include them in `CodingKeys`, decode with `decodeIfPresent`, and encode with `encodeIfPresent`. Add:

```swift
public mutating func updateToolDetails(
    type: ProjectToolType?,
    size: String?,
    notes: String?,
    now: Date = .now
) {
    let cleanSize = Self.normalizedOptionalText(size)
    let cleanNotes = Self.normalizedOptionalText(notes)
    guard toolType != type || toolSize != cleanSize || toolNotes != cleanNotes else { return }
    toolType = type
    toolSize = cleanSize
    toolNotes = cleanNotes
    updatedAt = now
}

private static func normalizedOptionalText(_ value: String?) -> String? {
    guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else {
        return nil
    }
    return clean
}
```

- [ ] **Step 4: Extend the atomic store update**

Change `updateProject` to accept the three tool values and call both:

```swift
try staged[index].rename(to: name)
staged[index].updateToolDetails(type: toolType, size: toolSize, notes: toolNotes)
```

before staging the photo change and persisting. Update its existing call sites to pass their current or edited values.

- [ ] **Step 5: Run Task 1 tests**

Run:

```bash
HOME=/tmp/knitnote-home swift test --disable-sandbox --filter projectToolDetails
HOME=/tmp/knitnote-home swift test --disable-sandbox --filter legacyProjectWithoutToolDetails
```

Expected: both tests PASS.

---

### Task 2: Edit and display project tools

**Files:**
- Modify: `KnitNote/Projects/EditProjectView.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift`

**Interfaces:**
- Consumes: `ProjectToolType`, project tool properties, and the extended store update from Task 1.
- Produces: Optional tool editor section and conditional detail card.

- [ ] **Step 1: Write failing UI contract tests**

Add:

```swift
@Test func projectEditorAndDetailSupportOptionalToolDetails() throws {
    let edit = try projectSource(named: "EditProjectView")
    let detail = try projectSource(named: "ProjectDetailView")

    #expect(edit.contains("Section(\"project.tool.section\")"))
    #expect(edit.contains("Picker(\"project.tool.type\""))
    #expect(edit.contains("TextField(\"project.tool.size\""))
    #expect(edit.contains("TextField(\"project.tool.notes\""))
    #expect(edit.contains("toolType: toolType"))
    #expect(edit.contains("toolSize: toolSize"))
    #expect(edit.contains("toolNotes: toolNotes"))
    #expect(detail.contains("hasToolDetails(project)"))
    #expect(detail.contains("Text(\"project.tool.section\")"))
    #expect(detail.contains("if let toolType = project.toolType"))
    #expect(detail.contains("if let toolSize = project.toolSize"))
    #expect(detail.contains("if let toolNotes = project.toolNotes"))
}
```

- [ ] **Step 2: Run the UI contract test and verify RED**

Run:

```bash
HOME=/tmp/knitnote-home swift test --disable-sandbox --filter projectEditorAndDetailSupportOptionalToolDetails
```

Expected: FAIL because neither screen contains tool UI.

- [ ] **Step 3: Add edit state and tool form section**

Add state:

```swift
@State private var toolType: ProjectToolType?
@State private var toolSize = ""
@State private var toolNotes = ""
```

Add a `Section("project.tool.section")` with a `Picker` containing `nil` plus `ProjectToolType.allCases`, and text fields for size and notes. Populate the state in `onAppear`, then pass the values to `store.updateProject` in `save()`.

- [ ] **Step 4: Add the conditional detail card**

After the photo/completion header and before counters, add a `WatercolorCard` only when `hasToolDetails(project)` is true. Use `LabeledContent` rows for each non-nil field and this helper:

```swift
private func hasToolDetails(_ project: StoredProject) -> Bool {
    project.toolType != nil || project.toolSize != nil || project.toolNotes != nil
}
```

Map tool types to localization keys with one focused helper returning `LocalizedStringKey`.

- [ ] **Step 5: Run Task 2 test**

Run:

```bash
HOME=/tmp/knitnote-home swift test --disable-sandbox --filter projectEditorAndDetailSupportOptionalToolDetails
```

Expected: PASS.

---

### Task 3: Localize, verify, and visually inspect

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`

**Interfaces:**
- Consumes: Localization keys used in Task 2.
- Produces: Traditional Chinese and English tool copy.

- [ ] **Step 1: Add a failing localization contract**

Extend the localization key list with:

```swift
"project.tool.section",
"project.tool.type",
"project.tool.type.none",
"project.tool.type.crochetHook",
"project.tool.type.knittingNeedles",
"project.tool.type.other",
"project.tool.size",
"project.tool.notes",
```

- [ ] **Step 2: Run localization tests and verify RED**

Run:

```bash
HOME=/tmp/knitnote-home swift test --disable-sandbox --filter LocalizationContractTests
```

Expected: FAIL because the new keys are absent.

- [ ] **Step 3: Add English and Traditional Chinese strings**

Add values:

| Key | English | Traditional Chinese |
|---|---|---|
| `project.tool.section` | Tools | 使用工具 |
| `project.tool.type` | Tool type | 工具類型 |
| `project.tool.type.none` | Not set | 未設定 |
| `project.tool.type.crochetHook` | Crochet hook | 鉤針 |
| `project.tool.type.knittingNeedles` | Knitting needles | 棒針 |
| `project.tool.type.other` | Other | 其他 |
| `project.tool.size` | Size | 尺寸 |
| `project.tool.notes` | Notes | 備註 |

- [ ] **Step 4: Run full verification**

Run:

```bash
HOME=/tmp/knitnote-home swift test --disable-sandbox
git diff --check
```

Expected: all tests PASS and no whitespace errors.

- [ ] **Step 5: Build and inspect iPhone and iPad**

Use Xcode to build and run `KnitNote` on iPhone 17 Pro Max and iPad Pro 13-inch. Verify the edit form fits, saving and clearing work, the detail card hides when empty, and long free-form values wrap without clipping.
