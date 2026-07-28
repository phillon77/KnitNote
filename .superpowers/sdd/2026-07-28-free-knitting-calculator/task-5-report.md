# Task 5 report: copy and share calculator results

## Scope delivered

- Added deterministic, localized plain-text payload builders for valid Gauge,
  one-row, and across-rows snapshots.
- Added accessible copy and system-share controls with 44-point hit targets.
- Wired actions only inside valid result views. Copy writes to `UIPasteboard` on
  iOS and does not update calculation-count state.
- Added only Task 5 English and Traditional Chinese catalog keys, plus catalog
  coverage and view-contract checks.
- Regenerated the Xcode project so the two new app files and new app-target
  XCTest are source members.

## TDD evidence

- RED: after regenerating XcodeGen membership, the requested app-target test
  command failed at compilation because `CalculatorShareText` and
  `CalculatorProductLinks` did not exist.
- GREEN compile evidence: generic-iOS `xcodebuild build-for-testing` completed
  with explicit `xcodebuild_exit=0`, compiling the new app-target XCTest source.

## Verification evidence

- `swift test --filter KnittingCalculatorLocalizationContractTests` — 1 test
  passed.
- `swift test --filter KnittingCalculatorViewContractTests` — 4 tests passed.
- `jq empty KnittingCalculator/Localization/Localizable.xcstrings` — passed.
- `git diff --check` — passed before commit.
- `xcodebuild build -quiet -project KnitNote.xcodeproj -scheme
  KnittingCalculator -destination 'generic/platform=iOS' -derivedDataPath
  /tmp/KnittingCalculatorShareBuild CODE_SIGNING_ALLOWED=NO` — explicit
  `xcodebuild_exit=0`.
- `xcodebuild build-for-testing -quiet -project KnitNote.xcodeproj -scheme
  KnittingCalculator -destination 'generic/platform=iOS' -derivedDataPath
  /tmp/KnittingCalculatorShareBuildForTesting CODE_SIGNING_ALLOWED=NO` —
  explicit `xcodebuild_exit=0`.

## Simulator debt

The requested iPhone simulator test was retried after implementation. It did
not run because `CoreSimulatorService` became invalid/refused connections, no
simulator runtime could be discovered, and `simdiskimaged` was not responding.
This is not treated as passing app-target execution. The generic-iOS build and
build-for-testing commands compile the final app and XCTest sources, but do not
replace simulator or physical-device acceptance.

## Self-review

- Shared output includes only the calculator title, entered values, result
  details, neutral step/schedule details where applicable, calculator
  attribution, and the free calculator landing-page URL. It excludes the
  existing KnitNote App Store URL and does not add a promotion or ad.
- Gauge actions appear with a valid stitch snapshot; optional row details are
  included only when that optional group is valid. One-row and across-rows
  actions appear only after their calculation succeeds.
- `CalculatorResultActions` owns no preferences or counting behavior; all three
  callers pass an empty success callback, so copy/share cannot double-count a
  valid calculation.
- The generated project changes are limited to the two app source files and
  the new XCTest membership.

## Review round 1: separate VoiceOver focus for result actions

- Review HEAD before this correction: `12d1529 feat: copy and share calculator results`.
- RED: `swift test --filter KnittingCalculatorViewContractTests` failed the new
  `adjustmentResultActionsRemainOutsideCombinedSummaryAccessibilityElement`
  contract for both one-row and across-rows results. The actions were children
  of a `VStack` marked `.accessibilityElement(children: .combine)`.
- GREEN: each successful adjustment result now contains a combined
  `resultSummaryView` and a sibling `CalculatorResultActions` view inside the
  same visual card. Copy and Share therefore retain their own VoiceOver focus.
  `swift test --filter KnittingCalculatorViewContractTests` passed 5 tests.
- Gauge was inspected and needs no change: its actions already sit in
  `gaugeCard` outside the combined `resultView`.
- Final generic-iOS compile evidence:
  `xcodebuild build -quiet -project KnitNote.xcodeproj -scheme
  KnittingCalculator -destination 'generic/platform=iOS' -derivedDataPath
  /tmp/KnittingCalculatorTask5Accessibility CODE_SIGNING_ALLOWED=NO` returned
  explicit `xcodebuild_exit=0`.
- Simulator execution remains unavailable for the existing CoreSimulatorService
  / `simdiskimaged` failure; this correction has no simulator-pass claim.
