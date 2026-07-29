# macOS Pattern Inbox Failure Dismissal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users dismiss a general pattern-inbox read failure without deleting pending files, while retaining Retry and item-specific Discard behavior.

**Architecture:** Keep storage and inbox recovery unchanged. Add one presentation-state operation to `PatternInboxProcessor`, select the non-destructive Later or destructive Discard action in `RootView` from the existing optional item identifier, and localize the new action.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, String Catalogs, Swift Package Manager, Xcode.

## Global Constraints

- Preserve all project data and pending shared files.
- Do not change StoreKit, trial, or lifetime entitlement behavior.
- Do not change the inbox storage or recovery format.
- Do not publish macOS 1.2.0.
- General failures must never delete an unknown inbox item.
- Existing user-owned changes and untracked files remain untouched.

---

### Task 1: Make General Inbox Failures Dismissible

**Files:**
- Modify: `Tests/KnitNoteCoreTests/PatternInboxAppContractTests.swift`
- Modify: `KnitNote/Patterns/PatternInboxProcessor.swift`
- Modify: `KnitNote/App/RootView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`

**Interfaces:**
- Consumes: `PatternInboxFailure.itemID: UUID?`
- Produces: `PatternInboxProcessor.dismissFailure() -> Void`
- Produces: localized key `patterns.inbox.later`

- [ ] **Step 1: Write the failing contract test**

Extend `failureHasReadableRetryAndDiscardActionsAndNoticeIsNonNavigating()` so it requires the general-failure escape path:

```swift
let processor = try readRepositoryFile("KnitNote/Patterns/PatternInboxProcessor.swift")

#expect(processor.contains("func dismissFailure()"))
#expect(processor.contains("failure = nil"))
#expect(root.contains("patterns.inbox.later"))
#expect(root.contains("patternInboxProcessor.dismissFailure()"))
#expect(root.contains("patternInboxProcessor.failure?.itemID"))
```

Extend the localization key list with:

```swift
"patterns.inbox.later",
```

The production mutation caught by this test is removal of the only non-destructive escape from a general failure.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter PatternInboxAppContractTests
```

Expected: FAIL because `dismissFailure()` and `patterns.inbox.later` do not exist.

- [ ] **Step 3: Add the minimal processor operation**

Add beside `retry()` and `discard()`:

```swift
func dismissFailure() {
    failure = nil
}
```

This method changes presentation state only.

- [ ] **Step 4: Add the general-failure Later branch**

Keep Retry first. Replace the existing one-sided conditional with:

```swift
if patternInboxProcessor.failure?.itemID != nil {
    Button("patterns.inbox.discard", role: .destructive) {
        patternInboxProcessor.discard()
    }
} else {
    Button("patterns.inbox.later", role: .cancel) {
        patternInboxProcessor.dismissFailure()
    }
}
```

Do not change the alert message or storage operations.

- [ ] **Step 5: Add English and Traditional Chinese localization**

Add `patterns.inbox.later` to `Localizable.xcstrings` with:

```json
"en": {
  "stringUnit": {
    "state": "translated",
    "value": "Later"
  }
},
"zh-Hant": {
  "stringUnit": {
    "state": "translated",
    "value": "稍後處理"
  }
}
```

- [ ] **Step 6: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter PatternInboxAppContractTests
```

Expected: all `PatternInboxAppContractTests` pass.

- [ ] **Step 7: Commit the behavior**

```bash
git add Tests/KnitNoteCoreTests/PatternInboxAppContractTests.swift \
  KnitNote/Patterns/PatternInboxProcessor.swift \
  KnitNote/App/RootView.swift \
  KnitNote/Localization/Localizable.xcstrings
git commit -m "fix: allow dismissing general inbox failures"
```

### Task 2: Verify Regression Safety and macOS Acceptance

**Files:**
- Modify only if an isolated verification defect is found; return to Task 1's RED-GREEN cycle before any code change.

**Interfaces:**
- Consumes: `PatternInboxProcessor.dismissFailure()`
- Produces: release evidence for Build 5 candidacy

- [ ] **Step 1: Run inbox and localization coverage**

Run:

```bash
swift test --filter PatternInbox
swift test --filter LocalizationContractTests
```

Expected: all selected tests pass.

- [ ] **Step 2: Run the complete Swift suite**

Run:

```bash
swift test
```

Expected: zero test failures.

- [ ] **Step 3: Verify macOS Release compilation**

Run:

```bash
xcodebuild -project KnitNote.xcodeproj \
  -scheme KnitNote \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/KnitNoteInboxDismissalDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Install a macOS candidate and reproduce the original state**

Launch KnitNote with the existing app data and pending inbox failure. Do not clear the app container or delete the pending shared file.

Expected: the alert shows Retry and Later.

- [ ] **Step 5: Verify non-destructive dismissal**

Choose Later.

Expected:

- the alert closes;
- existing projects remain visible;
- no pending shared file is deleted;
- no StoreKit error appears.

- [ ] **Step 6: Verify entitlement and persistence**

Create one project, quit KnitNote, reopen it, and inspect entitlement state.

Expected:

- the created project persists;
- the previously verified lifetime entitlement remains unlocked;
- no trial screen reappears;
- the app remains usable after relaunch.

- [ ] **Step 7: Record final evidence**

Run:

```bash
git status --short
git log -3 --oneline
```

Report the exact test counts, build result, physical macOS observations, commit, and all preserved user-owned dirty files. Do not archive, upload, submit, or publish without separate authorization.
