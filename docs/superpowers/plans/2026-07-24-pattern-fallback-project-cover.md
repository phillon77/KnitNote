# Pattern Fallback Project Cover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the first pattern's first page as a project's automatic cover whenever the project has no user-selected photo.

**Architecture:** Keep `StoredProject.photoFilename` exclusively for user-selected photos. Add a focused `PatternThumbnailFileService` that builds disposable JPEG thumbnails outside the backed-up live data root, expose one asynchronous cover-resolution method from `JSONProjectStore`, and route every project cover UI through a single `ProjectCoverView`.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Core Graphics, ImageIO, UniformTypeIdentifiers, Swift Package Manager, XcodeGen.

## Global Constraints

- Cover priority is user-selected project photo, first pattern's first-page thumbnail, then the existing default icon.
- Adding a pattern must never overwrite `StoredProject.photoFilename`.
- Removing a custom photo immediately falls back to the first pattern.
- Removing the first pattern immediately falls back to the next pattern.
- PDF thumbnails use page 1; PNG, JPEG, and HEIC patterns use the source image with orientation correction.
- Thumbnail generation and cleanup failures must not fail pattern import, reading, deletion, or project persistence.
- Thumbnails are disposable cache files outside the `KnitNote` live backup root and are never added to `ProjectArchive`.
- No archive schema-version change, new setting, prompt, cover editor, localization string, or third-party dependency.
- iPhone, iPad, and Mac use the same resolver and view.
- Do not change `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION`; release numbering is a separate App Store task.

---

## File Structure

- Create `Sources/KnitNoteCore/Patterns/PatternThumbnailFileService.swift`: render and cache first-page JPEG thumbnails.
- Create `Tests/KnitNoteCoreTests/PatternThumbnailFileServiceTests.swift`: verify PDF/image rendering, cache reuse, cleanup, and invalid input behavior.
- Modify `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`: own the thumbnail service, resolve cover URLs, warm cache after import, and clean cache after deletion.
- Modify `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`: verify cover priority, fallback switching, regeneration, and failure isolation.
- Create `KnitNote/Projects/ProjectCoverView.swift`: asynchronously resolve and display one project cover.
- Modify `KnitNote/Projects/ProjectCard.swift`: use `ProjectCoverView`.
- Modify `KnitNote/Projects/ProjectDetailView.swift`: use `ProjectCoverView`.
- Modify `KnitNote/Projects/ProjectsView.swift`: remove the now-redundant `photoURL` argument.
- Create `Tests/KnitNoteCoreTests/ProjectCoverViewContractTests.swift`: lock the shared UI wiring and async refresh contract.

---

