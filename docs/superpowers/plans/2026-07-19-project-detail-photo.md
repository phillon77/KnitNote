# Project Detail Photo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the project photo, or the existing default icon, between the large project title and counter row.

**Architecture:** Reuse `ProjectPhotoView` and `JSONProjectStore.photoURL(for:)`; no new image storage or fallback implementation is needed.

**Tech Stack:** SwiftUI, Swift Testing.

## Global Constraints

- Keep the large project name.
- Use a centered 96 by 96 point rounded-square image.
- Use the existing fallback icon when the project has no photo.
- Keep counters and watercolor styling unchanged.

---

### Task 1: Project Detail Photo

**Files:**
- Modify: `Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`

**Interfaces:**
- Consumes: `ProjectPhotoView(url: URL?)` and `JSONProjectStore.photoURL(for:)`.
- Produces: A project detail header with a live project photo or default placeholder.

- [ ] **Step 1: Write a failing source-contract test**

Require `ProjectPhotoView(url: store.photoURL(for: project))`, a 96 by 96 frame, rounded clipping, and placement before `CounterSelectorGrid`.

- [ ] **Step 2: Verify the test fails**

Run: `swift test --filter projectDetailShowsPhotoOrDefaultIconBeforeCounters`

Expected: FAIL because the detail screen currently repeats `Text(project.name)`.

- [ ] **Step 3: Implement the photo header**

Replace the repeated small `Text(project.name)` with:

```swift
ProjectPhotoView(url: store.photoURL(for: project))
    .frame(width: 96, height: 96)
    .clipShape(.rect(cornerRadius: 22))
```

- [ ] **Step 4: Verify**

Run:

```bash
swift test --filter projectDetailShowsPhotoOrDefaultIconBeforeCounters
swift test --filter ProjectCounterViewContractTests
git diff --check
```

Expected: All focused tests pass and the diff check reports no errors.
