# Task 6 Report — Watercolor Home, Help, and Navigation

## Scope

- Added a native SwiftUI watercolor theme with low-opacity decorative radial gradients, solid readable cards, and decorative accessibility hiding.
- Added the single-column calculator home with exactly two tool routes, a 620-point readable-width cap, and a neutral reserved promotion-card slot.
- Replaced the root placeholder with `NavigationStack` home navigation and a disabled Settings toolbar affordance; Task 7 owns the eventual route and settings UI.
- Added a one-page, dismissible contextual help sheet for Gauge and Adjustment. Each localized description includes the approved worked example and accepts no input.
- Added Task 6 English and Traditional Chinese strings plus catalog-coverage contracts.
- Regenerated `KnitNote.xcodeproj` so Theme, Home, and Help sources are target members.

## TDD Evidence

- RED: `swift test --filter KnittingCalculatorViewContractTests` failed as expected because `CalculatorHomeView.swift` did not exist and neither tool referenced `CalculatorHelpSheet`.
- RED: `swift test --filter KnittingCalculatorLocalizationContractTests` failed as expected for missing `app.home.title`.
- GREEN: `swift test --filter KnittingCalculatorViewContractTests` passed: 7 tests in 1 suite.
- GREEN: `swift test --filter KnittingCalculatorLocalizationContractTests` passed: 1 test in 1 suite.
- `jq empty KnittingCalculator/Localization/Localizable.xcstrings` and `git diff --check` passed.

## Build Evidence and Debt

- `xcodegen generate` completed and rewrote `KnitNote.xcodeproj` with the new source membership.
- `xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnittingCalculatorHomeDevice CODE_SIGNING_ALLOWED=NO` exited 0.
- iPhone 17 Pro Max and iPad Pro 13-inch (M5) simulator-destination attempts could not start because `CoreSimulatorService` was disconnected, no simulator runtimes were discoverable, and `simdiskimaged` was unavailable. Runtime/layout validation on those destinations remains outstanding.
- The repository-wide `swift test` tail stall remains a known environment debt; only Task 6 focused contracts were run.

## Review

- Reviewed the full staged diff against `a9f5d537b78d961cb985deac94b78b7b25cc3d2c` for scope: no onboarding, settings screen, KnitNote action/routing, rating, icon, or store work was added.
