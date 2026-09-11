# KnitNote Journal Social Sharing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an iPhone or iPad user render one journal entry as a warm scrapbook JPG and share it, save it to Photos, or copy its editable caption without mutating KnitNote data.

**Architecture:** Pure Foundation types in KnitNoteCore define share settings, text composition, render descriptions, generation receipts, and safe temporary exports. App-only SwiftUI files render the card and preview, while narrow iOS adapters own Photos, pasteboard, and activity-controller behavior. `ProjectJournalEntryDetailView` only resolves an immutable snapshot and presents the new flow.

**Tech Stack:** Swift 6, SwiftUI `ImageRenderer`, Core Graphics/ImageIO, Photos, UIKit system activity controller and pasteboard, Swift Testing, XcodeGen, String Catalogs.

**Spec:** `docs/superpowers/specs/2026-09-11-journal-social-sharing-design.md`

## Global Constraints

- Target iPhone and iPad on iOS/iPadOS 18+; do not expose the sharing UI on macOS in this release.
- Render exact 1080 x 1350 (4:5) and 1080 x 1920 (9:16) JPG output.
- Use the approved warm handmade scrapbook direction; original journal photo remains dominant.
- Share through system UI; do not add social SDKs, credentials, APIs, automatic publishing, analytics, or network calls.
- Preserve user-created project names and captions verbatim; never translate, rewrite, summarize, or generate them.
- Keep project and journal persistence byte-for-byte unchanged by sharing.
- The KnitNote mark is optional; all metadata switches default on and are preview-local only.
- `#KnitNote` is on by default for post text and never appears on the card unless already present in user-authored content.
- Completed-project journal entries remain shareable and read-only.
- Temporary cleanup must validate ownership and never follow symlinks or delete outside the owned export root.
- Do not infer release readiness from feature tests; exact-candidate iPhone and iPad acceptance remains a separate gate.

---

### Task 1: Pure Sharing Models and Text Composition

**Files:**
- Create: `Sources/KnitNoteCore/Projects/JournalSharing/JournalShareCardDescription.swift`
- Create: `Sources/KnitNoteCore/Projects/JournalSharing/JournalShareTextComposer.swift`
- Create: `Sources/KnitNoteCore/Projects/JournalSharing/JournalShareGenerationGate.swift`
- Create: `Tests/KnitNoteCoreTests/JournalShareModelTests.swift`

**Interfaces:**
- Consumes: Foundation `Date`, `Locale`, and immutable strings supplied by the app layer.
- Produces: `JournalShareFormat`, `JournalShareVisibility`, `JournalShareCardDescription`, `JournalShareTextComposer.compose(text:includeHashtag:)`, and `JournalShareGenerationGate`.

- [ ] **Step 1: Write failing model, text, and generation tests**

```swift
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct JournalShareModelTests {
    @Test func formatsExposeExactPixelSizes() {
        #expect(JournalShareFormat.post.pixelWidth == 1_080)
        #expect(JournalShareFormat.post.pixelHeight == 1_350)
        #expect(JournalShareFormat.story.pixelWidth == 1_080)
        #expect(JournalShareFormat.story.pixelHeight == 1_920)
    }

    @Test func descriptionOmitsHiddenMetadataWithoutChangingSource() {
        let visibility = JournalShareVisibility(
            showsProjectName: false,
            showsDate: true,
            showsCaption: false,
            showsBrand: false
        )
        let sourceCaption = "  第 36 行 🧶  "
        let result = JournalShareCardDescription.make(
            format: .post,
            visibility: visibility,
            projectName: "紅茶開衫",
            createdAt: Date(timeIntervalSince1970: 0),
            caption: sourceCaption,
            locale: Locale(identifier: "zh-Hant")
        )
        #expect(result.projectName == nil)
        #expect(result.caption == nil)
        #expect(result.formattedDate != nil)
        #expect(sourceCaption == "  第 36 行 🧶  ")
    }

    @Test(arguments: ["", "完成衣身", "完成衣身\n\n#knitnote", "#KnitNote 原本就在這裡"])
    func hashtagCompositionIsIdempotent(_ text: String) {
        let once = JournalShareTextComposer.compose(text: text, includeHashtag: true)
        let twice = JournalShareTextComposer.compose(text: once, includeHashtag: true)
        #expect(once == twice)
        #expect(once.localizedCaseInsensitiveContains("#knitnote"))
    }

    @Test func generationGateRejectsStaleCompletion() {
        var gate = JournalShareGenerationGate()
        let old = gate.begin()
        let current = gate.begin()
        #expect(!gate.finish(old))
        #expect(gate.finish(current))
    }
}
```

