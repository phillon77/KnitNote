# KnitNote 1.3.1 Integration Task 3 Verification Report

Date: 2026-08-04 (Asia/Taipei)

## Candidate Boundary

- Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/knitnote-1.3.1-implementation`
- Branch: `feat/knitnote-1.3.1`
- Verified source candidate: `6ca960e39c129e9b4a6d4e0aff8eed2f30b91c9c`
- Verification started from report-only HEAD: `9dd5b1f28206f47bdde4c37689ec2ddf50acff5d`
- `9dd5b1f^` resolves exactly to `6ca960e`; the HEAD-only change before this report was the Settings Task 3 report.
- Released comparison baseline: `cdb68cc`
- Marketing version/build remain deliberately unchanged at `1.3.0 (6)` for the app, Share Extension, and Watch app.
- No version/build, merge, push, upload, submission, price, StoreKit, or App Store Connect action was performed.

## Fresh Project, Tests, and Builds

All commands used the same unchanged source candidate.

| Gate | Result |
| --- | --- |
| `xcodegen generate` | PASS; generated project left no tracked diff |
| `swift test --disable-sandbox` | PASS: 1,218 tests in 111 suites, zero failures |
| `git diff --check` | PASS |
| Generic iOS clean unsigned build | PASS; app, Share Extension, and embedded Watch app validated |
| Generic macOS clean unsigned build | PASS |
| Generic watchOS `KnitNoteWatch` clean unsigned build | PASS |
| `bash AppStore/Verification/release_audit.sh --static-only` | PASS: metadata, offline commercial, release audit |

Derived-data roots:

- `/tmp/KnitNote-1.3.1-Candidate-iOS-Task3`
- `/tmp/KnitNote-1.3.1-Candidate-macOS-Task3`
- `/tmp/KnitNote-1.3.1-Candidate-watchOS-Task3`

The built Info.plists independently report:

- iOS: `com.phillon.KnitNote`, `1.3.0`, build `6`
- macOS: `com.phillon.KnitNote`, `1.3.0`, build `6`
- watchOS: `com.phillon.KnitNote.watch`, `1.3.0`, build `6`

## Focused Regression Evidence

| Suite | Result |
| --- | --- |
| `ReleaseConfigurationContractTests` | PASS: 19 tests |
| `KnitNoteBackupServiceTests` | PASS: 82 tests |
| `LocalizationContractTests` plus Share Extension localization | PASS: 34 tests in 2 suites |
| `WatchSyncModelsTests` | PASS: 9 tests |
| `WatchCommandApplicationTests` | PASS: 16 tests |
| `ProjectCounterTests` | PASS: 17 tests |
| `YouTubePatternStoreTests` | PASS: 12 tests |
| `PatternCalculatorTests` | PASS: 15 tests |
| `SettingsAboutVersionContractTests` | PASS: 4 tests |
| `PatternLibraryMigrationTests` | PASS: 27 tests |
| `YouTubeThumbnailCacheTests` | PASS: 7 tests |
| `YouTubePatternAssetTests` | PASS: 6 tests |
| `Task8XcodeProjectMembershipTests` | PASS: 2 tests |
| `PatternReaderCalculatorIntegrationTests` | PASS: 2 tests |
| `AppVersionInfoTests` | PASS: 3 tests |

The macOS Xcode test target was also run because the three commercial implementation suites are not members of the SwiftPM test product:

```text
xcodebuild ... test \
  -only-testing:KnitNoteAppTests/StoreKitPurchaseServiceLifecycleTests \
  -only-testing:KnitNoteAppTests/EntitlementCoordinatorTests \
  -only-testing:KnitNoteAppTests/KeychainTrialStoreTests
