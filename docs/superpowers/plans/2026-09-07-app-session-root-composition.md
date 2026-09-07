# App Session Composition and Root Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing local owner into the actual App, with fixed typed session dependencies, a real generation-isolated SwiftUI subtree and pre-factory screenshot isolation.

**Architecture:** Extend AppSessionResources rather than add another lifetime layer. KnitNoteApp owns one AppSessionOwner, and the production root wrapper reads its optional session and injects that exact session's store/inbox/presenters under one identity. Existing shipping local behavior is preserved with sync disabled; account authority/transaction activation is the subsequent consumer, not inferred from this compatibility route.

**Tech Stack:** Swift6,SwiftUI,Combine,SwiftTesting,actual-source isolated macOS hosting tests,Xcode.

**Spec:** `docs/superpowers/specs/2026-09-07-app-session-owner-integration-design.md` and upper `2026-09-06-cloud-sync-app-session-lifecycle-design.md` (same specs directory). User approved routine execution through release preparation without repeated small decisions.

## Global Constraints

- 維持1.7.0(13)，iOS18/macOS15/watchOS11；不改100,000,000-byte與64MiB上限、資料/wire格式、購買、語言偏好、開發故事或30天復原條件。
- No real App launch, live CloudKit/Keychain/Watch construction in tests, production-data operations, signing/install/push/merge/upload/submission.
- Normal shipping remains existing local-only compatibility behavior. Do not label existing global store a verified unbound legacy source, or open account paths based on cached identity. No cloud enablement or account-transition acceptance claim.
- Preserve already-proven owner/gate/group invariants; reuse completed source, never reopen completed SDD plans or rerun their tasks as new work.
- Full account install/readiness/bootstrap-restart work remains next, explicitly unfinished. This plan wires actual App composition/UI rather than another stop foundation.

### Task 1: Typed composition, actual root and factory routing

**Files:**
- Modify `KnitNote/App/AppSessionResources.swift`, `KnitNote/App/KnitNoteApp.swift`.
- Create `KnitNote/App/AppSessionRootView.swift`, `KnitNote/App/AppSessionComposition.swift`.
- Create `Tests/KnitNoteAppTests/AppSessionCompositionTests.swift`, `Tests/KnitNoteAppTests/AppSessionRootViewTests.swift`; optional `AppSessionCompositionTestSupport.swift` only if needed.
- Modify existing PBX memberships and `project.yml` only if required to keep existing source generation consistent; do not add targets or change release settings.

**Interfaces:**
- Consumes existing owner `visibleSession`, `beginTransition()`, `publishPreparedSession(_:for:)`, `waitForRetiredSessions()` and fixed store/group APIs.
- Add a typed `AppSessionPresentationResources` containing immutable `patternInboxProcessor`, `patternBackupReminderPresenter`, `reminderPresentationStore`, optional `AppSessionWatchResources` (fixed coordinator and native adapter). Add `presentation: AppSessionPresentationResources?` to AppSessionResources so existing lower-level test initializer remains compatible; the App composition path always supplies it. Root rejects missing presentation, never silently creates substitute dependencies. These are composition values, not account-readiness evidence.
- `AppSessionComposition.make(store:backupHistory:makeWatch:) throws -> AppSessionResources` creates its own presenters and inbox for the supplied fixed store, uses lazy `makeWatch: (JSONProjectStore) throws -> AppSessionWatchResources?`, and internally registers inbox/coordinator/adapter exactly once in the resource group. Ensure a failed construction stops/joins accepted work or prove none has started; factory must not start producers before successful full assembly.
- `AppSessionRootView<Content: View, Unavailable: View>` consumes owner plus content/unavailable builders. It owns the actual conditional session selection, required presentation unwrap, four environment injections and `.id(session.id)` around the entire content subtree. Shared entitlement/locale/update environment comes from App outside boundary.