### Task 1: Pattern Thumbnail Cache Service

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternThumbnailFileService.swift`
- Create: `Tests/KnitNoteCoreTests/PatternThumbnailFileServiceTests.swift`

**Interfaces:**
- Consumes: `PatternDocument`, `PatternKind`, a validated original pattern file URL.
- Produces:
  - `PatternThumbnailFileService.init(directory:maxPixelSize:)`
  - `thumbnailURL(projectID:pattern:sourceURL:) throws -> URL`
  - `cachedURL(projectID:patternID:) -> URL`
  - `delete(projectID:patternID:) throws`
  - `deleteProject(projectID:) throws`
  - `deleteAll() throws`

- [ ] **Step 1: Write failing PDF and image thumbnail tests**

Create `Tests/KnitNoteCoreTests/PatternThumbnailFileServiceTests.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite struct PatternThumbnailFileServiceTests {
    @Test func rendersPDFPageOneAndImagePatternsAsBoundedJPEG() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sources = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let pdfURL = sources.appendingPathComponent("chart.pdf")
        let imageURL = sources.appendingPathComponent("chart.png")
        try makePDF(at: pdfURL, size: CGSize(width: 1_200, height: 600))
        try makePNG(at: imageURL, width: 600, height: 1_200)
        let service = PatternThumbnailFileService(
            directory: root.appendingPathComponent("cache"),
            maxPixelSize: 800
        )
        let projectID = UUID()
        let pdf = PatternDocument(displayName: "PDF", kind: .pdf, storedFilename: "chart.pdf")
        let image = PatternDocument(displayName: "Image", kind: .image, storedFilename: "chart.png")

        let pdfThumbnail = try service.thumbnailURL(
            projectID: projectID,
            pattern: pdf,
            sourceURL: pdfURL
        )
        let imageThumbnail = try service.thumbnailURL(
            projectID: projectID,
            pattern: image,
            sourceURL: imageURL
        )

        #expect(try pixelSize(pdfThumbnail) == CGSize(width: 800, height: 400))
        #expect(try pixelSize(imageThumbnail) == CGSize(width: 400, height: 800))
        #expect(pdfThumbnail.pathExtension == "jpg")
        #expect(imageThumbnail.pathExtension == "jpg")
    }

    @Test func reusesCacheAndDeletesOnePatternOrWholeProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makePNG(at: source, width: 40, height: 20)
        let service = PatternThumbnailFileService(directory: root.appendingPathComponent("cache"))
        let projectID = UUID()
        let first = PatternDocument(displayName: "First", kind: .image, storedFilename: "first.png")
        let second = PatternDocument(displayName: "Second", kind: .image, storedFilename: "second.png")
        let firstURL = try service.thumbnailURL(projectID: projectID, pattern: first, sourceURL: source)
        let originalDate = try #require(
            try firstURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        let reusedURL = try service.thumbnailURL(projectID: projectID, pattern: first, sourceURL: source)
        let secondURL = try service.thumbnailURL(projectID: projectID, pattern: second, sourceURL: source)

        #expect(reusedURL == firstURL)
        #expect(try reusedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalDate)
        try service.delete(projectID: projectID, patternID: first.id)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        try service.deleteProject(projectID: projectID)
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))
        let otherProjectURL = try service.thumbnailURL(
            projectID: UUID(),
            pattern: first,
            sourceURL: source
        )
        try service.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: otherProjectURL.path))
    }

    @Test func concurrentRequestsShareOneValidCachedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makePNG(at: source, width: 640, height: 320)
        let service = PatternThumbnailFileService(directory: root.appendingPathComponent("cache"))
        let projectID = UUID()
        let pattern = PatternDocument(displayName: "Chart", kind: .image, storedFilename: "chart.png")

        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try service.thumbnailURL(
                        projectID: projectID,
                        pattern: pattern,
                        sourceURL: source
                    )
                }
            }
            var results: [URL] = []
            for try await url in group {
                results.append(url)
            }
            return results
        }

        #expect(Set(urls).count == 1)
        #expect(try pixelSize(try #require(urls.first)) == CGSize(width: 640, height: 320))
    }

    private func makePDF(at url: URL, size: CGSize) throws {
        var box = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.6, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
    }

    private func makePNG(at url: URL, width: Int, height: Int) throws {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func pixelSize(_ url: URL) throws -> CGSize {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return CGSize(
            width: try #require(properties[kCGImagePropertyPixelWidth] as? Int),
            height: try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        )
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter PatternThumbnailFileServiceTests
```

Expected: FAIL to compile because `PatternThumbnailFileService` does not exist.

- [ ] **Step 3: Implement the thumbnail service**

Create `Sources/KnitNoteCore/Patterns/PatternThumbnailFileService.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PatternThumbnailFileError: Error, Equatable, Sendable {
    case unreadableSource
    case renderingFailed
    case encodingFailed
}

public struct PatternThumbnailFileService: Sendable {
    public let directory: URL
    public let maxPixelSize: Int
    private let lock = PatternThumbnailFileLock()

    public init(directory: URL, maxPixelSize: Int = 800) {
        self.directory = directory
        self.maxPixelSize = max(1, maxPixelSize)
    }

    public func thumbnailURL(
        projectID: UUID,
        pattern: PatternDocument,
        sourceURL: URL
    ) throws -> URL {
        lock.value.lock()
        defer { lock.value.unlock() }
        let destination = cachedURL(projectID: projectID, patternID: pattern.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let image: CGImage
        switch pattern.kind {
        case .pdf:
            image = try renderPDFPageOne(sourceURL)
        case .image:
            image = try renderImage(sourceURL)
        }
        let data = try encodeJPEG(image)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public func cachedURL(projectID: UUID, patternID: UUID) -> URL {
        directory
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("\(patternID.uuidString).jpg")
    }

    public func delete(projectID: UUID, patternID: UUID) throws {
        lock.value.lock()
        defer { lock.value.unlock() }
        let url = cachedURL(projectID: projectID, patternID: patternID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func deleteProject(projectID: UUID) throws {
        lock.value.lock()
        defer { lock.value.unlock() }
        let url = directory.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func deleteAll() throws {
        lock.value.lock()
        defer { lock.value.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func renderImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ] as CFDictionary
              ) else {
            throw PatternThumbnailFileError.unreadableSource
        }
        return image
    }

    private func renderPDFPageOne(_ url: URL) throws -> CGImage {
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1) else {
            throw PatternThumbnailFileError.unreadableSource
        }
        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else {
            throw PatternThumbnailFileError.renderingFailed
        }
        let scale = min(CGFloat(maxPixelSize) / max(mediaBox.width, mediaBox.height), 1)
        let size = CGSize(
            width: max(1, (mediaBox.width * scale).rounded()),
            height: max(1, (mediaBox.height * scale).rounded())
        )
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PatternThumbnailFileError.renderingFailed
        }
        let target = CGRect(origin: .zero, size: size)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(target)
        context.concatenate(page.getDrawingTransform(
            .mediaBox,
            rect: target,
            rotate: 0,
            preserveAspectRatio: true
        ))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else {
            throw PatternThumbnailFileError.renderingFailed
        }
        return image
    }

    private func encodeJPEG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PatternThumbnailFileError.encodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw PatternThumbnailFileError.encodingFailed
        }
        return output as Data
    }
}

private final class PatternThumbnailFileLock: @unchecked Sendable {
    let value = NSLock()
}
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run:

```bash
swift test --filter PatternThumbnailFileServiceTests
```

Expected: all `PatternThumbnailFileServiceTests` pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add Sources/KnitNoteCore/Patterns/PatternThumbnailFileService.swift Tests/KnitNoteCoreTests/PatternThumbnailFileServiceTests.swift
git commit -m "Add pattern thumbnail cache service"
```

---

### Task 2: Store-Level Cover Resolution and Cache Lifecycle

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Consumes: `PatternThumbnailFileService` from Task 1 and existing `photoURL(for:)`, `patternURL(projectID:pattern:)`.
- Produces:
  - `projectCoverURL(for:) async -> URL?`
  - automatic thumbnail warming after successful pattern import
  - best-effort thumbnail cleanup after pattern or project deletion

- [ ] **Step 1: Add failing cover-priority and fallback tests**

Append focused tests to `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`. Reuse the file's existing `makeStoreJPEG(red:)` helper and add a `makeStorePNG(at:red:)` helper beside it.

```swift
@MainActor @Test func projectCoverPrefersCustomPhotoThenFallsBackThroughPatterns() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archiveURL = base.appendingPathComponent("KnitNote/projects-v1.json")
    let thumbnailService = PatternThumbnailFileService(
        directory: base.appendingPathComponent(".KnitNote-PatternThumbnailCache")
    )
    let store = JSONProjectStore(
        url: archiveURL,
        patternThumbnailService: thumbnailService
    )
    try store.add(name: "Sweater", photoData: makeStoreJPEG(red: 0.5))
    let projectID = try #require(store.projects.first?.id)
    let firstSource = base.appendingPathComponent("first.png")
    let secondSource = base.appendingPathComponent("second.png")
    try makeStorePNG(at: firstSource, red: 0.2)
    try makeStorePNG(at: secondSource, red: 0.8)
    let first = try await store.importPattern(from: firstSource, projectID: projectID)
    let second = try await store.importPattern(from: secondSource, projectID: projectID)

    let withPhoto = try #require(store.project(id: projectID))
    let customCoverURL = await store.projectCoverURL(for: withPhoto)
    #expect(customCoverURL == store.photoURL(for: withPhoto))

    try store.updateProject(
        id: projectID,
        name: withPhoto.name,
        toolType: withPhoto.toolType,
        toolSize: withPhoto.toolSize,
        toolNotes: withPhoto.toolNotes,
        photoChange: .remove
    )
    let withoutPhoto = try #require(store.project(id: projectID))
    let firstPatternCoverURL = await store.projectCoverURL(for: withoutPhoto)
    #expect(
        firstPatternCoverURL
            == thumbnailService.cachedURL(projectID: projectID, patternID: first.id)
    )

    try store.deletePattern(projectID: projectID, id: first.id)
    let afterFirstDeletion = try #require(store.project(id: projectID))
    let secondPatternCoverURL = await store.projectCoverURL(for: afterFirstDeletion)
    #expect(
        secondPatternCoverURL
            == thumbnailService.cachedURL(projectID: projectID, patternID: second.id)
    )

    try store.deletePattern(projectID: projectID, id: second.id)
    let withoutPatterns = try #require(store.project(id: projectID))
    let defaultCoverURL = await store.projectCoverURL(for: withoutPatterns)
    #expect(defaultCoverURL == nil)
}

