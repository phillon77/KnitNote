# Knitting Calculator Full-Screen Launch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Knitting Calculator launch at the physical iPhone's full native
screen size by giving the free app target its own declared launch screen.

**Architecture:** Keep this repair isolated from the interrupted Task 12
worktree. Add one calculator-owned launch storyboard, declare it in the free
target's generated Info.plist, and enforce both declaration and target resource
membership with a focused project contract. Physical acceptance on the same
iPhone is the release gate.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, XcodeGen, Interface Builder
launch storyboard, xcodebuild, xcrun devicectl.

## Global Constraints

- The physical iPhone screenshot is the authoritative failure evidence.
- Do not change SwiftUI fonts, padding, safe-area behavior, or card sizes to
  mask the compatibility-mode presentation.
- The free target identity remains `com.phillon.KnittingCalculator`, version
  `1.0.0`, build `1`, iOS 18+, iPhone and iPad.
- The launch screen belongs only to the free app target and must not reference
  KnitNote-only images or resources.
- Preserve all interrupted Task 12 changes in the original
  `codex/free-knitting-calculator` worktree.
- Do not create an App Store Connect record, upload, submit, merge, or push.

---

### Task 1: Add a calculator-owned launch screen

**Files:**
- Create: `KnittingCalculator/LaunchScreen.storyboard`
- Modify: `project.yml`
- Modify: `Tests/KnitNoteCoreTests/KnittingCalculatorProjectContractTests.swift`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: XcodeGen target `KnittingCalculator`.
- Produces: `UILaunchStoryboardName = LaunchScreen` and calculator-only
  `LaunchScreen.storyboard` resource membership.

- [ ] **Step 1: Write the failing launch-screen contract**

Add this focused test to
`Tests/KnitNoteCoreTests/KnittingCalculatorProjectContractTests.swift`:

```swift
@Test func freeAppDeclaresItsOwnLaunchScreen() throws {
    let yaml = try source("project.yml")
    let calculatorTarget = try #require(
        yaml.split(separator: "  KnittingCalculatorTests:").first?
            .split(separator: "  KnittingCalculator:").last
    )
    let storyboard = try source("KnittingCalculator/LaunchScreen.storyboard")

    #expect(calculatorTarget.contains("UILaunchStoryboardName: LaunchScreen"))
    #expect(calculatorTarget.contains("- LaunchScreen.storyboard"))
    #expect(
        calculatorTarget.contains(
            "- path: KnittingCalculator/LaunchScreen.storyboard"
        )
    )
    #expect(storyboard.contains("launchScreen=\"YES\""))
    #expect(!storyboard.contains("FamilyKnittingHero"))
}
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
swift test --filter freeAppDeclaresItsOwnLaunchScreen
```

Expected: FAIL because `KnittingCalculator/LaunchScreen.storyboard` and the
free-target launch-screen declaration/resource entry do not exist.

- [ ] **Step 3: Create the minimal free-app launch storyboard**

Create `KnittingCalculator/LaunchScreen.storyboard` as a launch-screen document
with one autoresizing root view and no text or image dependency:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB"
          version="3.0"
          toolsVersion="24000"
          targetRuntime="iOS.CocoaTouch"
          propertyAccessControl="none"
          useAutolayout="YES"
          launchScreen="YES"
          useTraitCollections="YES"
          useSafeAreas="YES"
          colorMatched="YES"
          initialViewController="calculator-launch-view-controller">
    <device id="retina6_12" orientation="portrait" appearance="light"/>
    <dependencies>
        <deployment identifier="iOS"/>
        <plugIn identifier="com.apple.InterfaceBuilder.IBCocoaTouchPlugin"
                version="24000"/>
        <capability name="Safe area layout guides" minToolsVersion="9.0"/>
        <capability name="System colors in document resources"
                    minToolsVersion="11.0"/>
    </dependencies>
    <scenes>
        <scene sceneID="calculator-launch-scene">
            <objects>
                <viewController id="calculator-launch-view-controller"
                                sceneMemberID="viewController">
                    <view key="view"
                          contentMode="scaleToFill"
                          id="calculator-launch-view">
                        <rect key="frame" x="0.0" y="0.0"
                              width="393" height="852"/>
                        <autoresizingMask key="autoresizingMask"
                                          widthSizable="YES"
                                          heightSizable="YES"/>
                        <viewLayoutGuide key="safeArea"
                                         id="calculator-launch-safe-area"/>
                        <color key="backgroundColor"
                               systemColor="systemBackgroundColor"/>
                    </view>
                </viewController>
                <placeholder placeholderIdentifier="IBFirstResponder"
                             id="calculator-launch-first-responder"
                             userLabel="First Responder"
                             sceneMemberID="firstResponder"/>
            </objects>
        </scene>
    </scenes>
    <resources>
        <systemColor name="systemBackgroundColor">
            <color white="1" alpha="1" colorSpace="custom"
                   customColorSpace="genericGamma22GrayColorSpace"/>
        </systemColor>
    </resources>
