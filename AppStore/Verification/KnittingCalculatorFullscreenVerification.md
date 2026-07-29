# Knitting Calculator full-screen verification

Verification date: 2026-07-29 (Asia/Taipei)

Candidate:

- Repair commit: `c943bd84edd1ed0978d2b0d073897faa10a69e17` (`fix: launch knitting calculator full screen`)
- Branch: `codex/knitting-calculator-fullscreen-fix`
- App: `com.phillon.KnittingCalculator`
- Version: `1.0.0`
- Build: `1`
- Device: `iPhone` — iPhone 17 Pro Max (`iPhone18,2`), iOS `26.5.2 (23F84)`
- CoreDevice identifier: `30C68657-A038-5548-A1C6-F9280C02D5FB` (available, paired)

## Executed device workflow

The following signed Debug device build used the existing local development
signing configuration; no signing, project, App Store, or release state was
changed.

```sh
xcodebuild -project KnitNote.xcodeproj \
  -scheme KnittingCalculator \
  -configuration Debug \
  -destination 'platform=iOS,id=30C68657-A038-5548-A1C6-F9280C02D5FB' \
  -derivedDataPath /tmp/KnittingCalculatorFullscreenDevice build
```

Result: exit `0`; `** BUILD SUCCEEDED **`. The processed app Info.plist reports
`com.phillon.KnittingCalculator`, version `1.0.0`, build `1`, and
`UILaunchStoryboardName = LaunchScreen`.

```sh
xcrun devicectl device install app \
  --device 30C68657-A038-5548-A1C6-F9280C02D5FB \
  /tmp/KnittingCalculatorFullscreenDevice/Build/Products/Debug-iphoneos/KnittingCalculator.app
xcrun devicectl device process launch \
  --device 30C68657-A038-5548-A1C6-F9280C02D5FB \
  com.phillon.KnittingCalculator
```

Results: both commands exited `0`. Installation reported bundle ID
`com.phillon.KnittingCalculator`; launch reported that the application was
launched.

## Screenshot capability

`xcrun devicectl device --help` exposes install, process, orientation, and
device-info commands, but no screenshot command. No `idevicescreenshot` tool
is installed. `xctrace` is present but does not provide a device-display
screenshot command. A subsequent `devicectl device info displays` attempt
could not complete because CoreDeviceService timed out while initializing;
therefore it provided neither display details nor a screenshot. No visual
acceptance has been inferred from install or launch output.

## Manual physical acceptance matrix

Status legend: `PASS` requires direct visual observation on the listed physical
iPhone. `PENDING` is not an acceptance result.

| Scenario | Status | Required handoff observation |
| --- | --- | --- |
| Clean launch fills from the top safe area to the bottom safe area | PENDING | Open the installed Calculator from a terminated state and confirm the app content reaches both safe-area edges. |
| No black compatibility bars | PENDING | On the clean launch, confirm no black letterboxing appears above, below, or beside the app. |
| Portrait fills the display | PENDING | Hold the iPhone in portrait and confirm the content fills the screen. |
| Landscape fills the display | PENDING | Rotate to landscape and confirm the content fills the screen. |
| Background and foreground remain full screen | PENDING | Background the app, return to it, and confirm full-screen presentation remains. |
| Terminate and reopen remain full screen | PENDING | Terminate the app, reopen it, and confirm full-screen presentation remains. |

## Integration gate

This evidence does not authorize cherry-picking into the original
`codex/free-knitting-calculator` worktree: every physical row above must be
directly observed as `PASS` first. That worktree's interrupted Task 12 files
must remain untouched until this gate is met.
