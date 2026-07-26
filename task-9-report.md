# Task 9 Report — Pattern File Share Extension

## Scope

Implemented only the iOS Share Extension intake path. The extension accepts exactly one actual PDF, PNG, JPEG, or HEIC attachment, validates and durably enqueues it in the shared App Group inbox with `.shareExtension` origin, and never opens or mutates the main App archive. No Task 10 inbox discovery, processing, notification, or duplicate-cleanup behavior was added.

## RED

- Added pure selection tests before production symbols existed. The first focused run failed to compile on the missing selector, provider selection, completion gate, and stable error mapping APIs.
- Added table tests for PDF, PNG, JPEG, and HEIC before broadening the initial PDF representation. The focused run failed until all four approved types were selected.
- Added concurrent cancellation/timeout tests before the one-shot state machine existed. The tests require exactly one provider callback to claim work and prevent late publication after cancellation or timeout.
- Added the security-scope and durable inbox test before `PatternShareInboxEnqueuer` existed. The compile failure preceded implementation of `.shareExtension`, nil project ID, and balanced security-scope behavior.
- Added extension target, entitlement, activation-predicate, localization, and flow contracts before their artifacts existed. The first target run reported three tests and six missing-contract issues; the first flow run reported two tests and four issues.
- The first genuine Share Extension build failed because the minimal source graph omitted the markup compatibility dependency referenced by `PatternFileService`. Added only `PatternMarkup` and `PatternMarkupFileService`, then rebuilt successfully.
- The first full regression found four stale `WatchPackagingContractTests` assertions that assumed only two versioned bundles. Updated the test to read and verify App, Watch, and Share metadata explicitly.
- Final membership review added both Share Core files to the executable PBX source test. It failed because `PatternShareInboxEnqueuer.swift` was still compiled by the Watch Core glob. Excluding it in `project.yml` and regenerating the project made the contract pass.

## GREEN

- Added the canonical iOS-only `KnitNoteShare` app-extension target with bundle identifier `com.phillon.KnitNote.share`, strict one-item/one-attachment activation predicate, privacy manifest, and `APPLICATION_EXTENSION_API_ONLY`.
- Added matching `group.com.phillon.KnitNote` entitlements to the iOS App and Share Extension while preserving the separate macOS entitlement configuration.
- Added pure provider selection for exactly one PDF, PNG, JPEG, or HEIC representation. Empty input, URL-only input, multiple attachments, and multiple extension items are rejected.
- Added an `NSLock`-protected completion gate. Exactly one callback can enter processing; cancellation can terminate waiting or active work; timeout can win only while the provider is still waiting.
- `ShareImportController` owns one provider `Progress`, a 20-second load timeout, cancellation, and a one-shot extension-context terminal path.
- The `NSItemProvider` callback remains alive while a dedicated worker queue synchronously performs security-scoped access, validation, and durable inbox copy. Late or duplicate callbacks cannot enqueue or publish twice.
- The enqueue path writes only one inbox item with `.shareExtension` origin and nil project ID. It does not reference `JSONProjectStore`, `ProjectArchive`, or host-App launch APIs.
- Added a compact SwiftUI loading/success/failure surface with exact English and Traditional Chinese copy and readable VoiceOver labels.
- The iOS App embeds the extension. The extension and Share-only Core files are absent from Watch membership, and no extension product appears in macOS or Watch build products.

## Verification

- Focused Task 9 plus Task 8 project compatibility: 17 tests across six suites passed before final regression.
- Watch packaging compatibility: 8 tests passed after adding the third versioned bundle.
- PBX source membership RED showed `PatternShareInboxEnqueuer.swift` in Watch Sources; the regenerated-project GREEN run passed after the explicit exclusion.
- Final full regression: `swift test --quiet` passed 744 tests in 63 suites.
- Fresh canonical Debug builds with code signing disabled passed for:
  - `KnitNoteShare`, generic iOS Simulator.
  - `KnitNote`, generic iOS Simulator.
  - `KnitNote`, generic macOS.
  - `KnitNoteWatch`, generic watchOS Simulator.
- The fresh iOS App product contains `KnitNote.app/PlugIns/KnitNoteShare.appex`.
- Fresh macOS and Watch build products contain no `KnitNoteShare.appex`.
- Built extension metadata reports bundle identifier `com.phillon.KnitNote.share`, principal class `KnitNoteShare.ShareViewController`, and the strict supported-file activation predicate.
- `plutil -lint` passed for both Info plists, both entitlements, the privacy manifest, and the generated PBX project.
- Both entitlements inspect to the single App Group `group.com.phillon.KnitNote`.
- `jq empty` passed for the Share and main App localization catalogs.
- Swift parse passed for every touched Swift file.
- `git diff --check` passed.

## Files

- `KnitNote.xcodeproj/project.pbxproj`
- `KnitNote.xcodeproj/xcshareddata/xcschemes/KnitNoteShare.xcscheme`
- `KnitNote/KnitNote-iOS.entitlements`
- `KnitNoteShare/Info.plist`
- `KnitNoteShare/KnitNoteShare.entitlements`
- `KnitNoteShare/Localizable.xcstrings`
- `KnitNoteShare/PrivacyInfo.xcprivacy`
- `KnitNoteShare/ShareImportController.swift`
- `KnitNoteShare/ShareImportView.swift`
- `KnitNoteShare/ShareViewController.swift`
- `Sources/KnitNoteCore/Patterns/PatternShareImportPresentation.swift`
- `Sources/KnitNoteCore/Patterns/PatternShareInboxEnqueuer.swift`
- `Tests/KnitNoteCoreTests/PatternShareImportPresentationTests.swift`
- `Tests/KnitNoteCoreTests/PatternShareInboxEnqueuerTests.swift`
- `Tests/KnitNoteCoreTests/ShareExtensionFlowContractTests.swift`
- `Tests/KnitNoteCoreTests/ShareExtensionLocalizationContractTests.swift`
- `Tests/KnitNoteCoreTests/ShareExtensionTargetContractTests.swift`
- `Tests/KnitNoteCoreTests/Task8XcodeProjectMembershipTests.swift`
- `Tests/KnitNoteCoreTests/WatchPackagingContractTests.swift`
- `docs/superpowers/plans/2026-07-26-task9-share-extension.md`
- `project.yml`
