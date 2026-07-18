# Focused Family Launch Camera Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the whole-image-only launch animation with a clearly visible four-second sequence focused first on the mother's knitting hands and then on Lemon's blink before entering the Projects hero.

**Architecture:** Add a deterministic platform-neutral timeline sampler to `KnitNoteCore`, then have SwiftUI sample it every animation frame for camera and local-motion values. Keep the complete original painting authoritative, use normalized focal points and feathered original-pixel masks, and retain the cancellation-safe coordinator and geometry-aware final transition.

**Tech Stack:** Swift 6, SwiftUI `TimelineView`, CoreGraphics, Swift Testing, XcodeGen, iOS 18+, macOS 15+, watchOS 11+ core compatibility.

## Global Constraints

- Normal playback is 4.0 seconds: hands 0.0–1.1, wide 1.1–1.8, Lemon 1.8–2.8, wide 2.8–3.4, home transition 3.4–4.0.
- Hand motion and Lemon's blink are required and visibly different at their extrema on iPhone.
- `FamilyKnittingHero` stays authoritative; do not redraw, regenerate, restyle, or replace its JPEG.
- Use feathered masks with no rectangular crop seams.
- Apply camera transforms to the complete painting in the same coordinate system as overlays.
- Tap-to-skip retains the 600 ms final transition; Reduce Motion omits zoom and local motion.
- Cold-launch-only, accessibility, localization, app data, and Apple Watch behavior remain unchanged.
- Preserve untracked `KnitNote 5.xcodeproj/` and `KnitNote 6.xcodeproj/`.

---

### Task 1: Deterministic Camera and Motion Timeline

**Files:**
- Create: `Sources/KnitNoteCore/Launch/FamilyLaunchTimeline.swift`
- Create: `Tests/KnitNoteCoreTests/FamilyLaunchTimelineTests.swift`
- Modify: `Sources/KnitNoteCore/Launch/LaunchExperienceState.swift`
- Modify: `Tests/KnitNoteCoreTests/LaunchExperienceStateTests.swift`

**Interfaces:**
- Consumes: elapsed milliseconds.
- Produces: `FamilyLaunchFrame` and `FamilyLaunchTimeline.frame(atMilliseconds:)` with normalized camera focus/zoom, signed hand progress, and blink progress.

- [ ] **Step 1: Write failing boundary tests**

```swift
import Testing
@testable import KnitNoteCore

@Test func familyLaunchUsesApprovedShotBoundaries() {
    #expect(FamilyLaunchTimeline.localSequenceMilliseconds == 3_100)
    #expect(FamilyLaunchTimeline.handsEndMilliseconds == 1_100)
    #expect(FamilyLaunchTimeline.firstWideEndMilliseconds == 1_800)
    #expect(FamilyLaunchTimeline.lemonEndMilliseconds == 2_800)
    #expect(FamilyLaunchTimeline.finalWideEndMilliseconds == 3_100)
    #expect(LaunchExperienceTiming.normalTotalMilliseconds == 4_000)
}

@Test func timelineStartsAndEndsWideAndStill() {
    let start = FamilyLaunchTimeline.frame(atMilliseconds: 0)
    let end = FamilyLaunchTimeline.frame(atMilliseconds: 3_100)
    #expect(start.cameraZoom == 1 && end.cameraZoom == 1)
    #expect(start.handProgress == 0 && end.handProgress == 0)
    #expect(start.blinkProgress == 0 && end.blinkProgress == 0)
}
```

- [ ] **Step 2: Run RED**

Run `swift test --disable-sandbox --filter FamilyLaunchTimelineTests`.

Expected: compilation fails because the timeline types do not exist and total time is still 2,600 ms.

- [ ] **Step 3: Add failing visibility tests**

