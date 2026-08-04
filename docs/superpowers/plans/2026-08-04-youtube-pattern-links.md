# YouTube Pattern Links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reusable YouTube links to the KnitNote pattern library, with automatic metadata, external playback, multi-project linking, safe backup/restore, and no stored video data.

**Architecture:** Extend the existing `PatternAsset` → `StoredPattern` → `PatternProjectUsage` model with a `.youtube` asset whose owned file is a tiny validated JSON sidecar. Keep URL parsing, canonicalization, persistence, and duplicate detection in `KnitNoteCore`; isolate Apple `LinkPresentation` metadata fetching in the app target; route YouTube items to `OpenURLAction` instead of `PatternReaderView`. Reuse the existing thumbnail cache for fetched images and exclude that cache from backup.

**Tech Stack:** Swift 6, Foundation, CryptoKit, SwiftUI, LinkPresentation, ImageIO/CoreGraphics, Swift Testing, XCStrings, XcodeGen, iOS 18, macOS 15.

## Global Constraints

- Target KnitNote 1.3.1; do not modify or rebuild the approved/released 1.3.0 Build 6 candidate.
- Support iPhone, iPad, and Mac; do not add YouTube links to Apple Watch.
- Treat YouTube as `PatternKind.youtube`; do not create a separate video database or project-only URL field.
- One YouTube item can link to zero, one, or many projects through existing `PatternProjectUsage` semantics.
- Open canonical HTTPS links externally; do not embed WebView, a player, a YouTube API key, login, search, playlists, or video downloads.
- Fetch title and thumbnail with `LPMetadataProvider`; allow editable/manual title and a default YouTube icon when fetching fails.
- Detect duplicates by normalized video ID/canonical URL, not the pasted URL string.
- Store only a small JSON sidecar, title, note, dates, and usages; never store video bytes.
- Include the sidecar and relationships in complete backup; exclude thumbnail and LinkPresentation caches.
- Add exact English and Traditional Chinese localization and accessible VoiceOver/Dynamic Type behavior.
- Keep YouTube usages at a default unused reading state; do not expose page, zoom, highlight, page note, markup, counter, or reader-calculator behavior.
- Raise `ProjectArchive.currentVersion` from 11 to 12 and preserve safe loading of archive versions 1 through 11.
- Do not modify StoreKit, pricing, trial, entitlements, privacy metadata, version/build, Git remote state, App Store Connect, or Small Business Program enrollment.

---

### Task 1: Parse and Canonicalize Supported YouTube URLs

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/YouTubePatternLink.swift`
- Create: `Tests/KnitNoteCoreTests/YouTubePatternLinkTests.swift`

**Interfaces:**
- Consumes: Foundation `URL` and `URLComponents` only.
- Produces: `YouTubePatternLink(videoID:canonicalURL:)`, `YouTubePatternLink.init(parsing:)`, and `YouTubePatternLinkError` for Tasks 2–6.

- [ ] **Step 1: Write failing accepted-form and rejection tests**

Create `YouTubePatternLinkTests.swift`:

```swift
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct YouTubePatternLinkTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=31",
        "https://youtu.be/dQw4w9WgXcQ?si=abc",
        "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        "https://www.youtube.com/live/dQw4w9WgXcQ?feature=share",
    ])
    func supportedFormsCanonicalize(_ rawValue: String) throws {
        let link = try YouTubePatternLink(parsing: #require(URL(string: rawValue)))
        #expect(link.videoID == "dQw4w9WgXcQ")
        #expect(link.canonicalURL.absoluteString ==
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test(arguments: [
        "http://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/playlist?list=PL123",
        "https://www.youtube.com/watch?v=",
        "https://example.com/watch?v=dQw4w9WgXcQ",
        "https://youtu.be/not-valid",
    ])
    func unsafeOrUnsupportedLinksAreRejected(_ rawValue: String) throws {
        #expect(throws: YouTubePatternLinkError.self) {
            try YouTubePatternLink(parsing: #require(URL(string: rawValue)))
        }
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter YouTubePatternLinkTests
```

Expected: compilation fails because `YouTubePatternLink` does not exist.

- [ ] **Step 3: Implement the immutable canonical link type**

Create these public types:

```swift
import Foundation

public enum YouTubePatternLinkError: Error, Equatable, Sendable {
    case insecureURL
    case unsupportedHost
    case missingVideoID
    case invalidVideoID
}

public struct YouTubePatternLink: Codable, Equatable, Hashable, Sendable {
    public let videoID: String
    public let canonicalURL: URL

    public init(videoID: String) throws {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        )
        guard videoID.count == 11,
              videoID.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)")
        else { throw YouTubePatternLinkError.invalidVideoID }
        self.videoID = videoID
        canonicalURL = url
    }

    public init(parsing url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw YouTubePatternLinkError.insecureURL
        }
        guard let host = url.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"]
                .contains(host) else {
            throw YouTubePatternLinkError.unsupportedHost
        }

        let path = url.pathComponents.filter { $0 != "/" }
        let videoID: String?
        if host == "youtu.be" {
            videoID = path.first
        } else if path.first == "watch" {
            videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value
        } else if let first = path.first,
                  ["shorts", "live"].contains(first),
                  path.count >= 2 {
            videoID = path[1]
        } else {
            videoID = nil
        }
        guard let videoID, !videoID.isEmpty else {
            throw YouTubePatternLinkError.missingVideoID
        }
        try self.init(videoID: videoID)
    }
}
```

Do not accept hosts by suffix matching. A `watch` URL with both `v` and `list` uses `v`; a playlist URL without `v` throws `.missingVideoID`.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run `swift test --filter YouTubePatternLinkTests`.

Expected: all canonicalization and rejection cases pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add Sources/KnitNoteCore/Patterns/YouTubePatternLink.swift \
  Tests/KnitNoteCoreTests/YouTubePatternLinkTests.swift
git commit -m "feat: parse YouTube pattern links"
```