@MainActor @Test func coverCacheRegeneratesWithoutChangingArchiveOrImportSuccess() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let liveRoot = base.appendingPathComponent("KnitNote")
    let archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
    let thumbnailRoot = base.appendingPathComponent(".KnitNote-PatternThumbnailCache")
    let service = PatternThumbnailFileService(directory: thumbnailRoot)
    let store = JSONProjectStore(url: archiveURL, patternThumbnailService: service)
    try store.add(name: "Hat")
    let projectID = try #require(store.projects.first?.id)
    let source = base.appendingPathComponent("chart.png")
    try makeStorePNG(at: source, red: 0.4)
    let pattern = try await store.importPattern(from: source, projectID: projectID)
    let project = try #require(store.project(id: projectID))
    let firstCandidate = await store.projectCoverURL(for: project)
    let firstURL = try #require(firstCandidate)
    try FileManager.default.removeItem(at: firstURL)

    let restarted = JSONProjectStore(url: archiveURL, patternThumbnailService: service)
    let restartedProject = try #require(restarted.project(id: projectID))
    let regeneratedCandidate = await restarted.projectCoverURL(for: restartedProject)
    let regenerated = try #require(regeneratedCandidate)

    #expect(regenerated == service.cachedURL(projectID: projectID, patternID: pattern.id))
    #expect(FileManager.default.fileExists(atPath: regenerated.path))
    #expect(!thumbnailRoot.path.hasPrefix(liveRoot.path + "/"))
    let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
    #expect(archive.projects.first?.photoFilename == nil)
}