</document>
```

- [ ] **Step 4: Declare the launch screen in the free target**

In `project.yml`, under `KnittingCalculator.info.properties`, add:

```yaml
        UILaunchStoryboardName: LaunchScreen
```

Exclude the storyboard from the broad source entry:

```yaml
          - LaunchScreen.storyboard
```

Add an explicit calculator-only resource:

```yaml
      - path: KnittingCalculator/LaunchScreen.storyboard
        buildPhase: resources
```

- [ ] **Step 5: Regenerate and verify GREEN**

Run:

```bash
xcodegen generate
swift test --filter freeAppDeclaresItsOwnLaunchScreen
plutil -lint KnittingCalculator/Info.plist
xcodebuild -project KnitNote.xcodeproj \
  -scheme KnittingCalculator \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/KnittingCalculatorFullscreenBuild \
  CODE_SIGNING_ALLOWED=NO build
```

Expected:

- focused contract passes;
- generated `KnittingCalculator/Info.plist` contains
  `UILaunchStoryboardName = LaunchScreen`;
- build exits 0;
- the previous missing-launch-screen warning is absent.

- [ ] **Step 6: Commit the repair**

```bash
git add project.yml \
  KnitNote.xcodeproj/project.pbxproj \
  KnittingCalculator/Info.plist \
  KnittingCalculator/LaunchScreen.storyboard \
  Tests/KnitNoteCoreTests/KnittingCalculatorProjectContractTests.swift
git commit -m "fix: launch knitting calculator full screen"
```

---

### Task 2: Physical iPhone acceptance and integration

**Files:**
- Create: `AppStore/Verification/KnittingCalculatorFullscreenVerification.md`
- Modify later in original worktree: interrupted Task 12 report/ledger only after
  the fix commit is applied there.

**Interfaces:**
- Consumes: signed Debug app built from Task 1.
- Produces: physical evidence that commit/build fills the complete iPhone
  display in all required launch states.

- [ ] **Step 1: Discover the same physical iPhone**

Run:

```bash
xcrun xcdevice list
xcrun devicectl list devices
```

Record the exact device name, identifier, iOS version, branch, commit, version,
and build.

- [ ] **Step 2: Build with the existing local signing configuration**

Run for the discovered iPhone 17 Pro Max:

```bash
xcodebuild -project KnitNote.xcodeproj \
  -scheme KnittingCalculator \
  -configuration Debug \
  -destination 'platform=iOS,id=30C68657-A038-5548-A1C6-F9280C02D5FB' \
  -derivedDataPath /tmp/KnittingCalculatorFullscreenDevice build
```

Expected: exit 0 without changing signing settings or creating external
profiles manually.

- [ ] **Step 3: Install and launch**

Run:

```bash
xcrun devicectl device install app \
  --device 30C68657-A038-5548-A1C6-F9280C02D5FB \
  /tmp/KnittingCalculatorFullscreenDevice/Build/Products/Debug-iphoneos/KnittingCalculator.app
xcrun devicectl device process launch \
  --device 30C68657-A038-5548-A1C6-F9280C02D5FB \
  com.phillon.KnittingCalculator
```

Expected: install and launch succeed.

- [ ] **Step 4: Record physical acceptance**

In `AppStore/Verification/KnittingCalculatorFullscreenVerification.md`, record
PASS or FAIL for:

- clean launch fills from the top safe area to the bottom safe area;
- no black compatibility bars;
- portrait fills the display;
- landscape fills the display;
- background and foreground remain full screen;
- terminate and reopen remain full screen.

Do not mark a row PASS without physical observation. Any discrepancy blocks
integration.

- [ ] **Step 5: Apply the verified commit to the original calculator branch**

After physical PASS, cherry-pick only the Task 1 repair commit into the original
`codex/free-knitting-calculator` worktree. Preserve its existing uncommitted
Task 12 files and resolve no unrelated changes.

Run there:

```bash
git status --short
git diff --check
swift test --filter freeAppDeclaresItsOwnLaunchScreen
```

Expected: Task 12 files remain present, the launch-screen contract passes, and
there are no unrelated modifications.

---

## Follow-up plan

After physical full-screen acceptance, write a separate implementation plan for
the approved independent `KnittingCalculator.xcodeproj` and shared calculator
Swift Package migration. Do not combine that migration with this urgent repair.
