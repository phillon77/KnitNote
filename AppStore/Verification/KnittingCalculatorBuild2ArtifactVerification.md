# Knitting Calculator Build 2 artifact verification

Status: artifact gate and user-approved narrowed physical source/layout smoke
gate passed.

## Immutable provenance

- `BUILD_SOURCE_SHA`:
  `d73fbd1781773acf089e7e0d235c94a813807311`
- `SCREENSHOT_PACKAGE_SHA`:
  `319f0fa222081aaba6a0f1415576db810167d0de`
- Candidate source:
  `/tmp/knitting-calculator-build2-source`
- Candidate source was a clean detached worktree at the exact
  `BUILD_SOURCE_SHA` before tests, archive, export, and artifact inspection.
- Candidate tests:
  `xcodebuild test -project KnittingCalculator.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorBuild2Tests`
- Candidate test result: 23 XCTest tests and 7 Swift Testing tests passed,
  with zero failures.

## Artifact paths and hashes

- Restored archive:
  `/tmp/KnittingCalculatorBuild2/KnittingCalculator.xcarchive`
- Preserved pre-export archive backup:
  `/tmp/KnittingCalculatorBuild2/KnittingCalculator.failed-development-signing-20260731T052836Z.xcarchive`
- Exported IPA:
  `/tmp/KnittingCalculatorBuild2/Export/KnittingCalculator.ipa`
- Archive `Info.plist` SHA-256:
  `c881754ba34f9662d6785ccbe42ac7be624ae8e5a5efabbaad449022c1f168e4`
- IPA SHA-256:
  `96afcdbdbc5c6c8bbca86b5a978bf20a8c7495f6645d17f4d4f190bae986fce9`
- Archive embedded App executable SHA-256:
  `ef1c3d1641b13020364b9b7236356072c8eeafd282f64bad902c1b5ae341dc67`
- Archive embedded App `Info.plist` SHA-256:
  `5d48695f3ca2032cef987346b6074caa43bbd29bdc1df85d04ca640578b28bfa`

## Archive identity and disclosed signing exception

- Bundle identifier: `com.phillon.KnittingCalculator`
- Marketing version: `1.0.0`
- Build number: `2`
- Team: `9CFPAUL5N5`
- Archive signer class: Apple Development
- Archive entitlements:
  `get-task-allow=true`; `beta-reports-active` absent
- Archive creation date: `2026-07-31 13:18:18 Asia/Taipei`
- Xcode: `26.6` (`17F113`)

The archive audit reported:

```text
KNITTING CALCULATOR RELEASE AUDIT: STATIC PRODUCT SCOPE PASS
KNITTING CALCULATOR RELEASE AUDIT: ARCHIVE STRUCTURE PASS
KNITTING CALCULATOR RELEASE AUDIT: FAIL — embedded profile is missing beta-reports-active
```

The user selected the amended Option A contract: preserve and disclose the
Development-signed archive, while treating only the exported IPA as the
authoritative Distribution signing gate. The archive result above is not
represented as an App Store Distribution archive PASS.

## Export and authoritative IPA gate

`/tmp/KnittingCalculatorBuild2/ExportOptions.plist` was linted successfully
with the exact Task 6 values:

- destination: `export`
- method: `app-store-connect`
- signing style: `automatic`
- team: `9CFPAUL5N5`
- upload symbols: `true`

The export completed locally without upload or provisioning updates and
produced exactly one IPA. The explicit IPA audit reported:

```text
KNITTING CALCULATOR RELEASE AUDIT: STATIC PRODUCT SCOPE PASS
KNITTING CALCULATOR RELEASE AUDIT: IPA STRUCTURE PASS
KNITTING CALCULATOR RELEASE AUDIT: IPA RELEASE SIGNING PASS
KNITTING CALCULATOR RELEASE AUDIT: PASS
```

Independent inspection of the exported IPA confirmed:

- bundle/version/build: `com.phillon.KnittingCalculator`, `1.0.0 (2)`
- signer class: Apple Distribution
- team: `9CFPAUL5N5`
- `beta-reports-active=true`
- `get-task-allow=false`
- no `ProvisionedDevices` list

The Distribution IPA is not the physical smoke-test artifact. The physical
source/layout check must use a separately built Development-signed App from
the same clean detached `BUILD_SOURCE_SHA`.

## Development physical-smoke artifact

- App:
  `/tmp/KnittingCalculatorBuild2Development/Build/Products/Release-iphoneos/KnittingCalculator.app`
- Configuration: Release, signed for Development
- Bundle/version/build:
  `com.phillon.KnittingCalculator`, `1.0.0 (2)`
- Team: `9CFPAUL5N5`
- Signer class: Apple Development
- Profile contains a provisioned-device list.
- Executable SHA-256:
  `2aa6104b2553aa73fdf4439556dc15f3a231d8175599aa6008aa21fbb6cb0816`
- `Info.plist` SHA-256:
  `5d48695f3ca2032cef987346b6074caa43bbd29bdc1df85d04ca640578b28bfa`
- The detached source remained clean at the exact `BUILD_SOURCE_SHA` after
  this build.

This App is only the pre-upload source/layout smoke artifact. Its installation
or user acceptance cannot prove that the App Store Distribution IPA ran on a
physical device.

## Physical source/layout smoke

The verified Development-signed App was installed on:

- iPhone 17 Pro Max, iOS 26.6 (23G71);
- iPad Air (5th generation), iPadOS 26.5.2 (23F84).

Fresh Build 2 user observations passed for:

- exact `1.0.0 (2)` and full-screen launch on both devices;
- iPhone gauge: 10 cm / 20 stitches / 25 cm produces 50 stitches;
- iPhone single-row: current 50, target 62, preserve 1 stitch on each side,
  increase 12, no clipping;
- iPhone across-row: 20 rows / 6 stitches / increase / single side, final row
  20, 3–4 row intervals, no overlap or clipping.

The user approved this narrowed Build 2 scope because the calculator regression
had already passed and the later Task 5 source changes were DEBUG-only
screenshot scrolling plus manifest/tool evidence. The dated Build 1/TestFlight
rotation, lifecycle, installed KnitNote-link, no-permission, and broader
functional results remain supporting prior evidence; they are not represented
as fresh Build 2 observations.

## Boundary

- No upload, App Store Connect mutation, submit, publish, push, merge, or
  evidence commit was performed.
- Physical PASS is limited to the user-approved source/layout smoke scope
  documented above.
- No claim is made that the Apple Distribution IPA ran on either device.
