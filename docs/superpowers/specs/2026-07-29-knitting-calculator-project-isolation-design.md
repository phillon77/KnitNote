# Knitting Calculator Project Isolation Design

Date: 2026-07-29

## Goal

Fix the physical-iPhone letterboxing immediately, then isolate the free
Knitting Calculator from KnitNote's app, Watch, share-extension, release, and
metadata configuration so the same class of target-configuration omission
cannot recur.

## Confirmed root cause

The free `KnittingCalculator` target has neither a launch-screen declaration
nor a launch-screen resource. The main `KnitNote` target has both
`UILaunchStoryboardName: LaunchScreen` and `KnitNote/LaunchScreen.storyboard`.
On the physical iPhone, the free app therefore launches in a legacy-sized,
letterboxed compatibility presentation with black areas above and below.

This is a target configuration defect, not a SwiftUI content-size defect.
Changing fonts, padding, card sizes, or safe-area handling would treat the
symptom and must not be used as the fix.

## Phase 1: Immediate full-screen repair

- Give the free app its own launch screen at
  `KnittingCalculator/LaunchScreen.storyboard`.
- Declare `UILaunchStoryboardName: LaunchScreen` in the free target's generated
  Info.plist configuration.
- Include the storyboard only in the free app target's iOS resources.
- Add a project contract that fails if either the declaration or target
  resource membership is removed.
- Regenerate the Xcode project, build, install on the same physical iPhone, and
  verify that the app fills the complete screen.
- Preserve the interrupted Task 12 release-audit files in the original
  `codex/free-knitting-calculator` worktree.

## Phase 2: Independent Xcode project

Create `KnittingCalculator.xcodeproj` as the only project needed to build,
test, archive, and release the free app.

The independent project owns:

- app and test targets;
- Info.plist and launch screen;
- icons, colors, and localized resources;
- privacy manifest;
- App Store metadata and release-audit scripts;
- iPhone and iPad build/test schemes.

It must not contain or depend on:

- the KnitNote application target;
- KnitNote Watch targets;
- KnitNote Share Extension;
- KnitNote entitlements, StoreKit products, archives, or release metadata;
- KnitNote product-version and build-number contracts.

## Shared calculator core

The four pure calculator implementations become a small Swift Package with no
SwiftUI, UIKit, persistence, StoreKit, networking, or product metadata.

Both KnitNote and Knitting Calculator consume the package through explicit
target dependencies. The package has its own focused unit tests. App-specific
tests remain in their respective projects.

The first isolation step keeps the package in the existing repository to avoid
an unnecessary remote dependency. The project boundary is the required
release isolation; moving the package or app to another repository can happen
later without changing the public calculator APIs.

## Verification and acceptance

Automated acceptance:

- launch-screen contract first fails, then passes after the repair;
- `KnittingCalculator.xcodeproj` builds without a launch-screen warning;
- the free app's focused tests pass without building KnitNote, Watch, or Share;
- the free app can archive and pass its product-specific release audit;
- KnitNote continues to build against the shared package.

Physical acceptance:

- clean install on the same iPhone opens full screen with no black bars;
- portrait and landscape both fill the display;
- background, terminate, and reopen remain full screen;
- iPad portrait, landscape, and Split View remain responsive;
- physical-device results override simulator and build results.

## Migration and release boundary

- Do not create an App Store Connect record, upload, submit, merge, or push as
  part of this design.
- Do not delete the existing combined target until the independent project has
  equivalent build, test, archive, and physical-device evidence.
- Resume the interrupted Task 12 only after the full-screen fix is physically
  accepted, using the independent project once migration is complete.