---

### Task 2: Add the Owned YouTube Sidecar Asset and Archive Version 12

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/YouTubePatternMetadata.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternDocument.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternFileService.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternThumbnailFileService.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternLibraryMigrator.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternLibraryMigrationTests.swift`
- Create: `Tests/KnitNoteCoreTests/YouTubePatternAssetTests.swift`

**Interfaces:**
- Consumes: `YouTubePatternLink` from Task 1.
- Produces: `.youtube`, `YouTubePatternMetadata`, `PatternFileService.storeYouTubeMetadata(_:assetID:)`, and `PatternFileService.youtubeMetadata(for:)` for Tasks 3–6.

- [ ] **Step 1: Write failing sidecar, security, and migration tests**

Cover these exact cases in `YouTubePatternAssetTests.swift`:

```swift
@Test func storesAndReloadsAValidatedYouTubeSidecar() throws {
    let root = temporaryDirectory()
    let service = PatternFileService(root: root)
    let link = try YouTubePatternLink(videoID: "dQw4w9WgXcQ")
    let metadata = YouTubePatternMetadata(link: link)
    let asset = try service.storeYouTubeMetadata(metadata, assetID: UUID())

    #expect(asset.kind == .youtube)
    #expect(asset.pageCount == nil)
    #expect(asset.storedFilename == "\(asset.id.uuidString).youtube")
    #expect(try service.youtubeMetadata(for: asset) == metadata)
}

@Test func rejectsTraversalWrongExtensionAndTamperedSidecars() throws {
    // Assert unsafe storedFilename, non-.youtube asset kind, malformed JSON,
    // canonical URL/video-ID disagreement, and SHA mismatch are rejected.
}
```

Add migration assertions that archive versions 1–11 load as version 12 without changing existing assets, patterns, usages, projects, yarns, reading state, or markup ownership.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter YouTubePatternAssetTests
swift test --filter PatternLibraryMigrationTests
```

Expected: `.youtube`, metadata APIs, and archive version 12 are absent.

- [ ] **Step 3: Define the versioned sidecar model**

Create:

```swift
import Foundation

public enum YouTubePatternMetadataError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidLink
}

public struct YouTubePatternMetadata: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let videoID: String
    public let canonicalURL: URL

    public init(link: YouTubePatternLink) {
        version = Self.currentVersion
        videoID = link.videoID
        canonicalURL = link.canonicalURL
    }

    public func validated() throws -> YouTubePatternLink {
        guard version == Self.currentVersion else {
            throw YouTubePatternMetadataError.unsupportedVersion
        }
        let link = try YouTubePatternLink(videoID: videoID)
        guard link.canonicalURL == canonicalURL else {
            throw YouTubePatternMetadataError.invalidLink
        }
        return link
    }
}
```

- [ ] **Step 4: Extend file ownership and validation without routing JSON into image rendering**

Add `.youtube` to `PatternKind`. In `PatternFileService`:

