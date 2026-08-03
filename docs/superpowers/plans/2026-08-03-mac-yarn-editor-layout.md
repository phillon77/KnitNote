# KnitNote Mac Yarn Editor Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the misaligned macOS yarn create/edit `Form` layouts with one clear centered single-column editor while preserving every iPhone/iPad workflow and all existing yarn data behavior.

**Architecture:** Add a Mac-only shared field component built from `ScrollView`, bounded vertical stacks, labeled fields, and reusable watercolor sections. `CreateYarnView` and `EditYarnView` keep their existing state, toolbar, save, scan, photo, link, and error logic; only their macOS content branches change. iOS/iPadOS continue using the current `YarnEditorFields` inside `Form`.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, XcodeGen, Xcode 26.6.

## Global Constraints

- macOS layout only: iPhone and iPad retain the existing `Form`, field order, camera/photo flow, OCR confirmation, and save behavior.
- Mac editor content width is exactly 560 pt maximum with exactly 28 pt outer padding.
- Mac sheets keep minimum width 520 pt, ideal width 620 pt, minimum height 560 pt, and `.presentationSizing(.fitted)`.
- Fields remain single-column at every supported Mac window width; wider windows add only outer whitespace.
- Existing `YarnEditorDraft`, persistence, validation, photo installation, label-photo management, project links, backup, and OCR logic remain unchanged.
- Traditional Chinese and English are both required; new section keys must have both translations.
- The existing user-owned untracked `KnitNote 5.xcodeproj/` must remain untouched.
- Do not change version/build metadata, merge, push, upload, submit, or release.

---

### Task 1: Build the Shared Mac Fields and Convert Create Yarn

**Files:**
- Create: `KnitNote/Yarn/MacYarnEditorFields.swift`
- Modify: `KnitNote/Yarn/CreateYarnView.swift:27-80`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/MacFormLayoutContractTests.swift`
- Modify: `Tests/KnitNoteAppTests/MacFormLayoutSmokeTests.swift`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `YarnEditorDraft`, `YarnInventoryEditValue`, `ChooseYarnProjectsView`, `WatercolorCard`, `YarnPhotoPicker`, and current `CreateYarnView.save()`.
- Produces: `MacYarnEditorFields(draft: Binding<YarnEditorDraft>)` and `MacYarnEditorSection(_:content:)`, both internal macOS-only SwiftUI views reusable by Task 2.

- [ ] **Step 1: Replace the partial width-only tests with failing single-column contracts**

Replace the current `macCreateYarnEditorRequestsFittedPresentationSizing` test in `MacFormLayoutContractTests` with these tests:

```swift
@Test func macCreateYarnEditorUsesSharedSingleColumnContentInsteadOfForm() throws {
    let source = try source(named: "CreateYarnView.swift")
    let editorContent = try #require(source.range(of: "private var editorContent"))
    let macBranch = try #require(
        source.range(of: "#if os(macOS)", range: editorContent.upperBound..<source.endIndex)
    )
    let nonMacBranch = try #require(
        source.range(of: "#else", range: macBranch.upperBound..<source.endIndex)
    )
    let macSource = String(source[macBranch.lowerBound..<nonMacBranch.lowerBound])
    let nonMacSource = String(source[nonMacBranch.upperBound...])

    #expect(macSource.contains("ScrollView"))
    #expect(macSource.contains("MacYarnEditorFields(draft: $draft)"))
    #expect(macSource.contains("MacYarnEditorSection(\"yarn.photo\")"))
    #expect(macSource.contains(".frame(maxWidth: 560)"))
    #expect(macSource.contains(".padding(28)"))
    #expect(!macSource.contains("Form"))
    #expect(nonMacSource.contains("Form"))
    #expect(nonMacSource.contains("YarnEditorFields(draft: $draft)"))
}

