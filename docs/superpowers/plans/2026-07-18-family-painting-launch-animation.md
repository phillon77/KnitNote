# Family Painting Launch Animation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 2.6-second cold-launch experience in which the original family knitting painting gently animates, returns to the untouched still artwork, and moves into the Projects home hero position.

**Architecture:** Keep deterministic launch phases in `KnitNoteCore`, drive their timing through a small main-actor coordinator, and render the original `FamilyKnittingHero` pixels through SwiftUI masks rather than generating new artwork. The normal home screen loads underneath an overlay and reports its live hero frame upward, allowing normal completion and tap-to-skip to converge on the same geometry-aware transition.

**Tech Stack:** Swift 6, SwiftUI, Observation/Combine, CoreGraphics geometry, Swift Testing, XcodeGen.

## Global Constraints

- Play on every cold launch of iPhone, iPad, and Mac, but not when returning from the background.
- Leave Apple Watch launch behavior unchanged.
- Normal playback lasts approximately 2.6 seconds and remains silent, with no logo or launch text.
- A tap anywhere skips through the same final home transition.
- Reduce Motion removes all local object motion and uses opacity-only reveal before entering home.
- `FamilyKnittingHero` remains the authoritative image; do not redraw, regenerate, restyle, or reinterpret it.
- Missing optional animation layers must fall back to the complete still painting and must never block the app.
- Root project, pattern, note, photo, localization, and Watch behavior must remain unchanged.
- Preserve the user's untracked `KnitNote 5.xcodeproj/` and `KnitNote 6.xcodeproj/` directories.

---

### Task 1: Deterministic Launch Phase State

**Files:**
- Create: `Sources/KnitNoteCore/Launch/LaunchExperienceState.swift`
- Create: `Tests/KnitNoteCoreTests/LaunchExperienceStateTests.swift`

**Interfaces:**
- Produces: `LaunchExperiencePhase`, `LaunchExperienceState`, `advance()`, and `skip()`.
- Consumes: no UI framework or persistent storage.

- [ ] **Step 1: Write failing phase tests**

```swift
import Testing
@testable import KnitNoteCore

@Test func normalLaunchVisitsEveryPhaseOnce() {
    var state = LaunchExperienceState(reduceMotion: false)
    #expect(state.phase == .revealing)
    state.advance(); #expect(state.phase == .animating)
    state.advance(); #expect(state.phase == .settling)
    state.advance(); #expect(state.phase == .enteringHome)
    state.advance(); #expect(state.phase == .complete)
    state.advance(); #expect(state.phase == .complete)
}

@Test func reduceMotionOmitsLocalObjectMotion() {
    var state = LaunchExperienceState(reduceMotion: true)
    #expect(state.phase == .revealing)
    state.advance(); #expect(state.phase == .enteringHome)
    state.advance(); #expect(state.phase == .complete)
}

@Test func skipIsIdempotentAndConvergesThroughHomeTransition() {
    var state = LaunchExperienceState(reduceMotion: false)
    state.skip(); #expect(state.phase == .enteringHome)
    state.skip(); #expect(state.phase == .enteringHome)
    state.advance(); #expect(state.phase == .complete)
    state.skip(); #expect(state.phase == .complete)
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build --filter LaunchExperienceStateTests
```

Expected: compilation fails because `LaunchExperienceState` and `LaunchExperiencePhase` do not exist.

- [ ] **Step 3: Implement the pure state reducer**

```swift
public enum LaunchExperiencePhase: Sendable, Equatable {
    case revealing
    case animating
    case settling
    case enteringHome
    case complete
}

public struct LaunchExperienceState: Sendable, Equatable {
    public private(set) var phase: LaunchExperiencePhase = .revealing
    public let reduceMotion: Bool

    public init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    public mutating func advance() {
        switch phase {
        case .revealing:
            phase = reduceMotion ? .enteringHome : .animating
        case .animating:
            phase = .settling
        case .settling:
            phase = .enteringHome
        case .enteringHome:
            phase = .complete
        case .complete:
            break
        }
    }

    public mutating func skip() {
        guard phase != .complete else { return }
        phase = .enteringHome
    }
}
```