- [ ] **Step 2: Run the focused suite and verify RED**

Run: `swift test --filter JournalShareModelTests`

Expected: compilation fails because the journal-sharing types do not exist.

- [ ] **Step 3: Implement the minimal pure types**

```swift
public enum JournalShareFormat: String, CaseIterable, Sendable {
    case post, story
    public var pixelWidth: Int { 1_080 }
    public var pixelHeight: Int { self == .post ? 1_350 : 1_920 }
}

public struct JournalShareVisibility: Equatable, Sendable {
    public var showsProjectName = true
    public var showsDate = true
    public var showsCaption = true
    public var showsBrand = true
}

public struct JournalShareCardDescription: Equatable, Sendable {
    public let format: JournalShareFormat
    public let projectName: String?
    public let formattedDate: String?
    public let caption: String?
    public let showsBrand: Bool
    public static func make(
        format: JournalShareFormat,
        visibility: JournalShareVisibility,
        projectName: String,
        createdAt: Date,
        caption: String?,
        locale: Locale
    ) -> Self {
        Self(
            format: format,
            projectName: visibility.showsProjectName ? projectName : nil,
            formattedDate: visibility.showsDate
                ? createdAt.formatted(.dateTime.year().month().day().locale(locale))
                : nil,
            caption: visibility.showsCaption ? caption : nil,
            showsBrand: visibility.showsBrand
        )
    }
}

public enum JournalShareTextComposer {
    public static func compose(text: String, includeHashtag: Bool) -> String {
        guard includeHashtag else { return text }
        let containsTag = text.split(whereSeparator: \Character.isWhitespace)
            .contains { $0.caseInsensitiveCompare("#KnitNote") == .orderedSame }
        guard !containsTag else { return text }
        return text.isEmpty ? "#KnitNote" : text + "\n\n#KnitNote"
    }
}

public struct JournalShareGenerationGate: Sendable {
    private var generation: UInt64 = 0
    public mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }
    public mutating func finish(_ candidate: UInt64) -> Bool { candidate == generation }
    public mutating func cancel() { generation &+= 1 }
}
```

Replace each comment with the direct implementation; do not add persistence, UI, or social-platform concepts to these files.

- [ ] **Step 4: Run model tests and the full core suite**

Run: `swift test --filter JournalShareModelTests`

Expected: PASS.

Run: `swift test`

Expected: all KnitNoteCore tests pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add Sources/KnitNoteCore/Projects/JournalSharing Tests/KnitNoteCoreTests/JournalShareModelTests.swift
git commit -m "feat: add journal share models"
```

---

### Task 2: Safe Temporary JPG Export Lifecycle

**Files:**
- Create: `Sources/KnitNoteCore/Projects/JournalSharing/JournalShareTemporaryExportService.swift`
- Create: `Tests/KnitNoteCoreTests/JournalShareTemporaryExportServiceTests.swift`

**Interfaces:**
- Consumes: encoded JPG `Data`, an entry `UUID`, an injected root `URL`, and `FileManager`.
- Produces: `JournalShareTemporaryExportService.exportJPEG(_:entryID:) -> URL`, `removeExport(at:)`, and `removeStaleExports(olderThan:now:)`.

- [ ] **Step 1: Write failing path-safety and cleanup tests**

```swift
@Suite struct JournalShareTemporaryExportServiceTests {
    @Test func exportWritesJPEGOnlyInsideOwnedRoot() throws {
        let root = temporaryDirectory()
        let service = JournalShareTemporaryExportService(root: root)
        let url = try service.exportJPEG(Data([0xFF, 0xD8, 0xFF, 0xD9]), entryID: UUID())
        #expect(url.pathExtension == "jpg")
        #expect(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        #expect(try Data(contentsOf: url) == Data([0xFF, 0xD8, 0xFF, 0xD9]))
    }

