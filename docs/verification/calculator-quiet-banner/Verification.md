# Quiet banner verification — 2026-09-17

## Scope

Local phase-one implementation on `feature/calculator-stitch-dictionary`, base HEAD `6b16af4f83b3e25a124085ea2809679564b8b522`. Changes remain uncommitted in the existing Calculator worktree. Existing untracked screenshots and other work were preserved. No Git push, App Store mutation, production ad activation, website publishing, or purchase product creation occurred.

## Evidence

- Xcode 27.0 (27A266a), after user accepted its license.
- Existing core: `swift test --package-path Packages/KnittingCalculatorCore --scratch-path /tmp/calculator-quiet-core-baseline`: 47 tests passed.
- Final app tests: `xcodebuild test -project KnittingCalculator.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,id=CCC0104E-86BA-4FB7-BDD9-CD2608F90F58' -derivedDataPath /tmp/calculator-quiet-banner-derived -clonedSourcePackagesDirPath /tmp/calculator-quiet-banner-packages -quiet`: exit 0, 46 passed, 0 failed, 0 skipped.
- Result bundle: `/tmp/calculator-quiet-banner-derived/Logs/Test/Test-KnittingCalculator-2026.09.17_13-30-42-+0800.xcresult`.
- New tests cover disabled/default/Debug/Release configuration, Google sample-ID rejection for production enablement, publisher mismatch, screenshot/test suppression, consent eligibility, one SDK-start claim, privacy change, and interrupted initial consent presentation.
- All 13 localization catalogs pass `knitting_calculator_localization_check.py`; `git diff --check` passes.
- GoogleMobileAds 13.9.0 and UMP 3.1.0 resolved from Google repositories and pinned in Package.resolved.
- Unsigned Release device build succeeded before the final consent/config refinements; final Release **simulator** build and runtime launch succeeded after them. A final device archive is not claimed.

## Runtime observations

- iPhone 17 Pro / iOS 26.5: explicit Debug `-calculatorTestAds` displayed Google's actual fixed-size banner with the Test mode label. See `iphone-test-banner.png`.
- Navigating into Gauge Calculator removed the advertising placement; returning home restored the placement/load flow.
- iPad Pro 11-inch M5 / iOS 26.5: local `-calculatorBannerPreview` placement checked in portrait and landscape. It remains 320 × 50 and does not cover tool cards. See `ipad-placement-preview.png` for portrait.
- Final Release simulator app launched normally and displayed no advertising placement with readiness `NO`, empty banner unit ID, and official sample App ID as a development placeholder. Sample App ID cannot enable Release requests because configuration rejects it.

## Issues found and resolved

1. Screenshot rendering test crashed because the screenshot root did not supply the new environment object. It now injects its own disabled advertising object; existing rendering regression passes.
2. Independent review found cancellation could permanently abandon consent preparation. Consent-info update and form load are now session-owned tasks; presentation checks the active controller after loading. The reviewed fix preserves pending presentation across navigation.
3. Actual Release launch exposed `GADInvalidInitializationException` when App ID was empty, even without explicit SDK start. A valid official sample App ID satisfies load-time validation while readiness and unit ID keep Release advertising disabled. Final Release launch was observed in the Simulator UI after rebuilding.

## Remaining before advertising release

- User AdMob registration, actual App ID and Banner unit ID, account/app verification, and app-ads.txt deployment.
- Backend Video OFF and initial auto-refresh OFF, applicable privacy messages, production creative/sound validation.
- Physical-device consent-required region, interruption during an actual consent form, offline/no-fill behavior, large text, VoiceOver, and narrow iPad split-view acceptance.
- Update the old 1.1.0 (4) ad-free release audit profile for the new advertising release with regression coverage; it deliberately still rejects remote SDK packages. No advertising archive-audit pass is claimed.
- Final privacy policy, App Store privacy disclosures, version/build selection, device archive, and explicit publishing authorization.

The global SDK mute API is not used: Google's documentation reserves it for reflecting the app user's mute control, which Calculator does not have. The product requirement is implemented with standard non-collapsible banners and the mandatory backend video-off setting; live creative behavior cannot be proven from a test creative.