@MainActor @Test func thumbnailFailureDoesNotRollbackSuccessfulPatternImport() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let blockedCacheRoot = base.appendingPathComponent("blocked-cache")
    try Data("not a directory".utf8).write(to: blockedCacheRoot)
    let store = JSONProjectStore(
        url: base.appendingPathComponent("KnitNote/projects-v1.json"),
        patternThumbnailService: PatternThumbnailFileService(directory: blockedCacheRoot)
    )
    try store.add(name: "Scarf")
    let projectID = try #require(store.projects.first?.id)
    let source = base.appendingPathComponent("chart.png")
    try makeStorePNG(at: source, red: 0.6)

    let imported = try await store.importPattern(from: source, projectID: projectID)
    let savedProject = try #require(store.project(id: projectID))
    let fallbackURL = await store.projectCoverURL(for: savedProject)

    #expect(savedProject.patterns.map(\.id) == [imported.id])
    #expect(fallbackURL == nil)
}
```

Add this helper at file scope:

```swift
private func makeStorePNG(at url: URL, red: CGFloat) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let context = try #require(CGContext(
        data: nil,
        width: 32,
        height: 16,
        bitsPerComponent: 8,
        bytesPerRow: 128,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
    let destination = try #require(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter projectCover
swift test --filter coverCache
```

Expected: FAIL to compile because `patternThumbnailService` injection and `projectCoverURL(for:)` do not exist.

- [ ] **Step 3: Inject the cache service and implement asynchronous resolution**

In `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`:

1. Add the stored dependency:

```swift
private let patternThumbnailService: PatternThumbnailFileService
```

2. Add a cover-only publication revision:

```swift
@Published public private(set) var projectCoverGeneration: UInt64 = 0
```

3. Add `patternThumbnailService: PatternThumbnailFileService? = nil` to both initializers. In the designated initializer assign:

```swift
let liveRoot = url.deletingLastPathComponent()
self.patternThumbnailService = patternThumbnailService ?? PatternThumbnailFileService(
    directory: liveRoot.deletingLastPathComponent().appendingPathComponent(
        ".KnitNote-PatternThumbnailCache",
        isDirectory: true
    )
)
```

4. Add the public async resolver next to `photoURL(for:)`:

```swift
public func projectCoverURL(for project: StoredProject) async -> URL? {
    if let photoURL = photoURL(for: project) {
        return photoURL
    }
    guard let pattern = project.patterns.first else { return nil }
    let sourceURL = patternFileService.url(projectID: project.id, pattern: pattern)
    let service = patternThumbnailService
    return await Task.detached(priority: .utility) {
        try? service.thumbnailURL(
            projectID: project.id,
            pattern: pattern,
            sourceURL: sourceURL
        )
    }.value
}
```

5. After `addPattern(projectID:pattern:)` succeeds inside `importPattern`, warm the cache off the main actor without allowing failure to escape. Await the detached work before ending the active pattern transaction so backup restore cannot race it:

```swift
let thumbnailService = patternThumbnailService
let patternSourceURL = service.url(projectID: projectID, pattern: pattern)
_ = await Task.detached(priority: .utility) {
    _ = try? thumbnailService.thumbnailURL(
        projectID: projectID,
        pattern: pattern,
        sourceURL: patternSourceURL
    )
}.value
```

6. After a pattern is durably removed, clean its thumbnail:

```swift
try? patternThumbnailService.delete(projectID: projectID, patternID: pattern.id)
```

7. After a project is durably removed, clean its thumbnail directory:

```swift
try? patternThumbnailService.deleteProject(projectID: id)
```

8. After `restoreBackup(_:)` has installed and reloaded the restored live data successfully, clear all disposable thumbnails and publish a cover-only revision so visible covers reload even when restored pattern IDs match the previous archive:

```swift
try? patternThumbnailService.deleteAll()
projectCoverGeneration &+= 1
```

- [ ] **Step 4: Run the focused and adjacent store tests**

Run:

```bash
swift test --filter projectCover
swift test --filter coverCache
swift test
```

Expected: focused tests and the complete package suite pass; existing project photos, pattern persistence, and deletion behavior remain green.

- [ ] **Step 5: Commit Task 2**

```bash
git add Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift
git commit -m "Resolve project covers from photos or patterns"
```

---

### Task 3: Shared Asynchronous Project Cover UI

**Files:**
- Create: `KnitNote/Projects/ProjectCoverView.swift`
- Modify: `KnitNote/Projects/ProjectCard.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `KnitNote/Projects/ProjectsView.swift`
- Create: `Tests/KnitNoteCoreTests/ProjectCoverViewContractTests.swift`

