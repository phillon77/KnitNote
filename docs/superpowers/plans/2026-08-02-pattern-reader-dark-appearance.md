# Pattern Reader Dark Appearance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make only the pattern reader automatically use dark chrome and a document-only night rendering effect in system Dark Mode, with a per-pattern remembered original-color override.

**Architecture:** Keep KnitNote's existing light watercolor app shell unchanged. Add a Core appearance policy and per-`StoredPattern` preference, a transactional Store mutation, and an app-only platform monitor that reads the actual operating-system appearance independently of the inherited SwiftUI light scheme. Apply a live invert-plus-hue-rotation modifier only to the PDF/image layer so highlight, handwriting, controls, thumbnails, viewport state, and source files remain unchanged.

**Tech Stack:** Swift 6, SwiftUI, PDFKit, UIKit/AppKit conditional compilation, Combine observation, Swift Testing, XCStrings, Xcode project membership.

## Global Constraints

- Target branch is the current KnitNote 1.3 candidate containing commit `b771d20`; create an isolated execution worktree before implementation.
- The app shell outside the pattern reader remains in its existing forced-light watercolor appearance.
- The pattern reader alone follows the actual iOS/iPadOS/macOS system appearance.
- Light Mode always shows original PDF/image colors.
- Dark Mode defaults to night rendering unless that `StoredPattern` remembers original colors.
- The preference is shared across every project linked to the same library pattern and is not stored in `PatternProjectUsage`.
- The display preference is available regardless of trial or purchase state.
- Do not modify, duplicate, export, or cache transformed PDF/image content.
- Do not filter highlight, handwriting, counters, page controls, toolbar content, or page thumbnails.
- Do not reload the document or change page, zoom, scroll, viewport, highlight, note, or markup state when appearance changes.
- Do not increment `ProjectArchive.currentVersion`; the additive field decodes absent data as `false` within the unpublished version 11 schema.
- Preserve Traditional Chinese and English localization, VoiceOver, Dynamic Type, iPhone, iPad, and Mac behavior.
- Do not change StoreKit, Watch, backup inclusion, app version/build, release metadata, pricing, Git remote state, or App Store Connect state.

---