- [ ] **Step 4: Run focused and full tests**

Run the focused command above, followed by:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build
```

Expected: all launch tests and the existing 43 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/KnitNoteCore/Launch/LaunchExperienceState.swift Tests/KnitNoteCoreTests/LaunchExperienceStateTests.swift
git commit -m "Add launch animation phase state"
```

---

### Task 2: Timed Coordinator with Cancellation-Safe Skip

**Files:**
- Create: `KnitNote/App/LaunchExperienceCoordinator.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `LaunchExperienceState` from Task 1.
- Produces: `@MainActor LaunchExperienceCoordinator`, published `phase`, `start(reduceMotion:)`, `skip()`, `homeOpacity`, and `showsOverlay`.

- [ ] **Step 1: Add coordinator timing constants and implementation**

Create a coordinator that holds exactly one playback task and never restarts after `start` has been called:

```swift
import SwiftUI

@MainActor
final class LaunchExperienceCoordinator: ObservableObject {
    @Published private(set) var phase: LaunchExperiencePhase = .revealing
    private var state: LaunchExperienceState?
    private var playbackTask: Task<Void, Never>?
    private var didStart = false

    var showsOverlay: Bool { phase != .complete }
    var homeOpacity: Double { phase == .enteringHome || phase == .complete ? 1 : 0 }

    func start(reduceMotion: Bool) {
        guard !didStart else { return }
        didStart = true
        state = LaunchExperienceState(reduceMotion: reduceMotion)
        phase = .revealing
        playbackTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            advance()
            if reduceMotion {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                advance()
                return
            }
            try? await Task.sleep(for: .milliseconds(1_400))
            guard !Task.isCancelled else { return }
            advance()
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            advance()
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            advance()
        }
    }

    func skip() {
        guard phase != .complete && phase != .enteringHome else { return }
        playbackTask?.cancel()
        state?.skip()
        publishState()
        playbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }

    private func advance() {
        state?.advance()
        publishState()
    }

    private func publishState() {
        if let state { phase = state.phase }
    }
}
```

- [ ] **Step 2: Regenerate and compile the app target**

Run:

```bash
xcodegen generate
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteLaunchCoordinator CODE_SIGNING_ALLOWED=NO build
```

Expected: `BUILD SUCCEEDED`; no UIKit reference appears in the Mac compilation.

- [ ] **Step 3: Review lifecycle invariants**

Confirm directly in `LaunchExperienceCoordinator.swift` that `didStart` is set before creating the task, `skip()` cancels the active task, every sleep checks cancellation, and `.complete` cannot transition backward.

- [ ] **Step 4: Commit**

```bash
git add KnitNote/App/LaunchExperienceCoordinator.swift KnitNote.xcodeproj/project.pbxproj project.yml
git commit -m "Add cold launch animation coordinator"
```

---

### Task 3: Original-Pixel Living Painting View

**Files:**
- Create: `KnitNote/Launch/FamilyLaunchAnimationView.swift`
- Create: `KnitNote/Launch/PaintingOverlayRegion.swift`
- Modify: `KnitNote/Assets.xcassets/FamilyKnittingHero.imageset/Contents.json` only if Xcode changes image metadata during verification; do not replace the JPEG.

**Interfaces:**
- Consumes: `LaunchExperiencePhase`, Reduce Motion behavior from the coordinator, and the existing `FamilyKnittingHero` image.
- Produces: `FamilyLaunchAnimationView(phase:destinationFrame:)` and normalized `PaintingOverlayRegion` values.

- [ ] **Step 1: Define normalized overlay regions without creating new artwork**

```swift
import CoreGraphics

struct PaintingOverlayRegion: Sendable, Equatable {
    let rect: CGRect