**Interfaces:**
- Consumes: `JSONProjectStore.projectCoverURL(for:) async -> URL?`, `ProjectPhotoView`.
- Produces: `ProjectCoverView(project:)`, the only app-level entry point for project cover display.

- [ ] **Step 1: Write the failing source contract**

Create `Tests/KnitNoteCoreTests/ProjectCoverViewContractTests.swift`:

```swift
import Foundation
import Testing

@Suite struct ProjectCoverViewContractTests {
    @Test func projectScreensUseOneAsyncCoverView() throws {
        let cover = try source("KnitNote/Projects/ProjectCoverView.swift")
        let card = try source("KnitNote/Projects/ProjectCard.swift")
        let detail = try source("KnitNote/Projects/ProjectDetailView.swift")
        let list = try source("KnitNote/Projects/ProjectsView.swift")

        #expect(cover.contains("await store.projectCoverURL(for: project)"))
        #expect(cover.contains(".task(id: revision)"))
        #expect(cover.contains("generation: store.projectCoverGeneration"))
        #expect(cover.contains("guard !Task.isCancelled else { return }"))
        #expect(cover.contains("ProjectPhotoView(url: resolvedURL)"))
        #expect(card.contains("ProjectCoverView(project: project)"))
        #expect(detail.contains("ProjectCoverView(project: project)"))
        #expect(!card.contains("let photoURL: URL?"))
        #expect(list.contains("ProjectCard(project: project)"))
        #expect(!list.contains("photoURL: store.photoURL"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
```

- [ ] **Step 2: Run the contract test and verify RED**

Run:

```bash
swift test --filter ProjectCoverViewContractTests
```

Expected: FAIL because `KnitNote/Projects/ProjectCoverView.swift` does not exist.

- [ ] **Step 3: Implement the shared cover view**

Create `KnitNote/Projects/ProjectCoverView.swift`:

```swift
import SwiftUI

struct ProjectCoverView: View {
    @EnvironmentObject private var store: JSONProjectStore
    let project: StoredProject
    @State private var resolvedURL: URL?

    var body: some View {
        ProjectPhotoView(url: resolvedURL)
            .task(id: revision) {
                resolvedURL = store.photoURL(for: project)
                guard !Task.isCancelled else { return }
                if resolvedURL == nil {
                    let fallbackURL = await store.projectCoverURL(for: project)
                    guard !Task.isCancelled else { return }
                    resolvedURL = fallbackURL
                }
            }
    }

    private var revision: ProjectCoverRevision {
        ProjectCoverRevision(
            photoFilename: project.photoFilename,
            firstPatternID: project.patterns.first?.id,
            generation: store.projectCoverGeneration
        )
    }
}

private struct ProjectCoverRevision: Hashable {
    let photoFilename: String?
    let firstPatternID: UUID?
    let generation: UInt64
}
```