- [ ] **Step 1: Write actual-source REDs for composition and root identity.** Create fresh `/tmp/knitnote-app-root-XXXXXX` harness from inspected current owner harness manifest/inventory via symlinks and add SwiftUI production/new tests. Preserve the old harness. No copied production implementation. Use explicit native operations and temporary Watch support root. Composition tests assert identical fixed store used by actual inbox/coordinator, different presenter identities between sessions, and stop/drain of all three real producers.

```swift
@Test @MainActor func oldAndNewSessionPresentationNeverMix() async throws {
    try await withCompositionFixture { fixture in
        let first = try fixture.makeFirst()
        let second = try fixture.makeSecond()
        let a = try #require(first.presentation)
        let b = try #require(second.presentation)
        #expect(a.patternInboxProcessor !== b.patternInboxProcessor)
        #expect(a.patternBackupReminderPresenter !== b.patternBackupReminderPresenter)
        #expect(a.reminderPresentationStore !== b.reminderPresentationStore)
        let owner = AppSessionOwner()
        try owner.publishPreparedSession(first, for: owner.generation)
        let generation = owner.beginTransition()
        try await owner.waitForRetiredSessions()
        try owner.publishPreparedSession(second, for: generation)
        #expect(owner.visibleSession === second)
        #expect(first.store.isSessionWriteRevoked)
        #expect(!second.store.isSessionWriteRevoked)
    }
}
```

Fixture builds actual store/inbox/Watch components, independent direct component/store joins before deleting roots. It may reuse existing test fixtures only with verified lifetime and no private cross-file access. Native support root must be explicit rather than PhoneWatchSyncCoordinator's shared default.

- [ ] **Step 2: Implement typed composition with one lifetime group.** Extend resource designated initializer privately/internal as necessary so presentation and producer group are fixed together. No arbitrary prebuilt inbox with unrelated store in the App public composition path. AppSessionWatchResources is platform-neutral because native adapter now compiles on macOS; only live construction is iOS conditional. Do not start Watch during factory construction.

```swift
let backup = PatternBackupReminderPresenter(history: backupHistory)
let reminders = KnittingReminderPresentationStore()
let inbox = PatternInboxProcessor(store: store, backupReminderPresenter: backup)
let watch = try makeWatch(store)
// Same exact objects are both exposed through presentation and registered
// in the resource's private fixed group: inbox, optional coordinator, adapter.
```

- [ ] **Step 3: Implement production root and real hosting tests.** Construct actual generic wrapper, not a test copy:

```swift
Group {
    if let session = owner.visibleSession, let presentation = session.presentation {
        content()
            .environmentObject(session.store)
            .environmentObject(presentation.patternInboxProcessor)
            .environmentObject(presentation.patternBackupReminderPresenter)
            .environmentObject(presentation.reminderPresentationStore)
            .id(session.id)
    } else {
        unavailable()
    }
}
```

Use NSHostingView on macOS with instrumented Content reading actual environment and @State selection/preview markers. Drive host layout/event-cycle using the existing MacYarnEditorLayoutTests pattern, not sleep/yield/emptyTask assumptions. Verify two windows share fixed instances, A→nil removes content, B restores new identities/reset state even with identical project UUID, and shared entitlement/language changes do not replace B. Preserve and invoke old A mutation closure to assert A revoked/B unchanged. If runtime cannot prove actual subtree behavior, report that limitation; don't replace with source `.id` string assertions. No real user windows or production App host.

- [ ] **Step 4: Wire KnitNoteApp through lazy launch routing.** Replace session-specific StateObjects with one owner. Preserve App-global entitlement, updates, language/locale and appropriate normal-mode projections. Keep RootView unchanged except any necessary explicit session callback routing. Publish one fully-composed compatibility local session during App initialization; no per-window factory. The shipping compatibility path continues existing non-sync global store behavior, not account binding/adoption. Language Watch publication reads the currently visible typed bundle only.

