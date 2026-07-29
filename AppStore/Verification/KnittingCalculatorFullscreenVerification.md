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

The supplied screenshots were captured on the listed iPhone after the requested
clean terminate/reopen and rotation sequence:

- Portrait home: `/Users/longzhenzhong/Downloads/截圖 2026-07-29 15.18.14.png`
- Landscape adjustment screen: `/Users/longzhenzhong/Downloads/截圖 2026-07-29 15.18.37.png`

| Scenario | Status | Evidence |
| --- | --- | --- |
| Clean launch fills from the top safe area to the bottom safe area | PASS | User confirmed the requested clean terminate/reopen sequence; the portrait home screenshot fills the displayed iPhone area. |
| No black compatibility bars | PASS | The portrait screenshot shows no legacy black bars above, below, or beside the installed app. |
| Portrait fills the display | PASS | The portrait home screenshot shows the app filling the iPhone display. |
| Landscape fills the display | PASS | The landscape adjustment-screen screenshot shows the app filling the iPhone display after rotation. |
| Background and foreground remain full screen | PENDING | No screenshot or user observation covers a background-to-foreground transition. |
| Terminate and reopen remain full screen | PASS | User confirmed the requested clean terminate/reopen sequence; the resulting portrait screenshot shows full-screen presentation. |

## Integration gate

The current physical evidence authorizes integration of the narrow launch-screen
repair only. The background/foreground scenario remains a later manual check.
The original `codex/free-knitting-calculator` worktree's interrupted Task 12
files must remain untouched by that integration.