    @Test func removeRejectsOutsideAndSymlinkTargets() throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory().appending(path: "keep.jpg")
        try Data([1]).write(to: outside)
        let service = JournalShareTemporaryExportService(root: root)
        #expect(throws: JournalShareTemporaryExportError.unsafeURL) {
            try service.removeExport(at: outside)
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func staleCleanupIsBoundedAndKeepsRecentFiles() throws {
        let root = temporaryDirectory()
        let service = JournalShareTemporaryExportService(root: root)
        let old = try service.exportJPEG(Data([1]), entryID: UUID())
        let recent = try service.exportJPEG(Data([2]), entryID: UUID())
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: old.path
        )
        let removed = try service.removeStaleExports(
            olderThan: 60,
            now: Date(timeIntervalSince1970: 120),
            maximumRemovals: 1
        )
        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }
}
```

- [ ] **Step 2: Run the focused suite and verify RED**

Run: `swift test --filter JournalShareTemporaryExportServiceTests`

Expected: compilation fails because the service does not exist.

- [ ] **Step 3: Implement owned-root validation, atomic writing, and bounded cleanup**

```swift
public struct JournalShareTemporaryExportService: Sendable {
    public init(root: URL, fileManager: FileManager = .default)
    public func exportJPEG(_ data: Data, entryID: UUID) throws -> URL
    public func removeExport(at url: URL) throws
    @discardableResult
    public func removeStaleExports(
        olderThan age: TimeInterval,
        now: Date = .now,
        maximumRemovals: Int = 50
    ) throws -> Int
}
```

Validate the physical root and parent, reject symbolic links, allow only service-generated `.jpg` basenames, create the owned directory explicitly, and use `.atomic` writes. Enumerate only direct children and stop at `maximumRemovals`.

- [ ] **Step 4: Run focused safety tests and the full core suite**

Run: `swift test --filter JournalShareTemporaryExportServiceTests`

Expected: PASS, including outside-root and symlink preservation.

Run: `swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit Task 2**

```bash
git add Sources/KnitNoteCore/Projects/JournalSharing/JournalShareTemporaryExportService.swift Tests/KnitNoteCoreTests/JournalShareTemporaryExportServiceTests.swift
git commit -m "feat: add safe journal share exports"
```

---

### Task 3: Warm Scrapbook Card and Exact JPG Renderer

**Files:**
- Create: `KnitNote/Projects/JournalSharing/JournalShareCardView.swift`
- Create: `KnitNote/Projects/JournalSharing/JournalShareCardRenderer.swift`
- Create: `Tests/KnitNoteAppTests/JournalShareCardRendererTests.swift`

**Interfaces:**
- Consumes: `JournalShareCardDescription` and decoded platform image data.
- Produces: `JournalShareCardRendering.renderJPEG(description:photoData:) async throws -> Data`; live type `SwiftUIJournalShareCardRenderer`.

- [ ] **Step 1: Write failing renderer dimension and decoding tests**

```swift
import ImageIO
import Testing
@testable import KnitNote
@testable import KnitNoteCore

@MainActor @Suite struct JournalShareCardRendererTests {
    @Test(arguments: [JournalShareFormat.post, .story])
    func rendersExactDecodableJPEG(_ format: JournalShareFormat) async throws {
        let description = fixtureDescription(format: format)
        let data = try await SwiftUIJournalShareCardRenderer().renderJPEG(
            description: description,
            photoData: fixtureJPEG()
        )
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == format.pixelWidth)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == format.pixelHeight)
    }

    @Test func invalidPhotoFailsWithoutProducingPlaceholder() async {
        await #expect(throws: JournalShareRenderError.invalidPhoto) {
            try await SwiftUIJournalShareCardRenderer().renderJPEG(
                description: fixtureDescription(format: .post),
                photoData: Data("bad".utf8)
            )
        }
    }
}
```