Screenshot branch must be selected before lazy live-store/Watch/projection/keychain/cloud factories. It uses explicit screenshot baseDirectory store overload and screenshot entitlement; no nativeWatch, languageprojection or entitlementprojection construction/write. Invalid screenshot requests retain existing fail-closed behavior. AppUpdateFixture remains a response fixture, not claimed to be an isolated full-session mode; don't broaden it into a new fixture product or change normal behavior under that flag silently. New isolated tests inject dependencies rather than launch real App.

Add routing tests against the actual composition route with throwing/counting lazy production closures: screenshot/isolated composition must leave forbidden counts at zero. Avoid calling StoreScreenshotMode.resolve in a unit test since it mutates fixture folders; inject resolved mode/path. Normal route start Watch only after resource publication and only for existing local-only behavior; no true cross-account Watch route. Preserve platform conditional build and App update/user-facing behavior. Unavailable builder uses safe existing localized loading state during this compatibility slice; full account reason/retry presentation comes with real identity orchestration, not raw errors or invented synced state.

- [ ] **Step 5: Focused/complete tests, self-review, commit.** Get runtime RED for wrong presentation identity and missing subtree reset, plus forbidden factory construction; restore before GREEN. Run combined new+existing owner/producer/native no-host suite once before commit. Existing relevant screenshot/App update/source contracts may need legitimate assertions updated for root delegation; do not weaken safety checks to accept new callsites. PBXlint/diffcheck, log paths/exits/hashes and precise source/target membership in report. Ask controller before any large build to avoid overlap.

```sh
python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --no-parallel
git diff --check
plutil -lint KnitNote.xcodeproj/project.pbxproj
git add -- KnitNote/App/AppSessionResources.swift KnitNote/App/AppSessionComposition.swift KnitNote/App/AppSessionRootView.swift KnitNote/App/KnitNoteApp.swift Tests/KnitNoteAppTests/AppSessionCompositionTests.swift Tests/KnitNoteAppTests/AppSessionRootViewTests.swift KnitNote.xcodeproj/project.pbxproj
git commit -m 'feat(sync): wire fixed sessions into the App root'
```

Explicit optional files only if changed. Report scope limits: this is actual local/screenshot App wiring, not identity/cloud activation; no blanket whole-sync completion claim.

### Task 2: Independent review and fixed-candidate verification (controller)

**Files:** `docs/superpowers/reports/2026-09-07-app-session-root-composition-verification.md`.

- [ ] Review Task1 and entire subplan baseline73d5749..HEAD, named root/fixture/account boundary risks, then scoped fixes. Preserve exact tests/runtime evidence and explicitly review source-contract changes.
- [ ] Freeze candidate; run fullCore, combined actualsource/hosting tests, macOS unsignedbuildfortesting and iOS unsignedbuild serially. Reuse inspected boundedrunner, new unique logs and `/tmp/app-root-{macos,ios}-derived` directories. No live App host/services.

```sh
python3 /tmp/task4-run-bounded.py 3600 arch -arm64 swift test --no-parallel
python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --no-parallel
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/app-root-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/app-root-ios-derived CODE_SIGNING_ALLOWED=NO build
```

- [ ] Save report/loghashes/frozenidentities/rulings and continue account orchestration under existing approval, not pauseautomation. Account mapper `/tmp/app-account-install-mapping.md` identifies required real canonical install/ACK/source validation and bootstrap-restart bridge; identity notes `/tmp/app-account-identity-interface-notes.md`. Do not infer cache account/empty files as legacy evidence. All remaining release gates unchanged.

## Self-review

Task1 integrates a single inseparable typed-session/root/launch-routing boundary, not an extra stop abstraction. Task2 verifies it. Resources appear both in actual App and real hosting tests. No arbitrary account proof or livecloud enablement is introduced. Parent identity/bootstrap/readiness work remains explicitly incomplete and follows this slice; no checkbox in this plan substitutes for those gates.
