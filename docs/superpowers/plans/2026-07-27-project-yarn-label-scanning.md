# KnitNote 1.3 Project Yarn and Label Scanning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** First repair the Mac Settings and Create Project layouts, then show every yarn used by a project immediately before its journal and let users create yarn records by privately scanning one or two label photos with confirmed, structured autofill.

**Architecture:** Repair Mac-only layout constraints without changing the iPhone/iPad UI. Keep `StoredYarn.linkedProjectIDs` as the only relationship source and expose an inverse project query through `JSONProjectStore`. Extend `StoredYarn` with optional normalized label fields and up to two managed label-photo filenames. A pure parser in `KnitNoteCore` converts OCR observations into reviewable candidates; a shared iOS/macOS Vision adapter produces observations, platform image pickers normalize input into App-managed temporary files, and the existing yarn editor remains the only final save path.

**Tech Stack:** Swift 6, SwiftUI, Vision, PhotosUI, AVFoundation/UIKit camera wrapper, Foundation, Swift Testing, XcodeGen

**Approved Design:** `docs/superpowers/specs/2026-07-29-knitnote-1.3-yarn-workflow-design.md`

**Milestones:** Task 0 delivers and reviews the Mac P0 layout repair before yarn work begins. Tasks 4–5 deliver and review the project/yarn relationship milestone. Tasks 1–3 and 6–8 deliver and review the label-scanning milestone. Task 9 is the shared 1.3 release gate. Task numbering follows code dependencies; no milestone authorizes a release by itself.

## Global Constraints

- Deployment targets remain iOS 18.0, macOS 15.0, and watchOS 11.0.
- Complete and accept Task 0 before starting the yarn implementation tasks.
- Mac Settings content is centered with at least 24 pt horizontal margins and a maximum content width of 720 pt.
- Mac Create Project has a 520 pt minimum width, 620 pt ideal width, and 560 pt minimum height; photo actions fall back vertically when horizontal space is insufficient.
- Mac-only layout changes must not alter the existing iPhone/iPad layouts.
- Project detail order is `photo → patterns → notes → counters → used yarn → journal`.
- One project can link multiple yarns and one yarn can link multiple projects.
- Unlinking never deletes a yarn or any yarn photo.
- Completed projects show historical yarn links read-only.
- Scan supports camera and photo library, one image by default and at most two label images.
- New and existing yarn records both support label scanning.
- Keep optimized managed JPEG copies only: strip metadata, longest edge approximately 1600 px, and target approximately 150–400 KB per image without making text unreadable.
- The user can delete a saved label photo without deleting confirmed text fields.
- Settings shows the total storage used by managed yarn-label photos.
- OCR and parsing remain on device; no network lookup, barcode database, generative guessing, analytics, or tracking.
- Uncertain fields remain empty or visibly require confirmation; the user must confirm the editor before save.
- Traditional Chinese and English localization and VoiceOver coverage are required.
- New backup data must remain backward-compatible with archive versions 1–10.
- Preserve user-owned untracked `.superpowers/brainstorm/`, `KnitNote 5.xcodeproj/`, and `KnitNote 6.xcodeproj/`.
- Do not change the release version/build until Tasks 0–9 pass review and the user explicitly authorizes release preparation.

---

### Task 0: Repair Mac Settings and Create Project Layouts

**Files:**
- Modify: `KnitNote/Settings/SettingsView.swift`
- Modify: `KnitNote/Projects/CreateProjectView.swift`
- Modify: `KnitNote/Projects/ProjectPhotoPicker.swift`
- Test: `Tests/KnitNoteCoreTests/MacFormLayoutContractTests.swift`
- Test: `Tests/KnitNoteAppTests/MacFormLayoutSmokeTests.swift`

**Interfaces:**
- Produces: centered Mac Settings content and a resizable, unclipped Create Project form.
- Preserves: current iPhone/iPad Settings and Create Project behavior.

- [ ] **Step 1: Write failing Mac layout contracts**

Add source contracts that require the Mac Settings branch to use at least 24 pt horizontal padding and a 720 pt maximum content width. Require the Mac Create Project branch to declare a 520 pt minimum width, 620 pt ideal width, and 560 pt minimum height. Require the photo action group to use `ViewThatFits` with both horizontal and vertical layouts.

