# Mac Create Project Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken macOS `Form` presentation in Create Project with a clear adaptive single-column layout while preserving the existing iPhone and iPad flow.

**Architecture:** Keep one `CreateProjectView` state and create action, but split only its content presentation by platform. macOS uses a centered `ScrollView` and bounded `VStack`; iOS/iPadOS retain the existing `Form`. `ProjectPhotoPicker` keeps its platform-specific controls and adaptive Mac action row.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Xcode 26.6.

## Global Constraints

- macOS only changes presentation; project creation, photo loading, errors, entitlement checks, and persistence remain unchanged.
- iPhone and iPad retain the current `Form`, camera action, and control order.
- Mac sheet remains resizable with minimum width 520, ideal width 620, minimum height 560, and `.presentationSizing(.fitted)`.
- All copy continues using existing localization keys.
- Use a non-private image for manual photo acceptance and do not save the test draft.

---

### Task 1: Replace the Mac Form with a bounded single-column layout

**Files:**
- Modify: `KnitNote/Projects/CreateProjectView.swift`
- Modify: `Tests/KnitNoteCoreTests/MacFormLayoutContractTests.swift`
- Modify: `Tests/KnitNoteAppTests/MacFormLayoutSmokeTests.swift`

**Interfaces:**
- Consumes: existing `name`, `selectedPhotoData`, `removesPhoto`, `isPhotoLoading`, `ProjectPhotoPicker`, and `create()`.
- Produces: `macProjectContent` and `projectForm` private views inside `CreateProjectView`; no public API changes.

- [ ] **Step 1: Write the failing platform-layout contracts**

Update the focused tests so they require a Mac-only `ScrollView`/bounded `VStack` and require the non-Mac branch to retain `Form`:

```swift
@Test func macCreateProjectUsesSingleColumnContentInsteadOfForm() throws {
    let source = try source(named: "CreateProjectView.swift")
    let macBranch = try #require(source.range(of: "#if os(macOS)"))
    let nonMacBranch = try #require(
        source.range(of: "#else", range: macBranch.upperBound..<source.endIndex)
    )
    let macSource = String(source[macBranch.lowerBound..<nonMacBranch.lowerBound])
    let nonMacSource = String(source[nonMacBranch.upperBound...])

    #expect(macSource.contains("ScrollView"))
    #expect(macSource.contains("VStack(alignment: .leading, spacing: 20)"))
    #expect(macSource.contains(".frame(maxWidth: 720)"))
    #expect(!macSource.contains("Form"))
    #expect(nonMacSource.contains("Form"))
}
```

Strengthen `MacFormLayoutSmokeTests` with the same platform boundary so an app-target test also catches an accidental return to Mac `Form`.

- [ ] **Step 2: Run the focused tests and observe RED**

Run:

```bash
env CLANG_MODULE_CACHE_PATH=/tmp/knitnote-mac-create-layout-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-mac-create-layout-cache \
swift test --disable-sandbox --filter MacFormLayoutContractTests
```

Expected: FAIL because current macOS content is still the shared `Form` and no bounded single-column view exists.

- [ ] **Step 3: Implement the minimal platform split**

Keep `NavigationStack`, toolbar, alert, frame, and tint shared. Replace only the content with:

```swift
#if os(macOS)
private var macProjectContent: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text("project.name")
                .font(.headline)
            TextField("project.name", text: $name)

            Text("project.photo.optional")
                .font(.headline)
            ProjectPhotoPicker(
                existingURL: nil,
                selectedData: $selectedPhotoData,
                removesExistingPhoto: $removesPhoto,
                isLoading: $isPhotoLoading
            )
        }
        .frame(maxWidth: 720)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .top)
    }
    .scrollContentBackground(.hidden)
    .background(WatercolorBackground())
}
#else
private var projectForm: some View {
    Form {
        Section { TextField("project.name", text: $name) }
        Section("project.photo.optional") { projectPhotoPicker }
    }
    .scrollContentBackground(.hidden)
    .background(WatercolorBackground())
}
#endif
```

Extract one private `projectPhotoPicker` view to avoid duplicating bindings. Do not change `create()` or `ProjectPhotoPicker` behavior.

- [ ] **Step 4: Run focused and platform verification**

Run:

```bash
env CLANG_MODULE_CACHE_PATH=/tmp/knitnote-mac-create-layout-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-mac-create-layout-cache \
swift test --disable-sandbox --filter MacFormLayoutContractTests

xcodebuild -quiet test -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/knitnote-mac-create-layout-tests \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests/MacFormLayoutSmokeTests

xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/knitnote-mac-create-layout-ios \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: focused tests PASS, Mac smoke PASS, iOS Simulator build exits 0.

- [ ] **Step 5: Verify the signed Mac candidate visually**

At 620, 520, and approximately 960 points wide, verify a single column with no split rows, clipping, or abnormal empty section. With a non-private photo, verify 620 horizontal actions, 520 vertical actions, and Replace before Remove in accessibility order. Check Traditional Chinese and English.

- [ ] **Step 6: Commit**

```bash
git add KnitNote/Projects/CreateProjectView.swift \
  Tests/KnitNoteCoreTests/MacFormLayoutContractTests.swift \
  Tests/KnitNoteAppTests/MacFormLayoutSmokeTests.swift
git commit -m "fix: rebuild Mac project creation layout"
```
