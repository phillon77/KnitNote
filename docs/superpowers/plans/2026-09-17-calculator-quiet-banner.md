# Quiet Banner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional, quiet home banner without disrupting calculator use.

**Architecture:** A pure configuration policy gates SDK usage. A scene-local banner host uses the consent coordinator and owns its ad lifecycle. All production advertising stays disabled until owner configuration and release checks are complete.

**Tech Stack:** Swift 6, SwiftUI/UIKit, GoogleMobileAds 13.9.0, GoogleUserMessagingPlatform 3.1.0, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-17-calculator-quiet-banner-design.md`

## Global Constraints

iOS 18 minimum; existing independent Calculator worktree only. Banner 320 × 50; no full-screen or collapsible requests. First-class existing 13 localizations. No changes to calculator math/drafts. No purchase implementation in phase one. No live IDs or production activation inferred from this approval.

## 1. Establish baseline and configuration policy

Files: create `KnittingCalculatorTests/CalculatorAdConfigurationTests.swift` and `KnittingCalculator/Model/CalculatorAdConfiguration.swift`.

- [ ] Run `git status --short`, `git rev-parse HEAD`, and `xcrun simctl list devices available`; record the selected simulator before building.
- [ ] Run existing Calculator tests with `xcodebuild test -project KnittingCalculator.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/calculator-quiet-banner-derived` (use the actual available simulator name).
- [ ] Write policy tests asserting that missing configuration, unapproved production readiness, sample production IDs, screenshot mode, and unit-test mode all disable advertising. Debug testing must select Google's test unit regardless of provided live IDs.
- [ ] Run the new tests to observe the missing feature; implement the pure resolver and rerun.

## 2. SDK and consent integration

Files: modify `KnittingCalculator/project.yml`, `KnittingCalculator/Info.plist`, generated `KnittingCalculator.xcodeproj/project.pbxproj`; create `KnittingCalculator/Model/CalculatorAdConsent.swift` and consent tests.

- [ ] Add exact SPM dependencies for GoogleMobileAds 13.9.0 and GoogleUserMessagingPlatform 3.1.0, regenerate with XcodeGen, and resolve packages.
- [ ] Add fail-closed release configuration; sample application ID remains a development placeholder to satisfy SDK load-time validation; Release enablement rejects it.
- [ ] Test consent-state transitions and duplicate callbacks before implementing the coordinator. No SDK start or banner request before current UMP eligibility.
- [ ] Disable publisher first-party ID before startup; enforce video-off in backend setup and use standard muted-by-default banners. Do not misuse the global mute API, which requires a user mute control. Request non-personalized ads; do not add ATT authorization requests. Use current SDK interfaces verified against downloaded headers.
- [ ] Test the unavailable-network path: show no advertising and leave the calculator usable.

## 3. Home placement and settings

Files: create `KnittingCalculator/Home/CalculatorBannerView.swift`; modify `CalculatorHomeView.swift`, `CalculatorSettingsView.swift`, `Localizable.xcstrings`.

- [ ] Implement standard banner host in a home-only safe-area inset. Attach the host to the presenting scene before requesting, and remove it when inactive or offscreen.
- [ ] Collapse failed/unavailable placement; do not repeatedly reload from SwiftUI updates. Use no collapsible request extras.
- [ ] Add localized Advertisement label, ad reporting link, and required privacy-options entry. Provide Debug-only non-network placement preview for screenshots.
- [ ] Run unit tests and verify preview layout on iPhone/iPad, large text and rotation. Verify narrow width does not clip the creative or hide controls.

## 4. Release preparation and review

Files: add `AppStore/Advertising/Setup.md` and a bilingual privacy-policy draft; adapt release audit only with regression tests preserving the old ad-free profile.

- [ ] Document owner setup and exact IDs needed, plus video-off/refresh-off settings and privacy messaging.
- [ ] Prepare privacy draft separately from currently published policy. Record actual SDK disclosures and required store metadata changes.
- [ ] Run configuration, consent, localization, existing core, and Release build checks. Record environmental failures separately from app failures.
- [ ] Review diff for production-test-ID leakage, screenshot networking, unsupported ad formats, and changes outside Calculator.
- [ ] Report implementation evidence and remaining account/device/release dependencies without claiming revenue activation.

## Current execution state

2026-09-17: Xcode license gate resolved by user. Baseline HEAD 6b16af4f83b3e25a124085ea2809679564b8b522; baseline core 47 tests passed and Xcode app test command exited 0. Initial new test compilation failed for the missing ad configuration type. SDK packages resolved; app compiled. First integration run passed 44 tests but screenshot rendering crashed because the screenshot root lacked the new environment object. Added a dedicated disabled advertising object to the screenshot root; validation continues. Production remains unconfigured and disabled.


## Verified implementation status

- Local implementation and review complete for phase one; 46 App tests and 47 core tests pass.
- Google fixed-size test banner loaded on iPhone; navigating into the gauge calculator removes it.
- iPhone and iPad portrait/landscape placement visually checked; iPad preview is local, not a production creative.
- All 13 localization catalogs pass the existing checker.
- Review caught interrupted consent flow; form loading is now separate from active-controller presentation.
- Release runtime exposed SDK validation of blank App ID even without explicit startup. The valid official sample App ID is a development placeholder; readiness NO and empty banner ID keep all Release ad requests disabled. Live IDs and account settings are still required before advertising release.
- Release audit profile, live creatives/sound, consent-required region on physical devices, offline/no-fill acceptance, large text and VoiceOver remain release-stage work. No push, submission, or site publishing performed.