- [ ] **Step 2: Run the focused app tests and verify RED**

Run: `xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteAppTests/JournalShareCardRendererTests`

Expected: compilation fails because the renderer and card do not exist.

- [ ] **Step 3: Implement the fixed-canvas scrapbook card**

```swift
struct JournalShareCardView: View {
    let description: JournalShareCardDescription
    let photo: Image

    var body: some View {
        ZStack {
            JournalSharePaperBackground()
            VStack(spacing: description.format == .post ? 34 : 48) {
                JournalShareInstantPhoto(photo: photo, format: description.format)
                JournalShareMetadata(description: description)
            }
        }
        .frame(width: CGFloat(description.format.pixelWidth),
               height: CGFloat(description.format.pixelHeight))
        .environment(\.colorScheme, .light)
    }
}
```

Use fixed canvas-relative metrics, a warm paper background, a restrained photo rotation, four caption lines for `.post`, six for `.story`, and bottom/side safe insets. Keep decorative layers hidden from accessibility; the preview supplies one combined label.

- [ ] **Step 4: Implement `ImageRenderer` plus color-managed JPEG encoding**

```swift
@MainActor protocol JournalShareCardRendering {
    func renderJPEG(
        description: JournalShareCardDescription,
        photoData: Data
    ) async throws -> Data
}

@MainActor struct SwiftUIJournalShareCardRenderer: JournalShareCardRendering {
    func renderJPEG(description: JournalShareCardDescription, photoData: Data) async throws -> Data {
        guard let source = CGImageSourceCreateWithData(photoData as CFData, nil),
              let photo = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw JournalShareRenderError.invalidPhoto
        }
        let renderer = ImageRenderer(content: JournalShareCardView(
            description: description,
            photo: Image(decorative: photo, scale: 1)
        ))
        renderer.proposedSize = ProposedViewSize(
            width: CGFloat(description.format.pixelWidth),
            height: CGFloat(description.format.pixelHeight)
        )
        renderer.scale = 1
        guard let output = renderer.cgImage else { throw JournalShareRenderError.renderFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw JournalShareRenderError.encodingFailed }
        CGImageDestinationAddImage(destination, output, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw JournalShareRenderError.encodingFailed
        }
        return data as Data
    }
}
```

Reject undecodable photos, nil renderer output, wrong output dimensions, and failed destination finalization with typed errors. Use sRGB output and a documented JPEG quality constant.

- [ ] **Step 5: Add boundary rendering cases and run tests**

Add cases for empty metadata, photo-only output, long Traditional Chinese, emoji, Arabic/Greek/Korean text, and every visibility flag. Decode every result and assert exact dimensions; use image-diff fixtures only for stable structural regions, not font antialiasing pixels.

Run: `xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteAppTests/JournalShareCardRendererTests`

Expected: PASS.

- [ ] **Step 6: Commit Task 3**

```bash
git add KnitNote/Projects/JournalSharing/JournalShareCardView.swift KnitNote/Projects/JournalSharing/JournalShareCardRenderer.swift Tests/KnitNoteAppTests/JournalShareCardRendererTests.swift
git commit -m "feat: render journal scrapbook cards"
```

---

### Task 4: Preview Coordinator and Injectable iOS Actions

**Files:**
- Create: `KnitNote/Projects/JournalSharing/JournalSharePreviewModel.swift`
- Create: `KnitNote/Projects/JournalSharing/JournalShareSystemActions.swift`
- Create: `Tests/KnitNoteAppTests/JournalSharePreviewModelTests.swift`