```swift
@Test func handsShotFocusesHandsAndHasTwoExtrema() {
    let a = FamilyLaunchTimeline.frame(atMilliseconds: 450)
    let b = FamilyLaunchTimeline.frame(atMilliseconds: 650)
    #expect(a.cameraZoom >= 2.0)
    #expect(a.cameraFocusX == FamilyLaunchTimeline.handsFocusX)
    #expect(abs(a.handProgress - b.handProgress) >= 1.5)
    #expect(a.blinkProgress == 0)
}

@Test func lemonShotFocusesLemonAndCompletesOneBlink() {
    let open = FamilyLaunchTimeline.frame(atMilliseconds: 2_150)
    let closed = FamilyLaunchTimeline.frame(atMilliseconds: 2_420)
    let reopened = FamilyLaunchTimeline.frame(atMilliseconds: 2_650)
    #expect(closed.cameraZoom >= 2.5)
    #expect(closed.cameraFocusX == FamilyLaunchTimeline.lemonFocusX)
    #expect(open.blinkProgress == 0)
    #expect(closed.blinkProgress == 1)
    #expect(reopened.blinkProgress == 0)
}

@Test func timelineClampsElapsedTime() {
    #expect(FamilyLaunchTimeline.frame(atMilliseconds: -1) == FamilyLaunchTimeline.frame(atMilliseconds: 0))
    #expect(FamilyLaunchTimeline.frame(atMilliseconds: 99_000) == FamilyLaunchTimeline.frame(atMilliseconds: 3_100))
}
```

- [ ] **Step 4: Implement the sampler and exact timing**

```swift
public struct FamilyLaunchFrame: Sendable, Equatable {
    public let cameraZoom: Double
    public let cameraFocusX: Double
    public let cameraFocusY: Double
    public let handProgress: Double
    public let blinkProgress: Double
}

public enum FamilyLaunchTimeline {
    public static let handsEndMilliseconds = 1_100
    public static let firstWideEndMilliseconds = 1_800
    public static let lemonEndMilliseconds = 2_800
    public static let finalWideEndMilliseconds = 3_100
    public static let localSequenceMilliseconds = finalWideEndMilliseconds
    public static let handsFocusX = 0.345
    public static let handsFocusY = 0.425
    public static let lemonFocusX = 0.665
    public static let lemonFocusY = 0.755

    public static func frame(atMilliseconds elapsed: Int) -> FamilyLaunchFrame {
        let time = min(max(elapsed, 0), localSequenceMilliseconds)
        let camera: (zoom: Double, x: Double, y: Double)
        switch time {
        case ..<250:
            let p = smooth(Double(time) / 250)
            camera = (mix(1, 2.2, p), mix(0.5, handsFocusX, p), mix(0.5, handsFocusY, p))
        case 250..<900:
            camera = (2.2, handsFocusX, handsFocusY)
        case 900..<1_100:
            let p = smooth(Double(time - 900) / 200)
            camera = (mix(2.2, 1, p), mix(handsFocusX, 0.5, p), mix(handsFocusY, 0.5, p))
        case 1_100..<1_800:
            camera = (1, 0.5, 0.5)
        case 1_800..<2_050:
            let p = smooth(Double(time - 1_800) / 250)
            camera = (mix(1, 2.7, p), mix(0.5, lemonFocusX, p), mix(0.5, lemonFocusY, p))
        case 2_050..<2_700:
            camera = (2.7, lemonFocusX, lemonFocusY)
        case 2_700..<2_800:
            let p = smooth(Double(time - 2_700) / 100)
            camera = (mix(2.7, 1, p), mix(lemonFocusX, 0.5, p), mix(lemonFocusY, 0.5, p))
        default:
            camera = (1, 0.5, 0.5)
        }

        let hand: Double
        switch time {
        case 250..<450: hand = mix(0, 1, smooth(Double(time - 250) / 200))
        case 450..<650: hand = mix(1, -1, smooth(Double(time - 450) / 200))
        case 650..<850: hand = mix(-1, 1, smooth(Double(time - 650) / 200))
        case 850..<900: hand = mix(1, 0, smooth(Double(time - 850) / 50))
        default: hand = 0
        }

        let blink: Double
        switch time {
        case 2_250..<2_420: blink = smooth(Double(time - 2_250) / 170)
        case 2_420..<2_580: blink = 1 - smooth(Double(time - 2_420) / 160)
        default: blink = 0
        }

        return FamilyLaunchFrame(
            cameraZoom: camera.zoom,
            cameraFocusX: camera.x,
            cameraFocusY: camera.y,
            handProgress: hand,
            blinkProgress: blink
        )
    }

    private static func mix(_ from: Double, _ to: Double, _ progress: Double) -> Double {
        from + ((to - from) * progress)
    }

    private static func smooth(_ progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        return p * p * (3 - (2 * p))
    }
}
```