```swift
@Test func macSettingsUsesCenteredBoundedContent() throws {
    let source = try source(named: "SettingsView.swift")
    #expect(source.contains("#if os(macOS)"))
    #expect(source.contains("maxWidth: 720"))
    #expect(source.contains(".padding(.horizontal, 24)"))
}

@Test func macCreateProjectHasUsableMinimumSize() throws {
    let source = try source(named: "CreateProjectView.swift")
    #expect(source.contains("minWidth: 520"))
    #expect(source.contains("idealWidth: 620"))
    #expect(source.contains("minHeight: 560"))
}

@Test func projectPhotoActionsAdaptToNarrowWidth() throws {
    let source = try source(named: "ProjectPhotoPicker.swift")
    #expect(source.contains("ViewThatFits"))
    #expect(source.contains("HStack"))
    #expect(source.contains("VStack"))
}
```

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter MacFormLayoutContractTests`

Run: `xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath .derived-data/mac-form-red CODE_SIGNING_ALLOWED=NO -only-testing:KnitNoteAppTests/MacFormLayoutSmokeTests`

Expected: FAIL because the Mac constraints and adaptive photo-action layout are not implemented.

- [ ] **Step 3: Center and bound Mac Settings**

Use a Mac-only container that fills the available width, centers the form, keeps at least 24 pt horizontal margins, and limits readable content to 720 pt. Preserve the current navigation, controls, localization, and iOS/iPadOS layout code.

- [ ] **Step 4: Make Mac Create Project resizable and complete**

Apply the Mac-only 520/620/560 frame contract. Ensure every localized label, input, validation message, and action remains visible at the minimum window size. Do not add fixed sizing to iPhone or iPad.

- [ ] **Step 5: Adapt the project photo actions**

Use `ViewThatFits` so photo actions remain horizontal when they fit and change to a vertical stack when they do not. Preserve camera/photo availability rules per platform and keep the visual order equal to the keyboard focus order.

- [ ] **Step 6: Run focused tests and cross-platform build checks**

Run: `swift test --filter MacFormLayoutContractTests`

Run: `xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath .derived-data/mac-form-green CODE_SIGNING_ALLOWED=NO -only-testing:KnitNoteAppTests/MacFormLayoutSmokeTests`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath .derived-data/mac-form-ios-regression CODE_SIGNING_ALLOWED=NO build`

Expected: focused tests pass and both Mac tests and iOS build succeed.

- [ ] **Step 7: Perform visual and accessibility acceptance**

On Mac, verify Settings and Create Project in Traditional Chinese and English at minimum, default, and enlarged window sizes. Verify labels do not clip, photo actions adapt, Return/Escape behavior is correct, keyboard focus follows visual order, and VoiceOver reads labels and actions. On iPhone and iPad, verify Settings and Create Project have no visual or interaction regression. Record screenshots and exact commit/device/OS evidence.

- [ ] **Step 8: Commit**

```bash
git add KnitNote/Settings/SettingsView.swift KnitNote/Projects/CreateProjectView.swift KnitNote/Projects/ProjectPhotoPicker.swift Tests/KnitNoteCoreTests/MacFormLayoutContractTests.swift Tests/KnitNoteAppTests/MacFormLayoutSmokeTests.swift
git commit -m "fix: repair Mac project and settings layouts"
```

---

### Task 1: Structured Yarn Label Model and Archive Version 11

**Files:**
- Modify: `Sources/KnitNoteCore/Yarn/StoredYarn.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift:4-55`
- Test: `Tests/KnitNoteCoreTests/StoredYarnLabelFieldsTests.swift`
- Test: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Produces: `YarnMetricRange`, optional normalized yarn fields, and `labelPhotoFilenames`.
- Consumes: old `StoredYarn` JSON with none of the new keys.

- [ ] **Step 1: Write failing model tests**

```swift
@Test func oldYarnDecodesWithEmptyLabelDetails() throws {
    let yarn = try JSONDecoder().decode(StoredYarn.self, from: legacyYarnJSON)
    #expect(yarn.ballWeightGrams == nil)
    #expect(yarn.lengthMeters == nil)
    #expect(yarn.fiberContent == nil)
    #expect(yarn.recommendedNeedleMM == nil)
    #expect(yarn.recommendedHookMM == nil)
    #expect(yarn.labelPhotoFilenames.isEmpty)
}

@Test func metricRangeRejectsNegativeOrDescendingValues() {
    #expect(throws: YarnValidationError.invalidMetricRange) { try YarnMetricRange(lower: 5, upper: 4) }
    #expect(throws: YarnValidationError.invalidMetricRange) { try YarnMetricRange(lower: -1, upper: 2) }
}
```

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter StoredYarnLabelFieldsTests`

Expected: FAIL because the fields and range are missing.

- [ ] **Step 3: Add normalized model types**

```swift
public struct YarnMetricRange: Codable, Equatable, Sendable {
    public let lower: Decimal
    public let upper: Decimal

    public init(lower: Decimal, upper: Decimal) throws {
        guard lower >= 0, upper >= lower else { throw YarnValidationError.invalidMetricRange }
        self.lower = lower
        self.upper = upper
    }
}
```

Add optional `ballWeightGrams`, `lengthMeters`, `fiberContent`, `recommendedNeedleMM`, `recommendedHookMM`, and `[String] labelPhotoFilenames`. Decode absent keys as nil/empty, normalize blank fiber content to nil, reject negative weight/length, reject more than two label filenames, and require every filename to satisfy the managed label-photo naming policy.

- [ ] **Step 4: Add one atomic detail updater**

```swift
public mutating func updateLabelDetails(
    ballWeightGrams: Decimal?,
    lengthMeters: Decimal?,
    fiberContent: String?,
    recommendedNeedleMM: YarnMetricRange?,
    recommendedHookMM: YarnMetricRange?,
    now: Date = .now
) throws
```

Add internal `setLabelPhotoFilenames(_:)` that accepts at most two already-validated managed filenames.

- [ ] **Step 5: Raise archive version**

Set `ProjectArchive.currentVersion = 11`; preserve minimum version 1 and decode versions 1–10 through optional-field defaults.

- [ ] **Step 6: Run model/store tests**

Run: `swift test --filter StoredYarn`

Run: `swift test --filter JSONProjectStoreTests`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/KnitNoteCore/Yarn/StoredYarn.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests
git commit -m "feat: add structured yarn label fields"
```