**Interfaces:**
- Consumes: immutable `JournalShareSource`, `JournalShareCardRendering`, `JournalShareTemporaryExportService`, `JournalPhotoSaving`, and `JournalTextCopying`.
- Produces: observable `JournalSharePreviewModel`, `prepareShare() -> JournalSharePayload`, `saveToPhotos()`, `copyText()`, `dismiss()`, and typed presentation state.

- [ ] **Step 1: Write failing coordinator tests with stubs**

```swift
@MainActor @Suite struct JournalSharePreviewModelTests {
    @Test func defaultsMatchApprovedProductChoices() {
        let model = makeModel()
        #expect(model.format == .post)
        #expect(model.visibility == JournalShareVisibility())
        #expect(model.includesHashtag)
    }

    @Test func staleRenderCannotReplaceNewSettings() async {
        let renderer = ControllableJournalShareRenderer()
        let model = makeModel(renderer: renderer)
        model.format = .story
        await renderer.finishFirst(with: fixtureJPEGData())
        #expect(model.previewFormat != .post)
    }

    @Test func sharingDoesNotMutateSource() async throws {
        let source = fixtureSource()
        let encodedBefore = try JSONEncoder().encode(source.entry)
        _ = try await makeModel(source: source).prepareShare()
        #expect(try JSONEncoder().encode(source.entry) == encodedBefore)
    }

    @Test func deniedPhotoAccessKeepsShareAndCopyAvailable() async {
        let model = makeModel(photoSaver: DeniedPhotoSaver())
        await model.saveToPhotos()
        #expect(model.photoSaveError != nil)
        #expect(model.canShare)
        #expect(model.canCopy)
    }
}
```

- [ ] **Step 2: Run the focused app tests and verify RED**

Run: `xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteAppTests/JournalSharePreviewModelTests`

Expected: compilation fails because the preview model and action protocols do not exist.

- [ ] **Step 3: Implement immutable source, state machine, and payload**

```swift
struct JournalShareSource: Sendable {
    let projectName: String
    let entry: ProjectJournalEntry
    let photoURL: URL
}

struct JournalSharePayload: Identifiable {
    let id = UUID()
    let fileURL: URL
    let text: String
}

@MainActor @Observable final class JournalSharePreviewModel {
    var format: JournalShareFormat = .post
    var visibility = JournalShareVisibility()
    var editableText: String
    var includesHashtag = true
    private(set) var state: JournalSharePreviewState = .loading

    func refreshPreview() async
    func prepareShare() async throws -> JournalSharePayload
    func saveToPhotos() async
    func copyText()
    func finishSharing(_ payload: JournalSharePayload)
    func dismiss()
}
```

Load photo data off the main actor with cancellation checks, render through the injected renderer, and publish only through `JournalShareGenerationGate`. Never retain a mutable store or project reference.
On initialization, call `removeStaleExports(olderThan: 86_400, maximumRemovals: 50)` as best-effort maintenance; do not broaden the cleanup root or delay opening the preview if cleanup fails.

- [ ] **Step 4: Implement narrow live system adapters**

```swift
@MainActor protocol JournalPhotoSaving {
    func saveJPEG(at url: URL) async throws
}

@MainActor protocol JournalTextCopying {
    func copy(_ text: String)
}

#if os(iOS)
struct IOSJournalPhotoSaver: JournalPhotoSaving {
    func saveJPEG(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw JournalPhotoSaveError.denied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        }
    }
}
struct IOSJournalTextCopier: JournalTextCopying {
    func copy(_ text: String) { UIPasteboard.general.string = text }
}
#endif
```

Map authorization denial/restriction separately from asset-write failure. Request Photos permission only inside `saveJPEG`. Do not import Photos or UIKit into KnitNoteCore.

- [ ] **Step 5: Run coordinator tests and the existing app suite**

Run: `xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteAppTests/JournalSharePreviewModelTests`

Expected: PASS.

Run: `xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteAppTests`

Expected: all app unit tests pass.