- Encode the sidecar with `JSONEncoder.outputFormatting = [.sortedKeys]`.
- Hash the exact encoded sidecar bytes for `PatternAsset.sha256`, preserving the existing file-integrity invariant; identical canonical links still produce identical sidecar bytes and hashes.
- Store the JSON atomically as `<asset UUID>.youtube`.
- Set `byteCount` to the written sidecar size and `pageCount` to `nil`.
- Validate the owned filename, regular-file/no-symlink boundary, JSON schema, canonical link, byte count, and SHA when reading.
- Add `case .youtube: return ["youtube"]` to the kind-specific extension switch and add `youtube` to the owned extension allowlist.

In `PatternThumbnailFileService.thumbnailURL(asset:sourceURL:)`, reject `.youtube` with `.unreadableSource`; never attempt to decode its JSON as PDF or image.

- [ ] **Step 5: Raise the archive version and update every exhaustive switch**

Change:

```swift
public static let currentVersion = 12
```

Update migration and release contract tests so versions 1–11 migrate to 12. Search all switches before compiling:

```bash
rg -n "switch .*kind|case \.pdf|case \.image|PatternKind" Sources KnitNote Tests
```

Every switch must explicitly handle `.youtube`; do not use a broad `default` that could send a sidecar into PDF/image code.

- [ ] **Step 6: Run focused and full core tests**

Run:

```bash
swift test --filter YouTubePatternAssetTests
swift test --filter PatternLibraryMigrationTests
swift test --filter PatternImportSecurityTests
swift test
```

Expected: all pass; existing PDF/image import and migration remain green.

- [ ] **Step 7: Commit Task 2**

```bash
git add Sources/KnitNoteCore/Patterns/YouTubePatternMetadata.swift \
  Sources/KnitNoteCore/Patterns/PatternDocument.swift \
  Sources/KnitNoteCore/Patterns/PatternFileService.swift \
  Sources/KnitNoteCore/Patterns/PatternThumbnailFileService.swift \
  Sources/KnitNoteCore/Projects/JSONProjectStore.swift \
  Sources/KnitNoteCore/Patterns/PatternLibraryMigrator.swift \
  Tests/KnitNoteCoreTests/PatternLibraryMigrationTests.swift \
  Tests/KnitNoteCoreTests/YouTubePatternAssetTests.swift
git commit -m "feat: store YouTube pattern assets"
```

---

### Task 3: Publish, Deduplicate, Link, and Read YouTube Patterns Transactionally

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Create: `Tests/KnitNoteCoreTests/YouTubePatternStoreTests.swift`

**Interfaces:**
- Consumes: `YouTubePatternLink`, `YouTubePatternMetadata`, and the file APIs from Tasks 1–2.
- Produces: `JSONProjectStore.addYouTubePattern(link:title:targetProjectID:now:)` and `JSONProjectStore.youtubeLink(patternID:)` for app UI.

- [ ] **Step 1: Write failing store transaction tests**

Use the existing `PatternLibraryStoreHarness` style and cover:

```swift
@Test func addsOneReusableYouTubePatternAndLinksTwoProjects() async throws {
    let harness = try PatternLibraryStoreHarness()
    let link = try YouTubePatternLink(videoID: "dQw4w9WgXcQ")
    let first = try await harness.store.addYouTubePattern(
        link: link, title: "Cable tutorial", targetProjectID: harness.firstProjectID
    )
    let second = try await harness.store.addYouTubePattern(
        link: link, title: "Ignored duplicate title", targetProjectID: harness.secondProjectID
    )

    #expect(first.resolution == .created)
    #expect(second.resolution == .existing)
    #expect(first.resolvedPatternID == second.resolvedPatternID)
    #expect(harness.store.patternAssets.filter { $0.kind == .youtube }.count == 1)
    #expect(harness.store.patternUsages.filter { $0.patternID == first.resolvedPatternID }.count == 2)
}
```

Also test library-only creation, blank title rejection, missing project rejection, existing active link idempotency, inactive usage reactivation, authorization denial before mutation, archive-save failure rollback, sidecar-write failure cleanup, permanent deletion, and `youtubeLink(patternID:)` validation.

- [ ] **Step 2: Run the focused tests and verify RED**

Run `swift test --filter YouTubePatternStoreTests`.

Expected: the store APIs and result type are absent.

- [ ] **Step 3: Add a result type that distinguishes creation from reuse**

Create this small value near the YouTube store APIs:

```swift
public struct YouTubePatternAddResult: Equatable, Sendable {
    public enum Resolution: Equatable, Sendable { case created, existing }
    public let resolution: Resolution
    public let patternID: UUID
    public var createdPatternID: UUID? { resolution == .created ? patternID : nil }
    public var resolvedPatternID: UUID { patternID }
}
```

The UI uses `resolution` for the existing-item alert and always uses `patternID` for optional thumbnail caching or navigation.

- [ ] **Step 4: Implement the atomic public APIs**

Expose:

```swift
public func addYouTubePattern(
    link: YouTubePatternLink,
    title: String,
    targetProjectID: UUID? = nil,
    now: Date = .now
) async throws -> YouTubePatternAddResult

public func youtubeLink(patternID: UUID) throws -> YouTubePatternLink
```

The add transaction must:

1. Preflight and commit `.importPattern` access using the existing entitlement path.
2. Trim and reject an empty title before any write.
3. Validate `targetProjectID` before any write.
4. Encode the canonical sidecar with sorted keys, compute its content SHA, and resolve an existing `.youtube` asset/pattern.
5. For an existing pattern, create/reactivate the requested usage and return `.existing` without changing its title.
6. For a new pattern, write the sidecar candidate, stage asset/pattern/optional usage arrays, persist once, then publish cleanup.
7. On any failure, remove unpublished sidecar/candidate data and leave arrays/archive unchanged.

Do not reuse the file inbox or Share Extension: those accept actual PDF/image files only and must continue rejecting ordinary URLs.

- [ ] **Step 5: Run focused and regression tests**

Run:

```bash
swift test --filter YouTubePatternStoreTests
swift test --filter PatternLibraryStoreTests
swift test --filter JSONProjectStoreEntitlementTests
swift test --filter PatternImportFaultTests
```

Expected: all pass and existing import transactions remain unchanged.

- [ ] **Step 6: Commit Task 3**

```bash
git add Sources/KnitNoteCore/Projects/JSONProjectStore.swift \
  Tests/KnitNoteCoreTests/YouTubePatternStoreTests.swift
git commit -m "feat: add reusable YouTube patterns"
```

---

### Task 4: Fetch Editable Metadata and Safely Cache External Thumbnails

**Files:**
- Create: `KnitNote/Patterns/YouTubeLinkMetadataFetcher.swift`
- Create: `KnitNote/Patterns/AddYouTubePatternView.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternThumbnailFileService.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Create: `Tests/KnitNoteCoreTests/YouTubeThumbnailCacheTests.swift`
- Create: `Tests/KnitNoteCoreTests/AddYouTubePatternContractTests.swift`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: parser and store APIs from Tasks 1–3.
- Produces: `YouTubeLinkMetadataFetching.fetch(for:)`, `AddYouTubePatternView(targetProjectID:onFinished:)`, and `JSONProjectStore.cacheYouTubeThumbnail(_:patternID:)`.

- [ ] **Step 1: Write failing fetch-state, screen-contract, and image-security tests**

Define contract coverage for `.idle`, `.loading`, `.loaded(title:thumbnailData:)`, and `.manualEntry(messageKey:)`. Assert the screen:

- Parses before fetching.
- Disables Add until canonical link and nonempty title exist.
- Keeps the title editable after fetch success.
- Enables manual title after timeout/offline/no metadata.
- Calls `addYouTubePattern` once and caches a thumbnail only after store success.
- Cancels the current provider when the sheet disappears or the URL changes.

In `YouTubeThumbnailCacheTests`, reject empty, non-image, oversized-dimension, malformed, and symlink/path-escape input. Confirm accepted input is decoded, downsampled, re-encoded as JPEG, and stored only at `PatternThumbnailFileService.cachedURL(assetID:)`.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter YouTubeThumbnailCacheTests
swift test --filter AddYouTubePatternContractTests
```

Expected: the fetcher, view, and external-thumbnail APIs do not exist.

- [ ] **Step 3: Implement the injectable LinkPresentation boundary**

Create:

```swift
import Foundation
import LinkPresentation

struct YouTubeLinkMetadata: Sendable {
    let title: String?
    let thumbnailData: Data?
}

protocol YouTubeLinkMetadataFetching {
    func fetch(for url: URL) async throws -> YouTubeLinkMetadata
}

final class LiveYouTubeLinkMetadataFetcher: YouTubeLinkMetadataFetching {
    func fetch(for url: URL) async throws -> YouTubeLinkMetadata {
        let provider = LPMetadataProvider()
        return try await withTaskCancellationHandler {
            let metadata = try await withCheckedThrowingContinuation { continuation in
                provider.startFetchingMetadata(for: url) { metadata, error in
                    if let metadata { continuation.resume(returning: metadata) }
                    else { continuation.resume(throwing: error ?? URLError(.badServerResponse)) }
                }
            }
            let data: Data?
            if let imageProvider = metadata.imageProvider {
                data = await withCheckedContinuation { continuation in
                    imageProvider.loadDataRepresentation(
                        forTypeIdentifier: UTType.image.identifier
                    ) { data, _ in
                        continuation.resume(returning: data)
                    }
                }
            } else {
                data = nil
            }
            return YouTubeLinkMetadata(title: metadata.title, thumbnailData: data)
        } onCancel: {
            provider.cancel()
        }
    }
}
```

Mark the protocol and live fetcher `@MainActor`, import `UniformTypeIdentifiers`, and add a reusable timeout race:

```swift
enum YouTubeMetadataFetchError: Error { case timedOut }

func withYouTubeMetadataTimeout<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(10))
            throw YouTubeMetadataFetchError.timedOut
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
```

Apply an explicit 10-second timeout in the screen state owner. Metadata failure changes the UI to manual-entry mode; it does not invalidate a previously parsed YouTube link.

- [ ] **Step 4: Add the safe external thumbnail cache API**

Add:

```swift
public func storeExternalThumbnail(data: Data, assetID: UUID) throws -> URL
```

Decode with ImageIO, cap source/destination dimensions and input bytes, downsample to `maxPixelSize`, encode JPEG, and write atomically to the existing cache directory. Expose a store wrapper:

```swift
public func cacheYouTubeThumbnail(_ data: Data, patternID: UUID) async
```

The wrapper verifies that the pattern still exists and is `.youtube` both before and after detached processing. Cache failure is best effort and never rolls back the stored link.

- [ ] **Step 5: Build the minimal adaptive add screen**

`AddYouTubePatternView` contains only URL, Read Metadata, editable Title, thumbnail/default icon, a nonblocking fallback message, Cancel, and Add. It receives an optional `targetProjectID`; on success it returns the resolved `patternID` and `resolution` through `onFinished`.

Use a `Form`/compact card layout that remains usable on iPhone, iPad split view, and Mac. Do not add description, channel, duration, playlist, tags, or embedded preview.

- [ ] **Step 6: Regenerate the Xcode project and run focused tests/build**

Run:

```bash
xcodegen generate
swift test --filter YouTubeThumbnailCacheTests
swift test --filter AddYouTubePatternContractTests
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: tests pass and the iOS target compiles with LinkPresentation.

- [ ] **Step 7: Commit Task 4**

```bash
git add KnitNote/Patterns/YouTubeLinkMetadataFetcher.swift \
  KnitNote/Patterns/AddYouTubePatternView.swift \
  Sources/KnitNoteCore/Patterns/PatternThumbnailFileService.swift \
  Sources/KnitNoteCore/Projects/JSONProjectStore.swift \
  Tests/KnitNoteCoreTests/YouTubeThumbnailCacheTests.swift \
  Tests/KnitNoteCoreTests/AddYouTubePatternContractTests.swift \
  KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: add YouTube pattern metadata form"
```

---

### Task 5: Integrate YouTube Items into the Pattern Library and Detail Screen

**Files:**
- Modify: `KnitNote/Patterns/PatternLibraryView.swift`
- Modify: `KnitNote/Patterns/PatternLibraryRow.swift`
- Modify: `KnitNote/Patterns/PatternDetailView.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternLibraryIndex.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternLibraryViewContractTests.swift`
- Create: `Tests/KnitNoteCoreTests/YouTubePatternLibraryContractTests.swift`

**Interfaces:**
- Consumes: `AddYouTubePatternView`, `youtubeLink(patternID:)`, and thumbnail cache behavior.
- Produces: a library add menu, YouTube-aware row/detail rendering, lazy thumbnail refresh, and external open action.

- [ ] **Step 1: Write failing library and detail contracts**

Assert:

- The plus toolbar is a `Menu` with file import and YouTube actions.
- Existing `.fileImporter` remains and is triggered only by the file action.
- YouTube rows say `patterns.library.youtube` and never show page count or sidecar byte size.
- Detail shows canonical URL and `patterns.youtube.open`, hides original-file export and file-size rows for `.youtube`, and preserves rename/note/link/delete controls.
- External opening calls the environment `openURL` with the canonical HTTPS URL and marks the pattern opened only after the user action.
- PDF/image items still route to the reader and keep their existing detail actions.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter YouTubePatternLibraryContractTests
swift test --filter PatternLibraryViewContractTests
```

