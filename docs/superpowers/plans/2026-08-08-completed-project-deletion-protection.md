# KnitNote 1.4.1 Completed-Project Deletion Protection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent accidental deletion of completed projects until the user explicitly restores the project to in-progress status.

**Architecture:** Enforce the rule in `JSONProjectStore` as the source-of-truth boundary, and independently project the same state into `EditProjectView` so the destructive action is visibly disabled with guidance. Reuse the existing resume and confirmed deletion flows; do not add a data migration or recovery system.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, macOS app-hosted tests, String Catalog, Python metadata validation, Xcode 26.

## Global Constraints

- This is a key KnitNote 1.4.1 update.
- Only completed projects are protected; in-progress projects retain the existing two-step deletion confirmation.
- A completed project becomes deletable only after `resumeProject(projectID:)` succeeds.
- Project deletion remains available regardless of trial or purchase state.
- The store must reject completed-project deletion even when called outside the editor UI.
- No archive schema change, deleted-item recovery, trash folder, new dependency, or remote service.
- New visible and accessibility copy must be complete in all twelve 1.4.1 runtime languages.
- Every production change follows a witnessed RED-GREEN TDD cycle.

---

### Task 1: Enforce completed-project protection in the store

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Produces: `ProjectDeletionError.projectCompleted`.
- Changes: `JSONProjectStore.delete(id:)` throws `ProjectDeletionError.projectCompleted` before staging files or persisting data when the target project is completed.
- Preserves: missing-ID deletion remains a no-op; in-progress deletion keeps its current transaction and cleanup behavior.

- [ ] **Step 1: Write the failing completed-project preservation test**

Add beside the existing project persistence/deletion tests:

```swift
@MainActor
@Test func completedProjectDeletionIsRejectedWithoutChangingStoredData() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CompletedDeletion-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = JSONProjectStore(url: url)
    try store.add(name: "Finished cardigan")
    let projectID = try #require(store.projects.first?.id)
    try store.markCompleted(projectID: projectID)
    let archiveBefore = try Data(contentsOf: url)

    #expect(throws: ProjectDeletionError.projectCompleted) {
        try store.delete(id: projectID)
    }

    #expect(store.project(id: projectID)?.isCompleted == true)
    #expect(try Data(contentsOf: url) == archiveBefore)
}
```

- [ ] **Step 2: Write the failing resume-then-delete test**

```swift
@MainActor
@Test func resumedProjectCanBeDeleted() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ResumedDeletion-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = JSONProjectStore(url: url)
    try store.add(name: "Finished cardigan")
    let projectID = try #require(store.projects.first?.id)
    try store.markCompleted(projectID: projectID)
    try store.resumeProject(projectID: projectID)

    try store.delete(id: projectID)

    #expect(store.project(id: projectID) == nil)
    #expect(JSONProjectStore(url: url).project(id: projectID) == nil)
}
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```bash
swift test --filter 'completedProjectDeletionIsRejectedWithoutChangingStoredData|resumedProjectCanBeDeleted'
```

Expected: compilation fails because `ProjectDeletionError` does not exist, proving the new guard is absent.

- [ ] **Step 4: Add the error and guard at the mutation boundary**

Add near the existing project mutation error types:

```swift
public enum ProjectDeletionError: Error, Equatable, Sendable {
    case projectCompleted
}
```

In `delete(id:)`, keep authorization first, resolve the project, and guard before collecting filenames or starting `PatternLibraryDeletionTransaction`:

```swift
public func delete(id: UUID) throws {
    try requireAccess(.deleteProject)
    guard let deletedProject = projects.first(where: { $0.id == id }) else { return }
    guard !deletedProject.isCompleted else {
        throw ProjectDeletionError.projectCompleted
    }
    // Existing transactional deletion continues unchanged.
}
```

- [ ] **Step 5: Run focused and entitlement regression tests**

Run:

```bash
swift test --filter 'JSONProjectStoreTests|FeatureAccessPolicyTests|JSONProjectStoreEntitlementTests'
```

Expected: PASS; completed deletion is rejected, resumed deletion succeeds, and deletion remains entitlement-independent.

- [ ] **Step 6: Commit the store boundary**

```bash
git add Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift
git commit -m "feat: protect completed projects from deletion"
```

---

### Task 2: Disable completed-project deletion in the editor

**Files:**
- Modify: `KnitNote/Projects/EditProjectView.swift`
- Modify: `Tests/KnitNoteAppTests/EditProjectDeletionActionTests.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`

**Interfaces:**
- Produces: internal `ProjectDeletionAvailability` with `.allowed` and `.requiresResume`.
- Consumes: `StoredProject.isCompleted` and `ProjectDeletionError.projectCompleted` from Task 1.
- Changes: the editor delete button remains visible but is disabled for `.requiresResume`; explanatory text appears directly below it.

- [ ] **Step 1: Write failing editor availability tests**

Extend `EditProjectDeletionActionTests.swift`:

```swift
@MainActor
@Test func completedProjectRequiresResumeBeforeEditorDeletion() throws {
    var project = try StoredProject(name: "Finished cardigan")
    project.markCompleted(at: Date(timeIntervalSince1970: 1_000))

    #expect(ProjectDeletionAvailability(project: project) == .requiresResume)
}

