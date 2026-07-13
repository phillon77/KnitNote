# Project Photos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one persistent optional photo to each knitting project, with Photos and camera input on iPhone/iPad, image selection on Mac, and reliable previews throughout the app.

**Architecture:** Store only an optional photo filename in `StoredProject`; keep normalized JPEG files in a dedicated application-support directory through `ProjectPhotoFileService`. Stage UI image changes until Save, let `JSONProjectStore` coordinate model persistence and file cleanup, and isolate platform pickers behind SwiftUI views.

**Tech Stack:** Swift 6, SwiftUI, PhotosUI, UIKit camera picker, ImageIO/CoreGraphics, Swift Testing, XcodeGen.

## Global Constraints

- Project name remains the only required creation field.
- iPhone and iPad support Photos and camera; Mac supports image selection without camera capture.
- Existing version-5 archives load without migration or data loss.
- Each project stores at most one normalized JPEG with a 1600-pixel maximum long edge.
- Failed photo operations preserve the previously committed project and photo.
- Existing row, note, pattern, highlight, markup, and page-state behavior must remain unchanged.
- All new user-facing text supports Traditional Chinese and English.

---

### Task 1: Backward-Compatible Project Photo Metadata

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/StoredProject.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Produces: `StoredProject.photoFilename: String?` and `setPhotoFilename(_:now:)`.

- [ ] **Step 1: Write the failing compatibility tests**