Expected: YouTube UI branches and localization keys are absent.

- [ ] **Step 3: Add the two-choice library menu and completion routing**

Replace the direct plus button with a menu containing:

```swift
Button("patterns.import.files", systemImage: "folder") { importing = true }
Button("patterns.youtube.add", systemImage: "play.rectangle") {
    addingYouTubeLink = true
}
```

Present `AddYouTubePatternView(targetProjectID: nil)` and route `.existing` to the existing-item alert/navigation path. Keep the one-time backup reminder behavior for newly created YouTube items by extending its accepted result boundary explicitly; do not fake a file-import outcome.

- [ ] **Step 4: Render and refresh YouTube thumbnails without blocking rows**

Make `PatternThumbnailView` inspect the asset kind. For `.youtube`:

1. Read existing cached JPEG.
2. If absent, show `play.rectangle.fill` immediately.
3. Start a low-priority metadata fetch using the canonical link.
4. Cache any valid returned image through the store wrapper.
5. Re-read the cache only if the same pattern/asset still exists and the task was not cancelled.

Never replace the stored user-edited title from lazy metadata.

- [ ] **Step 5: Add YouTube-aware detail actions**

Branch the header and information/actions cards by `asset.kind`. The YouTube branch uses:

```swift
@Environment(\.openURL) private var openURL

private func openYouTubePattern() {
    guard let link = try? store.youtubeLink(patternID: patternID) else {
        errorMessage = String(localized: "patterns.youtube.error.open")
        return
    }
    openURL(link.canonicalURL) { accepted in
        if accepted { try? store.markPatternOpened(id: patternID) }
        else { errorMessage = String(localized: "patterns.youtube.error.open") }
    }
}
```

Do not create a reader route for `.youtube` and do not export the JSON sidecar through ShareLink.

- [ ] **Step 6: Run focused and existing library tests**

Run:

```bash
swift test --filter YouTubePatternLibraryContractTests
swift test --filter PatternLibraryViewContractTests
swift test --filter PatternLibraryModelTests
```

Expected: all pass for PDF, image, and YouTube rows.

- [ ] **Step 7: Commit Task 5**

```bash
git add KnitNote/Patterns/PatternLibraryView.swift \
  KnitNote/Patterns/PatternLibraryRow.swift \
  KnitNote/Patterns/PatternDetailView.swift \
  Sources/KnitNoteCore/Patterns/PatternLibraryIndex.swift \
  Tests/KnitNoteCoreTests/PatternLibraryViewContractTests.swift \
  Tests/KnitNoteCoreTests/YouTubePatternLibraryContractTests.swift
git commit -m "feat: show YouTube patterns in library"
```

---

### Task 6: Integrate YouTube Items into Project Pattern Workflows

**Files:**
- Modify: `KnitNote/Patterns/ProjectPatternsView.swift`
- Modify: `KnitNote/Patterns/ChooseLibraryPatternView.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectPatternsViewContractTests.swift`
- Create: `Tests/KnitNoteCoreTests/YouTubeProjectPatternsContractTests.swift`

**Interfaces:**
- Consumes: the add screen, link store APIs, row helpers, and external open behavior from Tasks 3–5.
- Produces: project-level add/link/open/unlink support without reader creation.

- [ ] **Step 1: Write failing project workflow contracts**

Assert that:

- The project plus menu has exactly link existing, import PDF/image, and add YouTube link.
- `AddYouTubePatternView(targetProjectID: projectID)` creates or reuses and links in one transaction.
- Choose-existing rows include the YouTube type in visible text/VoiceOver.
- Tapping PDF/image assigns the existing reader selection.
- Tapping YouTube calls `openURL` and never assigns `selectedPattern`/creates `PatternReaderView`.
- Swipe unlink and relink retain existing `PatternProjectUsage` semantics for YouTube.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter YouTubeProjectPatternsContractTests
swift test --filter ProjectPatternsViewContractTests
```

Expected: the project UI has no YouTube branch.

- [ ] **Step 3: Add the project menu and kind-based open route**

Add:

```swift
Button("patterns.youtube.add", systemImage: "play.rectangle") {
    showingYouTubeImporter = true
}
```

When a row is tapped, resolve its asset kind before routing:

```swift
switch selection.asset.kind {
case .youtube: openYouTube(selection)
case .pdf, .image: selectedPattern = selection
}
```

Use the same canonical URL/open-error behavior as the detail screen. Do not duplicate parsing in the view.

- [ ] **Step 4: Add type text to the existing-link chooser**

Render `patternAssetDescription(asset, locale:)` beneath each title. Resolve the asset from `option.pattern.assetID`; if the relation is unexpectedly missing, omit the invalid option instead of presenting a broken row.

- [ ] **Step 5: Run focused and usage regression tests**

Run:

```bash
swift test --filter YouTubeProjectPatternsContractTests
swift test --filter ProjectPatternsViewContractTests
swift test --filter PatternLibraryStoreTests
```

Expected: YouTube link/unlink/relink works and existing reader routing remains green.

- [ ] **Step 6: Commit Task 6**

```bash
git add KnitNote/Patterns/ProjectPatternsView.swift \
  KnitNote/Patterns/ChooseLibraryPatternView.swift \
  Tests/KnitNoteCoreTests/ProjectPatternsViewContractTests.swift \
  Tests/KnitNoteCoreTests/YouTubeProjectPatternsContractTests.swift
git commit -m "feat: link YouTube patterns to projects"
```

---

### Task 7: Complete Localization, VoiceOver, and Dynamic Type Contracts

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/YouTubePatternLibraryContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/YouTubeProjectPatternsContractTests.swift`

**Interfaces:**
- Consumes: all user-facing states from Tasks 4–6.
- Produces: exact English/Traditional Chinese strings and accessibility contracts.

- [ ] **Step 1: Add failing required-localization assertions**

Require exact keys for:

```swift
"patterns.youtube.add"
"patterns.youtube.url"
"patterns.youtube.readMetadata"
"patterns.youtube.loading"
"patterns.youtube.title"
"patterns.youtube.type"
"patterns.youtube.open"
"patterns.youtube.fallback.manualTitle"
"patterns.youtube.error.invalidURL"
"patterns.youtube.error.metadata"
"patterns.youtube.error.open"
"patterns.youtube.accessibility.thumbnail"
```

Add any separate duplicate/success key actually referenced by the screens. Tests must reject missing `en` or `zh-Hant` values and raw-key fallback.

- [ ] **Step 2: Run localization tests and verify RED**

Run `swift test --filter LocalizationContractTests`.

Expected: the required keys are missing.

- [ ] **Step 3: Add exact localized copy and accessible semantics**

Use concise copy. Required base translations include:

| Key | English | Traditional Chinese |
|---|---|---|
| `patterns.youtube.add` | Add YouTube Link | 加入 YouTube 連結 |
| `patterns.youtube.readMetadata` | Read Video Info | 讀取影片資料 |
| `patterns.youtube.title` | Title | 標題 |
| `patterns.youtube.type` | YouTube Video | YouTube 影片 |
| `patterns.youtube.open` | Open in YouTube | 在 YouTube 開啟 |
| `patterns.youtube.fallback.manualTitle` | Video info couldn't be loaded. Enter a title to save this link. | 無法讀取影片資料。輸入標題後仍可儲存連結。 |

The combined row accessibility label must include title, type, and active-project count. Progress and fallback states must be exposed through visible text and accessibility values, not color alone.

- [ ] **Step 4: Run localization and UI contract tests**

Run:

```bash
swift test --filter LocalizationContractTests
swift test --filter YouTubePatternLibraryContractTests
swift test --filter YouTubeProjectPatternsContractTests
```

Expected: both locales and all accessibility contracts pass.

- [ ] **Step 5: Commit Task 7**

```bash
git add KnitNote/Localization/Localizable.xcstrings \
  Tests/KnitNoteCoreTests/LocalizationContractTests.swift \
  Tests/KnitNoteCoreTests/YouTubePatternLibraryContractTests.swift \
  Tests/KnitNoteCoreTests/YouTubeProjectPatternsContractTests.swift
git commit -m "feat: localize YouTube pattern links"
```

---

### Task 8: Preserve YouTube Links through Complete Backup and Restore

**Files:**
- Modify: `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`
- Modify: `Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`

**Interfaces:**
- Consumes: archive version 12 and owned `.youtube` sidecar validation from Task 2.
- Produces: complete-backup round trip with no thumbnail/video payload and explicit release-format contracts.

