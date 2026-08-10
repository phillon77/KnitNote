# Project Detail Counter Reminder Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display and operate the selected counter's pending reminder directly below the project detail counter grid.

**Architecture:** `ProjectDetailView` derives the card from the store-backed selected counter and reuses `CounterReminderCard`. Complete and Stop call the existing direct store transactions, then verify the store postcondition before treating the action as successful; no local state can hide the card.

**Tech Stack:** SwiftUI, KnitNoteCore `JSONProjectStore`, Swift Testing source contracts, Xcode iOS/macOS builds, CoreDevice physical overlay installation.

## Global Constraints

- Keep the card immediately after `CounterSelectorGrid` and before `ProjectYarnSection`.
- Reuse `CounterReminderCard`; do not duplicate its UI, localization, or accessibility behavior.
- Bind only to `project.selectedCounter.reminder?.pending` and the selected reminder message.
- Complete passes the exact reminder ID and observed occurrence count; Stop passes the exact reminder ID.
- Never clear local presentation state to hide the card. The store must publish the accepted mutation.
- A thrown or rejected/stale operation leaves the card visible and sets the existing project-detail error alert.
- Do not change scheduling, Watch, pattern-reader behavior, catalogs, metadata, version/build, archive/export, upload, submission, merge, or push state.
- Preserve untracked `.superpowers/brainstorm/`, `AppStore/Verification/CounterReminders150Verification.md`, `build/`, and `task-3-report.md`.

---

### Task 1: Wire the pending reminder card into project detail

**Files:**
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift`

**Interfaces:**
- Consumes: `CounterReminderCard`, `StoredProject.selectedCounter`, `CounterReminderPending`, `JSONProjectStore.completeCounterReminder`, and `JSONProjectStore.stopCounterReminder`.
- Produces: project-detail pending-card presentation and the private Complete/Stop callbacks that verify store postconditions.

- [ ] **Step 1: Write the failing project-detail source contract**

Add a test to `ProjectCounterViewContractTests` that extracts the source between
the counter selector card and the yarn section, then requires the selected
counter reminder and existing card:

```swift
@Test func projectDetailShowsSelectedPendingReminderBelowCounters() throws {
    let source = try projectSource(named: "ProjectDetailView")
    let reminderSection = try #require(sourceSection(
        source,
        from: "CounterSelectorGrid(",
        to: "ProjectYarnSection("
    ))

    #expect(reminderSection.contains("project.selectedCounter.reminder"))
    #expect(reminderSection.contains("if let pending = reminder.pending"))
    #expect(reminderSection.contains("CounterReminderCard("))
    #expect(reminderSection.contains("pending: pending"))
    #expect(reminderSection.contains("message: reminder.message"))
    #expect(reminderSection.contains("completeProjectCounterReminder("))
    #expect(reminderSection.contains("stopProjectCounterReminder("))
}
```

Add a second test that extracts the two callback methods and requires exact
store arguments, postcondition checks, and error retention:

```swift
@Test func projectDetailReminderActionsAreStoreBackedAndFailClosed() throws {
    let source = try projectSource(named: "ProjectDetailView")
    let complete = try #require(sourceSection(
        source,
        from: "private func completeProjectCounterReminder(",
        to: "private func stopProjectCounterReminder("
    ))
    let stop = try #require(sourceSection(
        source,
        from: "private func stopProjectCounterReminder(",
        to: "private func reminderActionFailed("
    ))

    #expect(complete.contains("try store.completeCounterReminder("))
    #expect(complete.contains("reminderID: pending.reminderID"))
    #expect(complete.contains("observedCount: pending.occurrenceCount"))
    #expect(complete.contains("store.project(id: projectID)"))
    #expect(complete.contains("reminderActionFailed()"))
    #expect(stop.contains("try store.stopCounterReminder("))
    #expect(stop.contains("reminderID: pending.reminderID"))
    #expect(stop.contains("store.project(id: projectID)"))
    #expect(stop.contains("reminderActionFailed()"))
    #expect(!complete.contains("pending = nil"))
    #expect(!stop.contains("pending = nil"))
}
```

- [ ] **Step 2: Run the focused contract and verify RED**

Run:

```bash
swift test --disable-sandbox --filter ProjectCounterViewContractTests
```

Expected: the two new tests fail because `ProjectDetailView` has no card or
direct reminder callbacks.

- [ ] **Step 3: Add the store-derived card in the approved position**

Immediately after the `WatercolorCard` containing `CounterSelectorGrid`, add:

```swift
if let reminder = project.selectedCounter.reminder,
   let pending = reminder.pending {
    let counterID = project.selectedCounterID
    CounterReminderCard(
        pending: pending,
        message: reminder.message,
        onComplete: {
            completeProjectCounterReminder(counterID: counterID, pending: pending)
        },
        onStop: {
            stopProjectCounterReminder(counterID: counterID, pending: pending)
        }
    )
}
```

Do not wrap it in a second `WatercolorCard`; the reusable component already
provides the visual card.

- [ ] **Step 4: Implement Complete with a fail-closed postcondition**

Add this private callback before `hasActivePatterns`:

```swift
private func completeProjectCounterReminder(
    counterID: UUID,
    pending: CounterReminderPending
) {
    do {
        try store.completeCounterReminder(
            projectID: projectID,
            counterID: counterID,
            reminderID: pending.reminderID,
            observedCount: pending.occurrenceCount
        )
        guard let counter = store.project(id: projectID)?.counters.first(where: { $0.id == counterID }),
              counter.reminder?.pending?.reminderID != pending.reminderID else {
            reminderActionFailed()
            return
        }
    } catch {
        counterSaveError = error.localizedDescription
    }
}
```

The guard treats a missing project/counter as failure and accepts only a store
state where the matching pending reminder no longer exists.

- [ ] **Step 5: Implement Stop with a fail-closed postcondition**

Add:

```swift
private func stopProjectCounterReminder(
    counterID: UUID,
    pending: CounterReminderPending
) {
    do {
        try store.stopCounterReminder(
            projectID: projectID,
            counterID: counterID,
            reminderID: pending.reminderID
        )
        guard let counter = store.project(id: projectID)?.counters.first(where: { $0.id == counterID }),
              counter.reminder?.id != pending.reminderID || counter.reminder?.isActive != true else {
            reminderActionFailed()
            return
        }
    } catch {
        counterSaveError = error.localizedDescription
    }
}