### Task 2: Pure OCR Candidate and Field Parser

**Files:**
- Create: `Sources/KnitNoteCore/Yarn/YarnLabelObservation.swift`
- Create: `Sources/KnitNoteCore/Yarn/YarnLabelFieldParser.swift`
- Test: `Tests/KnitNoteCoreTests/YarnLabelFieldParserTests.swift`

**Interfaces:**
- Produces: `YarnLabelObservation`, `YarnLabelField`, `YarnLabelCandidate`, `YarnLabelParseResult`, and `YarnLabelFieldParser.parse(_:)`.
- Consumes: OCR text, confidence, normalized bounding box, and source image index; no Vision dependency in core.

- [ ] **Step 1: Write failing parser fixtures**

```swift
@Test func parsesEnglishMetricLabel() {
    let result = parser.parse(observations("""
    DROPS BELLE
    Colour 12
    Dye lot 991
    50 g / 120 m
    53% Cotton 33% Viscose 14% Linen
    Needles 4 mm
    """))
    #expect(result.best(.brand)?.text == "DROPS")
    #expect(result.best(.series)?.text == "BELLE")
    #expect(result.best(.colorCode)?.text == "12")
    #expect(result.best(.dyeLot)?.text == "991")
    #expect(result.best(.ballWeightGrams)?.decimalValue == 50)
    #expect(result.best(.lengthMeters)?.decimalValue == 120)
}

@Test func conflictingSidesRequireConfirmation() {
    let result = parser.parse([
        .init(text: "Color 12", confidence: 0.95, sourceImageIndex: 0),
        .init(text: "Color 13", confidence: 0.96, sourceImageIndex: 1)
    ])
    #expect(result.candidates(for: .colorCode).count == 2)
    #expect(result.fieldsRequiringConfirmation.contains(.colorCode))
}
```

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter YarnLabelFieldParserTests`

Expected: FAIL because parser types are missing.

- [ ] **Step 3: Implement candidate types**

```swift
public enum YarnLabelField: String, CaseIterable, Sendable {
    case brand, series, color, colorCode, dyeLot
    case ballWeightGrams, lengthMeters, fiberContent
    case recommendedNeedleMM, recommendedHookMM
}

public struct YarnLabelCandidate: Equatable, Sendable {
    public let field: YarnLabelField
    public let text: String
    public let decimalValue: Decimal?
    public let confidence: Float
    public let sourceImageIndex: Int
}
```

- [ ] **Step 4: Implement deterministic parsing rules**

Recognize English and Traditional Chinese headings (`Color/Colour/色名/色號`, `Lot/Dye Lot/染缸號`, `Needle/針`, `Hook/鉤針`), metric/imperial weight and length, percentage fiber lines, and size ranges. Convert ounces to grams, yards to meters, and inches only when explicitly attached to the matching unit. Never infer absent fields. Mark equal normalized candidates as one; mark differing high-confidence values from either side as requiring confirmation.

- [ ] **Step 5: Add malformed and mixed-language cases**

Test empty OCR, low confidence, `50 g / 120 m`, `1.75 oz / 131 yds`, decimal commas, range `3.5–4 mm`, mixed Chinese/English, percentages not totaling 100, unrelated numbers, and more than two source indices. Invalid observations are ignored rather than crashing.

- [ ] **Step 6: Run parser tests**

Run: `swift test --filter YarnLabelFieldParserTests`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/KnitNoteCore/Yarn/YarnLabelObservation.swift Sources/KnitNoteCore/Yarn/YarnLabelFieldParser.swift Tests/KnitNoteCoreTests/YarnLabelFieldParserTests.swift
git commit -m "feat: parse yarn label text on device"
```

### Task 3: Managed Label Photo Service

**Files:**
- Create: `Sources/KnitNoteCore/Yarn/YarnLabelPhotoFileService.swift`
- Test: `Tests/KnitNoteCoreTests/YarnLabelPhotoFileServiceTests.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift:438-520`

**Interfaces:**
- Produces: `YarnLabelPhotoFileService.prepare(data:yarnID:ordinal:)`, atomic publish/rollback, `url(filename:)`, `totalStorageBytes()`, and filename validation.
- Consumes: JPEG/HEIC/PNG bytes, yarn ID, ordinal 1 or 2.

- [ ] **Step 1: Write failing security and transaction tests**

