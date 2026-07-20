# Project Supporting Action Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the compact project note/pattern buttons with two full-width watercolor action cards matching the calculator card.

**Architecture:** Keep all state and sheet routing in `ProjectDetailView`. Change only the two action labels and their card containers; reuse existing localization keys and actions.

**Tech Stack:** SwiftUI, Swift Testing source contracts.

## Global Constraints

- Preserve note and pattern actions exactly.
- Use one `WatercolorCard` per action with a full-width leading `Label`.
- Preserve calculator → note → pattern → journal ordering.
- Do not change completion behavior, localization catalogs, or persistence.

### Task 1: Restyle the two project actions

**Files:**
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `Tests/KnitNoteCoreTests/EvenStitchAdjustmentViewContractTests.swift`

- [ ] Add a failing source contract that requires two full-width watercolor cards and rejects the old supporting-button layout.
- [ ] Run the focused test and confirm it fails on the current `supportingButton` implementation.
- [ ] Replace the old `HStack` with two `WatercolorCard` blocks containing plain full-width buttons and complete labels.
- [ ] Remove the now-unused `supportingButton` helper.
- [ ] Run focused and full tests, regenerate Xcode, build macOS, and run `git diff --check`.
