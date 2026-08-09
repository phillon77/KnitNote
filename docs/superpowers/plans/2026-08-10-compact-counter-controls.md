# Compact Counter Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the counter manager’s uneven localized decrement and increment titles with equal-width `−1` and `+1` controls while preserving complete localized VoiceOver labels and existing behavior.

**Architecture:** Keep the change inside `CounterManagerView`; use language-neutral visible symbols and retain the existing String Catalog keys only as accessibility labels. Source contracts bind the visible labels, equal sizing, minimum target height, reset behavior, and accessibility boundary.

**Tech Stack:** SwiftUI, Swift Testing source contracts, Xcode iOS/macOS builds, physical iPhone overlay installation.

## Global Constraints

- Candidate identity remains KnitNote `1.5.0` (Build `9`) at the implementation commit.
- Visible decrement and increment labels are exactly `−1` and `+1`.
- The two compact controls use identical sizing and at least a 44-point interactive height.
- Reset remains visually and behaviorally unchanged and retains its confirmation dialog.
- VoiceOver retains the full localized `counter.minusOne` and `counter.increment` labels.
- No counter arithmetic, persistence, reminders, Watch synchronization, catalogs, project data, or user-created/imported content changes.
- Preserve untracked `.superpowers/brainstorm/`, `AppStore/Verification/CounterReminders150Verification.md`, and `build/`.
- Do not archive, export, upload, modify App Store Connect, merge, or push.

---

### Task 1: Compact visible counter controls

**Files:**
- Modify: `KnitNote/Projects/CounterManagerView.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift`

**Interfaces:**
- Consumes: `CounterManagerView.adjustValue(by:)`, the existing reset confirmation, and localized accessibility keys `counter.minusOne` and `counter.increment`.
- Produces: visible `−1` and `+1` controls with identical `52 × 44` minimum label frames.

- [ ] **Step 1: Write the failing source contract**

Add a test to `ProjectCounterViewContractTests.swift` that reads `CounterManagerView.swift` and requires the compact labels, shared sizing, and accessibility labels:

```swift
@Test func counterManagerUsesCompactEqualWidthValueControlsWithFullAccessibilityLabels() throws {
    let source = try counterSource("KnitNote/Projects/CounterManagerView.swift")

    #expect(source.contains("Text(\"−1\")"))
    #expect(source.contains("Text(\"+1\")"))
    #expect(source.components(separatedBy: ".frame(minWidth: 52, minHeight: 44)").count - 1 == 2)
    #expect(source.contains(".accessibilityLabel(Text(\"counter.minusOne\"))"))
    #expect(source.contains(".accessibilityLabel(Text(\"counter.increment\"))"))
    #expect(source.contains("Button(\"counter.reset\", systemImage: \"arrow.counterclockwise\", role: .destructive)"))
}
```

Use the suite’s existing repository source helper name if it differs from `counterSource(_:)`; do not introduce a duplicate helper.

- [ ] **Step 2: Run RED**

Run:

```bash
swift test --disable-sandbox --filter ProjectCounterViewContractTests
```

Expected: FAIL because decrement and increment still use localized visible button titles and do not contain the two compact label frames.

- [ ] **Step 3: Implement the compact controls**

Replace only the visible label bodies of `decrementButton` and `incrementButton`:

```swift
private var decrementButton: some View {
    Button {
        adjustValue(by: -1)
    } label: {
        Text("−1")
            .font(.headline)
            .monospacedDigit()
            .frame(minWidth: 52, minHeight: 44)
    }
    .buttonStyle(.borderless)
    .disabled(currentValue == 0)
    .accessibilityLabel(Text("counter.minusOne"))
}

private var incrementButton: some View {
    Button {
        adjustValue(by: 1)
    } label: {
        Text("+1")
            .font(.headline)
            .monospacedDigit()
            .frame(minWidth: 52, minHeight: 44)
    }
    .buttonStyle(.borderless)
    .disabled(currentValue == .max)
    .accessibilityLabel(Text("counter.increment"))
}
```

Do not alter `resetButton`, `adjustValue(by:)`, or catalog values.

- [ ] **Step 4: Run focused GREEN and localization safeguards**

Run:

```bash
swift test --disable-sandbox --filter ProjectCounterViewContractTests
swift test --disable-sandbox --filter LocalizationContractTests
swift test --disable-sandbox --filter CounterReminderTests
```

Expected: all tests PASS. The catalog test proves the full localized accessibility keys remain available; reminder behavior remains unchanged.

- [ ] **Step 5: Build iOS and macOS**

Run:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: both commands end with `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Verify scope and commit**

Run:

```bash
git diff --check
git status --short
git add KnitNote/Projects/CounterManagerView.swift Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift
git commit -m "fix: compact counter value controls"
```

Expected: commit contains only the view and its source contract; preserved untracked paths remain untouched.

---

### Task 2: Physical iPhone re-acceptance

**Files:**
- Modify only after user evidence: `AppStore/Verification/CounterReminders150Verification.md`

**Interfaces:**
- Consumes: exact committed Task 1 Debug product, bundle `com.phillon.KnitNote`, version `1.5.0` (Build `9`).
- Produces: scoped physical evidence for compact controls only; it does not accept reminders, Watch, iPad, Mac, metadata, archive, or release gates.

- [ ] **Step 1: Build the exact committed iPhone candidate**

Run with the physical iPhone destination and a fresh `/tmp` DerivedData directory:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
  -destination 'id=00008150-00042D6A3612401C' \
  -derivedDataPath /tmp/KnitNote150CompactControls-iPhone \
  KNITNOTE_SOURCE_REVISION="$(git rev-parse HEAD)" build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Verify and overlay-install without removing data**

Inspect `Info.plist` for exact version/build/revision, query the currently installed app, then run:

```bash
xcrun devicectl device install app \
  --device 00008150-00042D6A3612401C \
  /tmp/KnitNote150CompactControls-iPhone/Build/Products/Debug-iphoneos/KnitNote.app
```

Do not uninstall or erase the app. Query the installed app again and require `1.5.0` / `9`.

- [ ] **Step 3: Obtain scoped user acceptance**

Ask the user to verify:

1. Existing projects remain present.
2. The manager displays aligned `−1`, `+1`, and reset actions without wrapping.
3. `−1`, `+1`, and reset still behave correctly.
4. VoiceOver announces full decrement, increment, and reset actions.

Record PASS only from the user’s explicit response. Leave every unrelated physical/release gate PENDING.