```swift
@Test func filenamesAreOwnedByYarnAndOrdinal() throws {
    let prepared = try service.prepare(data: fixtureJPEG, yarnID: yarnID, ordinal: 1)
    #expect(prepared.filename.hasPrefix("\(yarnID.uuidString)-label-1-"))
}

@Test func thirdPhotoIsRejected() {
    #expect(throws: YarnLabelPhotoFileError.invalidOrdinal) {
        try service.prepare(data: fixtureJPEG, yarnID: yarnID, ordinal: 3)
    }
}

@Test func normalizedPhotoIsJPEGWithinDimensionAndStoragePolicy() throws {
    let prepared = try service.prepare(data: oversizedFixture, yarnID: yarnID, ordinal: 1)
    let properties = try fixtureInspector.properties(of: prepared.url)
    #expect(properties.format == .jpeg)
    #expect(max(properties.width, properties.height) <= 1_600)
    #expect(properties.metadataKeys.isEmpty)
}

@Test func storageUsageCountsOnlyManagedRegularFiles() throws {
    try fixtureWriter.installManagedJPEG(bytes: 240_000, in: labelDirectory)
    try fixtureWriter.installManagedJPEG(bytes: 180_000, in: labelDirectory)
    #expect(try service.totalStorageBytes() == 420_000)
}
```

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter YarnLabelPhotoFileServiceTests`

Expected: FAIL because service is missing.

- [ ] **Step 3: Implement isolated label storage**

Use `YarnLabelPhotos/` separate from display `YarnPhotos/`. Validate regular files and decoded image bounds, reject symlinks and path traversal, strip metadata, orient the pixels, resize proportionally until the longest edge is at most 1600 px, and encode a managed JPEG. Start near 0.78 quality and reduce quality in bounded steps only when needed; target roughly 150–400 KB while prioritizing readable label text. Enforce a hard decoded-pixel and encoded-byte ceiling before publication. Use unique filenames containing yarn ID and ordinal.

- [ ] **Step 4: Implement prepare/publish/rollback**

Prepared files live under a validated transaction directory. Archive persistence occurs between prepare and publish; failure removes candidates and leaves old photos. Successful replacement removes old managed photos only after the new archive is durable.

Implement `totalStorageBytes()` by enumerating only validated regular managed files directly inside `YarnLabelPhotos/`. Ignore transaction directories, symlinks, and unknown filenames; surface enumeration failure rather than reporting a misleading zero.

- [ ] **Step 5: Run service tests**

Run: `swift test --filter YarnLabelPhotoFileServiceTests`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/KnitNoteCore/Yarn/YarnLabelPhotoFileService.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/YarnLabelPhotoFileServiceTests.swift
git commit -m "feat: store yarn label photos safely"
```

### Task 4: Store Queries, Atomic Yarn Save, and Relationship Rules

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift:1428-1515`
- Test: `Tests/KnitNoteCoreTests/ProjectYarnLinkTests.swift`
- Test: `Tests/KnitNoteCoreTests/JSONProjectStoreYarnLabelTests.swift`

**Interfaces:**
- Produces: `yarns(linkedTo:)`, `setProjectYarns(projectID:yarnIDs:)`, `YarnLabelPhotoChange`, and atomic add/update overloads.
- Consumes: existing `StoredYarn.linkedProjectIDs` as the single relation source.

- [ ] **Step 1: Write failing inverse-query/link tests**

```swift
@Test func projectReturnsEveryLinkedYarnInLibraryOrder() throws {
    try store.setProjectYarns(projectID: project.id, yarnIDs: [first.id, third.id])
    #expect(store.yarns(linkedTo: project.id).map(\.id) == [first.id, third.id])
}

@Test func unlinkDoesNotDeleteYarn() throws {
    try store.setProjectYarns(projectID: project.id, yarnIDs: [])
    #expect(store.yarn(id: first.id) != nil)
}

@Test func completedProjectRejectsLinkChanges() throws {
    try store.markCompleted(projectID: project.id)
    #expect(throws: ProjectStoreError.projectCompleted) {
        try store.setProjectYarns(projectID: project.id, yarnIDs: [first.id])
    }
}
```

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter ProjectYarnLinkTests`

Expected: FAIL because APIs/error are missing.

- [ ] **Step 3: Implement inverse query and transactional relationship update**

```swift
public func yarns(linkedTo projectID: UUID) -> [StoredYarn] {
    yarns.filter { $0.linkedProjectIDs.contains(projectID) }
}

public func setProjectYarns(projectID: UUID, yarnIDs: Set<UUID>) throws
```

Validate project exists, is not completed, and every yarn ID exists before staging any change. Update every yarn’s set in one staged array and persist once. Empty set unlinks all. Preserve library order.

- [ ] **Step 4: Write failing atomic label-photo save tests**

Cover adding with one/two photos, replacing one side, removing one side, archive failure rollback, corrupt candidate rejection, and orphan cleanup after yarn deletion.

- [ ] **Step 5: Implement photo change API**