Set reveal to 300 ms, local animation to 2,800 ms, settling to 300 ms, and home transition to 600 ms. Their total is exactly 4,000 ms, and local animation plus settling equals the timeline's 3,100 ms.

- [ ] **Step 5: Verify GREEN and regression suite**

Run `swift test --disable-sandbox --filter FamilyLaunchTimelineTests`, then `swift test --disable-sandbox`.

Expected: new tests and the full suite pass; the old `2_600` assertion is updated to `4_000`.

- [ ] **Step 6: Commit**

```bash
git add Sources/KnitNoteCore/Launch/FamilyLaunchTimeline.swift Sources/KnitNoteCore/Launch/LaunchExperienceState.swift Tests/KnitNoteCoreTests/FamilyLaunchTimelineTests.swift Tests/KnitNoteCoreTests/LaunchExperienceStateTests.swift
git commit -m "Add focused family launch timeline"
```

---

### Task 2: Frame-Driven Complete-Painting Camera

**Files:**
- Modify: `KnitNote/Launch/FamilyLaunchAnimationView.swift`
- Modify: `Tests/KnitNoteCoreTests/LaunchExperienceStateTests.swift`

**Interfaces:**
- Consumes: timeline frames, launch phase, and Reduce Motion.
- Produces: a 60 fps complete-painting camera transform that resets outside the local sequence and remains nested inside the final hero transition.

- [ ] **Step 1: Add a failing source-contract test**

```swift
@Test func launchViewSamplesTheTimelineEveryAnimationFrame() throws {
    let source = try launchAnimationSource()
    #expect(source.contains("TimelineView(.animation"))
    #expect(source.contains("FamilyLaunchTimeline.frame(atMilliseconds:"))
    #expect(source.contains("cameraTransform(frame:"))
    #expect(!source.contains("blinkProgress = 1"))
}
```

Extract the existing repository path lookup into `launchAnimationSource()` so source tests share it.

- [ ] **Step 2: Run RED**

Run `swift test --disable-sandbox --filter launchViewSamplesTheTimelineEveryAnimationFrame`.

Expected: FAIL because the current implementation uses a task-driven blink and no frame timeline.

- [ ] **Step 3: Implement frame sampling and camera geometry**

When `.animating` begins, store reference-date milliseconds. Use:

```swift
TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                        paused: phase != .animating && phase != .settling)) { context in
    let elapsed = elapsedMilliseconds(at: context.date)
    let frame = reduceMotion
        ? FamilyLaunchTimeline.frame(atMilliseconds: 0)
        : FamilyLaunchTimeline.frame(atMilliseconds: elapsed)
    cameraPainting(size: canvasSize, frame: frame)
}
```

Transform the complete layered painting with:

```swift
private func cameraTransform(frame: FamilyLaunchFrame, size: CGSize) -> (CGFloat, CGSize) {
    let scale = CGFloat(frame.cameraZoom)
    return (scale, CGSize(
        width: (0.5 - frame.cameraFocusX) * size.width * scale,
        height: (0.5 - frame.cameraFocusY) * size.height * scale
    ))
}
```

Keep `PaintingCompositeTransition` outside this transform so final alignment still uses the live hero frame.

- [ ] **Step 4: Verify tests and builds**

Run:

```bash
swift test --disable-sandbox
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteFocusedLaunch CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteFocusedLaunchMac CODE_SIGNING_ALLOWED=NO build
```

Expected: all tests pass and both builds report `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add KnitNote/Launch/FamilyLaunchAnimationView.swift Tests/KnitNoteCoreTests/LaunchExperienceStateTests.swift
git commit -m "Animate focused family launch camera"
```

---

### Task 3: Feathered Hand Motion and Visible Lemon Blink

**Files:**
- Modify: `Sources/KnitNoteCore/Launch/FamilyLaunchTimeline.swift`
- Modify: `KnitNote/Launch/PaintingOverlayRegion.swift`
- Modify: `KnitNote/Launch/FamilyLaunchAnimationView.swift`
- Create: `Tests/KnitNoteCoreTests/PaintingOverlayMotionTests.swift`

**Interfaces:**
- Consumes: signed hand progress, blink progress, normalized regions, and original image pixels.
- Produces: `PaintingOverlayMotion`, feathered hands/needles movement, and eye-cover plus eye-compression layers.

- [ ] **Step 1: Write failing motion tests**

```swift
import Testing
@testable import KnitNoteCore

@Test func handExtremaAreVisibleAndRestIsExact() {
    let left = PaintingOverlayMotion(handProgress: -1, blinkProgress: 0)
    let right = PaintingOverlayMotion(handProgress: 1, blinkProgress: 0)
    let rest = PaintingOverlayMotion(handProgress: 0, blinkProgress: 0)
    #expect(right.handsRotationDegrees - left.handsRotationDegrees >= 2.4)
    #expect(right.handsVerticalTravel - left.handsVerticalTravel >= 3.0)
    #expect(rest.handsRotationDegrees == 0 && rest.handsVerticalTravel == 0)
}

@Test func closedBlinkIsReadableOnPhone() {
    let open = PaintingOverlayMotion(handProgress: 0, blinkProgress: 0)
    let closed = PaintingOverlayMotion(handProgress: 0, blinkProgress: 1)
    #expect(open.eyeCoverOpacity == 0)
    #expect(closed.eyeCoverOpacity == 1)
    #expect(closed.eyeScaleY <= 0.12)
}
```

- [ ] **Step 2: Run RED**

Run `swift test --disable-sandbox --filter PaintingOverlayMotionTests`.

Expected: compilation fails because this testable motion model does not exist.

- [ ] **Step 3: Implement clamped motion values**

```swift
public struct PaintingOverlayMotion: Sendable, Equatable {
    public let handsRotationDegrees: Double
    public let handsVerticalTravel: Double
    public let needleCounterRotationDegrees: Double
    public let eyeCoverOpacity: Double
    public let eyeScaleY: Double

    public init(handProgress: Double, blinkProgress: Double) {
        let hand = min(max(handProgress, -1), 1)
        let blink = min(max(blinkProgress, 0), 1)
        handsRotationDegrees = 1.4 * hand
        handsVerticalTravel = 1.8 * hand
        needleCounterRotationDegrees = -0.7 * hand
        eyeCoverOpacity = blink
        eyeScaleY = 1 - 0.9 * blink
    }
}
```

- [ ] **Step 4: Implement feathered original-pixel layers**

Use a SwiftUI `Canvas` alpha mask made from overlapping blurred ellipses around the two hands and needles, with a 12–18% feather rather than a rectangle. Apply canvas-relative travel and rotation, then `compositingGroup()` before camera scaling.

For Lemon, move original pixels immediately above the eyes into the eye region through a feathered capsule mask, and vertically compress the original eye pixels to `eyeScaleY`. Blend both using `eyeCoverOpacity` above the unchanged base painting.

- [ ] **Step 5: Add a regression contract preventing removal of local motion**