@Test func macYarnFieldsUseVerticalLabeledSectionsWithoutForm() throws {
    let source = try source(named: "MacYarnEditorFields.swift")

    #expect(source.contains("#if os(macOS)"))
    #expect(source.contains("struct MacYarnEditorFields: View"))
    #expect(source.contains("VStack(alignment: .leading, spacing: 20)"))
    #expect(source.contains("MacYarnEditorSection(\"yarn.section.basic\")"))
    #expect(source.contains("MacYarnEditorSection(\"yarn.label.details\")"))
    #expect(source.contains("MacYarnEditorSection(\"yarn.section.inventory\")"))
    #expect(source.contains("MacYarnEditorSection(\"yarn.section.storage\")"))
    #expect(source.contains("MacYarnEditorSection(\"yarn.linkedProjects\")"))
    #expect(!source.contains("Form"))
    #expect(!source.contains("Section {"))
}
```

Extend `MacFormLayoutSmokeTests` with:

```swift
let createYarn = try source(named: "CreateYarnView.swift", in: "Yarn")
let macYarnFields = try source(named: "MacYarnEditorFields.swift", in: "Yarn")

#expect(createYarn.contains("MacYarnEditorFields(draft: $draft)"))
#expect(macYarnFields.contains("VStack(alignment: .leading, spacing: 20)"))
#expect(macYarnFields.contains("MacYarnEditorSection"))
#expect(!macYarnFields.contains("Form"))
```

Add the exact copy contract to `LocalizationContractTests`:

```swift
private let requiredMacYarnSectionTranslations = [
    "yarn.section.basic": ["en": "Basic Details", "zh-Hant": "基本資料"],
    "yarn.section.inventory": ["en": "Inventory", "zh-Hant": "庫存"],
    "yarn.section.storage": ["en": "Storage & Notes", "zh-Hant": "收納與筆記"],
]