private func reminderActionFailed() {
    counterSaveError = LocaleAwareText.string("counter.error.notSaved", locale: locale)
}
```

- [ ] **Step 6: Run focused view and store verification**

Run:

```bash
swift test --disable-sandbox --filter ProjectCounterViewContractTests
swift test --disable-sandbox --filter JSONProjectStoreTests
swift test --disable-sandbox --filter JSONProjectStoreEntitlementTests
```

Expected: all three suites pass, including existing stale reminder ID/count,
completed-project, and persistence-failure cases.

- [ ] **Step 7: Build both affected app platforms**

Run:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: both commands exit 0 with `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit the scoped implementation**

Run:

```bash
git diff --check
git add KnitNote/Projects/ProjectDetailView.swift \
  Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift
git commit -m "fix: show counter reminders on projects"
```

Expected: the commit changes exactly the project detail view and its source
contract.

---

### Task 2: Re-accept the exact iPhone project-detail flow

**Files:**
- Modify only after explicit user evidence: `AppStore/Verification/CounterReminders150Verification.md`

**Interfaces:**
- Consumes: exact committed Task 1 Debug product, bundle `com.phillon.KnitNote`, version `1.5.0` (Build `9`).
- Produces: scoped iPhone physical evidence for the project-detail reminder card; unrelated device and release gates stay pending.

- [ ] **Step 1: Build and inspect the exact committed iPhone product**

Use a fresh `/tmp` DerivedData path and embed `git rev-parse HEAD` as
`KNITNOTE_SOURCE_REVISION`. Require `BUILD SUCCEEDED`, version `1.5.0`, build
`9`, exact revision, bundle `com.phillon.KnitNote`, and team `9CFPAUL5N5`.

- [ ] **Step 2: Overlay-install without uninstalling or erasing data**

Query the installed app before and after `xcrun devicectl device install app`.
Require the post-install app to remain `1.5.0` (Build `9`). Do not use uninstall,
erase, reset, or container-deletion commands.

- [ ] **Step 3: Obtain scoped user acceptance**

Ask the user to confirm on the project detail page:

1. Existing projects and counter values remain present.
2. Crossing a configured reminder shows one card immediately below the counter grid without opening a pattern.
3. A combined two-occurrence reminder displays the latest row and count 2.
4. Complete clears the card once and persists after reopen.
5. A later pending reminder followed by Stop disables it, persists after reopen, and does not revive.
6. VoiceOver announces reached row, combined count, Complete, and Stop truthfully.

Record PASS only from the user's explicit response against the exact installed
revision. Do not infer iPad, Watch, Mac, archive, upload, App Store Connect, or
release acceptance.
