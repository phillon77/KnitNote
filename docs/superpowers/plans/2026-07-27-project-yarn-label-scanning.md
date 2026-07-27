# Project Yarn and Label Scanning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show every yarn used by a project immediately before its journal and let users create yarn records by privately scanning one or two label photos with confirmed, structured autofill.

**Architecture:** Keep `StoredYarn.linkedProjectIDs` as the only relationship source and expose an inverse project query through `JSONProjectStore`. Extend `StoredYarn` with optional normalized label fields and up to two managed label-photo filenames. A pure parser in `KnitNoteCore` converts OCR observations into reviewable candidates; an iOS Vision adapter produces observations, and the existing yarn editor remains the only final save path.

**Tech Stack:** Swift 6, SwiftUI, Vision, PhotosUI, AVFoundation/UIKit camera wrapper, Foundation, Swift Testing, XcodeGen

## Global Constraints

- Deployment targets remain iOS 18.0, macOS 15.0, and watchOS 11.0.
- Project detail order is `photo → patterns → notes → counters → used yarn → journal`.
- One project can link multiple yarns and one yarn can link multiple projects.
- Unlinking never deletes a yarn or any yarn photo.
- Completed projects show historical yarn links read-only.
- Scan supports camera and photo library, one image by default and at most two label images.
- OCR and parsing remain on device; no network lookup, barcode database, generative guessing, analytics, or tracking.
- Uncertain fields remain empty or visibly require confirmation; the user must confirm the editor before save.
- Traditional Chinese and English localization and VoiceOver coverage are required.
- New backup data must remain backward-compatible with archive versions 1–10.
- Preserve user-owned untracked `.superpowers/brainstorm/`, `KnitNote 5.xcodeproj/`, and `KnitNote 6.xcodeproj/`.

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
- Produces: `YarnLabelPhotoFileService.prepare(data:yarnID:ordinal:)`, atomic publish/rollback, `url(filename:)`, and filename validation.
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
```

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter YarnLabelPhotoFileServiceTests`

Expected: FAIL because service is missing.

- [ ] **Step 3: Implement isolated label storage**

Use `YarnLabelPhotos/` separate from display `YarnPhotos/`. Validate regular files and decoded image bounds, reject symlinks and path traversal, strip metadata through normalized re-encoding, cap each normalized image at the existing yarn-photo byte/pixel limits, and use unique filenames containing yarn ID and ordinal.

- [ ] **Step 4: Implement prepare/publish/rollback**

Prepared files live under a validated transaction directory. Archive persistence occurs between prepare and publish; failure removes candidates and leaves old photos. Successful replacement removes old managed photos only after the new archive is durable.

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
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Test: `Tests/KnitNoteCoreTests/ProjectYarnViewContractTests.swift`
- Test: `Tests/KnitNoteCoreTests/ProjectDetailLayoutContractTests.swift`

**Interfaces:**
- Consumes: `store.yarns(linkedTo:)` and `setProjectYarns(projectID:yarnIDs:)`.
- Produces: compact yarn rows, selection sheet, and read-only completed presentation.

- [ ] **Step 1: Write failing layout contract**

Assert source order places `ProjectYarnSection` after `CounterSelectorGrid` and before `ProjectJournalSection`; assert completed projects pass `isEditable: false`.

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter ProjectYarnViewContractTests`

Expected: FAIL because the section is missing.

- [ ] **Step 3: Implement compact section**

For no links, show only localized “Add Used Yarn” when editable and a concise empty history label when completed. For each yarn show optional photo, `name`, available `brand/series`, and available `color/colorCode`; omit blank lines. Row navigation opens `YarnDetailView`.

- [ ] **Step 4: Implement multi-select linking**

`ChooseProjectYarnsView` receives the current set, toggles existing library yarns, and calls `setProjectYarns` only on Done. Cancel makes no changes. An unlink confirmation states that the yarn remains in the library.

- [ ] **Step 5: Add Traditional Chinese/English and VoiceOver**

VoiceOver combines yarn name, brand/series, color/code, and linked status. Color is not the only populated indicator. Dynamic type rows wrap vertically.

- [ ] **Step 6: Run view and store tests**

Run: `swift test --filter ProjectYarn`

Run: `swift test --filter ProjectDetailLayoutContractTests`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add KnitNote/Projects/ProjectYarnSection.swift KnitNote/Projects/ChooseProjectYarnsView.swift KnitNote/Projects/ProjectDetailView.swift KnitNote/Localization/Localizable.xcstrings Tests/KnitNoteCoreTests
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

- [ ] **Step 3: Implement Vision adapter**

Use `VNRecognizeTextRequest` with `.accurate`, language correction, recognition languages `zh-Hant` and `en-US` when supported, and candidate confidence. Convert bounding boxes to the core normalized representation. Invalid image data returns `.invalidImage`; no observations returns a valid empty parse result.

- [ ] **Step 4: Run session tests and iOS compile**

Run: `swift test --filter YarnLabelScanSessionTests`

Run: `xcodegen generate && xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath .derived-data/yarn-vision CODE_SIGNING_ALLOWED=NO build`

Expected: PASS and `BUILD SUCCEEDED`.

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
- Create: `Sources/KnitNoteCore/Yarn/YarnLabelDraftSeed.swift`
- Modify: `KnitNote/Yarn/YarnLibraryView.swift:55-66`
- Modify: `KnitNote/Yarn/CreateYarnView.swift`
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
```