    static let handsAndYarn = PaintingOverlayRegion(
        rect: CGRect(x: 0.30, y: 0.32, width: 0.12, height: 0.21)
    )
    static let lemonEars = PaintingOverlayRegion(
        rect: CGRect(x: 0.61, y: 0.68, width: 0.10, height: 0.17)
    )
    static let yarnBall = PaintingOverlayRegion(
        rect: CGRect(x: 0.64, y: 0.72, width: 0.17, height: 0.27)
    )
}
```

Each overlay renders the same `FamilyKnittingHero` image at the same aspect-fit canvas size, then clips to its normalized region. Do not save modified raster output.

- [ ] **Step 2: Implement the layered painting**

Build `FamilyLaunchAnimationView` from:

- one authoritative full-image base layer;
- an `originalPixelOverlay(region:)` helper that duplicates the same image and masks it to a normalized rectangle;
- hands motion limited to at most 2 points of translation and 0.7 degrees of rotation, repeated twice only during `.animating`;
- yarn-ball motion limited to 1.2 degrees of rotation;
- Lemon ear motion limited to 1 point and 0.8 degrees;
- a SwiftUI `Path` eyelid stroke using sampled dark-gray/brown theme colors, visible briefly during `.animating` and hidden in all final states;
- `.accessibilityLabel(Text("art.familyHero.accessibility"))` on the composite and `.accessibilityHidden(true)` on every overlay.

Use a fixed painting aspect ratio of `2560.0 / 1440.0` so every mask remains aligned on iPhone, iPad, and Mac.

- [ ] **Step 3: Make every final-state transform exact**

For `.settling`, reset all overlay offsets, rotations, blink opacity, and animation repetition to their original values. For `.enteringHome`, animate the whole composite toward `destinationFrame` over 0.6 seconds. For `.complete`, render nothing. Ensure the complete full painting remains visible behind all overlays so a missing or invisible local layer cannot produce a blank launch screen.

- [ ] **Step 4: Compile Mac and visually inspect a SwiftUI preview**

Run the Mac build command from Task 2. In Xcode Preview or the running Mac app, confirm that no face, hand, yarn, or rabbit outline visibly doubles at rest. If an overlay edge is noticeable, reduce that overlay's amplitude; if it remains visible, remove only that local movement as required by the design spec.

- [ ] **Step 5: Commit**

```bash
git add KnitNote/Launch/FamilyLaunchAnimationView.swift KnitNote/Launch/PaintingOverlayRegion.swift KnitNote.xcodeproj/project.pbxproj
git commit -m "Animate original family painting layers"
```

---

### Task 4: Live Hero Destination and Root Transition

**Files:**
- Create: `KnitNote/Launch/FamilyHeroFramePreferenceKey.swift`
- Modify: `KnitNote/App/KnitNoteApp.swift`
- Modify: `KnitNote/App/RootView.swift`
- Modify: `KnitNote/Projects/ProjectsView.swift`
- Modify: `KnitNote/Theme/WatercolorSurfaces.swift`

**Interfaces:**
- Consumes: `LaunchExperienceCoordinator` and `FamilyLaunchAnimationView`.
- Produces: a live `CGRect` destination in the root coordinate space and a cold-launch-only overlay.

- [ ] **Step 1: Add the hero frame preference**

```swift
import SwiftUI