```swift
public enum YarnLabelPhotoChange: Sendable {
    case unchanged
    case replace(first: Data?, second: Data?)
    case removeAll
}

public func addYarn(_ yarn: StoredYarn, photoData: Data?, labelPhotos: [Data]) throws
public func updateYarn(_ yarn: StoredYarn, photoChange: YarnPhotoChange, labelPhotoChange: YarnLabelPhotoChange) throws
```

Require `labelPhotos.count <= 2`; coordinate label and display photo transactions with archive persistence so either all model references become durable or none do.

- [ ] **Step 6: Run relationship and persistence tests**

Run: `swift test --filter ProjectYarnLinkTests`

Run: `swift test --filter JSONProjectStoreYarnLabelTests`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/ProjectYarnLinkTests.swift Tests/KnitNoteCoreTests/JSONProjectStoreYarnLabelTests.swift
git commit -m "feat: link project yarn and save label photos"
```

### Task 5: Project “Used Yarn” Section

**Files:**
- Create: `KnitNote/Projects/ProjectYarnSection.swift`
- Create: `KnitNote/Projects/ChooseProjectYarnsView.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift:84-110`
- Modify: `KnitNote/Yarn/YarnEditorFields.swift:120-145`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Test: `Tests/KnitNoteCoreTests/ProjectYarnViewContractTests.swift`
- Test: `Tests/KnitNoteCoreTests/ProjectDetailLayoutContractTests.swift`

**Interfaces:**
- Consumes: `store.yarns(linkedTo:)` and `setProjectYarns(projectID:yarnIDs:)`.
- Produces: compact yarn rows, selection sheet, and read-only completed presentation.

- [ ] **Step 1: Write failing layout contract**

Assert source order places `ProjectYarnSection` after `CounterSelectorGrid` and before `ProjectJournalSection`; assert completed projects pass `isEditable: false`. Assert the existing yarn editor still exposes project selection, saves through the same `linkedProjectIDs`, and refuses completed-project relationship changes.

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter ProjectYarnViewContractTests`

Expected: FAIL because the section is missing.

- [ ] **Step 3: Implement compact section**

For no links, show only localized “Add Used Yarn” when editable and a concise empty history label when completed. For each yarn show optional photo, `name`, available `brand/series`, and available `color/colorCode`; omit blank lines. Row navigation opens `YarnDetailView`.

- [ ] **Step 4: Implement multi-select linking**

`ChooseProjectYarnsView` receives the current set, toggles existing library yarns, and calls `setProjectYarns` only on Done. Cancel makes no changes. An unlink confirmation states that the yarn remains in the library.

Keep the yarn-side project picker as the second editing entry point. Before save, intersect selected IDs with existing projects and restore links for completed projects to their original values. The Store remains authoritative and rejects any attempt to add or remove a completed-project link, so both UI entry points use one relationship model and one persistence rule.

- [ ] **Step 5: Add Traditional Chinese/English and VoiceOver**

VoiceOver combines yarn name, brand/series, color/code, and linked status. Color is not the only populated indicator. Dynamic type rows wrap vertically.

- [ ] **Step 6: Run view and store tests**

Run: `swift test --filter ProjectYarn`

Run: `swift test --filter ProjectDetailLayoutContractTests`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add KnitNote/Projects/ProjectYarnSection.swift KnitNote/Projects/ChooseProjectYarnsView.swift KnitNote/Projects/ProjectDetailView.swift KnitNote/Yarn/YarnEditorFields.swift KnitNote/Localization/Localizable.xcstrings Tests/KnitNoteCoreTests
git commit -m "feat: show used yarn in projects"
```

### Task 6: Vision OCR Adapter and Scan Session

**Files:**
- Create: `Sources/KnitNoteCore/Yarn/YarnLabelRecognitionService.swift`
- Create: `Sources/KnitNoteCore/Yarn/YarnLabelScanSession.swift`
- Create: `KnitNote/Yarn/VisionYarnLabelRecognitionService.swift`
- Test: `Tests/KnitNoteCoreTests/YarnLabelScanSessionTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces: async `recognize(imageData:sourceImageIndex:)`, cancellable `YarnLabelScanSession`, and parser-ready observations.
- Consumes: `YarnLabelFieldParser`.

- [ ] **Step 1: Write failing session tests with fake recognition**

```swift
@Test func oneImageProducesDraftCandidates() async throws {
    let session = YarnLabelScanSession(recognizer: fake(["Colour 12", "50 g / 120 m"]), parser: .init())
    let result = try await session.scan([fixtureData])
    #expect(result.best(.colorCode)?.text == "12")
}

@Test func thirdImageIsRejectedBeforeRecognition() async {
    await #expect(throws: YarnLabelScanError.tooManyImages) {
        try await session.scan([data, data, data])
    }
}
```

- [ ] **Step 2: Implement protocol/session and pass fake tests**

```swift
protocol YarnLabelRecognitionService: Sendable {
    func recognize(imageData: Data, sourceImageIndex: Int) async throws -> [YarnLabelObservation]
}
```