```

Result: PASS, 42 tests in 3 suites, zero failures. This includes verified free-app transaction handling, lifetime purchase/restore refresh behavior, unavailable StoreKit behavior, durable seven-day trial start, expiry rejection, Watch entitlement gating, and transaction-listener lifecycle.

## Persistence and Backup Inspection

- `ProjectArchive.currentVersion` is `12`; supported versions remain `1...12`.
- The migrator accepts every supported older archive, preserves the existing pattern tree, emits `ProjectArchive.currentVersion`, then validates the complete current snapshot and every owned asset. Migration regression: 27 tests PASS.
- A YouTube item is persisted as an owned `Patterns/Assets/<asset-id>.youtube` JSON sidecar with byte count and SHA-256 in the archive/backup manifest.
- Backup validation decodes and validates `YouTubePatternMetadata`; missing, tampered, oversized, symlinked, and schema-invalid sidecars are rejected before replacing live data.
- `versionTwelveYouTubeBackupRoundTripsTwoUsagesWithoutCachedMedia` proves title, note, active/inactive usage links, project IDs, canonical link, and sidecar round-trip.
- The generated YouTube thumbnail is stored at sibling cache root `.KnitNote-PatternThumbnailCache`, outside the live `KnitNote` backup root. The backup test proves the package and manifest exclude cache entries, JPEG thumbnail data, and video extensions (`.mp4`, `.mov`).
- Calculator state is a reader-owned `@State private var calculatorState`; searches of project archive types, `PatternProjectUsage`, backup, Settings, entitlements, `UserDefaults`, `AppStorage`, and `SceneStorage` found no calculator persistence path. Reader integration tests PASS.

## Settings and Localization Inspection

- `AppVersionInfo.current(in:)` reads `Bundle.infoDictionary` and parses `CFBundleShortVersionString` plus `CFBundleVersion`; missing or blank values return the safe placeholder path.
- `SettingsView` injects `AppVersionInfo.current()` by default, formats using the app-selected SwiftUI locale, and displays `—` when unavailable. No planned release number is hardcoded in the Settings source.
- The 34 new calculator, YouTube, and Settings/About localization keys were parsed directly from `Localizable.xcstrings`; every one has nonempty English and Traditional Chinese translations.
- Localization contract tests additionally prove the approved exact copy and placeholder contracts; no raw key fallback is accepted by those contracts.

## Commercial, Entitlement, and Privacy Comparison

The following 15 files have byte-for-byte identical Git object hashes at released baseline `cdb68cc` and current source candidate `6ca960e`:

1. `KnitNote/StoreKit/KnitNote.storekit`
2. `KnitNote/Entitlements/StoreKitPurchaseService.swift`
3. `KnitNote/Entitlements/KeychainTrialStore.swift`
4. `Sources/KnitNoteCore/Entitlements/TrialRecord.swift`
5. `Sources/KnitNoteCore/Entitlements/LegacyPaidVersionPolicy.swift`
6. `Sources/KnitNoteCore/Entitlements/EntitlementProjection.swift`
7. `KnitNote/KnitNote-iOS.entitlements`
8. `KnitNote/KnitNote-macOS.entitlements`
9. `KnitNoteShare/KnitNoteShare.entitlements`
10. `KnitNote/PrivacyInfo.xcprivacy`
11. `KnitNoteShare/PrivacyInfo.xcprivacy`
12. `KnitNoteWatch/PrivacyInfo.xcprivacy`
13. `KnitNote/Info.plist`
14. `KnitNoteShare/Info.plist`
15. `KnitNoteWatch/Info.plist`

The baseline/current `project.yml` commercial settings are also identical: team `9CFPAUL5N5`, product bundle IDs, entitlements paths, StoreKit configuration path, marketing version `1.3.0`, and build `6`. The only `project.yml` changes are reviewed source membership: app version/calculator exclusions from Watch and YouTube metadata/link support for the Share Extension. The generated pbxproj diff contains no commercial, signing-entitlement, privacy-resource, StoreKit-path, version, build, or bundle-ID changes.

The Lifetime Unlock identifier remains `com.phillon.KnitNote.lifetimeUnlock`, the trial duration remains exactly seven days, and the StoreKit/trial/legacy-owner implementation is byte-identical to `cdb68cc`.

## Watch and Counter Boundary

- `KnitNoteWatch` and its string catalog contain no YouTube UI, action, title, or localized copy. Shared archive/model code can decode the `.youtube` enum case, but the feature has no Watch-facing entry point.
- `AppVersionInfo.swift` and `PatternCalculator.swift` are explicitly excluded from the Watch target specification.
- The standalone generic watchOS build passes.
- Six-counter snapshot shape, command application, selection, increment/decrement floor/reset, completed-project locking, and sync regressions pass (9 + 16 + 17 focused tests).

## Result and Remaining Boundary

**Task 3 automated combined regression: PASS.** No scoped source defect was found, so no source was edited.

This is automated/build/static evidence only. It does not satisfy Task 4 physical acceptance on iPhone, iPad, Mac, or Watch, destructive real-data backup/restore, VoiceOver, archive/signing inspection, App Store Connect selected-build verification, or any release action. Those remain explicit later gates for one exact candidate.