- [ ] **Step 6: Commit Task 4**

```bash
git add KnitNote/Projects/JournalSharing/JournalSharePreviewModel.swift KnitNote/Projects/JournalSharing/JournalShareSystemActions.swift Tests/KnitNoteAppTests/JournalSharePreviewModelTests.swift
git commit -m "feat: coordinate journal share previews"
```

---

### Task 5: iPhone and iPad Preview UI and Journal Entry Integration

**Files:**
- Create: `KnitNote/Projects/JournalSharing/JournalSharePreviewView.swift`
- Create: `KnitNote/Projects/JournalSharing/JournalActivityView.swift`
- Modify: `KnitNote/Projects/ProjectJournalEntryDetailView.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectJournalViewContractTests.swift`
- Create: `Tests/KnitNoteAppTests/JournalSharePresentationContractTests.swift`

**Interfaces:**
- Consumes: current project/entry and `store.journalPhotoURL(for:)`; `JournalSharePreviewModel` actions and state.
- Produces: iOS-only Share toolbar entry, accessible preview sheet, and system activity presentation whose completion removes its payload export.

- [ ] **Step 1: Write failing source-contract tests**

```swift
@Test func detailSharesActiveAndCompletedEntriesOnIOS() throws {
    let detail = try projectSource(named: "ProjectJournalEntryDetailView")
    #expect(detail.contains("#if os(iOS)"))
    #expect(detail.contains("Button(\"journal.share\", systemImage: \"square.and.arrow.up\")"))
    #expect(detail.contains("JournalSharePreviewView("))
    #expect(detail.contains("store.journalPhotoURL(for: entry)"))
    #expect(detail.range(of: "journal.share")!.lowerBound < detail.range(of: "if !project.isCompleted")!.lowerBound)
}

@Test func previewExposesTwoFormatsFourMetadataSwitchesAndThreeOutputs() throws {
    let source = try projectSource(named: "JournalSharing/JournalSharePreviewView")
    for token in ["journal.share.format.post", "journal.share.format.story",
                  "journal.share.showProject", "journal.share.showDate",
                  "journal.share.showCaption", "journal.share.showBrand",
                  "journal.share.action.share", "journal.share.action.save",
                  "journal.share.action.copy"] {
        #expect(source.contains(token))
    }
}
```

- [ ] **Step 2: Run contract tests and verify RED**

Run: `swift test --filter ProjectJournalViewContractTests`

Expected: FAIL because the share UI tokens are absent.

- [ ] **Step 3: Build the iOS-only preview UI**

```swift
#if os(iOS)
struct JournalSharePreviewView: View {
    @State private var model: JournalSharePreviewModel
    @State private var activityPayload: JournalSharePayload?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    JournalSharePreviewImage(state: model.state)
                    Picker("journal.share.format", selection: $model.format) {
                        Text("journal.share.format.post").tag(JournalShareFormat.post)
                        Text("journal.share.format.story").tag(JournalShareFormat.story)
                    }
                        .pickerStyle(.segmented)
                    JournalShareVisibilityControls(visibility: $model.visibility)
                    TextField("journal.share.text", text: $model.editableText, axis: .vertical)
                    Toggle("journal.share.hashtag", isOn: $model.includesHashtag)
                    JournalShareActionBar(model: model, activityPayload: $activityPayload)
                }
            }
        }
    }
}
#endif
```

Use existing watercolor surfaces and berry tint for the app UI without changing the fixed exported palette. Add one combined accessibility description to the preview; announce save/copy/failure results. Keep controls usable at accessibility Dynamic Type sizes.
When Photos access is denied or restricted, keep Share and Copy enabled and include a localized **Open Settings** action using `UIApplication.openSettingsURLString`; do not show that action for an ordinary asset-write failure.

- [ ] **Step 4: Wrap `UIActivityViewController` with iPad-safe presentation and cleanup**