Session accepts one or two images, runs recognition off the main actor, preserves source indices, checks cancellation, and passes combined observations to the parser.

- [ ] **Step 3: Implement shared iOS/macOS Vision adapter**

Use `VNRecognizeTextRequest` with `.accurate`, language correction, and candidate confidence. At runtime query supported recognition languages on iOS and macOS, prioritize `zh-Hant` and `en-US`, and safely fall back to the available list instead of failing on an unsupported language. Convert bounding boxes to the core normalized representation. Invalid image data returns `.invalidImage`; no observations returns a valid empty parse result.

- [ ] **Step 4: Run session tests and iOS/macOS compiles**

Run: `swift test --filter YarnLabelScanSessionTests`

Run: `xcodegen generate && xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath .derived-data/yarn-vision CODE_SIGNING_ALLOWED=NO build`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=macOS' -derivedDataPath .derived-data/yarn-vision-mac CODE_SIGNING_ALLOWED=NO build`

Expected: PASS and both builds report `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/KnitNoteCore/Yarn/YarnLabelRecognitionService.swift Sources/KnitNoteCore/Yarn/YarnLabelScanSession.swift KnitNote/Yarn/VisionYarnLabelRecognitionService.swift Tests/KnitNoteCoreTests/YarnLabelScanSessionTests.swift project.yml KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: recognize yarn labels with vision"
```

### Task 7: Scan Entry, Camera/Photo Selection, and Confirmed Editor Autofill

**Files:**
- Create: `KnitNote/Yarn/CreateYarnEntryView.swift`
- Create: `KnitNote/Yarn/YarnLabelImagePicker.swift`
- Create: `KnitNote/Yarn/YarnLabelScanView.swift`
- Create: `KnitNote/Yarn/YarnLabelCandidateReviewView.swift`
- Create: `KnitNote/Yarn/YarnLabelScanLauncher.swift`
- Create: `KnitNote/Yarn/MacYarnLabelFileImporter.swift`
- Create: `Sources/KnitNoteCore/Yarn/YarnLabelDraftSeed.swift`
- Modify: `KnitNote/Yarn/YarnLibraryView.swift:55-66`
- Modify: `KnitNote/Yarn/CreateYarnView.swift`
- Modify: `KnitNote/Yarn/EditYarnView.swift`
- Modify: `KnitNote/Yarn/YarnEditorFields.swift:37-142`
- Modify: `KnitNote/Info.plist`
- Modify: `project.yml`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Test: `Tests/KnitNoteCoreTests/YarnLabelScanViewContractTests.swift`
- Test: `Tests/KnitNoteCoreTests/YarnLabelDraftSeedTests.swift`

**Interfaces:**
- Consumes: scan session/result and atomic store save.
- Produces: “Scan Yarn Label” / “Add Manually” entry choice and editable confirmed draft.

- [ ] **Step 1: Write failing draft mapping tests**

```swift
@Test func acceptedCandidatesProduceDraftSeedWithoutSaving() {
    let seed = YarnLabelDraftSeed(scanResult: fixtureResult, accepted: [.brand, .series, .colorCode])
    #expect(seed.brand == "DROPS")
    #expect(seed.series == "BELLE")
    #expect(seed.colorCode == "12")
}

@Test func applyingScanToExistingYarnChangesDraftOnly() throws {
    var draft = YarnEditorDraft(yarn: existingYarn, locale: enUS)
    let seed = YarnLabelDraftSeed(scanResult: fixtureResult, accepted: [.colorCode, .dyeLot])
    draft.apply(seed)
    #expect(draft.colorCode == "12")
    #expect(draft.dyeLot == "991")
    #expect(store.yarn(id: existingYarn.id) == existingYarn)
}
```

- [ ] **Step 2: Implement entry chooser**

The yarn-library plus button presents two large, simple actions: scan label or add manually. Manual path opens the unchanged editor. Scan path offers camera and photo library. `EditYarnView` exposes the same reusable `YarnLabelScanLauncher`, initialized with any existing first/second label images. On macOS, hide camera and offer Photos or Finder selection while preserving manual entry.

`MacYarnLabelFileImporter` accepts JPEG, PNG, and HEIC. It starts security-scoped access only long enough to copy the selected item into an App-controlled transient area, then stops access. Do not persist an external file path or security-scoped bookmark. Cancellation, an inaccessible file, an iCloud item that is not downloaded, and an unsupported format each produce a localized, recoverable state without changing the yarn draft.

- [ ] **Step 3: Implement one/two-image scan flow**

After the first image, run OCR and show result. Display “Scan Other Side” only while image count is one. Never accept a third. Allow replacing/removing either selected image before final save.

- [ ] **Step 4: Implement candidate review**

Preselect one unique high-confidence candidate per field. Low-confidence/ambiguous fields show “Needs confirmation” text and require an explicit choice or remain empty. Conflicting candidates show both source-side values. Continue creates the tested core `YarnLabelDraftSeed`. The create flow initializes `YarnEditorDraft(seed:)`; the edit flow calls `draft.apply(seed)` without clearing existing fields that the user did not accept from the scan. Neither path saves before the user taps Done.

