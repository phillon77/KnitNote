# KnitNote 1.5 Dutch Localization Verification

**Verification date:** 2026-08-09
**Source boundary:** `feature/knitnote-1.5` at `c88b7eeb55171d4c6f1f03832c27d64ec1fb4896`

This record verifies the already-completed atomic thirteen-locale transition. It does not change locale declarations, metadata, version/build, signing, archives, uploads, App Store Connect, or any source behavior.

## Immutable boundary

- The branch and HEAD matched the verification brief before work started.
- Pre-existing untracked paths were preserved: `.superpowers/brainstorm/`, `AppStore/Verification/CounterReminders150Verification.md`, and `build/`.
- `git diff --check` passed before this verification record was added.

## Automated source and release-audit gates

| Command | Fresh result |
| --- | --- |
| `swift test --disable-sandbox --filter ReleaseAuditLocalizationTests` | PASS — 54 tests, 1 suite, 311.065 seconds |
| `swift test --disable-sandbox --filter ReleaseCandidateIdentityTests` | PASS — 5 tests, 1 suite, 14.124 seconds |
| `swift test --disable-sandbox` | PASS — 1,468 tests, 125 suites, 322.475 seconds |
| `AppStore/Verification/release_audit.sh --static-only` | PASS — metadata, offline commercial, and static release audit checks |

The focused release audit and identity suite cover the exact thirteen source/generated locale declarations, PBX known regions, and release-audit localization contract. The full suite repeated those checks in the exact source boundary.

## Unsigned Debug build and packaging audit

All commands used `CODE_SIGNING_ALLOWED=NO` and completed with `** BUILD SUCCEEDED **`.

| Product | Build command | Built product | Declared locales | Packaged `.lproj` locales |
| --- | --- | --- | --- | --- |
| iOS main | `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` | `~/Library/Developer/Xcode/DerivedData/KnitNote-cnkrjwlswkkyatefkewemlenlryc/Build/Products/Debug-iphonesimulator/KnitNote.app` | 13 | 13 |
| macOS main | `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build` | `~/Library/Developer/Xcode/DerivedData/KnitNote-cnkrjwlswkkyatefkewemlenlryc/Build/Products/Debug/KnitNote.app` | 13 | 13 |
| Watch | `xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Debug -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build` | `~/Library/Developer/Xcode/DerivedData/KnitNote-cnkrjwlswkkyatefkewemlenlryc/Build/Products/Debug-watchsimulator/KnitNoteWatch.app` | 13 | 13 |
| Share | `xcodebuild -project KnitNote.xcodeproj -target KnitNoteShare -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` | `build/Debug-iphoneos/KnitNoteShare.appex` | 13 | 13 |

For every product, `CFBundleLocalizations` and the deduplicated `.lproj` directories were exactly:

`da de el en fi fr ja ko nb nl sv zh-Hans zh-Hant`

Each product contains `nl.lproj`. The target-style Share command emitted Xcode's expected warning that the destination is ignored because no scheme is passed; the requested target build still succeeded. Packaging verifies resources, not linguistic quality or physical UI behavior.

## Read-only Dutch source review

This is a source-grounded editorial review only, not native/qualified Dutch acceptance. Reviewed repository-owned copy includes:

- Navigation/language: `Nederlands`, `Projecten`; runtime source contracts verify German `Projekte` and Dutch `Projecten` through the same semantic key.
- Reminder: `Toer %lld bereikt.`, `Deze herinnering voltooien`, `Herinnering stoppen`, with matching Watch copy; format/plural contracts are covered by the automated suites.
- Compact Watch actions: `Verminder met één`, `Zet op nul`, `Annuleer`.
- Share: `Voeg toe aan KnitNote`, `Annuleer`, `Sluit`; file-import errors are specific to the shared file.
- Camera permission: `Maak foto's voor breiprojecten, dagboekitems en garenlabels.`
- Glossary contains `project`, `patroon`, `garen`, `toerenteller`, `toer`, `steek`, `breinaald`, and `haaknaald` for the required core concepts.
- Repository metadata `AppStore/Metadata/nl-NL.md` is present and was read; its Dutch copy remains repository-owned preparation, not live App Store state.

No source review step rewrote user-created/imported names, reminders, notes, patterns, yarn data, or YouTube data. Native Dutch domain acceptance remains required for `stekenverhouding`, `proeflap`/`proeflapje`, the `meerderen`/`minderen` and `samenbreien` families, `ronde` versus `toer`, and the mandated `Deze herinnering voltooien` wording.

## Physical and native-acceptance gates — PENDING

No device was installed, launched, or modified for this record. `xcrun xcdevice list` reported only the available local Mac (`My Mac`, macOS 26.6.1); no available physical iPhone, iPad, or Apple Watch was reported. CoreSimulatorService was unavailable, so no simulator was used.

The following exact-candidate acceptance remains pending:

1. Qualified/native Dutch reviewer approval for knitting terminology, reminder wording, compact Watch wording, permission copy, and metadata.
2. iPhone and iPad in Dutch: navigation/title, reminder formatting and plurals, Share UI, VoiceOver, Dynamic Type, and user-created/imported content unchanged; repeat the large title in German as `Projekte` and Dutch as `Projecten`.
3. Apple Watch in Dutch: counter/reminder copy, haptic/acknowledgement behavior, reconnect behavior, VoiceOver, and no duplicate completion.
4. Mac in Dutch: navigation/title, reminder formatting and plurals, keyboard navigation, VoiceOver, Dynamic Type, Share path where applicable, and user-created/imported content unchanged.
5. Install over a prior-version data set and confirm existing non-disposable projects and counters are unchanged.

These pending gates prevent linguistic or physical release acceptance. This document is automated/package evidence only.