- [ ] **Step 1: Write failing backup, restore, and tamper tests**

Add cases that:

1. Create one YouTube pattern linked to two projects, unlink one usage, and customize title/note.
2. Cache a thumbnail JPEG.
3. Export a complete backup.
4. Assert the package includes the `.youtube` sidecar and archive, but excludes thumbnail cache and all video/media files.
5. Restore over disposable test data.
6. Assert canonical URL, title, note, active/inactive usages, and project IDs round-trip exactly.
7. Assert the restored cache is absent and the fallback icon path remains valid.
8. Reject a missing, tampered, oversized, symlinked, or schema-invalid sidecar without replacing live data.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter KnitNoteBackupServiceTests
swift test --filter ReleaseConfigurationContractTests
```

Expected: backup validators do not yet recognize `.youtube` and release contracts still expect archive 11.

- [ ] **Step 3: Extend the backup resource allowlist and validation**

Treat `.youtube` files as required owned pattern resources subject to the existing byte-count/SHA manifest. During staging and installation:

- Require filename UUID to equal asset ID.
- Require `asset.kind == .youtube`, `pageCount == nil`, and stored extension `youtube`.
- Decode and validate `YouTubePatternMetadata` before accepting installation.
- Keep thumbnails outside manifest enumeration and replacement.
- Preserve existing package, archive, and per-file size limits.

Update release contracts to require `ProjectArchive.currentVersion = 12` while leaving `KnitNoteBackupManifest.currentFormatVersion = 2` unless a failing compatibility test proves a manifest schema change is necessary.

- [ ] **Step 4: Run backup and destructive-restore regression tests**

Run:

```bash
swift test --filter KnitNoteBackupServiceTests
swift test --filter ReleaseConfigurationContractTests
swift test --filter JSONProjectStoreTests
```

Expected: all backup/restore/tamper cases pass and live data is preserved on failure.

- [ ] **Step 5: Commit Task 8**

```bash
git add Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift \
  Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift \
  Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift
git commit -m "feat: back up YouTube pattern links"
```

---

### Task 9: Run Complete Automated and Three-Platform Acceptance Gates

**Files:**
- Modify only if a verification failure identifies a scoped defect.
- Record results in the current 1.3.1 execution checklist; do not mark App Store submission complete.

**Interfaces:**
- Consumes: the completed Tasks 1–8 candidate commit.
- Produces: one immutable YouTube-feature candidate suitable for later integration with the other 1.3.1 plans.

- [ ] **Step 1: Verify repository identity and cleanliness**

Run:

```bash
git rev-parse --show-toplevel
git branch --show-current
git status --short
git log -1 --oneline
git diff --check
```

Expected: the intended 1.3.1 worktree/branch, no unrelated changes, and no whitespace errors.

- [ ] **Step 2: Run all Swift package tests**

Run `swift test`.

Expected: all suites pass with zero failures.

- [ ] **Step 3: Regenerate and build iOS and macOS without signing**

Run:

```bash
xcodegen generate
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/KnitNote-1.3.1-YouTube-iOS \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/KnitNote-1.3.1-YouTube-macOS \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: both builds succeed. A simulator-service failure is infrastructure evidence, not a passed build.

- [ ] **Step 4: Execute the nine physical/manual scenarios from the approved spec**

Use the same candidate commit on iPhone, iPad, and Mac. Record pass/fail separately for online metadata, offline manual fallback, duplicate URLs, two-project link/unlink, external YouTube/browser routing, iPad rotations/split view, Mac layout/browser, destructive backup/restore, and VoiceOver.

- [ ] **Step 5: Run existing PDF/image and Watch regression smoke checks**

Confirm PDF/image import, reader page/zoom/highlight/notes/markup/counters, project linking/unlinking, and backup still work. Confirm the Watch counter target builds and sync behavior is unchanged; YouTube must not appear on Watch.

- [ ] **Step 6: Commit only scoped fixes, then repeat all affected gates**

Do not amend or declare completion on stale results. After any code change, rerun the focused tests, full `swift test`, both builds, and the affected physical scenario before recording a pass.

---

## Completion Boundary

This plan is complete only when Tasks 1–9 are implemented, reviewed task by task, all automated tests and iOS/macOS builds pass, and the same exact candidate commit passes the required iPhone/iPad/Mac physical scenarios plus Watch regression. It does not authorize version/build changes, merging, pushing, uploading, App Store submission, price changes, or Small Business Program enrollment.