@Test func macYarnSectionStringsHaveExactBilingualCopy() throws {
    let strings = try catalogStrings()

    for (key, expectedValues) in requiredMacYarnSectionTranslations {
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        for (language, expectedValue) in expectedValues {
            let translation = try #require(localizations[language] as? [String: Any])
            let stringUnit = try #require(translation["stringUnit"] as? [String: Any])
            #expect(stringUnit["value"] as? String == expectedValue)
        }
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
env CLANG_MODULE_CACHE_PATH=/tmp/knitnote-mac-yarn-layout-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-mac-yarn-layout-cache \
swift test --disable-sandbox --filter MacFormLayoutContractTests

swift test --disable-sandbox --filter LocalizationContractTests.macYarnSectionStringsHaveExactBilingualCopy
```

Expected: FAIL because `MacYarnEditorFields.swift` and the three new catalog entries do not exist, and `CreateYarnView` still uses a Mac `Form` with width-only modifiers.

- [ ] **Step 3: Add the exact bilingual section copy**

Add these keys to `Localizable.xcstrings`, preserving the file's existing JSON structure and extraction state:

| Key | Traditional Chinese | English |
|---|---|---|
| `yarn.section.basic` | `基本資料` | `Basic Details` |
| `yarn.section.inventory` | `庫存` | `Inventory` |
| `yarn.section.storage` | `收納與筆記` | `Storage & Notes` |

Do not add copy for existing keys such as `yarn.label.details`, `yarn.linkedProjects`, `yarn.photo`, or any field label.

- [ ] **Step 4: Create the Mac-only reusable field and card components**

Create `MacYarnEditorFields.swift` with this structure and every existing field binding:

```swift
import SwiftUI

#if os(macOS)
struct MacYarnEditorFields: View {
    @Environment(\.locale) private var locale
    @Binding var draft: YarnEditorDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MacYarnEditorSection("yarn.section.basic") {
                labeledField("yarn.name") {
                    TextField("yarn.name", text: $draft.name).labelsHidden()
                }
                labeledField("yarn.brand") {
                    TextField("yarn.brand", text: $draft.brand).labelsHidden()
                }
                labeledField("yarn.series") {
                    TextField("yarn.series", text: $draft.series).labelsHidden()
                }
                labeledField("yarn.color") {
                    TextField("yarn.color", text: $draft.color).labelsHidden()
                }
                labeledField("yarn.colorCode") {
                    TextField("yarn.colorCode", text: $draft.colorCode).labelsHidden()
                }
            }

            MacYarnEditorSection("yarn.label.details") {
                labeledField("yarn.dyeLot") {
                    TextField("yarn.dyeLot", text: $draft.dyeLot).labelsHidden()
                }
                decimalField(
                    "yarn.ballWeightGrams",
                    text: $draft.ballWeightGrams.text,
                    value: draft.ballWeightGrams
                )
                decimalField(
                    "yarn.lengthMeters",
                    text: $draft.lengthMeters.text,
                    value: draft.lengthMeters
                )
                labeledField("yarn.fiberContent") {
                    TextField("yarn.fiberContent", text: $draft.fiberContent, axis: .vertical)
                        .labelsHidden()
                        .lineLimit(2...5)
                }
                metricRangeField(
                    "yarn.recommendedNeedleMM",
                    lower: $draft.needleLowerMM.text,
                    upper: $draft.needleUpperMM.text
                )
                metricRangeField(
                    "yarn.recommendedHookMM",
                    lower: $draft.hookLowerMM.text,
                    upper: $draft.hookUpperMM.text
                )
            }

            MacYarnEditorSection("yarn.section.inventory") {
                decimalField(
                    "yarn.remainingBalls",
                    text: $draft.remainingBalls.text,
                    value: draft.remainingBalls
                )
                decimalField(
                    "yarn.remainingGrams",
                    text: $draft.remainingGrams.text,
                    value: draft.remainingGrams
                )
            }

            MacYarnEditorSection("yarn.section.storage") {
                labeledField("yarn.storageLocation") {
                    TextField("yarn.storageLocation", text: $draft.storageLocation).labelsHidden()
                }
                labeledField("yarn.notes") {
                    TextField("yarn.notes", text: $draft.notes, axis: .vertical)
                        .labelsHidden()
                        .lineLimit(3...8)
                }
            }

            MacYarnEditorSection("yarn.linkedProjects") {
                NavigationLink {
                    ChooseYarnProjectsView(selectedProjectIDs: $draft.linkedProjectIDs)
                } label: {
                    HStack {
                        Text("yarn.linkedProjects")
                        Spacer()
                        Text(draft.linkedProjectIDs.count, format: .number)
                        Image(systemName: "chevron.right")
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(WatercolorTheme.actionBerry)
            }
        }
    }

    @ViewBuilder
    private func labeledField<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func decimalField(
        _ title: LocalizedStringKey,
        text: Binding<String>,
        value: YarnInventoryEditValue
    ) -> some View {
        labeledField(title) {
            TextField(title, text: text).labelsHidden()
            validationMessage(for: value)
        }
    }

    private func metricRangeField(
        _ title: LocalizedStringKey,
        lower: Binding<String>,
        upper: Binding<String>
    ) -> some View {
        labeledField(title) {
            HStack(spacing: 8) {
                TextField("yarn.range.lower", text: lower).frame(width: 96)
                Text("–")
                TextField("yarn.range.upper", text: upper).frame(width: 96)
                Text("mm").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func validationMessage(for value: YarnInventoryEditValue) -> some View {
        switch value.input(locale: locale) {
        case .invalid:
            Text("yarn.error.invalidNumber").font(.caption).foregroundStyle(.red)
        case .negative:
            Text("yarn.error.negativeInventory").font(.caption).foregroundStyle(.red)
        case .empty, .value:
            EmptyView()
        }
    }
}

struct MacYarnEditorSection<Content: View>: View {
    private let title: LocalizedStringKey
    private let content: Content

    init(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        WatercolorCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(WatercolorTheme.ink)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
```

Keep the visible label above each `TextField`; `.labelsHidden()` hides only the duplicate field label while retaining the field's localized accessibility label.

- [ ] **Step 5: Convert only Create Yarn's Mac content**

Inside the shared `NavigationStack`, replace the current all-platform `Form` block with an explicit platform content property:

```swift
NavigationStack {
    editorContent
        .navigationTitle("yarn.create")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("common.done") { save() }
                    .disabled(!draft.canSave(locale: locale) || isPhotoLoading)
            }
        }
        .alert("error.saveFailed", isPresented: errorIsPresented) {
            Button("common.retry") { save() }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(errorMessage?.rawValue ?? YarnOperationFailure.saveRetry.rawValue))
        }
}
```

Add the platform-specific content without modifying `save()`:

```swift
@ViewBuilder
private var editorContent: some View {
#if os(macOS)
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            MacYarnEditorFields(draft: $draft)
            MacYarnEditorSection("yarn.photo") {
                yarnPhotoPicker
            }
        }
        .frame(maxWidth: 560)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(WatercolorBackground())
#else
    Form {
        YarnEditorFields(draft: $draft)
        Section("yarn.photo") { yarnPhotoPicker }
    }
    .scrollContentBackground(.hidden)
    .background(WatercolorBackground())
#endif
}

private var yarnPhotoPicker: some View {
    YarnPhotoPicker(
        existingURL: nil,
        selectedData: $selectedPhotoData,
        removesExistingPhoto: $removesExistingPhoto,
        isLoading: $isPhotoLoading
    )
}
```

Retain the current Mac 520/620/560 sheet frame and fitted sizing. Delete the unsuccessful `.frame(maxWidth: 520).frame(maxWidth: .infinity)` width-only modifiers from the old `Form`.

- [ ] **Step 6: Regenerate the project and run focused verification**

Run:

```bash
xcodegen generate

env CLANG_MODULE_CACHE_PATH=/tmp/knitnote-mac-yarn-layout-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-mac-yarn-layout-cache \
swift test --disable-sandbox --filter MacFormLayoutContractTests

swift test --disable-sandbox --filter LocalizationContractTests.macYarnSectionStringsHaveExactBilingualCopy

xcodebuild -quiet test -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteMacYarnLayout-Task1-Tests \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests/MacFormLayoutSmokeTests

xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/KnitNoteMacYarnLayout-Task1-iOS \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: contract tests PASS, Mac smoke PASS, iOS Simulator build exits 0, and `KnitNote.xcodeproj` contains `MacYarnEditorFields.swift` only in the main KnitNote target.

- [ ] **Step 7: Review and commit Task 1**

Check:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; `KnitNote 5.xcodeproj/` remains untracked and untouched.

Commit only Task 1 files:

```bash
git add KnitNote/Yarn/MacYarnEditorFields.swift \
  KnitNote/Yarn/CreateYarnView.swift \
  KnitNote/Localization/Localizable.xcstrings \
  Tests/KnitNoteCoreTests/MacFormLayoutContractTests.swift \
  Tests/KnitNoteAppTests/MacFormLayoutSmokeTests.swift \
  Tests/KnitNoteCoreTests/LocalizationContractTests.swift \
  KnitNote.xcodeproj/project.pbxproj
git commit -m "fix: rebuild Mac create yarn layout"
```

---

### Task 2: Convert Edit Yarn Without Changing Scan or Photo Behavior

**Files:**
- Modify: `KnitNote/Yarn/EditYarnView.swift:18-88`
- Modify: `Tests/KnitNoteCoreTests/MacFormLayoutContractTests.swift`
- Modify: `Tests/KnitNoteAppTests/MacFormLayoutSmokeTests.swift`

**Interfaces:**
- Consumes: Task 1 `MacYarnEditorFields` and `MacYarnEditorSection`, plus existing `YarnLabelScanLauncher`, `YarnLabelPhotoGallery`, `YarnPhotoPicker`, `labelPhotoItems`, `removeLabelPhoto(at:)`, and `save()`.
- Produces: Mac Edit Yarn using the same 560 pt single-column structure while iOS/iPadOS retain the current `Form` and section order.

- [ ] **Step 1: Write the failing Edit Yarn platform contract**

Replace the partial `macEditYarnEditorRequestsFittedPresentationSizing` test with:

```swift
@Test func macEditYarnEditorUsesSharedSingleColumnContentAndKeepsAllActions() throws {
    let source = try source(named: "EditYarnView.swift")
    let editorContent = try #require(source.range(of: "private var editorContent"))
    let macBranch = try #require(
        source.range(of: "#if os(macOS)", range: editorContent.upperBound..<source.endIndex)
    )
    let nonMacBranch = try #require(
        source.range(of: "#else", range: macBranch.upperBound..<source.endIndex)
    )
    let macSource = String(source[macBranch.lowerBound..<nonMacBranch.lowerBound])
    let nonMacSource = String(source[nonMacBranch.upperBound...])

    #expect(macSource.contains("ScrollView"))
    #expect(macSource.contains("MacYarnEditorSection(\"yarn.scan.action\")"))
    #expect(macSource.contains("MacYarnEditorFields(draft: $draft)"))
    #expect(macSource.contains("MacYarnEditorSection(\"yarn.labelPhotos\")"))
    #expect(macSource.contains("MacYarnEditorSection(\"yarn.photo\")"))
    #expect(macSource.contains(".frame(maxWidth: 560)"))
    #expect(macSource.contains(".padding(28)"))
    #expect(!macSource.contains("Form"))
    #expect(nonMacSource.contains("Form"))
    #expect(nonMacSource.contains("YarnLabelScanLauncher"))
    #expect(nonMacSource.contains("YarnLabelPhotoGallery"))
    #expect(nonMacSource.contains("YarnPhotoPicker"))
}
```

Extend the app-target smoke test:

```swift
let editYarn = try source(named: "EditYarnView.swift", in: "Yarn")
#expect(editYarn.contains("MacYarnEditorSection(\"yarn.scan.action\")"))
#expect(editYarn.contains("MacYarnEditorFields(draft: $draft)"))
#expect(editYarn.contains("MacYarnEditorSection(\"yarn.labelPhotos\")"))
#expect(editYarn.contains("MacYarnEditorSection(\"yarn.photo\")"))
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
env CLANG_MODULE_CACHE_PATH=/tmp/knitnote-mac-yarn-layout-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-mac-yarn-layout-cache \
swift test --disable-sandbox --filter MacFormLayoutContractTests.macEditYarnEditorUsesSharedSingleColumnContentAndKeepsAllActions
```

Expected: FAIL because Edit Yarn still uses the old Mac `Form`.

- [ ] **Step 3: Extract Edit Yarn's existing controls without changing their callbacks**

Add these exact private views:

```swift
private var scanLauncher: some View {
    YarnLabelScanLauncher { output in
        draft.apply(output.seed, locale: locale)
        scannedLabelPhotos = output.labelPhotos
    } label: {
        Label("yarn.scan.action", systemImage: "viewfinder")
    }
}

private var yarnPhotoPicker: some View {
    YarnPhotoPicker(
        existingURL: yarn.flatMap(store.photoURL(for:)),
        selectedData: $selectedPhotoData,
        removesExistingPhoto: $removesExistingPhoto,
        isLoading: $isPhotoLoading
    )
}
```

Do not change `labelPhotoItems`, `removeLabelPhoto(at:)`, `save()`, label-photo replacement semantics, or concurrent project-link merge behavior.

- [ ] **Step 4: Add the Mac single-column and retain the iOS Form**

Use this platform content property:

```swift
@ViewBuilder
private var editorContent: some View {
#if os(macOS)
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            MacYarnEditorSection("yarn.scan.action") {
                scanLauncher
            }
            MacYarnEditorFields(draft: $draft)
            if !labelPhotoItems.isEmpty {
                MacYarnEditorSection("yarn.labelPhotos") {
                    YarnLabelPhotoGallery(items: labelPhotoItems) { index in
                        removeLabelPhoto(at: index)
                    }
                }
            }
            MacYarnEditorSection("yarn.photo") {
                yarnPhotoPicker
            }
        }
        .frame(maxWidth: 560)
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(WatercolorBackground())
#else
    Form {
        Section { scanLauncher }
        YarnEditorFields(draft: $draft)
        if !labelPhotoItems.isEmpty {
            Section("yarn.labelPhotos") {
                YarnLabelPhotoGallery(items: labelPhotoItems) { index in
                    removeLabelPhoto(at: index)
                }
            }
        }
        Section("yarn.photo") { yarnPhotoPicker }
    }
    .scrollContentBackground(.hidden)
    .background(WatercolorBackground())
#endif
}
```

Wire `editorContent` into the existing `NavigationStack`. Retain the toolbar, alert, `onAppear`, Mac 520/620/560 frame, fitted presentation, iOS 340/520 frame, and tint. Delete the obsolete Mac width-only modifiers attached to the old shared `Form`.

- [ ] **Step 5: Run focused and platform verification**

Run:

```bash
env CLANG_MODULE_CACHE_PATH=/tmp/knitnote-mac-yarn-layout-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-mac-yarn-layout-cache \
swift test --disable-sandbox --filter MacFormLayoutContractTests

xcodebuild -quiet test -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteMacYarnLayout-Task2-Tests \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests/MacFormLayoutSmokeTests

xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/KnitNoteMacYarnLayout-Task2-iOS \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/KnitNoteMacYarnLayout-Task2-Mac \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: focused tests PASS, Mac smoke PASS, and both platform builds exit 0.

- [ ] **Step 6: Review and commit Task 2**

Run `git diff --check` and inspect `git diff --stat`. Commit only:

```bash
git add KnitNote/Yarn/EditYarnView.swift \
  Tests/KnitNoteCoreTests/MacFormLayoutContractTests.swift \
  Tests/KnitNoteAppTests/MacFormLayoutSmokeTests.swift
git commit -m "fix: rebuild Mac edit yarn layout"
```

---

### Task 3: Complete Regression and Physical Mac Acceptance

**Files:**
- Verify only: all files committed in Tasks 1-2
- Preserve: `KnitNote 5.xcodeproj/`

**Interfaces:**
- Consumes: exact Task 2 candidate SHA and `/tmp/KnitNoteMacYarnLayout-Final-Mac/Build/Products/Debug/KnitNote.app`.
- Produces: automated cross-platform evidence plus Mac physical acceptance for Create Yarn and Edit Yarn; no release action.

- [ ] **Step 1: Run the full Swift test suite**

Run:

```bash
env CLANG_MODULE_CACHE_PATH=/tmp/knitnote-mac-yarn-layout-final-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-mac-yarn-layout-final-cache \
swift test --disable-sandbox
```

Expected: all suites and tests PASS with exit 0. Record the exact totals from output; do not reuse totals from a prior candidate.

- [ ] **Step 2: Regenerate and build clean iOS and Mac artifacts**

Run:

```bash
xcodegen generate

xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  -derivedDataPath /tmp/KnitNoteMacYarnLayout-Final-iOS \
  CODE_SIGNING_ALLOWED=NO clean build

xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=macOS' \
  -configuration Debug \
  -derivedDataPath /tmp/KnitNoteMacYarnLayout-Final-Mac \
  CODE_SIGNING_ALLOWED=NO clean build
```

Expected: both builds exit 0. Confirm the Mac artifact exists at the path listed in this task's Interfaces.

- [ ] **Step 3: Inspect Create Yarn on the exact Mac artifact**

Launch the exact Mac artifact and verify at the 620 pt ideal width and 520 pt minimum width:

1. Basic Details, Label Details, Inventory, Storage & Notes, Linked Projects, and Photo are one centered column.
2. Every visible label begins at the same card content edge; no standard field jumps to a right-side column.
3. Needle and hook ranges stay directly below their labels and remain fully visible.
4. Vertical scrolling reaches the Photo section and does not hide toolbar Done/Cancel.
5. Long values do not overlap labels.
6. Tab moves from top to bottom; Return triggers only the currently valid primary action; Escape closes without saving.

- [ ] **Step 4: Inspect Edit Yarn with privacy-safe data**

Create one temporary yarn using typed dummy values only, for example name `Mac QA Yarn`, brand `Test Brand`, series `Test Series`, and no personal photo. Open Edit Yarn and verify:

1. Scan Label appears above common fields.
2. All common groups match Create Yarn's alignment.
3. Linked Projects still opens and returns without altering unrelated links.
4. The Label Photos group appears only when label photos exist.
5. Display Photo actions remain usable.
6. Done saves edits and reopening shows them.

Delete the temporary yarn after verification. Do not select, inspect, copy, or retain private Photos/Finder content.

- [ ] **Step 5: Verify localization and accessibility**

For both Create and Edit:

1. Switch to Traditional Chinese and verify `基本資料`, `庫存`, and `收納與筆記` with no clipping.
2. Switch to English and verify `Basic Details`, `Inventory`, and `Storage & Notes` with no clipping.
3. Increase text size and confirm the single column grows vertically and remains scrollable.
4. Turn on VoiceOver and confirm section headings, field labels, range lower/upper fields, link count, Scan Label, Label Photos, Photo, Cancel, and Done are announced in visual order.

- [ ] **Step 6: Confirm regression boundaries and repository state**

Run:

```bash
git diff --check
git status --short
git rev-parse HEAD
git log -3 --oneline
```

Expected:

- No tracked implementation changes remain after Tasks 1-2 commits.
- `KnitNote 5.xcodeproj/` remains user-owned and untracked.
- Version stays 1.2.1 and build stays 4.
- No merge, push, upload, submission, or release occurred.

Record the exact candidate SHA, test totals, build paths, languages checked, Mac widths checked, and Create/Edit results in the task handoff. Do not call the branch release-ready until any separately required TestFlight or commercial-state matrix is complete.