struct FamilyHeroFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}
```

In `FamilyHeroView`, add a transparent `GeometryReader` background that reports:

```swift
Color.clear.preference(
    key: FamilyHeroFramePreferenceKey.self,
    value: proxy.frame(in: .named("KnitNoteRoot"))
)
```

- [ ] **Step 2: Own the coordinator for the app-process lifetime**

Add `@StateObject private var launchExperience = LaunchExperienceCoordinator()` to `KnitNoteApp` and inject it with `.environmentObject(launchExperience)`. This object must not use `AppStorage`; a new process creates a new coordinator, while background/foreground changes reuse the existing object.

- [ ] **Step 3: Layer the animation above the already-loaded home screen**

Update `RootView` to:

- read `accessibilityReduceMotion` and the coordinator from the environment;
- wrap the existing `TabView` and launch overlay in a root `ZStack` using `.coordinateSpace(name: "KnitNoteRoot")`;
- store the latest non-empty hero frame from `.onPreferenceChange`;
- set the existing `TabView` opacity from `homeOpacity` and hide it from accessibility until entering home;
- show `FamilyLaunchAnimationView` only while `showsOverlay` is true;
- apply `.contentShape(.rect).onTapGesture { coordinator.skip() }` to the full-screen overlay;
- call `coordinator.start(reduceMotion:)` once from `.task`.

- [ ] **Step 4: Protect startup when geometry or artwork is unavailable**

If the hero frame is still empty when `.enteringHome` begins, use an aspect-fit frame centered in the top third as a temporary destination and allow completion on schedule. If `FamilyKnittingHero` cannot render, immediately invoke `skip()` and reveal the normal home screen rather than leaving an opaque overlay.

- [ ] **Step 5: Build and run the supported app platforms**

Run:

```bash
xcodegen generate
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteLaunchMac CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -destination 'generic/platform=watchOS' -derivedDataPath /tmp/KnitNoteLaunchWatch CODE_SIGNING_ALLOWED=NO build
```

Then run `KnitNote` from Xcode on the available iPhone and iPad destinations. Expected: the iOS and Mac launch overlay plays once per process; Watch opens exactly as before.

- [ ] **Step 6: Commit**

```bash
git add KnitNote/App/KnitNoteApp.swift KnitNote/App/RootView.swift KnitNote/Launch/FamilyHeroFramePreferenceKey.swift KnitNote/Projects/ProjectsView.swift KnitNote/Theme/WatercolorSurfaces.swift KnitNote.xcodeproj/project.pbxproj project.yml
git commit -m "Transition launch painting into home hero"
```

---

### Task 5: Accessibility, Interaction, and Acceptance Verification

**Files:**
- Modify: `Tests/KnitNoteCoreTests/LaunchExperienceStateTests.swift`
- Modify: `docs/superpowers/specs/2026-07-18-family-painting-launch-animation-design.md` only if implementation revealed a necessary clarified constraint.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: verified cold-launch, skip, Reduce Motion, fallback, geometry, and regression behavior.

- [ ] **Step 1: Add reducer edge-case tests**

Add tests that call `skip()` from `.animating`, `.settling`, `.enteringHome`, and `.complete`; verify every non-complete state converges to `.enteringHome`, never returns to an earlier phase, and repeated `advance()` calls keep `.complete` stable.

- [ ] **Step 2: Run the complete automated suite**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build
```

Expected: all existing tests plus the new launch tests pass with zero failures.

- [ ] **Step 3: Run complete build verification**

Run the Mac and Watch commands from Task 4 and use Xcode to build/run iPhone and iPad. Expected: all four platform checks complete without a Swift compiler error.

- [ ] **Step 4: Perform the launch acceptance matrix**

Verify and record each result:

- cold launch completes the normal 2.6-second sequence;
- background/foreground does not replay it;
- tapping during reveal, local motion, and settling enters home once without a flash;
- Reduce Motion uses only fades and still completes;
- iPhone and iPad portrait/landscape end at the live hero frame;
- iPad split or resized window and Mac resizing recompute the destination;
- VoiceOver exposes one painting description and no decorative layers;
- project creation, row count, notes, photos, patterns, markup, and localization still work;
- temporarily disabling an optional overlay leaves the full painting and home transition intact.

- [ ] **Step 5: Review the final diff**

Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace error, no generated build products, and the user's `KnitNote 5.xcodeproj/` and `KnitNote 6.xcodeproj/` remain untracked and untouched.

- [ ] **Step 6: Commit final verification adjustments**

```bash
git add Tests/KnitNoteCoreTests/LaunchExperienceStateTests.swift
git commit -m "Verify family painting launch experience"
```
