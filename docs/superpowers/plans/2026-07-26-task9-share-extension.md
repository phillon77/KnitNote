# Task 9 Pattern File Share Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an iOS-only KnitNote Share Extension that accepts exactly one real PDF, PNG, JPEG, or HEIC file and durably enqueues it in the shared App Group inbox without opening or mutating the main App archive.

**Architecture:** `KnitNoteShare` is a dedicated iOS app-extension target embedded only by the iOS App. A small, platform-neutral Core presentation layer selects exactly one supported pattern file, owns a thread-safe one-shot completion gate, and maps errors; UIKit glue loads the temporary `NSItemProvider` file representation, keeps its callback alive while background validation and atomic enqueue complete, and guards completion with cancellation and timeout. The target links only the extension files and the minimal inbox/file-validation Core graph.

**Tech Stack:** Swift 6, UIKit, SwiftUI, Foundation, UniformTypeIdentifiers, Swift Testing, XcodeGen, iOS 18.

## Global Constraints

- This Task 9 delivery accepts exactly one PDF, PNG, JPEG, or HEIC attachment; ordinary URLs and multiple attachments are rejected.
- App Group is exactly `group.com.phillon.KnitNote`; extension bundle identifier is exactly `com.phillon.KnitNote.share`.
- The extension only calls `PatternInboxFileService.enqueue(... origin: .shareExtension ...)`; it never reads or writes `ProjectArchive`.
- Do not implement Task 10 main-App inbox discovery, processing, notifications, or duplicate cleanup.
- `NSItemProvider` temporary file access, validation, and enqueue stay inside the file-representation completion lifetime and off the main thread.
- All new user-facing copy is exact English and Traditional Chinese and has a readable VoiceOver label.
- The extension is not a source, resource, dependency, or embedded product of macOS or Watch targets.

---

### Task 1: Pure Share Request Contracts

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternShareImportPresentation.swift`
- Create: `Tests/KnitNoteCoreTests/PatternShareImportPresentationTests.swift`

**Interfaces:**
- Produces: `PatternShareImportAttachmentSelector.indexOfSingleSupportedFile(in:)`
- Produces: `PatternShareImportCompletionGate.beginProcessing()`, `finish()`, and `cancel()`
- Produces: `PatternShareImportErrorMessage` and `PatternShareImportErrorMapper`

- [x] Write literal table tests proving PDF, PNG, JPEG, and HEIC are accepted while zero, multiple, and URL-only attachment descriptions are rejected.
- [x] Run `swift test --filter PatternShareImportPresentationTests` and confirm missing production symbols fail compilation.
- [x] Implement exact-one-supported-file selection without importing UIKit.
- [x] Add concurrent tests proving only one callback can claim processing and late callbacks cannot publish after cancel/timeout.
- [x] Implement the `NSLock`-protected one-shot gate.
- [x] Add exhaustive mapping tests for unsupported, multiple, access, timeout, cancellation, empty, oversized, invalid file, App Group, and fallback failures.
- [x] Implement the minimal stable localization-key mapper and rerun the focused suite.

### Task 2: Canonical iOS Extension Target and Entitlements

**Files:**
- Create: `KnitNote/KnitNote-iOS.entitlements`
- Create: `KnitNoteShare/KnitNoteShare.entitlements`
- Create: `KnitNoteShare/Info.plist`
- Create: `KnitNoteShare/PrivacyInfo.xcprivacy`
- Modify: `project.yml`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`
- Create: `Tests/KnitNoteCoreTests/ShareExtensionTargetContractTests.swift`

**Interfaces:**
- Produces: `KnitNoteShare.appex`, bundle identifier `com.phillon.KnitNote.share`
- Consumes: App Group `group.com.phillon.KnitNote`

