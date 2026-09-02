# KnitNote Cross-Device iCloud Sync Roadmap

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this roadmap plan-by-plan. Each child plan uses checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver offline-first iPhone, iPad, and Mac synchronization without weakening local persistence, backup, or Watch reliability.

**Architecture:** Keep `JSONProjectStore` as the local source of truth, add deterministic domain synchronization primitives, connect them to CloudKit with `CKSyncEngine`, then add migration, account isolation, UI, and release verification. The four plans are sequential because each consumes explicit interfaces from the preceding plan.

**Tech Stack:** Swift 6, Swift Testing, Foundation, CryptoKit, CloudKit, CKSyncEngine, SwiftUI, XcodeGen

**Spec:** `docs/superpowers/specs/2026-09-02-cross-device-icloud-sync-design.md`

## Global Constraints

- Deployment floors remain iOS 18.0, macOS 15.0, and watchOS 11.0.
- iPhone, iPad, and Mac use one CloudKit private database; Watch continues through the paired iPhone only.
- Local writes complete before sync publication; no network condition may block ordinary editing.
- User content, UUIDs, knitting numbers, abbreviations, and yarn links must remain lossless.
- Unlinking `ProjectYarnLink` never deletes `Yarn`.
- App language, UI preferences, StoreKit state, and rebuildable caches never sync.
- Destructive cloud schema deployment, build upload, or App Review submission requires separate explicit authorization.
- Every implementation plan ends in a reviewable, independently testable commit series.

## Execution Order

1. `docs/superpowers/plans/2026-09-02-cross-device-sync-1-core.md`
   - Deterministic record model, merge engine, durable mutation journal, local-store publication boundary.
2. `docs/superpowers/plans/2026-09-02-cross-device-sync-2-cloudkit-assets.md`
   - CKRecord mapping, CKSyncEngine adapter, private-zone transport, immutable asset staging and conflict groups.
3. `docs/superpowers/plans/2026-09-02-cross-device-sync-3-migration-account-safety.md`
   - Existing-data bootstrap, staged installation, recent deletion, account-scoped encrypted recovery vault.
4. `docs/superpowers/plans/2026-09-02-cross-device-sync-4-product-release.md`
   - App lifecycle wiring, status UI, backup and Watch integration, localization, entitlements, end-to-end and physical release gates.

## Cross-Plan Gate

Do not begin the next plan until the current plan's targeted tests, full `swift test`, `git diff --check`, and an independent code review pass. CloudKit development-container integration starts in Plan 2; production schema deployment is only a documented manual gate in Plan 4.