### Task 1: Add the Per-Pattern Preference and Pure Appearance Policy

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternReaderAppearance.swift`
- Modify: `Sources/KnitNoteCore/Patterns/StoredPattern.swift`
- Create: `Tests/KnitNoteCoreTests/PatternReaderAppearanceTests.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj`
- Modify: `Tests/KnitNoteCoreTests/Task8XcodeProjectMembershipTests.swift`

**Interfaces:**
- Consumes: `StoredPattern.id` as the stable library-pattern identity.
- Produces: `PatternSystemAppearance`, `PatternReaderAppearancePolicy.usesNightRendering(systemAppearance:prefersOriginalColorsInDarkMode:) -> Bool`, and `StoredPattern.prefersOriginalColorsInDarkMode: Bool`.

- [ ] **Step 1: Write failing policy and compatibility tests**

Create `PatternReaderAppearanceTests.swift`:

```swift
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct PatternReaderAppearanceTests {
    @Test func nightRenderingRequiresDarkSystemAndNoOriginalColorOverride() {
        #expect(!PatternReaderAppearancePolicy.usesNightRendering(
            systemAppearance: .unresolved,
            prefersOriginalColorsInDarkMode: false
        ))
        #expect(!PatternReaderAppearancePolicy.usesNightRendering(
            systemAppearance: .light,
            prefersOriginalColorsInDarkMode: false
        ))
        #expect(PatternReaderAppearancePolicy.usesNightRendering(
            systemAppearance: .dark,
            prefersOriginalColorsInDarkMode: false
        ))
        #expect(!PatternReaderAppearancePolicy.usesNightRendering(
            systemAppearance: .dark,
            prefersOriginalColorsInDarkMode: true
        ))
    }

    @Test func legacyPatternWithoutAppearancePreferenceDefaultsToNightInDarkMode() throws {
        let assetID = UUID()
        let patternID = UUID()
        let data = Data("""
        {
          "id":"\(patternID.uuidString)",
          "assetID":"\(assetID.uuidString)",
          "displayName":"Legacy",
          "createdAt":0
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(StoredPattern.self, from: data)
        #expect(!decoded.prefersOriginalColorsInDarkMode)
    }

    @Test func patternAppearancePreferenceRoundTrips() throws {
        let pattern = StoredPattern(
            assetID: UUID(),
            displayName: "Color chart",
            prefersOriginalColorsInDarkMode: true
        )
        let decoded = try JSONDecoder().decode(
            StoredPattern.self,
            from: JSONEncoder().encode(pattern)
        )
        #expect(decoded == pattern)
        #expect(decoded.prefersOriginalColorsInDarkMode)
    }
}
```

Extend `Task8XcodeProjectMembershipTests` so `PatternReaderAppearance.swift` must belong to the `KnitNote` app target and must not be required by the Watch or Share targets.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter PatternReaderAppearanceTests
swift test --filter Task8XcodeProjectMembershipTests
```

Expected: compilation fails because the policy type and stored preference do not exist, and membership fails until the new file is registered.

- [ ] **Step 3: Implement the minimal Core policy**

Create `PatternReaderAppearance.swift`:

```swift
import Foundation

public enum PatternSystemAppearance: Equatable, Sendable {
    case unresolved
    case light
    case dark
}

public enum PatternReaderAppearancePolicy: Sendable {
    public static func usesNightRendering(
        systemAppearance: PatternSystemAppearance,
        prefersOriginalColorsInDarkMode: Bool
    ) -> Bool {
        systemAppearance == .dark && !prefersOriginalColorsInDarkMode
    }
}
```

- [ ] **Step 4: Add backward-compatible `StoredPattern` coding**

Add this stored property and initializer parameter:

```swift
public var prefersOriginalColorsInDarkMode: Bool

public init(
    id: UUID = UUID(),
    assetID: UUID,
    displayName: String,
    note: String? = nil,
    createdAt: Date = .now,
    lastOpenedAt: Date? = nil,
    prefersOriginalColorsInDarkMode: Bool = false
) {
    // existing assignments
    self.prefersOriginalColorsInDarkMode = prefersOriginalColorsInDarkMode
}
```

Define complete coding keys and explicit `init(from:)` / `encode(to:)`. The new field must use `decodeIfPresent(Bool.self, forKey:) ?? false`; all existing fields retain their current required/optional behavior:

```swift
private enum CodingKeys: String, CodingKey {
    case id, assetID, displayName, note, createdAt, lastOpenedAt
    case prefersOriginalColorsInDarkMode
}
```

Do not add the field to `PatternAsset` or `PatternProjectUsage`.

- [ ] **Step 5: Register project membership and verify GREEN**

Add `PatternReaderAppearance.swift` to the Patterns group and the `KnitNote` target's Sources phase in `KnitNote.xcodeproj/project.pbxproj`. Do not add it to `KnitNoteWatch` or `KnitNoteShare`.

Run:

```bash
swift test --filter PatternReaderAppearanceTests
swift test --filter Task8XcodeProjectMembershipTests
```

Expected: both suites pass.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/KnitNoteCore/Patterns/PatternReaderAppearance.swift \
  Sources/KnitNoteCore/Patterns/StoredPattern.swift \
  Tests/KnitNoteCoreTests/PatternReaderAppearanceTests.swift \
  Tests/KnitNoteCoreTests/Task8XcodeProjectMembershipTests.swift \
  KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: add per-pattern night appearance preference"
```

---

### Task 2: Persist the Display Preference Without an Entitlement Gate

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternLibraryStoreTests.swift`

**Interfaces:**
- Consumes: `StoredPattern.prefersOriginalColorsInDarkMode` from Task 1 and the reader's `expectedDataGeneration`.
- Produces: `JSONProjectStore.setPatternPrefersOriginalColorsInDarkMode(id:prefersOriginalColors:expectedDataGeneration:) throws -> UInt64`.

- [ ] **Step 1: Write failing transactional Store tests**

Add tests using `PatternLibraryStoreHarness`:

```swift
@MainActor @Test
func patternOriginalColorPreferencePersistsAndIsSharedAcrossUsages() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndTwoProjects()
    _ = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    _ = try harness.store.linkPattern(
        patternID: harness.patternID,
        to: try #require(harness.secondProjectID)
    )
    let usagesBefore = harness.store.patternUsages
    let generation = harness.store.dataGeneration

    let next = try harness.store.setPatternPrefersOriginalColorsInDarkMode(
        id: harness.patternID,
        prefersOriginalColors: true,
        expectedDataGeneration: generation
    )

    #expect(next > generation)
    #expect(harness.store.patterns.first { $0.id == harness.patternID }?
        .prefersOriginalColorsInDarkMode == true)
    #expect(harness.store.patternUsages == usagesBefore)
    #expect(usagesBefore.count == 2)
    #expect(try harness.reopenedStore().patterns.first { $0.id == harness.patternID }?
        .prefersOriginalColorsInDarkMode == true)
}

@MainActor @Test
func missingOrStalePatternAppearanceMutationPublishesNothing() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let before = harness.store.patterns
    let generation = harness.store.dataGeneration

    #expect(throws: PatternLibraryMutationError.patternNotFound) {
        _ = try harness.store.setPatternPrefersOriginalColorsInDarkMode(
            id: UUID(),
            prefersOriginalColors: true,
            expectedDataGeneration: generation
        )
    }
    #expect(throws: ProjectStoreError.staleDataGeneration) {
        _ = try harness.store.setPatternPrefersOriginalColorsInDarkMode(
            id: harness.patternID,
            prefersOriginalColors: true,
            expectedDataGeneration: generation &+ 1
        )
    }
    #expect(harness.store.patterns == before)
    #expect(harness.store.dataGeneration == generation)
}

@MainActor @Test
func failedPatternAppearanceWriteLeavesMemoryAndDiskUnchanged() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject(
        failingArchiveWrites: true
    )
    let before = harness.store.patterns
    let archiveBefore = try Data(contentsOf: harness.archiveURL)
    harness.archiveWriteGate?.shouldFail = true

    #expect(throws: ProjectStoreError.persistenceFailed) {
        _ = try harness.store.setPatternPrefersOriginalColorsInDarkMode(
            id: harness.patternID,
            prefersOriginalColors: true,
            expectedDataGeneration: harness.store.dataGeneration
        )
    }
    #expect(harness.store.patterns == before)
    #expect(try Data(contentsOf: harness.archiveURL) == archiveBefore)
}
```

Add a focused test that constructs a store with `authorizeMutation: { _ in .requiresUnlock }`, invokes this display-preference API, and expects success with no authorization callback record. This proves it is not accidentally routed through `.editPattern` or another paid mutation.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter PatternLibraryStoreTests
```

Expected: compilation fails because the Store API does not exist.

- [ ] **Step 3: Implement the narrow Store mutation**

Add beside `renamePattern` / `setPatternNote`:

```swift
@discardableResult
public func setPatternPrefersOriginalColorsInDarkMode(
    id: UUID,
    prefersOriginalColors: Bool,
    expectedDataGeneration: UInt64
) throws -> UInt64 {
    try ensureArchiveAvailable()
    guard dataGeneration == expectedDataGeneration else {
        throw ProjectStoreError.staleDataGeneration
    }
    guard let index = patterns.firstIndex(where: { $0.id == id }) else {
        throw PatternLibraryMutationError.patternNotFound
    }
    guard patterns[index].prefersOriginalColorsInDarkMode != prefersOriginalColors else {
        return dataGeneration
    }
    var staged = patterns
    staged[index].prefersOriginalColorsInDarkMode = prefersOriginalColors
    try persist(projects: projects, yarns: yarns, patterns: staged)
    return dataGeneration
}
```

Do not call `requireAccess` or `commitSuccessfulMutation`; this is a display/accessibility preference. Preserve the existing transactional `persist` boundary so a failed write publishes nothing.

- [ ] **Step 4: Verify GREEN and relevant entitlement regressions**

Run:

```bash
swift test --filter PatternLibraryStoreTests
swift test --filter JSONProjectStoreEntitlementTests
```

Expected: both suites pass and paid content mutations remain restricted.

- [ ] **Step 5: Commit Task 2**

```bash
git add Sources/KnitNoteCore/Projects/JSONProjectStore.swift \
  Tests/KnitNoteCoreTests/PatternLibraryStoreTests.swift
git commit -m "feat: persist pattern night appearance preference"
```

---

### Task 3: Observe Actual System Appearance Inside the Light App Shell

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternSystemAppearanceObservation.swift`
- Create: `KnitNote/Patterns/PatternSystemAppearanceMonitor.swift`
- Create: `Tests/KnitNoteCoreTests/PatternSystemAppearanceContractTests.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj`
- Modify: `Tests/KnitNoteCoreTests/Task8XcodeProjectMembershipTests.swift`

**Interfaces:**
- Consumes: `PatternSystemAppearance` from Task 1.
- Produces: platform-neutral interface-style mapping, foreground-scene selection, style-change filtering, and an injectable observation lifecycle in KnitNoteCore.
- Produces: `@MainActor final class PatternSystemAppearanceMonitor: ObservableObject` with `@Published private(set) var appearance`, plus `start()`, `refresh()`, and `stop()`.

- [ ] **Step 1: Write failing behavior and membership contracts**

Create `PatternSystemAppearanceContractTests.swift` against real KnitNoteCore APIs. Do not read or search app source text. Cover these observable behaviors:

- `.unspecified`, `.light`, and `.dark` map to `.unresolved`, `.light`, and `.dark`.
- The first foreground-active scene wins over an earlier inactive scene.
- With no foreground-active scene, the first scene is used; no scenes resolve to `.unresolved`.
- `start()` publishes the injected resolver result and an installed signal publishes the next result.
- Repeated `start()` refreshes without installing twice; repeated `stop()` removes once; a retained signal cannot refresh after stop; a later start installs again.
- The probe filter emits only when the platform-neutral interface style changes.

Extend the membership test so `PatternSystemAppearanceObservation.swift` and `PatternSystemAppearanceMonitor.swift` belong only to the `KnitNote` app target and never Watch or Share.

- [ ] **Step 2: Run contracts and verify RED**

Run:

```bash
swift test --filter PatternSystemAppearanceContractTests
swift test --filter Task8XcodeProjectMembershipTests
```

Expected: behavior tests fail because the resolver/scene/lifecycle APIs do not exist; membership fails before the new Core seam is registered in the KnitNote target.

- [ ] **Step 3: Implement the platform-neutral behavior seam**

Create `PatternSystemAppearanceObservation.swift` in KnitNoteCore with:

- `PatternSystemInterfaceStyle`, `PatternSystemAppearanceScene`, and pure `PatternSystemAppearanceResolver` mapping/selection/filtering.
- `@MainActor PatternSystemAppearanceObservation`, injected with a resolver, observer installer/remover, and publisher closure.
- Idempotent observer installation/removal and a lifecycle guard that ignores stale observer signals after stop.

Run `swift test --filter PatternSystemAppearanceContractTests` and verify all behavior tests pass before wiring UIKit/AppKit.

- [ ] **Step 4: Implement thin platform adapters**

Create the app-only `PatternSystemAppearanceMonitor` with conditional UIKit/AppKit imports. It owns `@Published private(set) var appearance`, delegates `start()`, `refresh()`, and `stop()` to the tested Core lifecycle, and supplies only platform adapters:

Platform resolution rules:

- iOS/iPadOS: convert connected `UIWindowScene` values into the tested Core scene representation using `scene.screen.traitCollection.userInterfaceStyle` and foreground-active state. Refresh on `UIApplication.didBecomeActiveNotification` and `UIApplication.willEnterForegroundNotification`.
- macOS: map `NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])`; observe `NSApp.effectiveAppearance` using KVO and call `refresh()` on change.
- Never infer appearance from clock time, screen brightness, or stored user preference.

On iOS/iPadOS, implement `PatternSystemAppearanceChangeProbe` as a small `UIViewRepresentable`. Register `UITraitUserInterfaceStyle` changes with `registerForTraitChanges` and route previous/current styles through the tested Core filter before invoking `onChange`. The current iOS deployment target is 18.0, so no deprecated `traitCollectionDidChange(_:)` fallback is needed; if support later drops below iOS 17, add only an availability-scoped legacy fallback. The probe remains only a change signal: the monitor still resolves the actual connected screen rather than trusting the light app shell's inherited `colorScheme`.

- [ ] **Step 5: Register app-only project membership and verify builds**

Add both files to their respective Patterns groups and the `KnitNote` Sources phase only.

Run:

```bash
swift test --filter PatternSystemAppearanceContractTests
swift test --filter Task8XcodeProjectMembershipTests
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/KnitNoteReaderDark-Task3-iOS \
  CODE_SIGNING_ALLOWED=NO build -quiet
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteReaderDark-Task3-Mac \
  CODE_SIGNING_ALLOWED=NO build -quiet
```

Expected: six behavior tests, membership, and both platform builds pass. The iOS build must contain no warning from `PatternSystemAppearanceChangeProbe`.

- [ ] **Step 6: Commit Task 3**

```bash
git add Sources/KnitNoteCore/Patterns/PatternSystemAppearanceObservation.swift \
  KnitNote/Patterns/PatternSystemAppearanceMonitor.swift \
  Tests/KnitNoteCoreTests/PatternSystemAppearanceContractTests.swift \
  Tests/KnitNoteCoreTests/Task8XcodeProjectMembershipTests.swift \
  KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: observe system appearance for pattern reader"
```

---

### Task 4: Add Document-Only Night Rendering, Toolbar Control, and Localization

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternReaderAppearancePresentation.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Create: `KnitNote/Patterns/PatternNightRenderingModifier.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Create: `Tests/KnitNoteCoreTests/PatternReaderAppearancePresentationTests.swift`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj`
- Modify: `Tests/KnitNoteCoreTests/Task8XcodeProjectMembershipTests.swift`

**Interfaces:**
- Consumes: Task 1 policy/preference, Task 2 Store mutation, and Task 3 monitor.
- Produces: reader-only automatic dark chrome, document-only night transformation, localized accessible original/night toggle, and Store-coordinated persistence without a reader reload.

- [ ] **Step 1: Write failing reader-appearance behavior tests**

Create a small pure `PatternReaderAppearancePresentation` seam and write tests before its implementation. Do not read or search `PatternReaderView.swift` or modifier source. Verify observable decisions for unresolved/light/dark appearance with original-color preference on and off:

- whether night rendering is active;
- reader chrome light/dark choice;
- next toggle intent (show original or restore night);
- dark/light accessibility-hint selection.

Continue using the existing behavior tests for Store persistence, revision coordination, appearance observation lifecycle, PDF viewport, and highlight geometry. Verify UIKit/AppKit integration by warning-free platform builds and the Task 5 physical matrix. Document-only modifier placement is a visual/interaction acceptance boundary, not a source-text contract.

Add localization expectations:

```swift
private let requiredPatternAppearanceTranslations = [
    "patterns.appearance.showOriginal": [
        "en": "Show Original Colors",
        "zh-Hant": "顯示原色",
    ],
    "patterns.appearance.useNight": [
        "en": "Use Night Appearance",
        "zh-Hant": "使用夜間顯示",
    ],
    "patterns.appearance.darkHint": [
        "en": "Changes this pattern only.",
        "zh-Hant": "只變更這份織圖。",
    ],
    "patterns.appearance.lightHint": [
        "en": "This choice is used automatically in Dark Mode.",
        "zh-Hant": "此選擇會在深色模式中自動套用。",
    ],
]
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter PatternReaderAppearancePresentationTests
swift test --filter LocalizationContractTests
```

Expected: the presentation behavior tests fail because the pure seam does not exist, and localization checks fail because the strings do not exist.

- [ ] **Step 3: Implement the document-only modifier**

Create `PatternNightRenderingModifier.swift`:

```swift
import SwiftUI

struct PatternNightRenderingModifier: ViewModifier {
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content
                .colorInvert()
                .hueRotation(.degrees(180))
        } else {
            content
        }
    }
}

extension View {
    func patternNightRendering(active: Bool) -> some View {
        modifier(PatternNightRenderingModifier(isActive: active))
    }
}
```

Register it in the Patterns group and the `KnitNote` app target only.

- [ ] **Step 4: Integrate the monitor and derive reader appearance**

In `PatternReaderView` add:

```swift
@StateObject private var systemAppearance = PatternSystemAppearanceMonitor()

private var storedPattern: StoredPattern? {
    store.patterns.first { $0.id == context.patternID }
}

private var prefersOriginalColorsInDarkMode: Bool {
    storedPattern?.prefersOriginalColorsInDarkMode ?? false
}

private var usesNightRendering: Bool {
    PatternReaderAppearancePolicy.usesNightRendering(
        systemAppearance: systemAppearance.appearance,
        prefersOriginalColorsInDarkMode: prefersOriginalColorsInDarkMode
    )
}

private var readerPreferredColorScheme: ColorScheme {
    systemAppearance.appearance == .dark ? .dark : .light
}
```

Apply `.preferredColorScheme(readerPreferredColorScheme)` to the reader presentation only. Start/refresh the monitor on reader appearance and active scene phase; stop it on disappearance. Do not change `KnitNoteApp.swift`'s app-shell `.preferredColorScheme(.light)`.

On iOS/iPadOS, mount `PatternSystemAppearanceChangeProbe` as a clear, non-interactive background view inside the reader presentation. Its `onChange` closure calls `systemAppearance.refresh()`. Keep it outside the document transform and overlay stacks so it cannot affect PDF geometry, gestures, highlighting, markup, counters, or thumbnail layout. macOS uses the monitor's `NSApp.effectiveAppearance` observation and does not mount the UIKit probe.

- [ ] **Step 5: Scope night rendering to document representables**

Apply:

```swift
.patternNightRendering(active: usesNightRendering)
```

to `PDFReaderView` and `ImageReaderView` only. It must be inside the inner document ZStack and must not wrap `HighlightOverlay`, `PatternMarkupOverlay`, `PatternReaderControls`, or `PatternPageThumbnailStrip`.

Changing `usesNightRendering` must update modifiers in place. Do not change `.id(readerSession.generation)`, `readerSession`, `pdfNavigator`, `pdfViewport`, or `state` to force a reload.

- [ ] **Step 6: Add the transactional toolbar action**

Add one primary toolbar button. Its action calls:

```swift
private func toggleOriginalColorsInDarkMode() {
    guard let expectedDataGeneration else { return }
    do {
        let nextGeneration = try store.setPatternPrefersOriginalColorsInDarkMode(
            id: context.patternID,
            prefersOriginalColors: !prefersOriginalColorsInDarkMode,
            expectedDataGeneration: expectedDataGeneration
        )
        self.expectedDataGeneration = nextGeneration
        revisionCoordinator.confirmMutation(generation: nextGeneration)
    } catch {
        saveError = error.localizedDescription
    }
}
```

Use `sun.max` when the action will show original colors and `moon.stars` when the action will restore night appearance. Select `patterns.appearance.showOriginal` versus `patterns.appearance.useNight` from the stored state, and select the dark/light accessibility hint from `systemAppearance.appearance`. The control remains enabled in read-only or expired-trial reader contexts because it changes display metadata, not paid content.

- [ ] **Step 7: Add bilingual XCStrings and verify GREEN**

Add the four exact keys and translations from Step 1 to `Localizable.xcstrings`. Ensure extraction state is manual and both `en` and `zh-Hant` string units are present.

Run:

```bash
swift test --filter PatternReaderAppearanceTests
swift test --filter PatternReaderAppearancePresentationTests
swift test --filter PatternReaderRevisionCoordinatorTests
swift test --filter PatternSystemAppearanceContractTests
swift test --filter PDFReaderScaleContractTests
swift test --filter HighlightOverlayContractTests
swift test --filter LocalizationContractTests
swift test --filter Task8XcodeProjectMembershipTests
```

Expected: all focused suites pass.

Also run the iOS Simulator and macOS `KnitNote` builds used in Task 3. These builds plus Task 5 device acceptance replace source-grep assertions for monitor mounting, document-transform scope, toolbar wiring, and platform availability.

- [ ] **Step 8: Commit Task 4**

```bash
git add Sources/KnitNoteCore/Patterns/PatternReaderAppearancePresentation.swift \
  KnitNote/Patterns/PatternReaderView.swift \
  KnitNote/Patterns/PatternNightRenderingModifier.swift \
  KnitNote/Localization/Localizable.xcstrings \
  Tests/KnitNoteCoreTests/PatternReaderAppearancePresentationTests.swift \
  Tests/KnitNoteCoreTests/LocalizationContractTests.swift \
  Tests/KnitNoteCoreTests/Task8XcodeProjectMembershipTests.swift \
  KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: add reader-only night appearance"
```

---

### Task 5: Complete Cross-Platform and Physical Verification

**Files:**
- Verify only; modify no production files unless a failing test identifies a specific defect, in which case return to the owning task's RED/GREEN cycle and create a separate fix commit.

**Interfaces:**
- Consumes: the exact HEAD produced by Tasks 1–4.
- Produces: an immutable physical-acceptance candidate with recorded test/build evidence.

- [ ] **Step 1: Run repository hygiene checks**

```bash
git status --short
git diff --check
git log --oneline --decorate -6
```

Expected: clean status, no whitespace errors, and four task commits after the approved design/plan commits.

- [ ] **Step 2: Run the full Swift test suite**

```bash
swift test
```

Expected: all tests pass; the count is at least the 1,042-test pre-feature baseline plus the new appearance tests.

- [ ] **Step 3: Build iOS Simulator and macOS from fresh DerivedData**

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/KnitNoteReaderDark-Final-iOS \
  CODE_SIGNING_ALLOWED=NO build -quiet

xcodebuild -project KnitNote.xcodeproj -scheme KnitNote \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteReaderDark-Final-Mac \
  CODE_SIGNING_ALLOWED=NO build -quiet
```

Expected: both exit 0.

- [ ] **Step 4: Build and install the exact HEAD on the connected iPad**

First record:

```bash
git rev-parse HEAD
xcrun xcdevice list
```

If iPad Air 5 `00008103-001934E41128A01E` is available:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote \
  -configuration Debug \
  -destination 'id=00008103-001934E41128A01E' \
  -derivedDataPath /tmp/KnitNoteReaderDark-Final-iPad build -quiet

xcrun devicectl device install app \
  --device 00008103-001934E41128A01E \
  /tmp/KnitNoteReaderDark-Final-iPad/Build/Products/Debug-iphoneos/KnitNote.app
```

Do not claim physical acceptance merely because installation succeeds.

- [ ] **Step 5: Perform the approved physical acceptance matrix**

On iPad, and on iPhone when available, verify:

1. Light Mode displays original PDF/image colors.
2. Switching the system to Dark Mode and returning to the open reader changes reader chrome and the document without reopening.
3. The rest of KnitNote remains the existing light watercolor appearance after leaving the reader.
4. Black-and-white pages remain legible; a colored chart can switch to original colors.
5. The per-pattern original-color choice survives reader reopen and app relaunch.
6. The same pattern opened from another linked project shares the choice; a different pattern retains its own default.
7. Zoom, horizontal/vertical scrolling, page changes, rotation, background/foreground, and saved width/height position remain stable.
8. Horizontal/vertical/cross highlights and handwriting retain approved colors and positions.
9. Page thumbnails, counters, page controls, and notes remain unfiltered.
10. VoiceOver announces the action and hint correctly in Traditional Chinese and English.

On Mac, repeat automatic reader-only appearance, PDF/image filtering, preference persistence, original-color switching, VoiceOver, zoom, scroll, and page-change checks.

- [ ] **Step 6: Stop at the acceptance boundary**

Report the exact candidate SHA and evidence. Do not merge, push, upload, change version/build, or submit to App Store Connect until the user explicitly chooses the next integration/release action.