- [ ] **Step 2: Implement entry chooser**

The yarn-library plus button presents two large, simple actions: scan label or add manually. Manual path opens the unchanged editor. Scan path offers camera and photo library. On macOS, hide camera and offer photo-file selection while preserving manual entry.

- [ ] **Step 3: Implement one/two-image scan flow**

After the first image, run OCR and show result. Display “Scan Other Side” only while image count is one. Never accept a third. Allow replacing/removing either selected image before final save.

- [ ] **Step 4: Implement candidate review**

Preselect one unique high-confidence candidate per field. Low-confidence/ambiguous fields show “Needs confirmation” text and require an explicit choice or remain empty. Conflicting candidates show both source-side values. Continue creates the tested core `YarnLabelDraftSeed`, then opens `CreateYarnView` with a `YarnEditorDraft(seed:)` adapter and label image data; it does not save.

- [ ] **Step 5: Extend editor fields and save path**

Add weight grams, length meters, fiber content, needle range, and hook range. Use locale-aware decimal input and validation. If series is present and name is blank, propose series as name but keep it editable. Done calls the atomic store overload with zero, one, or two label photos.

- [ ] **Step 6: Add permissions and failure UI**

Add localized camera purpose copy covering projects, journals, and yarn labels. Permission denial offers Settings and Photo Library. Empty OCR proceeds to blank editor with retained label photo. Cancellation cleans transient state.

- [ ] **Step 7: Run UI contracts and iPhone/iPad builds**

Run: `swift test --filter YarnLabel`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath .derived-data/yarn-scan-ui CODE_SIGNING_ALLOWED=NO build`

Expected: PASS and `BUILD SUCCEEDED`.

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
- Modify: `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`
- Modify: `Sources/KnitNoteCore/Backup/KnitNoteBackupManifest.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift:1565-2020`
- Test: `Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift`
- Test: `Tests/KnitNoteCoreTests/YarnLabelPhotoViewContractTests.swift`

**Interfaces:**
- Consumes: managed label-photo filenames and new structured fields.
- Produces: inspect/replace/remove label images and safe version-11 backup/restore.

- [ ] **Step 1: Write failing backup tests**

Build a version-11 archive with two label images and assert export contains both under `YarnLabelPhotos/`, manifest preview remains valid, restore reproduces bytes and fields, and a version-10 backup restores with empty new fields.

- [ ] **Step 2: Extend backup validation**

Include only referenced managed label photos. Enforce existing per-file and total package limits, reject symlinks/path traversal/duplicate paths/invalid images, and stage restore atomically with archive validation before replacing live data.

- [ ] **Step 3: Reconcile and delete orphan label photos**

At successful load/recovery remove only unreferenced managed files inside the validated label directory. Yarn deletion removes its label photos after archive persistence; failures leave the last valid state recoverable.

- [ ] **Step 4: Add detail and edit presentation**

Yarn detail shows structured label information only when present and a horizontally scrollable, VoiceOver-labeled gallery of up to two originals. Edit permits view, replace, or remove, and submits one atomic change.

- [ ] **Step 5: Run backup and view tests**

Run: `swift test --filter KnitNoteBackupServiceTests`

Run: `swift test --filter YarnLabelPhoto`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add KnitNote/Yarn Sources/KnitNoteCore/Backup Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests
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

Expected: all tests pass and both Release builds succeed.

- [ ] **Step 4: Perform physical iPhone/iPad acceptance**

Verify camera scan, photo-library scan, Traditional Chinese label, English label, mixed label, blurred/no-text image, second side, conflict choice, cancel/retry, saved label originals, project with multiple yarns, one yarn in multiple projects, unlink without deletion, completed-project read-only state, backup/restore, Dynamic Type, and VoiceOver. Record device/OS/build and pass/fail evidence.

- [ ] **Step 5: Run diff and review gates**

Run: `git diff --check main...HEAD`

Run: `git status --short && git diff --stat main...HEAD`

Use `superpowers:requesting-code-review` for specification compliance and then code quality. Fix confirmed findings with tests and repeat Step 3.

- [ ] **Step 6: Commit verification documentation**

```bash
git add KnitNote/Localization KnitNote/PrivacyInfo.xcprivacy AppStore/AppStoreSubmission.md Tests/KnitNoteCoreTests
git commit -m "test: verify yarn scanning release"
```

- [ ] **Step 7: Stop for integration choice**

Use `superpowers:finishing-a-development-branch`. Do not merge, push, create a PR, or submit a release without explicit user authorization.