Add tests that construct a project, verify `photoFilename == nil`, set `"<uuid>.jpg"`, round-trip through `JSONEncoder`/`JSONDecoder`, and decode a hand-built legacy JSON object with no `photoFilename`.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build --filter JSONProjectStoreTests
```

Expected: compilation fails because `photoFilename` and `setPhotoFilename` do not exist.

- [ ] **Step 3: Implement optional metadata**

Add `public private(set) var photoFilename: String?`, initialize it to `nil`, include it in `CodingKeys`, decode with `decodeIfPresent`, and add:

```swift
public mutating func setPhotoFilename(_ filename: String?, now: Date = .now) {
    photoFilename = filename
    updatedAt = now
}
```

- [ ] **Step 4: Run the focused and full tests**

Expected: compatibility tests and all existing tests pass.

- [ ] **Step 5: Commit**

Commit as `Add optional project photo metadata`.

### Task 2: Normalized Photo File Service

**Files:**
- Create: `Sources/KnitNoteCore/Projects/ProjectPhotoFileService.swift`
- Create: `Tests/KnitNoteCoreTests/ProjectPhotoFileServiceTests.swift`

**Interfaces:**
- Produces: `ProjectPhotoFileService`, `ProjectPhotoFileError.invalidImage`, `save(data:projectID:) -> String`, `url(filename:) -> URL`, and `delete(filename:)`.

- [ ] **Step 1: Write failing service tests**

Use ImageIO/CoreGraphics in the test helper to create a 2400×1200 JPEG. Verify saving returns `"<project-id>.jpg"`, the stored image has a maximum dimension of 1600, invalid bytes throw `.invalidImage`, a second save replaces the file, and delete is idempotent.

- [ ] **Step 2: Run the focused tests and verify RED**

Expected: compilation fails because `ProjectPhotoFileService` does not exist.

- [ ] **Step 3: Implement minimal normalization and atomic storage**

Decode with `CGImageSourceCreateWithData`, create a thumbnail using `kCGImageSourceThumbnailMaxPixelSize: 1600` and transform handling, encode JPEG at quality `0.86` with `CGImageDestination`, create the photo directory, and atomically write to `<UUID>.jpg`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Expected: all service tests pass and stored dimensions are bounded.

- [ ] **Step 5: Commit**

Commit as `Add project photo file service`.

### Task 3: Transactional Store Operations

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Produces: `ProjectPhotoChange` with `.unchanged`, `.replace(Data)`, `.remove`; `add(name:photoData:)`; `updateProject(id:name:photoChange:)`; `photoURL(for:)`.

- [ ] **Step 1: Write failing store tests**

Create the store with an injectable `ProjectPhotoFileService`. Verify create-with-photo persists filename, replace changes bytes without changing rows/notes, remove clears metadata and file, delete cleans the file, version 6 is written, and invalid replacement leaves the old model/file unchanged.

- [ ] **Step 2: Run tests and verify RED**

Expected: compilation fails because the initializer and photo operations do not exist.

- [ ] **Step 3: Implement create, edit, remove, and cleanup**

Add a photo service dependency based on the archive directory. Stage a copied project array, perform photo writes before archive persistence, commit published projects only after persistence succeeds, and remove superseded files after success. Keep `add(name:)` and `rename(id:to:)` as compatibility wrappers.

- [ ] **Step 4: Run focused and full tests**

Expected: transactional tests pass and all existing state tests remain green.

- [ ] **Step 5: Commit**

Commit as `Persist project photos transactionally`.

### Task 4: Cross-Platform Photo Selection and Editing UI

**Files:**
- Create: `KnitNote/Projects/ProjectPhotoPicker.swift`
- Create: `KnitNote/Projects/CameraCaptureView.swift`
- Create: `KnitNote/Projects/ProjectPhotoEditor.swift`
- Create: `KnitNote/Projects/EditProjectView.swift`
- Modify: `KnitNote/Projects/CreateProjectView.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Delete: `KnitNote/Projects/RenameProjectView.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `ProjectPhotoChange` and store photo APIs.
- Produces: shared photo preview/actions, iOS camera capture, and combined project editing.

- [ ] **Step 1: Add shared staged-photo state**

`ProjectPhotoEditor` displays the staged bytes or existing URL, exposes Choose Photo, conditionally exposes Take Photo on iOS when `UIImagePickerController.isSourceTypeAvailable(.camera)`, and exposes Remove when a photo exists.

- [ ] **Step 2: Add platform pickers**

Use `PhotosPicker` with image-only matching for library selection. Add an iOS-only `UIViewControllerRepresentable` camera wrapper whose coordinator returns JPEG data or cancellation without mutation. Mac receives only the system image picker.

- [ ] **Step 3: Integrate creation and editing**

Keep the creation name validation unchanged and pass optional staged bytes to `add`. Replace the rename sheet with `EditProjectView`, preserve cancel/save behavior, and call `updateProject` once with the staged `ProjectPhotoChange`.

- [ ] **Step 4: Add camera usage metadata**

In `project.yml`, add an iOS SDK-conditioned `INFOPLIST_KEY_NSCameraUsageDescription` explaining that KnitNote uses the camera to add a project photo. Regenerate the project.

- [ ] **Step 5: Build iOS and Mac**

Expected: Mac build succeeds without UIKit references; iPhone/iPad builds expose camera and Photos actions.

- [ ] **Step 6: Commit**

Commit as `Add project photo selection and editing`.

### Task 5: Project Card Preview, Localization, and Acceptance

**Files:**
- Create: `KnitNote/Projects/ProjectPhotoView.swift`
- Modify: `KnitNote/Projects/ProjectCard.swift`
- Modify: `KnitNote/Projects/ProjectsView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`

**Interfaces:**
- Consumes: `store.photoURL(for:)`.
- Produces: resilient square card previews and localized photo controls.

- [ ] **Step 1: Add resilient photo rendering**

Load the local URL using platform image decoding, render it with aspect-fill in a 58-point square continuous rectangle, and fall back to the existing lavender placeholder if the filename is absent, missing, or invalid.

- [ ] **Step 2: Pass photo URLs into cards**

Keep navigation, ordering, swipe deletion, and accessibility behavior unchanged while supplying each card with its resolved local URL.

- [ ] **Step 3: Add Traditional Chinese and English strings**

Add keys for choose photo, take photo, replace photo, remove photo, project photo accessibility, unavailable camera, and invalid photo/save errors. Preserve all existing string-catalog entries.

- [ ] **Step 4: Run complete verification**

Run all Swift tests, Mac build, Watch build, Xcode iPhone run, and Xcode iPad run. Manually verify create, replace, remove, cancel, relaunch persistence, missing-file fallback, camera cancellation, Dynamic Type, and existing pattern reader flows.

- [ ] **Step 5: Commit**

Commit as `Show project photos on watercolor cards`.