- [ ] **Step 5: Extend editor fields and save path**

Add weight grams, length meters, fiber content, needle range, and hook range. Use locale-aware decimal input and validation. If series is present and name is blank, propose series as name but keep it editable. Create and edit Done both call the atomic store overload with zero, one, or two label photos. Removing a photo submits a photo change only; it never clears already confirmed label fields.

- [ ] **Step 6: Add permissions and failure UI**

Add localized camera purpose copy covering projects, journals, and yarn labels. Permission denial offers Settings and Photo Library. Empty OCR proceeds to blank editor with retained label photo. Cancellation cleans transient state.

- [ ] **Step 7: Run UI contracts and iOS/macOS builds**

Run: `swift test --filter YarnLabel`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath .derived-data/yarn-scan-ui CODE_SIGNING_ALLOWED=NO build`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=macOS' -derivedDataPath .derived-data/yarn-scan-ui-mac CODE_SIGNING_ALLOWED=NO build`

Expected: PASS and both builds report `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
git add Sources/KnitNoteCore/Yarn/YarnLabelDraftSeed.swift KnitNote/Yarn KnitNote/Info.plist KnitNote/Localization/Localizable.xcstrings project.yml KnitNote.xcodeproj Tests/KnitNoteCoreTests
git commit -m "feat: add confirmed yarn label scanning flow"
```

### Task 8: Yarn Detail/Edit Label Photos, Backup, and Restore

**Files:**
- Modify: `KnitNote/Yarn/YarnDetailView.swift`
- Modify: `KnitNote/Yarn/EditYarnView.swift`
- Create: `KnitNote/Yarn/YarnLabelPhotoGallery.swift`
- Create: `KnitNote/Settings/YarnLabelStorageRow.swift`
- Modify: `KnitNote/Settings/SettingsView.swift`
- Modify: `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`
- Modify: `Sources/KnitNoteCore/Backup/KnitNoteBackupManifest.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift:1565-2020`
- Test: `Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift`
- Test: `Tests/KnitNoteCoreTests/YarnLabelPhotoViewContractTests.swift`
- Test: `Tests/KnitNoteCoreTests/YarnLabelStorageContractTests.swift`

**Interfaces:**
- Consumes: managed label-photo filenames and new structured fields.
- Produces: inspect/replace/remove label images, visible storage usage, and safe version-11 backup/restore.

- [ ] **Step 1: Write failing backup tests**

Build a version-11 archive with two label images and assert export contains both under `YarnLabelPhotos/`, manifest preview remains valid, restore reproduces bytes and fields, and a version-10 backup restores with empty new fields.

- [ ] **Step 2: Extend backup validation**

Include only referenced managed label photos. Enforce existing per-file and total package limits, reject symlinks/path traversal/duplicate paths/invalid images, and stage restore atomically with archive validation before replacing live data.

On Mac, export and import through user-selected Downloads or iCloud Drive locations using security-scoped access only for the active operation. Copy the package into an App-controlled staging directory before validation, stop external access after the copy, and never retain an external path or bookmark. A cloud item that is not downloaded must produce a recoverable error without changing live data.

- [ ] **Step 3: Reconcile and delete orphan label photos**

At successful load/recovery remove only unreferenced managed files inside the validated label directory. Yarn deletion removes its label photos after archive persistence; failures leave the last valid state recoverable.

- [ ] **Step 4: Add detail and edit presentation**

Yarn detail shows structured label information only when present and a horizontally scrollable, VoiceOver-labeled gallery of up to two originals. Edit permits view, replace, or remove, and submits one atomic change.

- [ ] **Step 5: Add storage usage to Settings**

`YarnLabelStorageRow` asynchronously reads `totalStorageBytes()` through the store/service boundary and formats it with `ByteCountFormatter`. Show localized “Yarn label photos” plus the formatted value. While loading, show a progress indicator; on enumeration failure, show localized “Unavailable” rather than `0 KB`. Refresh after Settings appears and after a yarn label-photo mutation notification.

Add contract tests that assert Settings includes the row, uses `ByteCountFormatter`, exposes a VoiceOver value, and distinguishes loading/error/loaded states.

- [ ] **Step 6: Run backup, view, and storage tests**

Run: `swift test --filter KnitNoteBackupServiceTests`

Run: `swift test --filter YarnLabelPhoto`

