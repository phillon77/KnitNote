# Independent Knitting Calculator Project Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to implement this plan task by task.
> Each implementation task requires a fresh implementer and a separate review.

**Goal:** Make `KnittingCalculator.xcodeproj` independently buildable,
testable, archivable, and releasable while KnitNote and the free app share only
a small calculator-domain Swift Package.

**Architecture:** Extract the four pure calculator implementations into a
repository-local `KnittingCalculatorCore` package. Add explicit package
dependencies to both products, create a calculator-only XcodeGen specification
and generated project, prove equivalence, and only then remove the free-app
targets from `KnitNote.xcodeproj`. Product UI, resources, metadata, tests, and
release evidence remain owned by their respective apps.

**Tech Stack:** Swift 6, Swift Package Manager, SwiftUI, XCTest, Swift Testing,
XcodeGen, Xcode 16+, `xcodebuild`, and `xcrun devicectl`.

## Global constraints

- Preserve the accepted full-screen launch repair and bundle identity
  `com.phillon.KnittingCalculator`, version `1.0.0`, build `1`.
- Do not change calculator behavior or public API during extraction.
- `KnittingCalculatorCore` must not import SwiftUI, UIKit, StoreKit, Combine,
  persistence, networking, or product metadata.
- Keep the package local to this repository for this migration.
- Do not remove the combined-project targets until independent build, tests,
  archive, and physical launch have equivalent evidence.
- Preserve the interrupted Task 12 files in the original calculator worktree.
- Do not create an App Store Connect record, upload, submit, merge, or push.

---

### Task 1: Extract the pure calculator domain package

**Files:**

- Create: `Packages/KnittingCalculatorCore/Package.swift`
- Move:
  `Sources/KnitNoteCore/Calculators/GaugeCalculator.swift` to
  `Packages/KnittingCalculatorCore/Sources/KnittingCalculatorCore/GaugeCalculator.swift`
- Move:
  `Sources/KnitNoteCore/Calculators/EvenStitchAdjustmentCalculator.swift` to
  `Packages/KnittingCalculatorCore/Sources/KnittingCalculatorCore/EvenStitchAdjustmentCalculator.swift`
- Move:
  `Sources/KnitNoteCore/Calculators/EvenStitchAdjustmentInputParser.swift` to
  `Packages/KnittingCalculatorCore/Sources/KnittingCalculatorCore/EvenStitchAdjustmentInputParser.swift`
- Move:
  `Sources/KnitNoteCore/Calculators/RowIntervalAdjustmentCalculator.swift` to
  `Packages/KnittingCalculatorCore/Sources/KnittingCalculatorCore/RowIntervalAdjustmentCalculator.swift`
- Move: `Tests/KnitNoteCoreTests/GaugeCalculatorTests.swift`
- Move: `Tests/KnitNoteCoreTests/EvenStitchAdjustmentCalculatorTests.swift`
- Move: `Tests/KnitNoteCoreTests/RowIntervalAdjustmentCalculatorTests.swift`
- Create:
  `Packages/KnittingCalculatorCore/Tests/KnittingCalculatorCoreTests/DependencyBoundaryTests.swift`

**Interfaces:**

- Produces library product and module `KnittingCalculatorCore`.
- Preserves all existing public calculator input, result, error, parser, and
  unit APIs.

- [ ] Write a package-boundary test that scans package production sources and
  rejects forbidden imports.
- [ ] Run the nested package test and confirm RED before `Package.swift` and
  the moved sources exist:

```bash
swift test --package-path Packages/KnittingCalculatorCore
```

- [ ] Create the Swift 6 package, move the implementations and their focused
  unit tests without behavior changes, and update test imports to
  `@testable import KnittingCalculatorCore`.
- [ ] Run the package suite and confirm GREEN:

```bash
swift test --package-path Packages/KnittingCalculatorCore
```

- [ ] Check the public API diff and commit only the package extraction.

---

### Task 2: Make KnitNote consume the shared package

**Files:**

- Modify: `Package.swift`
- Modify: `project.yml`
- Modify: `KnitNote/Calculators/GaugeCalculatorView.swift`
- Modify: `KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift`
- Modify: `KnitNote/Calculators/RowIntervalAdjustmentView.swift`
- Modify any remaining KnitNote source that uses calculator-domain types.
- Modify project/package contracts under `Tests/KnitNoteCoreTests/`.
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**

- `KnitNoteCore` depends on local package product `KnittingCalculatorCore`.
- Xcode target `KnitNote` explicitly links `KnittingCalculatorCore`.

- [ ] Add a failing contract asserting that KnitNote declares the local package
  dependency and no longer owns calculator implementation files.
- [ ] Update root `Package.swift` with a local package dependency and product
  dependency so existing non-Xcode tests compile.
- [ ] Update `project.yml`, import `KnittingCalculatorCore` at calculator
  consumers, and regenerate `KnitNote.xcodeproj`.
- [ ] Run:

```bash
swift test --filter GaugeCalculator
swift test --filter EvenStitchAdjustment
swift test --filter RowIntervalAdjustment
xcodebuild -project KnitNote.xcodeproj \
  -scheme KnitNote \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/KnitNoteSharedCalculatorCore \
  CODE_SIGNING_ALLOWED=NO build
```

- [ ] Confirm KnitNote builds without duplicate symbols or missing imports and
  commit the consumer migration.

---

### Task 3: Create the independent calculator Xcode project

**Files:**

- Create: `KnittingCalculator/project.yml`
- Create: `KnittingCalculator.xcodeproj/project.pbxproj` via XcodeGen
- Create shared scheme files generated for `KnittingCalculator`.
- Modify: root `project.yml` only as needed to avoid duplicate ownership during
  the equivalence window.