```swift
#if os(iOS)
struct JournalActivityView: UIViewControllerRepresentable {
    let payload: JournalSharePayload
    let completion: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [payload.fileURL, payload.text], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in completion() }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
```

Present it from SwiftUI as a sheet so iPad receives a valid presentation anchor. Treat all completion outcomes, including cancellation, as cleanup opportunities rather than alerts.

- [ ] **Step 5: Add the detail toolbar entry outside the completed-project edit gate**

Capture `JournalShareSource(projectName:entry:photoURL:)` only after all values resolve. Place only the share button outside `if !project.isCompleted`; leave edit/delete exactly where they are. Compile the new files away on macOS with `#if os(iOS)` around UI entry points.

- [ ] **Step 6: Run contract and app tests**

Run: `swift test --filter ProjectJournalViewContractTests`

Expected: PASS.

Run: `xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteAppTests/JournalSharePresentationContractTests`

Expected: PASS.

- [ ] **Step 7: Commit Task 5**

```bash
git add KnitNote/Projects/ProjectJournalEntryDetailView.swift KnitNote/Projects/JournalSharing/JournalSharePreviewView.swift KnitNote/Projects/JournalSharing/JournalActivityView.swift Tests/KnitNoteCoreTests/ProjectJournalViewContractTests.swift Tests/KnitNoteAppTests/JournalSharePresentationContractTests.swift
git commit -m "feat: add journal share preview flow"
```

---

### Task 6: Localization, Photos Usage Description, and Release Contracts

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `KnitNote/Localization/InfoPlist.xcstrings`
- Modify: `project.yml`
- Modify: `Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`

**Interfaces:**
- Consumes: every `journal.share.*` key referenced by Tasks 4-5.
- Produces: complete 13-language app strings and localized `NSPhotoLibraryAddUsageDescription` wired into the generated app Info.plist.

- [ ] **Step 1: Add failing localization and configuration contracts**

```swift
@Test func journalShareKeysCoverEverySupportedLocalization() throws {
    let required = [
        "journal.share", "journal.share.title", "journal.share.format",
        "journal.share.format.post", "journal.share.format.story",
        "journal.share.showProject", "journal.share.showDate",
        "journal.share.showCaption", "journal.share.showBrand",
        "journal.share.text", "journal.share.hashtag",
        "journal.share.action.share", "journal.share.action.save",
        "journal.share.action.copy", "journal.share.rendering",
        "journal.share.error.photo", "journal.share.error.render",
        "journal.share.error.photosDenied", "journal.share.error.save",
        "journal.share.saved", "journal.share.copied"
    ]
    let url = releaseAuditRepositoryRoot
        .appending(path: "KnitNote/Localization/Localizable.xcstrings")
    let payload = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    let strings = try #require(payload["strings"] as? [String: Any])
    for key in required {
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        #expect(Set(localizations.keys) == Set(releaseLocales))
        for locale in releaseLocales {
            let localization = try #require(localizations[locale] as? [String: Any])
            let unit = try #require(localization["stringUnit"] as? [String: Any])
            #expect((unit["value"] as? String)?.isEmpty == false)
        }
    }
}

@Test func appDeclaresLocalizedPhotoAddUsage() throws {
    let project = try String(
        contentsOf: releaseAuditRepositoryRoot.appending(path: "project.yml"),
        encoding: .utf8
    )
    #expect(project.contains("NSPhotoLibraryAddUsageDescription:"))
    for locale in releaseLocales {
        let values = try compiledInfoPlistValues(locale: locale)
        #expect(values["NSPhotoLibraryAddUsageDescription"]?.isEmpty == false)
    }
}
```

- [ ] **Step 2: Run focused release tests and verify RED**

Run: `swift test --filter ReleaseAuditLocalizationTests`

Expected: FAIL with missing journal share keys.

Run: `swift test --filter ReleaseConfigurationContractTests`

Expected: FAIL with missing Photos usage description.

- [ ] **Step 3: Add authoritative Traditional Chinese and English strings**

Use concise source copy such as:

```text
journal.share = 分享
journal.share.title = 分享編織日記
journal.share.format.post = 貼文 4:5
journal.share.format.story = 限時動態 9:16
journal.share.action.save = 儲存到照片
journal.share.action.copy = 複製貼文文字
NSPhotoLibraryAddUsageDescription = 將你製作的編織日記分享卡儲存到照片。
```

Add English values with the same meaning. Do not translate user content or name specific social networks in permission copy.

- [ ] **Step 4: Complete all existing supported languages and wire the Info key**

Fill `zh-Hans`, `de`, `fr`, `ja`, `nb`, `sv`, `fi`, `da`, `ko`, `el`, and `nl` for every new key. Add `NSPhotoLibraryAddUsageDescription` to the KnitNote target's `info.properties` in `project.yml` and localize the key in `InfoPlist.xcstrings`. Do not add read/write Photos permission when add-only suffices.

- [ ] **Step 5: Regenerate the project and run localization/configuration audits**

Run: `xcodegen generate`

Expected: project generation succeeds.

Run: `swift test --filter ReleaseAuditLocalizationTests`

Expected: PASS.

Run: `swift test --filter ReleaseConfigurationContractTests`

Expected: PASS.

- [ ] **Step 6: Commit Task 6**

```bash
git add KnitNote/Localization/Localizable.xcstrings KnitNote/Localization/InfoPlist.xcstrings project.yml KnitNote.xcodeproj Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift
git commit -m "feat: localize journal sharing"
```

---

### Task 7: Integration Verification and Candidate Evidence

**Files:**
- Create: `AppStore/Verification/JournalSharingVerification.md`
- Modify only if an observed failure requires it: files introduced by Tasks 1-6.

**Interfaces:**
- Consumes: the complete implementation and exact Git commit under test.
- Produces: reproducible automated evidence plus a clearly separated physical-device checklist; it does not claim unperformed device acceptance.

- [ ] **Step 1: Run formatting and repository integrity checks**

Run: `git diff --check`

Expected: no output.

Run: `git status --short`

Expected: only intentional implementation/evidence changes.

- [ ] **Step 2: Run all core tests serially**

Run: `swift test --no-parallel`

Expected: all tests pass with zero failures.

- [ ] **Step 3: Run the macOS-hosted app test bundle**

Run: `xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteAppTests`

Expected: exit 0.

- [ ] **Step 4: Build the iOS app for Simulator and a generic device**

Run: `xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`

Expected: exit 0.

Run: `xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`

Expected: exit 0.

- [ ] **Step 5: Run targeted iPhone and iPad UI smoke tests where available**

Select currently installed simulator names with `xcrun simctl list devices available`; do not invent destinations. Exercise entry detail -> Share, both ratios, metadata switches, Copy, activity-sheet cancellation, and iPad presentation. Record the exact simulator runtime and device names.

Expected: no crash, stale preview, clipped controls, or mutation of the source entry.

- [ ] **Step 6: Write verification evidence without overstating physical coverage**

Record commands, UTC timestamps, full SHA, pass/fail results, exact JPG dimensions, and any simulator destinations in `AppStore/Verification/JournalSharingVerification.md`. Include an unchecked physical checklist for iPhone/iPad Photos denial/authorization, Instagram receipt, TikTok receipt, long Traditional Chinese, one other non-Latin locale, cancellation, and temporary cleanup.

- [ ] **Step 7: Review the final diff and commit verification**

Run: `git diff --stat dd499905c053b884882838f53eec69c6b0925f2d..HEAD`

Run: `git diff --check dd499905c053b884882838f53eec69c6b0925f2d..HEAD`

Expected: only journal-sharing source, tests, localization/configuration, generated project changes, the approved spec/plan, and evidence; no whitespace errors.

```bash
git add AppStore/Verification/JournalSharingVerification.md
git commit -m "test: verify journal social sharing"
```

Physical iPhone/iPad acceptance is performed later against the exact release candidate and must not be marked complete by this task.