Run: `swift test --filter YarnLabelStorage`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add KnitNote/Yarn KnitNote/Settings Sources/KnitNoteCore/Backup Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests
git commit -m "feat: back up yarn label details and photos"
```

### Task 9: Localization, Privacy, Full Verification, and Physical Acceptance

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `KnitNote/Localization/InfoPlist.xcstrings`
- Modify: `KnitNote/PrivacyInfo.xcprivacy` only if required by the final API audit
- Modify: `AppStore/AppStoreSubmission.md`
- Test: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Test: `Tests/KnitNoteCoreTests/PrivacyManifestContractTests.swift`
- Test: `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`

**Interfaces:**
- Consumes: all Tasks 1–8.
- Produces: release-ready localized behavior and current verification evidence.

- [ ] **Step 1: Complete localization/accessibility contracts**

Assert every new key exists in `en` and `zh-Hant`, camera purpose text mentions yarn labels, conflict/low-confidence states have non-color text, and scan/link controls have VoiceOver labels and hints.

- [ ] **Step 2: Audit privacy declarations**

Confirm Vision processing is local, no network/analytics SDK was added, selected photos and camera frames are user-provided data, and required-reason APIs remain accurately declared. Change the privacy manifest only when the API audit proves a declaration is required.

- [ ] **Step 3: Run complete automated tests**

Run: `swift test`

Run: `xcodegen generate`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -configuration Release -derivedDataPath .derived-data/yarn-release-ios CODE_SIGNING_ALLOWED=NO build`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=macOS' -configuration Release -derivedDataPath .derived-data/yarn-release-mac CODE_SIGNING_ALLOWED=NO build`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -destination 'generic/platform=watchOS' -configuration Release -derivedDataPath .derived-data/yarn-release-watch CODE_SIGNING_ALLOWED=NO build`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteShare -destination 'generic/platform=iOS' -configuration Release -derivedDataPath .derived-data/yarn-release-share CODE_SIGNING_ALLOWED=NO build`

Run: `bash AppStore/Verification/release_audit.sh --static-only`

Expected: all tests pass; iOS, macOS, watchOS, and Share Extension Release builds succeed; metadata and static release audit pass.

- [ ] **Step 4: Perform physical iPhone/iPad acceptance**

Verify camera scan, photo-library scan, Traditional Chinese label, English label, mixed label, blurred/no-text image, second side, conflict choice, cancel/retry, optimized saved label copies, label-photo storage usage, project with multiple yarns, one yarn in multiple projects, unlink without deletion, completed-project read-only state, backup/restore, Dynamic Type, and VoiceOver. Record exact commit SHA, version, build, device, OS, and pass/fail evidence.

Use the same candidate through TestFlight to re-run the commercial regression matrix: new seven-day trial user, expired trial, verified Lifetime Unlock owner, legacy paid owner, StoreKit temporarily unavailable, reinstall/restore purchase, Share Extension import, paired Watch entitlement sync, and Watch reconnection. A green local StoreKit configuration run is not accepted as TestFlight evidence.

- [ ] **Step 5: Perform physical Mac acceptance**

Using the same immutable candidate, verify:

- Settings and Create Project in Traditional Chinese and English at minimum, default, and enlarged window sizes.
- Complete labels and aligned controls at the 520 pt Create Project minimum width.
- Horizontal-to-vertical photo-action fallback, keyboard focus order, Return/Escape behavior, and VoiceOver.
- New and existing yarn flows using Photos and Finder JPEG, PNG, and HEIC input.
- Finder cancellation, denied/inaccessible files, iCloud items not downloaded, unsupported formats, and retry.
- Traditional Chinese, English, mixed, blurred, and no-text OCR with user confirmation before save.
- Backup export/import through Downloads and iCloud Drive, including an unavailable cloud item and no partial live-data replacement.
- Project/yarn linking, unlinking, completed-project read-only history, saved label images, and persistence after relaunch.

Record exact commit SHA, version, build, Mac model, macOS version, window-size matrix, and pass/fail evidence. Mac Release compilation or automated tests do not replace this acceptance.

- [ ] **Step 6: Run diff and review gates**

Run: `git diff --check main...HEAD`

Run: `git status --short && git diff --stat main...HEAD`

Run: `git rev-parse --show-toplevel && git branch --show-current && git rev-parse HEAD && git rev-parse origin/main`

Confirm the intended repository/worktree, expected feature branch, no unrelated tracked changes, and preservation of user-owned untracked paths. Use `superpowers:requesting-code-review` for specification compliance and then code quality. Fix confirmed findings with tests and repeat Steps 3–6.

- [ ] **Step 7: Commit verification documentation**

```bash
git add KnitNote/Localization KnitNote/PrivacyInfo.xcprivacy AppStore/AppStoreSubmission.md Tests/KnitNoteCoreTests
git commit -m "test: verify yarn scanning release"
```

- [ ] **Step 8: Stop for integration choice**

Use `superpowers:finishing-a-development-branch`. Do not merge, push, create a PR, alter version/build, archive, upload, change App Store price/IAP/metadata, submit, or release without explicit user authorization.

After an authorized merge, create one immutable release-candidate commit and repeat Steps 3–6 against that exact commit. Before submission, verify the selected App Store Connect build, free App price, non-consumable Lifetime Unlock IAP, localized metadata, screenshots, and review notes all describe the same candidate. After submission, record archive path, commit SHA, version/build, selected build, IAP, price, storefront state, and submission ID; push/tag the submitted source so it can be reconstructed.
