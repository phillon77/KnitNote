# Task 7 Report: KnitNote routing and Settings

## Delivered

- Replaced the reserved home card with a low-priority KnitNote promotion, shown only on Home and Settings.
- Described KnitNote as a separate app, without upgrade or full-version language.
- Added installed-app routing through `knitnote://`, with fallback to the existing KnitNote App Store URL (`id6793023054`) only when the launch completion reports failure.
- Registered the `knitnote` URL scheme on the KnitNote target.
- Added Settings navigation, unit conversion/persistence, destructive local-input reset confirmation, feedback and privacy links, and bundle version/build display.
- Reset remains limited to `resetDrafts()`, preserving the selected unit and app counters.

## TDD evidence

- RED: `KnittingCalculatorTests/KnitNoteLinkRouterTests.swift` failed because `KnitNoteLinkRouter` did not exist.
- RED: `KnittingCalculatorViewContractTests` failed because the Settings screen did not exist.
- RED: the separate-product/low-priority promotion contract failed before its card copy and bordered action were added.
- GREEN: routing, view, and localization contracts pass after implementation.

## Verification

- `xcodegen generate`
- `xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorTask7FinalPhone CODE_SIGNING_ALLOWED=NO`
- `xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -derivedDataPath /tmp/KnittingCalculatorTask7FinalPad CODE_SIGNING_ALLOWED=NO`
- `xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteTask7FinalScheme CODE_SIGNING_ALLOWED=NO`
- `swift test --filter KnittingCalculatorViewContractTests` (10 tests)
- `swift test --filter KnittingCalculatorLocalizationContractTests` (1 test)
- `git diff --check`

The simulator commands required host Simulator access after the sandbox could not connect to CoreSimulatorService; the elevated final run completed successfully. External App Store behavior is covered by the unit-testable route decision rather than opening an external store during tests.
