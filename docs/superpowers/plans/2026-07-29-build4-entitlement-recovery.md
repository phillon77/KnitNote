# KnitNote Build 4 Entitlement Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make KnitNote usable through its local seven-day trial when StoreKit verification is temporarily unavailable, and replace the raw project-store error with a deferred unlock presentation.

**Architecture:** `EntitlementCoordinator` will keep permanent access fail-closed while resolving local trial access independently from StoreKit availability. Project creation will translate `accessRestricted` into a typed presentation result so the child sheet dismisses before the root unlock sheet is requested.

**Tech Stack:** Swift 6, SwiftUI, StoreKit 2, Swift Testing, XCTest/XcodeBuild

## Global Constraints

- Only verified StoreKit data may grant lifetime or legacy-paid ownership.
- StoreKit unavailability may permit Keychain-backed trial access but never permanent access.
- Do not persist StoreKit availability as an entitlement or project it as a permanent Watch state.
- Do not expose `ProjectStoreError error 6` in user-facing UI.
- Do not change App Store pricing, availability, IAP metadata, external testing, or review state.
- Target release candidate is version `1.2.1`, Build `4`.

---

### Task 1: Resolve Local Trial While StoreKit Is Unavailable

**Files:**
- Modify: `Tests/KnitNoteAppTests/EntitlementCoordinatorTests.swift`
- Modify: `KnitNote/Entitlements/EntitlementCoordinator.swift`

**Interfaces:**
- Consumes: `PurchaseQualification.unavailable`, `TrialStore.load()`, `EntitlementResolver.resolve(purchase:trial:now:)`
- Produces: `EntitlementCoordinator.prepare()` that publishes a trial snapshot without granting permanent access

- [ ] **Step 1: Write failing coordinator tests**

Add tests that construct `EntitlementCoordinator` with
`PurchaseServiceSpy(qualification: .unavailable)` and:

```swift
@Test @MainActor
func unavailablePurchaseLookupStillPreparesTrialNotStarted() async {
    let trialStore = TrialStoreSpy(record: nil)
    let coordinator = EntitlementCoordinator(
        purchaseService: PurchaseServiceSpy(qualification: .unavailable),
        trialStore: trialStore
    )

    await coordinator.prepare()

    #expect(coordinator.verifiedSnapshot == .trialNotStarted)
    #expect(coordinator.allowsWrites)
}
```

Add parameterized coverage for active and expired trial records. Assert that
`.unavailable` never produces `.permanentlyUnlocked` or `.legacyPaidOwner`.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -quiet \
  -project KnitNote.xcodeproj \
  -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteBuild4CoordinatorRed \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests/EntitlementCoordinatorTests
```

Expected: the new unavailable-preparation tests fail because
`finishPreparation` leaves `isPrepared` false.

- [ ] **Step 3: Implement the minimal preparation change**

In `EntitlementCoordinator.prepare()`, keep the verified-purchase early return.
For `.none` and `.unavailable`, load the trial store and resolve using `.none`:

```swift
let trial = try trialStore.load()
return .prepared(resolver.resolve(
    purchase: .none,
    trial: trial,
    now: now()
))
```

Do not change `StoreKitPurchaseService` verification rules and do not map
`.unavailable` to a permanent snapshot.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Repeat the Step 2 command with derived data
`/tmp/KnitNoteBuild4CoordinatorGreen`.

Expected: all `EntitlementCoordinatorTests` pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add KnitNote/Entitlements/EntitlementCoordinator.swift \
  Tests/KnitNoteAppTests/EntitlementCoordinatorTests.swift
git commit -m "fix: allow local trial during StoreKit outage"
```

### Task 2: Defer Unlock Presentation Out of Project Creation

**Files:**
- Create: `KnitNote/Projects/CreateProjectPresentation.swift`
- Create: `Tests/KnitNoteAppTests/CreateProjectPresentationTests.swift`
- Modify: `KnitNote/Projects/CreateProjectView.swift`
- Modify: `KnitNote/Projects/ProjectsView.swift`

**Interfaces:**
- Produces:

```swift
enum CreateProjectFailurePresentation: Equatable {
    case requestUnlock
    case saveError(String)
}

struct CreateProjectFailureMapper {
    static func presentation(for error: Error) -> CreateProjectFailurePresentation
}
```

- `CreateProjectView` receives `onRequestUnlock: () -> Void`.
- `ProjectsView` owns a pending unlock flag and calls its existing
  `onShowUnlock` only after the create sheet has dismissed.

- [ ] **Step 1: Write failing mapper tests**

Create `CreateProjectPresentationTests.swift`:

```swift
import Testing
@testable import KnitNote

@Suite struct CreateProjectPresentationTests {
    @Test func accessRestrictionRequestsUnlock() {
        #expect(
            CreateProjectFailureMapper.presentation(
                for: ProjectStoreError.accessRestricted
            ) == .requestUnlock
        )
    }

    @Test func persistenceFailureRemainsSaveError() {
        let result = CreateProjectFailureMapper.presentation(
            for: ProjectStoreError.persistenceFailed
        )
        guard case let .saveError(message) = result else {
            Issue.record("Expected save error")
            return
        }
        #expect(!message.isEmpty)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -quiet \
  -project KnitNote.xcodeproj \
  -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteBuild4PresentationRed \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests/CreateProjectPresentationTests
```

Expected: compilation fails because the mapper does not exist.

- [ ] **Step 3: Implement the failure mapper**

Create `CreateProjectPresentation.swift` with the exact enum and mapper
interfaces above. Return `.requestUnlock` only for
`ProjectStoreError.accessRestricted`; return
`.saveError(error.localizedDescription)` for every other error.

- [ ] **Step 4: Route the child sheet outcome**

Update `CreateProjectView`:

```swift
let onRequestUnlock: () -> Void
```

On `.requestUnlock`, call `dismiss()` and then `onRequestUnlock()`; on
`.saveError`, set `errorMessage`.

Update `ProjectsView` to set `pendingUnlockAfterCreate = true` from the child.
Use the create sheet's `onDismiss` to consume that flag and call
`onShowUnlock()`. This guarantees the root unlock sheet is requested only after
the create sheet is gone.

- [ ] **Step 5: Run focused tests and verify GREEN**

Repeat Step 2 with derived data
`/tmp/KnitNoteBuild4PresentationGreen`.

Expected: all `CreateProjectPresentationTests` pass.

- [ ] **Step 6: Run comparable project and entitlement tests**

Run:

```bash
xcodebuild test -quiet \
  -project KnitNote.xcodeproj \
  -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteBuild4FocusedGreen \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests/EntitlementCoordinatorTests \
  -only-testing:KnitNoteAppTests/CreateProjectPresentationTests
```

Expected: zero failures.

- [ ] **Step 7: Commit Task 2**

```bash
git add KnitNote/Projects/CreateProjectPresentation.swift \
  KnitNote/Projects/CreateProjectView.swift \
  KnitNote/Projects/ProjectsView.swift \
  Tests/KnitNoteAppTests/CreateProjectPresentationTests.swift
git commit -m "fix: present unlock after project sheet dismissal"
```

### Task 3: Release Candidate Verification

**Files:**
- Modify only if required by project settings:
  `KnitNote.xcodeproj/project.pbxproj`
- Create: `AppStore/Verification/Build4EntitlementRecovery.md`

**Interfaces:**
- Produces: version `1.2.1` Build `4` candidate and recorded verification evidence

- [ ] **Step 1: Set Build 4**

Update every shipping KnitNote target's `CURRENT_PROJECT_VERSION` from `3` to
`4` while keeping `MARKETING_VERSION = 1.2.1`. Do not modify unrelated scheme
files.

- [ ] **Step 2: Run the Swift package suite**

```bash
swift test --scratch-path /tmp/KnitNoteBuild4SwiftTests
```

Expected: zero test failures.

- [ ] **Step 3: Run the app test suite**

```bash
xcodebuild test -quiet \
  -project KnitNote.xcodeproj \
  -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteBuild4AppTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: zero test failures.

- [ ] **Step 4: Build unsigned Release targets**

Run clean Release builds for:

```text
KnitNote / generic/platform=iOS
KnitNote / generic/platform=macOS
KnitNoteWatch / generic/platform=watchOS
KnitNoteShare / generic/platform=iOS
```

Use a separate `/tmp/KnitNoteBuild4-*` derived-data path for each build and
`CODE_SIGNING_ALLOWED=NO`.

Expected: all four builds succeed.

- [ ] **Step 5: Record exact evidence**

Create `AppStore/Verification/Build4EntitlementRecovery.md` containing commit,
commands, exit codes, test counts, build destinations, and the remaining
physical TestFlight acceptance steps. Do not claim physical acceptance before
the iPad run.

- [ ] **Step 6: Commit Task 3**

```bash
git add KnitNote.xcodeproj/project.pbxproj \
  AppStore/Verification/Build4EntitlementRecovery.md
git commit -m "chore: prepare KnitNote 1.2.1 Build 4"
```

- [ ] **Step 7: Stop before external actions**

Report verification evidence and request explicit authorization before archive,
upload, tester-group changes, or any App Store Connect mutation.
