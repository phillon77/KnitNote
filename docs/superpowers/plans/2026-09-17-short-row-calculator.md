# Shoulder Short Rows Implementation Plan

**Goal:** Add an independent shoulder short-row tool to Knitting Calculator and current KnitNote, sharing calculation and SwiftUI presentation.
**Approved scope:** 2026-09-17 conversation: gauge, target height, one shoulder width; rounded height, turns, distribution, row-by-row instructions, staircase preview; shoulder mode only.
**Architecture:** A local Swift package `Packages/ShortRowKit` owns the engine, localized input parser, localized screen and diagram. Both apps depend on the same package sources. Keep matching copies in the existing Calculator worktree and the new KnitNote feature worktree; do not change other Calculator work in progress.
**Tech stack:** Swift 6, Swift Testing, SwiftUI; iOS 18/macOS 15. No new remote dependencies.

## Calculation contract
- Work a single separated shoulder from neck edge toward armhole, progressively shorter rows; start face selectable. Use wrap-and-turn on the NEXT unworked stitch. Return rows go to neck edge without a short-row wrap.
- Let R = round(height * rowsPer10cm / 10 / 2) * 2, ties upward. Reject R < 2; report actual R * 10 / rowsPer10cm.
- T = R/2 pairs. Split W into T+1 positive segments. This reserves an inner worked segment: W/T would produce a zero-length final row. Distribute remainder evenly, deterministic outer-to-inner. Each odd row works W minus cumulative outer segments; each even row returns over that same number of stitches.
- Final full shoulder row resolves all wraps; it adds equally to all stitches and is excluded from height difference. No automatic binding off or neckline shaping.
- Maximum 10,000 shoulder stitches and 200 shaping rows. Reject nonfinite/nonpositive inputs, insufficient width, fractional stitch counts, trailing text, or ambiguous grouped numeric input.
- en and zh-Hant are first-class. Other locales use English fallback. No persistence, ads, account, cloud, or release changes.

## Tasks
- [x] Add `ShortRowCalculatorTests.swift`: hand-derived W24/R6 => outgoing 18,12,6; actual per-stitch extra rows 6...0; remainder widths; ties; zero/NaN/infinity; overcrowded turns; strict locale parsing.
- [x] Observe failing tests, implement `ShortRowCalculator.swift` and `ShortRowInput.swift`, run `swift test --package-path Packages/ShortRowKit`.
- [x] Add `ShortRowCalculatorView.swift`, `ShortRowDiagram.swift`, and en/zh-Hant package resources. Provide blank inputs, sample button, inline validation, explicit start face, summary, steps and final wrap resolution instructions. Use labels and text for screen-reader alternatives.
- [x] Add ShortRowKit local package and a navigation link to each app's project.yml/tool screen; use package-owned localized navigation labels without changing app string catalogs, regenerate projects preserving prior work.
- [x] Verify package tests, existing Calculator core tests, iOS Simulator builds for both apps and macOS KnitNote build. Inspect rendered UI if available. Review diff and verify identical package sources across worktrees. Record evidence and limitations.

## Domain references
- https://www.purlsoho.com/create/short-rows-wrap-turn/ (wrap next unworked stitch; resolve wraps on later full row).
- https://www.creativefibre.org.nz/education/finesse-your-knitting-shoulder-and-back-neck-shaping/ (shoulder segments worked progressively shorter).
- The T+1 segment contract is derived from this specific schedule, not a claim that every shoulder pattern uses the same formula. A stitch-level row-count test independently verifies the height difference.