```swift
@Test func launchCannotRegressToWholeImageOnlyMotion() throws {
    let source = try launchAnimationSource()
    #expect(source.contains("featheredHandsMask"))
    #expect(source.contains("originalPixelOverlay(region: .handsAndYarn"))
    #expect(source.contains("sourceRegion: .lemonEyeCoverSource"))
    #expect(source.contains("motion.eyeScaleY"))
}
```

- [ ] **Step 6: Verify full suite and platforms**

Run `swift test --disable-sandbox`, iOS and macOS build commands from Task 2, then:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -destination 'generic/platform=watchOS Simulator' -derivedDataPath /tmp/KnitNoteFocusedLaunchWatch CODE_SIGNING_ALLOWED=NO build
```

Expected: tests pass and installed platform components build. If the Watch runtime is missing, record the exact Xcode error and confirm the coordinator remains excluded from Watch in `project.yml`.

- [ ] **Step 7: Commit**

```bash
git add Sources/KnitNoteCore/Launch/FamilyLaunchTimeline.swift KnitNote/Launch/PaintingOverlayRegion.swift KnitNote/Launch/FamilyLaunchAnimationView.swift Tests/KnitNoteCoreTests/PaintingOverlayMotionTests.swift Tests/KnitNoteCoreTests/LaunchExperienceStateTests.swift
git commit -m "Animate knitting hands and Lemon blink"
```

---

### Task 4: Simulator Video and Frame-Difference Acceptance

**Files:**
- Modify only when acceptance first exposes a reproducible defect: the corresponding Task 1–3 source and test files.
- Preserve byte-for-byte: `KnitNote/Assets.xcassets/FamilyKnittingHero.imageset/family-knitting-hero.jpg`.

**Interfaces:**
- Consumes: built app and booted iPhone/iPad simulators.
- Produces: objective frame evidence and acceptance results; no permanent diagnostic code.

- [ ] **Step 1: Record the artwork hash**

Run `shasum -a 256 KnitNote/Assets.xcassets/FamilyKnittingHero.imageset/family-knitting-hero.jpg` and retain the value for the final comparison.

- [ ] **Step 2: Record an iPhone cold launch**

Use the available iPhone 17 Pro Max simulator `15AE99B6-14AF-4BCE-BBD9-0007899F5590`: build and install, terminate the app, start `xcrun simctl io 15AE99B6-14AF-4BCE-BBD9-0007899F5590 recordVideo /tmp/knitnote-focused-launch-phone.mp4`, launch `com.example.KnitNote`, wait 4.5 seconds, and stop recording. If that simulator was deleted, select the first available iPhone from `xcrun simctl list devices available` and record its replacement identifier in the acceptance notes before continuing.

- [ ] **Step 3: Compare exact frames**

Extract frames near 0.55, 0.90, 1.50, 2.15, 2.42, 2.65, 3.10, and 3.80 seconds. Confirm the two hand frames differ visibly; 1.50 and 3.10 are wide; Lemon dominates at 2.42; open/closed/reopened eye pixels differ; no hard crop edge or ghost appears; and 3.80 converges on the hero.

- [ ] **Step 4: Repeat iPad portrait and landscape acceptance**

Confirm focal subjects stay on-screen, safe areas have no black bands, rotation creates no stale offset, and final hero alignment remains exact.

- [ ] **Step 5: Verify interaction and accessibility**

Test skip during both close-ups, Reduce Motion with no transforms, background/foreground without replay, and exactly one localized family-art accessibility element.

- [ ] **Step 6: Run final verification**

```bash
swift test --disable-sandbox
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteFocusedLaunchFinal CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteFocusedLaunchFinalMac CODE_SIGNING_ALLOWED=NO build
git diff --check
shasum -a 256 KnitNote/Assets.xcassets/FamilyKnittingHero.imageset/family-knitting-hero.jpg
```

Expected: all tests pass, both builds succeed, diff check is silent, and the image hash is unchanged.

- [ ] **Step 7: Correct only demonstrated defects**

For each defect, first add one failing regression test, verify RED, implement the smallest fix, and verify GREEN. If no defect appears, create no empty commit.
