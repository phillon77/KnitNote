# Project Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent, reversible completed state that locks counters while preserving project content.

**Architecture:** `StoredProject.completedAt` is the single source of truth. Model mutation guards enforce locked counters; SwiftUI disables gestures and presents localized status controls and badges.

**Tech Stack:** Swift 6, SwiftUI, Codable JSON persistence, Swift Testing, String Catalog.

## Global Constraints

- Existing decoded projects remain in progress.
- Completion never deletes counters, notes, patterns, photos, or reading state.
- Completed counters are read-only in Project Detail and Pattern Reader.
- Notes, patterns, markup, highlights, navigation, editing, and resuming remain available.
- Traditional Chinese and English are both required.

---

### Task 1: Persistent Completion State

**Files:**
- Modify: `Tests/KnitNoteCoreTests/ProjectCounterTests.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`
- Modify: `Sources/KnitNoteCore/Projects/StoredProject.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`

**Interfaces:**
- Produces: `StoredProject.completedAt: Date?`, `isCompleted: Bool`, `markCompleted(at:)`, `resume(at:)`, plus matching store methods.

- [ ] Write failing tests for completion, counter locks, resume, legacy decoding, and store reload.
- [ ] Run focused model/store tests and confirm the missing APIs fail compilation.
- [ ] Add optional Codable state, completion methods, model counter guards, and store methods.
- [ ] Run focused tests and confirm they pass.

### Task 2: Completion UI and Localization

**Files:**
- Modify: `Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Modify: `KnitNote/Projects/EditProjectView.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `KnitNote/Projects/CounterSelectorGrid.swift`
- Modify: `KnitNote/Projects/ProjectCard.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Modify: `KnitNote/Patterns/PatternReaderControls.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`

**Interfaces:**
- Consumes: `StoredProject.isCompleted`, `completedAt`, and store completion methods.
- Produces: Edit actions, completion badges, dates, and disabled counter gestures.

- [ ] Write failing source and localization contract tests.
- [ ] Run focused contract tests and confirm they fail.
- [ ] Add localized status UI, badges, and `isEnabled` counter parameters.
- [ ] Run contracts, full tests, `git diff --check`, and an app build.