- Modify: `Tests/KnitNoteCoreTests/KnittingCalculatorProjectContractTests.swift`
- Create calculator-project contract tests under `KnittingCalculatorTests/` if
  runtime-independent placement is needed.

**Interfaces:**

- Project contains only `KnittingCalculator` and
  `KnittingCalculatorTests` targets.
- App target depends on local package
  `../Packages/KnittingCalculatorCore`.
- Owns calculator Info.plist, launch screen, assets, localizations, privacy
  manifest, and test scheme.

- [ ] Write failing contracts for the independent project topology, package
  dependency, bundle/version settings, launch resource membership, and absence
  of KnitNote, Watch, Share, StoreKit config, and KnitNote entitlements.
- [ ] Create calculator-only XcodeGen spec using paths relative to
  `KnittingCalculator/project.yml`.
- [ ] Generate only the independent project:

```bash
xcodegen generate \
  --spec KnittingCalculator/project.yml \
  --project .
```

- [ ] Verify the generated project lists exactly the app and test targets:

```bash
xcodebuild -list -project KnittingCalculator.xcodeproj
```

- [ ] Build and test without invoking `KnitNote.xcodeproj`:

```bash
xcodebuild -project KnittingCalculator.xcodeproj \
  -scheme KnittingCalculator \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/IndependentKnittingCalculatorBuild \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project KnittingCalculator.xcodeproj \
  -scheme KnittingCalculator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -derivedDataPath /tmp/IndependentKnittingCalculatorTests
```

- [ ] Inspect the built Info.plist and app bundle for bundle ID, version/build,
  launch storyboard, privacy manifest, localization resources, and AppIcon.
- [ ] Commit the independent project and contracts.

---

### Task 4: Prove archive and release-audit independence

**Files:**

- Modify:
  `AppStore/Verification/knitting_calculator_release_audit.sh`
- Modify:
  `AppStore/Verification/KnittingCalculatorPhysicalVerification.md`
- Modify applicable calculator-only release metadata/contracts.

**Interfaces:**

- Audit accepts or resolves `KnittingCalculator.xcodeproj` directly.
- Audit does not read KnitNote, Watch, Share, or KnitNote release-version state.

- [ ] Add failing audit assertions proving the project path and product scope
  are calculator-only.
- [ ] Update the interrupted Task 12 audit script and ledger only after copying
  their preserved work into the migration branch.
- [ ] Create an unsigned generic archive:

```bash
xcodebuild archive \
  -project KnittingCalculator.xcodeproj \
  -scheme KnittingCalculator \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/KnittingCalculatorIndependent.xcarchive \
  -derivedDataPath /tmp/KnittingCalculatorIndependentArchive \
  CODE_SIGNING_ALLOWED=NO
```

- [ ] Run the product-specific static audit against the archive/project and
  confirm KnitNote version, Watch packaging, and Share Extension cannot affect
  its result.
- [ ] Record exact commands, commit, version/build, and results; commit the
  release-audit isolation.

---

### Task 5: Physical-device equivalence gate

**Files:**

- Modify:
  `AppStore/Verification/KnittingCalculatorPhysicalVerification.md`

**Interfaces:**

- Consumes a signed build produced only by
  `KnittingCalculator.xcodeproj`.
- Produces physical equivalence evidence for removal of the old combined
  target.

- [ ] Build, install, and launch the independent project on the same physical
  iPhone.
- [ ] Record PASS/FAIL for clean launch, no bars, portrait, landscape,
  terminate/reopen, and background/foreground.
- [ ] Verify density calculation and both adjustment modes produce the same
  representative results as before migration.
- [ ] Verify settings persistence, help, share/copy actions, and restrained
  KnitNote promotion link.
- [ ] Run iPad portrait, landscape, and Split View checks on an available
  physical device; if no physical iPad is available, mark those rows BLOCKED,
  not PASS.
- [ ] Commit the physical evidence only after the user confirms visible
  behavior.

---

### Task 6: Remove combined-project calculator targets and close migration

**Files:**

- Modify: root `project.yml`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`
- Modify:
  `Tests/KnitNoteCoreTests/KnittingCalculatorProjectContractTests.swift`
- Modify release documentation to point to `KnittingCalculator.xcodeproj`.

**Interfaces:**

- `KnitNote.xcodeproj` contains no `KnittingCalculator` or
  `KnittingCalculatorTests` target.
- Both products continue consuming the one shared package.

- [ ] Add a failing contract asserting that the combined project no longer
  declares calculator targets or their app resources.
- [ ] Remove only those two targets and the calculator scheme from root
  `project.yml`, regenerate, and update contracts/documentation.
- [ ] Re-run package tests, calculator tests/build/archive/audit, and KnitNote
  generic iOS build.
- [ ] Run `git diff --check` and inspect the final diff for accidental KnitNote
  release, entitlement, Watch, Share, or App Store state changes.
- [ ] Request independent code review of the complete migration.
- [ ] Keep the branch/worktree intact if the repository-wide suite still has
  unrelated failures; report narrow verification separately.
- [ ] After this task, resume Task 12 using only
  `KnittingCalculator.xcodeproj`.

## Completion evidence

Migration is complete only when all of the following are true:

- the shared package suite passes;
- KnitNote builds against the shared package;
- the independent app build and test suite pass without building KnitNote;
- the independent archive and calculator-only audit pass;
- the same physical iPhone remains full screen across all six launch states;
- physical iPad results are recorded or explicitly BLOCKED;
- the combined project no longer owns the calculator targets;
- no external App Store, Git remote, upload, submit, merge, or push action has
  occurred.