- [x] Write executable plist/entitlement tests for matching App Group values and a strict activation predicate accepting exactly one PDF, PNG, JPEG, or HEIC attachment.
- [x] Write PBX structure and source-membership tests for iOS-only embedding and absence from Watch.
- [x] Run the focused target tests and confirm failures because the target and artifacts are absent.
- [x] Add XcodeGen configuration with iOS-only App embedding and SDK-conditional iOS App entitlements; preserve macOS entitlements.
- [x] Limit extension source membership to `KnitNoteShare` and the minimal Core file-validation/inbox graph.
- [x] Create valid plist, entitlement, and privacy artifacts and run `xcodegen generate`.
- [x] Run focused tests and `plutil -lint` until green.

### Task 3: NSItemProvider Loading and Durable Enqueue

**Files:**
- Create: `KnitNoteShare/ShareImportController.swift`
- Create: `KnitNoteShare/ShareViewController.swift`
- Create: `Tests/KnitNoteCoreTests/ShareExtensionFlowContractTests.swift`

**Interfaces:**
- Consumes: `[NSExtensionItem]`, `NSItemProvider.loadFileRepresentation(forTypeIdentifier:)`
- Consumes: `PatternStorageLocations.live().inboxRoot`
- Produces: one `.shareExtension` inbox item or one terminal localized failure

- [x] Add behavior contracts for exact-one provider selection, security-scope bracketing, `.shareExtension` origin, nil project ID, timeout, cancellation, and terminal-context completion.
- [x] Run the focused flow tests and confirm missing controller behavior.
- [x] Implement a provider adapter that creates one `Progress`, a timeout timer, and one completion gate.
- [x] In the provider callback, acquire security scope, synchronously validate and enqueue on the dedicated worker queue before the callback returns, stop access with `defer`, and then publish one terminal result on the main actor.
- [x] Cancel the provider `Progress` and invalidate the gate when the user cancels or the extension disappears.
- [x] Prove a late callback, multiple providers, or repeated lifecycle callback cannot enqueue twice.
- [x] Rerun presentation, flow, inbox, and file-validation tests.

### Task 4: Minimal Localized Accessible UI

**Files:**
- Create: `KnitNoteShare/ShareImportView.swift`
- Create: `KnitNoteShare/Localizable.xcstrings`
- Modify: `KnitNoteShare/ShareViewController.swift`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ShareExtensionFlowContractTests.swift`

**Interfaces:**
- Consumes: loading, success, failure, cancelled presentation state
- Produces: localized complete/cancel actions and VoiceOver-readable status

- [x] Add exact en/zh-Hant catalog expectations and accessibility behavior contracts before catalog/UI implementation.
- [x] Run focused tests and confirm missing keys and UI behavior.
- [x] Implement a compact SwiftUI host with progress, success, and error states; no host-App launch.
- [x] On success call `completeRequest`; on failure or user cancellation call `cancelRequest` exactly once.
- [x] Rerun focused presentation, localization, and flow suites.

### Task 5: Canonical Verification and Isolated Commit

**Files:**
- Create: `task-9-report.md`
- Modify: this plan checklist

**Interfaces:**
- Consumes: all Task 9 artifacts.
- Produces: reproducible evidence without Task 10 behavior.

- [x] Run `swift test --filter PatternShareImportPresentationTests`, target/flow/localization focused tests, and existing inbox/file-service compatibility tests.
- [x] Run full `swift test --quiet`.
- [x] Run canonical Debug `xcodebuild` for `KnitNoteShare` on generic iOS Simulator.
- [x] Run canonical Debug `xcodebuild` for `KnitNote` on generic iOS Simulator and verify `KnitNoteShare.appex` is embedded.
- [x] Run canonical macOS App and Watch builds to prove no wrong-target membership.
- [x] Run Swift parse, `jq empty`, `plutil -lint`, PBX membership tests, entitlement inspection, and `git diff --check`.
- [x] Record RED/GREEN and exact verification evidence in `task-9-report.md`.
- [x] Stage only Task 9 files and commit `feat: add pattern file share extension`.