@MainActor
@Test func inProgressProjectAllowsEditorDeletion() throws {
    let project = try StoredProject(name: "Cardigan")

    #expect(ProjectDeletionAvailability(project: project) == .allowed)
}
```

- [ ] **Step 2: Run the app-hosted tests and verify RED**

Run outside the restricted sandbox if Xcode cannot access its services:

```bash
xcodebuild test \
  -project KnitNote.xcodeproj \
  -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteCompletedDeletionTDD \
  -only-testing:KnitNoteAppTests/EditProjectDeletionActionTests \
  CODE_SIGNING_ALLOWED=NO \
  -quiet
```

Expected: FAIL because `ProjectDeletionAvailability` does not exist.

- [ ] **Step 3: Add the presentation seam and wire it to the editor**

Add above `EditProjectView`:

```swift
enum ProjectDeletionAvailability: Equatable {
    case allowed
    case requiresResume

    init(project: StoredProject?) {
        self = project?.isCompleted == true ? .requiresResume : .allowed
    }
}
```

Resolve it from the current project, retain the existing destructive button, and add the state projection:

```swift
private var deletionAvailability: ProjectDeletionAvailability {
    ProjectDeletionAvailability(project: project)
}
```

```swift
Section {
    Button("common.delete", systemImage: "trash", role: .destructive) {
        showingDeleteConfirmation = true
    }
    .disabled(deletionAvailability == .requiresResume)

    if deletionAvailability == .requiresResume {
        Text("project.delete.requiresResume")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
```

The confirmation dialog and `EditProjectDeletionAction.perform` remain the only allowed editor deletion route. Do not auto-resume or delete from the disabled button.

- [ ] **Step 4: Add the exact twelve-language guidance key**

Add `project.delete.requiresResume` to `Localizable.xcstrings` with these values:

```text
en: Restore this project to in progress before deleting it.
zh-Hant: 請先將作品恢復為進行中，才能刪除。
zh-Hans: 请先将作品恢复为进行中，才能删除。
de: Setze dieses Projekt vor dem Löschen auf „In Bearbeitung“ zurück.
fr: Remettez ce projet en cours avant de le supprimer.
ja: この作品を削除するには、先に「進行中」に戻してください。
nb: Gjenoppta prosjektet før du sletter det.
sv: Återuppta projektet innan du tar bort det.
fi: Jatka projektia ennen kuin poistat sen.
da: Genoptag projektet, før du sletter det.
ko: 이 프로젝트를 삭제하려면 먼저 진행 중으로 되돌리세요.
el: Επαναφέρετε πρώτα το έργο σε εξέλιξη για να το διαγράψετε.
```

Add this key to the required semantic localization dictionary and require all twelve locales.

- [ ] **Step 5: Run editor and localization tests**

Run:

```bash
xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteCompletedDeletionTDD -only-testing:KnitNoteAppTests/EditProjectDeletionActionTests CODE_SIGNING_ALLOWED=NO -quiet
swift test --filter 'LocalizationContractTests|FeatureAccessPolicyTests'
```

Expected: PASS with the editor availability and all twelve translations covered.

- [ ] **Step 6: Commit the editor protection**

```bash
git add KnitNote/Projects/EditProjectView.swift KnitNote/Localization/Localizable.xcstrings Tests/KnitNoteAppTests/EditProjectDeletionActionTests.swift Tests/KnitNoteCoreTests/LocalizationContractTests.swift
git commit -m "feat: explain completed-project deletion protection"
```

---

### Task 3: Present deletion protection as a key 1.4.1 update

**Files:**
- Modify: `AppStore/Metadata/en-US.md`
- Modify: `AppStore/Metadata/zh-Hant.md`
- Modify: `AppStore/Metadata/zh-Hans.md`
- Modify: `AppStore/Metadata/de-DE.md`
- Modify: `AppStore/Metadata/fr-FR.md`
- Modify: `AppStore/Metadata/ja-JP.md`
- Modify: `AppStore/Metadata/nb-NO.md`
- Modify: `AppStore/Metadata/sv-SE.md`
- Modify: `AppStore/Metadata/fi-FI.md`
- Modify: `AppStore/Metadata/da-DK.md`
- Modify: `AppStore/Metadata/ko-KR.md`
- Modify: `AppStore/Metadata/el-GR.md`
- Modify: `AppStore/Verification/metadata_check_test.py`

**Interfaces:**
- Consumes: the existing 1.4.1 six-language What's New sentence.
- Produces: truthful What's New copy naming completed-project deletion protection in every App Store locale.

- [ ] **Step 1: Add failing metadata assertions**

In `metadata_check_test.py`, add a semantic assertion that all twelve What's New fields contain the locale-appropriate protection phrase and do not claim deleted projects can be recovered. Use these exact appended sentences as the expected fixture:

```text
en-US: Completed projects are now protected from accidental deletion; restore one to in progress before deleting it.
zh-Hant: 已完成作品現在有防誤刪保護；如需刪除，請先恢復為進行中。
zh-Hans: 已完成作品现在有防误删保护；如需删除，请先恢复为进行中。
de-DE: Abgeschlossene Projekte sind jetzt vor versehentlichem Löschen geschützt. Setze ein Projekt vor dem Löschen zuerst auf „In Bearbeitung“ zurück.
fr-FR: Les projets terminés sont désormais protégés contre les suppressions accidentelles. Remettez-les en cours avant de les supprimer.
ja-JP: 完了した作品の誤削除を防ぐ保護を追加しました。削除するには、先に「進行中」に戻してください。
nb-NO: Fullførte prosjekter er nå beskyttet mot utilsiktet sletting. Gjenoppta et prosjekt før du sletter det.
sv-SE: Slutförda projekt skyddas nu mot oavsiktlig radering. Återuppta ett projekt innan du tar bort det.
fi-FI: Valmiit projektit on nyt suojattu tahattomalta poistamiselta. Jatka projektia ennen kuin poistat sen.
da-DK: Afsluttede projekter er nu beskyttet mod utilsigtet sletning. Genoptag et projekt, før du sletter det.
ko-KR: 완료된 프로젝트를 실수로 삭제하지 않도록 보호합니다. 삭제하려면 먼저 진행 중으로 되돌리세요.
el-GR: Τα ολοκληρωμένα έργα προστατεύονται πλέον από κατά λάθος διαγραφή. Επαναφέρετε πρώτα ένα έργο σε εξέλιξη για να το διαγράψετε.
```

- [ ] **Step 2: Run metadata tests and verify RED**

Run:

```bash
python3 -m unittest AppStore.Verification.metadata_check_test
```

Expected: FAIL because the twelve What's New fields mention only localization.

- [ ] **Step 3: Append the exact localized sentences**

Append the sentence listed in Step 1 to each existing What's New field. Preserve the current language announcement, version number, URLs, and all other metadata fields unchanged.

- [ ] **Step 4: Validate metadata and commit**

Run:

```bash
python3 AppStore/Verification/metadata_check.py AppStore/Metadata
python3 -m unittest AppStore.Verification.metadata_check_test
```

Expected: PASS with length, URL, keyword, forbidden-claim, version, and deletion-protection assertions green.

```bash
git add AppStore/Metadata AppStore/Verification/metadata_check_test.py
git commit -m "docs: highlight completed-project protection in 1.4.1"
```

---

### Task 4: Verify source, builds, and iPhone behavior

**Files:**
- Modify: `AppStore/Verification/Localization141Verification.md`

**Interfaces:**
- Consumes: exact commits from Tasks 1–3.
- Produces: current source/build evidence plus explicit pending or passed iPhone acceptance; does not upload, submit, push, or change commercial state.

- [ ] **Step 1: Run complete automated verification**

Run sequentially:

```bash
swift test --quiet
xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteCompletedDeletionTests -only-testing:KnitNoteAppTests/EditProjectDeletionActionTests CODE_SIGNING_ALLOWED=NO -quiet
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteCompletedDeletion-iOS CODE_SIGNING_ALLOWED=NO build -quiet
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteCompletedDeletion-macOS CODE_SIGNING_ALLOWED=NO build -quiet
python3 AppStore/Verification/metadata_check.py AppStore/Metadata
bash AppStore/Verification/release_audit.sh --static-only
git diff --check
```

Expected: every command exits 0. Record exact test counts and build identities; do not infer signed-archive or App Store readiness from unsigned builds.

- [ ] **Step 2: Install the exact Debug candidate on the paired iPhone**

Build for the live iPhone identifier returned by `xcrun devicectl list devices`, install the resulting `KnitNote.app` over the existing bundle, and launch `com.phillon.KnitNote`. Do not uninstall or erase app data.

- [ ] **Step 3: Perform the three-path physical acceptance**

Using disposable projects only:

1. In-progress project: editor delete button is enabled, confirmation appears, deletion succeeds, and the app returns to the project list.
2. Completed project: editor delete button is disabled, the localized resume guidance is visible, and the project remains after leaving/reopening the app.
3. Restored project: tap Resume, reopen Edit, confirm delete, and verify the project disappears after app relaunch.

Also verify VoiceOver announces the disabled Delete control and its guidance in Traditional Chinese. Existing non-disposable projects must remain unchanged.

- [ ] **Step 4: Record truthful release evidence**

Update `Localization141Verification.md` with the exact commit, commands, counts, device/OS, locale, and each physical result. Keep the release at `STOP` until all existing 1.4.1 signed-archive, native-speaker, platform, screenshot, and App Store Connect gates are independently complete.

- [ ] **Step 5: Commit verification only after evidence is current**

```bash
git add AppStore/Verification/Localization141Verification.md
git commit -m "test: verify completed-project deletion protection"
```

Do not push, archive, upload, submit, or change App Store pricing without a separate explicit user instruction.
