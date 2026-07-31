# Knitting Calculator Build 2 screenshot verification

Date: 2026-07-31

## Provenance

- Screenshot-host source (`BUILD_SOURCE_SHA`):
  `d73fbd1781773acf089e7e0d235c94a813807311`
- Source commit: `fix: center screenshot result actions`
- Screenshot manifest SHA-256:
  `6b81ae0033660c0461fe4cb9e00ef2131de630c11afbbfe4825065862f073809`
- Screenshot host:
  `/tmp/KnittingCalculatorBuild2Screenshots/Build/Products/Debug-iphonesimulator/KnittingCalculator.app`
- Manifest runtime:
  `com.apple.CoreSimulator.SimRuntime.iOS-26-5`
- Dedicated phone:
  `Knitting Calculator Store iPhone`
  (`com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max`)
- Dedicated tablet:
  `Knitting Calculator Store iPad`
  (`com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB`)

No simulator UDID or other private device identifier is recorded in this
document.

## Source correction and release gates

Full-resolution review of the first package found the adjustment scene's real
Copy and Share actions clipped at the lower boundary. A failing screenshot-mode
contract test was added first. The smallest correction changes only the DEBUG
screenshot scroll target to the center of the real result actions; the Release
view hierarchy and Release initializers are unchanged.

The red test failed before the correction, then the renewed gates at
`BUILD_SOURCE_SHA` passed:

- screenshot-mode iOS tests: 7/7;
- focused Swift tests: 2/2;
- screenshot-tool tests: 27/27;
- project contract tests: 13/13;
- metadata tests: 5/5 and metadata check PASS;
- public-site tests: 2/2 and site check PASS;
- calculator release-audit tests: 23/23 and static audit PASS;
- shell syntax, Python byte-compilation, and unsigned Release build;
- source-diff and whitespace checks.

The final focused iOS result bundle was:

`/tmp/KnittingCalculatorTask5FinalCenterGates/Logs/Test/Test-KnittingCalculator-2026.07.31_11-56-52-+0800.xcresult`

## Build and capture

The DEBUG host was built from the exact source above:

```bash
xcodebuild -project KnittingCalculator.xcodeproj \
  -scheme KnittingCalculator \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/KnittingCalculatorBuild2Screenshots \
  CODE_SIGNING_ALLOWED=NO build
```

The two dedicated simulator identifiers were exported only in the local shell.
Their values were not written to this document or the repository. The checked-in
capture script was run unchanged:

```bash
export CALC_IPHONE_UDID='<dedicated store iPhone identifier>'
export CALC_IPAD_UDID='<dedicated store iPad identifier>'
export SCREENSHOT_SETTLE_SECONDS=10

CALC_SCREENSHOT_APP=/tmp/KnittingCalculatorBuild2Screenshots/Build/Products/Debug-iphonesimulator/KnittingCalculator.app \
  AppStore/KnittingCalculator/Screenshots/capture.sh zh-Hant

CALC_SCREENSHOT_APP=/tmp/KnittingCalculatorBuild2Screenshots/Build/Products/Debug-iphonesimulator/KnittingCalculator.app \
  AppStore/KnittingCalculator/Screenshots/capture.sh en
```

Capture produced nine fresh Raw frames per locale. The approved output
dimensions are 1284 x 2778 for iPhone and 2064 x 2752 for iPad.

### Recovery record

The first fresh English package contained an Apple Intelligence notification
overlay on `en/iphone/02-gauge.png`. The complete failed English Raw and
Generated sets were preserved outside the repository, and the whole English
locale was recaptured rather than splicing a frame.

The first recovery run used a 900-second outer bound. Simulator data migration
exhausted that bound during iPad boot before frame 1, so it left zero English
Raw or Generated frames and no residual capture or boot-status process. The
zh-Hant Raw hash list remained byte-identical. After cleanly shutting down the
dedicated simulators, the same unchanged capture script was rerun with a
measured 1800-second outer bound and completed all nine English frames. The
longer bound changes only orchestration time; `SCREENSHOT_SETTLE_SECONDS=10`
was the sole runtime capture override.

## Composition and validation

Composition was serialized and run twice from the final Raw inputs:

```bash
python3 AppStore/KnittingCalculator/Screenshots/compose.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json

find AppStore/KnittingCalculator/Screenshots/Generated \
  -type f -name '*.png' -exec shasum -a 256 {} + | sort

python3 AppStore/KnittingCalculator/Screenshots/compose.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json

python3 AppStore/KnittingCalculator/Screenshots/validate.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json
```

The two complete hash lists matched exactly (20/20 files: 18 deliverables plus
two local contact sheets). The validator reported `18 screenshots valid`.

## Approved output hashes

The following SHA-256 values cover only the 18 tracked App Store deliverables;
the two local contact sheets are intentionally excluded.

```text
c13ae2e6f2115dc7de66aff23044944e46e8b696b0031fe921a2d9662dfb1352  AppStore/KnittingCalculator/Screenshots/Generated/en/ipad/01-home.png
2c692f619b1068f8614eaab53fc44dac52013be884cd2cdfde0391060048a110  AppStore/KnittingCalculator/Screenshots/Generated/en/ipad/02-gauge.png
507b42e02cbbf4de5c1f9186c250b72facc9e76eac059bbfccd929d94e519b4f  AppStore/KnittingCalculator/Screenshots/Generated/en/ipad/03-adjustment.png
5b8cbc0925232d4e033e66b664e939e6a47838cb191e3a434e6e115db10663ff  AppStore/KnittingCalculator/Screenshots/Generated/en/ipad/04-privacy-knitnote.png
27e385813c45b2d47e82debf674ac84a8029213d2a4f1405a1cbad30019a8cc2  AppStore/KnittingCalculator/Screenshots/Generated/en/iphone/01-home.png
2da78e8c54c946e5766667e3710aad4c25d0e490d4eee4f37bd6da3fb898a366  AppStore/KnittingCalculator/Screenshots/Generated/en/iphone/02-gauge.png
5a2b0f5b0706527bd230d427e6aa05da22af566db82efe8305be6f2c01642c6e  AppStore/KnittingCalculator/Screenshots/Generated/en/iphone/03-adjustment.png
bc3b073ffe21f5d28f6ea710dd2c661c8756e4565cf4e26747dafc8c424b16e1  AppStore/KnittingCalculator/Screenshots/Generated/en/iphone/04-privacy.png
ea2612e319ae5e5c034aaaaebb32194208950f523d566be82504927937bcf222  AppStore/KnittingCalculator/Screenshots/Generated/en/iphone/05-knitnote.png
539424f859d45d597a109852fa8b78b83aee15d9d97e8f4d40e16ec6d8b11f0f  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/ipad/01-home.png
1cb60739abe490a08351f65e7539f2603628467937911a0480690c67c256307d  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/ipad/02-gauge.png
b3a3e7de3bd79e4662aae9ea35d6af7d51cefa8f7a1f8edf7ef238e7de2195bc  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/ipad/03-adjustment.png
1cb22be07a7f9ef06eec4165171ac9c8bc241b12c9adc877ba2b3157a2593288  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/ipad/04-privacy-knitnote.png
9e76490abb566c2e78fd05d96273874e8e108c6b5b6ca12434582b81d35995ac  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/iphone/01-home.png
03214d9a56a4ae1d028cc78f103ab6a320901447c50ff2e41eed62ae1adaa60d  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/iphone/02-gauge.png
5fb95fc1a71ef8f4b65b1c0f2af5826730d1671c1357d865b7a1b8206da24634  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/iphone/03-adjustment.png
5127a5f38037a3e93e5928f7fa25df21c26c9f86951d6e585e01f824b851c3a8  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/iphone/04-privacy.png
61cffa4e6929e0304fffb2e6d1820763ba0a5de0737b69733a5c636d56e70406  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/iphone/05-knitnote.png
```

## Full-resolution visual acceptance

PASS: both local contact sheets and all 18 individual PNGs were inspected at
full resolution.

- English and Traditional Chinese copy, locale punctuation, device family,
  scene order, and dimensions are correct.
- No text is clipped. No half-screen layout, live date, debug label, private
  identifier, notification, or system overlay is visible.
- Home and Settings use the normal Release hierarchy and retain the real
  KnitNote promotion content.
- The first four frames do not visually foreground KnitNote; the final
  promotion frame identifies KnitNote as a separate App.
- Gauge and adjustment results are readable. Increase/Decrease and One
  side/Both sides are distinct, and Copy/Share actions are fully visible.

The contact sheets remain available for local review but are not part of the
tracked screenshot package.
