# Task 3 automated verification report — Settings About Version

## Immutable candidate

- Commit: `6ca960e39c129e9b4a6d4e0aff8eed2f30b91c9c`
- Branch: `feat/knitnote-1.3.1`
- Repository root: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/knitnote-1.3.1-implementation`
- Release metadata was not changed. `project.yml` and the generated Xcode project remain at `1.3.0 (6)` for the iOS app, macOS app, Share extension, and Watch app.
- Before this report was added, the final boundary check showed the candidate commit above, `git status --short` produced no output, and `git diff --check` produced no output.

## Automated evidence

All commands below were run from the repository root at the immutable candidate above.

| Gate | Command / artifact | Result |
| --- | --- | --- |
| Full regression suite | `swift test --disable-sandbox` | Passed: 1,218 tests in 111 suites, zero failures. |
| iOS Simulator clean build | `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath .derived-data/settings-version-ios CODE_SIGNING_ALLOWED=NO clean build` | `BUILD SUCCEEDED`. This app build also built and validated the embedded Share extension and Watch app. |
| macOS clean build | `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'platform=macOS' -derivedDataPath .derived-data/settings-version-macos CODE_SIGNING_ALLOWED=NO clean build` | `BUILD SUCCEEDED`. |
| Watch scope / clean build | `xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Debug -destination 'generic/platform=watchOS Simulator' -derivedDataPath .derived-data/settings-version-watch CODE_SIGNING_ALLOWED=NO clean build` | `BUILD SUCCEEDED`. The version parser remains excluded from the Watch target by the tested XcodeGen contract. |
| Actual iOS bundle metadata | `.derived-data/settings-version-ios/Build/Products/Debug-iphonesimulator/KnitNote.app/Info.plist` | `CFBundleShortVersionString = 1.3.0`; `CFBundleVersion = 6`. |
| Actual macOS bundle metadata | `.derived-data/settings-version-macos/Build/Products/Debug/KnitNote.app/Contents/Info.plist` | `CFBundleShortVersionString = 1.3.0`; `CFBundleVersion = 6`. |
| Actual Watch bundle metadata | `.derived-data/settings-version-watch/Build/Products/Debug-watchsimulator/KnitNoteWatch.app/Info.plist` | `CFBundleShortVersionString = 1.3.0`; `CFBundleVersion = 6`. |
| Parser and fallback contracts | Full suite includes `AppVersionInfoTests` and `SettingsAboutVersionContractTests`. | Both bundle values are trimmed and displayed only when both are valid; missing, blank, malformed, or wrong-typed metadata resolves to the noninteractive fallback rather than hard-coded release numbers. |
| Localization contracts | Full suite includes `LocalizationContractTests`; source inspection checked `settings.about`, `settings.version`, and `settings.version.format`. | English uses `1.3.0 (Build 6)` with half-width parentheses; Traditional Chinese uses `1.3.0（Build 6）` with full-width parentheses. Formatting uses the app-selected SwiftUI locale rather than `Locale.current`. |
| Static Settings-row contract | Full suite includes `SettingsAboutVersionContractTests`. | The About section is after backup/restore, is static text rather than a button/link, and does not hard-code planned version or build values. |

The temporary workspace-local DerivedData created by this run was removed after reading the built bundle metadata. Build logs contained the existing informational AppIntents warning that metadata extraction was skipped because the app has no AppIntents framework dependency; it did not cause a build failure.

## Required physical acceptance — pending final integrated candidate

No physical-device or accessibility acceptance is claimed by this automated report. The following checks must be performed on artifacts built from one final integrated commit and must record that exact commit and installed artifact:

### iPhone

1. Open Settings and confirm the row shows the actual installed bundle version and build in English and Traditional Chinese.
2. Confirm the row is complete at enlarged Dynamic Type sizes.
3. With VoiceOver, confirm it is announced as static information, not as a button or link.

### iPad

1. Repeat the version/build check in portrait and landscape.
2. Repeat with enlarged Dynamic Type and VoiceOver; confirm no clipping or unintended action trait.

### Mac

1. Confirm the same installed version/build appears at the bottom of the existing bounded Settings form.
2. Confirm the row does not change the form width or existing layout.
3. Confirm VoiceOver exposes static information and no button/link action.

### Missing-field acceptance build

1. Build a same-source test artifact with either bundle field omitted.
2. Confirm the Settings value is `—`.
3. Confirm language selection, calculators, yarn-label storage, backup, and restore remain usable.

## Boundary

This report does not merge, push, change version/build, upload, submit, or release the candidate. It establishes automated evidence only; physical iPhone, iPad, Mac, VoiceOver, and Dynamic Type acceptance remains pending for the final integrated 1.3.1 candidate.