Change `KnitNote/Projects/ProjectCard.swift`:

```swift
import SwiftUI

struct ProjectCard: View {
    let project: StoredProject

    var body: some View {
        WatercolorCard {
            HStack(spacing: 16) {
                ProjectCoverView(project: project)
                    .frame(width: 58, height: 58)
                    .clipShape(.rect(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.headline)
                        .foregroundStyle(WatercolorTheme.ink)
                    if project.isCompleted {
                        Label("project.status.completed", systemImage: "checkmark.seal.fill")
                            .font(.caption.bold())
                            .foregroundStyle(WatercolorTheme.actionBerry)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WatercolorTheme.actionBerry)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
    }
}
```

Change the cover in `KnitNote/Projects/ProjectDetailView.swift`:

```swift
ProjectCoverView(project: project)
    .frame(width: 96, height: 96)
    .clipShape(.rect(cornerRadius: 22))
```

Change the project card call in `KnitNote/Projects/ProjectsView.swift`:

```swift
ProjectCard(project: project)
```

- [ ] **Step 4: Generate the Xcode project and run UI contract plus platform builds**

Run:

```bash
xcodegen generate
swift test --filter ProjectCoverViewContractTests
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNotePatternCoverIOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNotePatternCoverMac CODE_SIGNING_ALLOWED=NO build
```

Expected: contract test passes and both builds end with `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit Task 3**

```bash
git add KnitNote/Projects/ProjectCoverView.swift KnitNote/Projects/ProjectCard.swift KnitNote/Projects/ProjectDetailView.swift KnitNote/Projects/ProjectsView.swift Tests/KnitNoteCoreTests/ProjectCoverViewContractTests.swift KnitNote.xcodeproj/project.pbxproj
git commit -m "Show pattern fallback covers in project screens"
```

---

### Task 4: Regression, Backup Boundary, and Final Verification

**Files:**
- Modify only if a failing verification exposes an in-scope defect in files from Tasks 1–3.

**Interfaces:**
- Consumes: all Task 1–3 behavior.
- Produces: verified cross-platform source ready for a later version/build increment and App Store submission.

- [ ] **Step 1: Run the complete Swift package suite**

Run:

```bash
swift test
```

Expected: all tests pass with zero failures.

- [ ] **Step 2: Verify cache and archive boundaries**

Run:

```bash
rg -n "PatternThumbnail|photoFilename|ProjectArchive.currentVersion" Sources/KnitNoteCore/Projects/JSONProjectStore.swift Sources/KnitNoteCore/Patterns/PatternThumbnailFileService.swift Sources/KnitNoteCore/Projects/StoredProject.swift
```

Expected:

- thumbnail cache root is `.KnitNote-PatternThumbnailCache`, a sibling of the live `KnitNote` root;
- `StoredProject.photoFilename` is not assigned during pattern import;
- `ProjectArchive.currentVersion` remains `9`.

- [ ] **Step 3: Re-run both app builds from clean derived-data paths**

Run:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNotePatternCoverFinalIOS CODE_SIGNING_ALLOWED=NO clean build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNotePatternCoverFinalMac CODE_SIGNING_ALLOWED=NO clean build
```

Expected: both commands end with `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Verify repository hygiene**

Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only intentional feature files are modified or untracked. Preserve the user's existing `.superpowers/`, `KnitNote 5.xcodeproj/`, and `KnitNote 6.xcodeproj/` paths without staging or changing them.

- [ ] **Step 5: Commit any verification-only correction, otherwise record the verified HEAD**

If Step 1–4 required an in-scope correction:

```bash
git add Sources/KnitNoteCore/Patterns/PatternThumbnailFileService.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift KnitNote/Projects/ProjectCoverView.swift Tests/KnitNoteCoreTests/PatternThumbnailFileServiceTests.swift Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift Tests/KnitNoteCoreTests/ProjectCoverViewContractTests.swift
git commit -m "Harden pattern fallback project covers"
```

If no correction was required, do not create an empty commit. Record:

```bash
git log -1 --oneline
git status --short
```

Expected: the latest feature commit is present and the only remaining untracked paths are the preserved user-owned paths named in Step 4.
