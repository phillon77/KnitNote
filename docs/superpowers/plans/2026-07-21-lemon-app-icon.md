# Lemon App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a production App icon based on the unchanged Lemon-and-yarn watercolor artwork and configure KnitNote to use it on iPhone, iPad, Mac, and Apple Watch.

**Architecture:** Generate one opaque 1024-pixel master with an AI-generated background and the existing `LemonYarn` pixels composited unchanged. Derive deterministic platform renditions from that master, describe them in separate main-app and Watch asset catalogs, and verify both the catalog contracts and the built products.

**Tech Stack:** Xcode asset catalogs, PNG, Swift Testing, Foundation/ImageIO, XcodeGen, `sips`, `xcodebuild`

## Global Constraints

- Preserve `KnitNote/Assets.xcassets/LemonYarn.imageset/lemon-yarn.png` unchanged.
- Use the original Lemon pose, proportions, markings, and brushwork; do not redraw or AI-restyle Lemon.
- Deliver an opaque 1024-by-1024 master without pre-rendered rounded corners or platform masks.
- Keep approximately 12 percent visual safety space around Lemon and the yarn ball.
- Use a pale sky-blue, lavender, and soft-white watercolor background with no text, border, flowers, tools, or decorative shadows.
- Version one has no dark-mode or tinted icon variants.
- Maintain iOS 18.0, macOS 15.0, and watchOS 11.0 deployment floors.
- Add no third-party dependencies.

---

### Task 1: Lock the App Icon Contract

**Files:**
- Create: `Tests/KnitNoteCoreTests/AppIconAssetContractTests.swift`
- Test: `Tests/KnitNoteCoreTests/AppIconAssetContractTests.swift`

**Interfaces:**
- Consumes: repository files relative to `#filePath`.
- Produces: contract coverage for catalog structure, master-image properties, project settings, and source-art preservation.

- [ ] **Step 1: Write the failing contract tests**

```swift
import Foundation
import ImageIO
import Testing

@Suite struct AppIconAssetContractTests {
    @Test func mainAndWatchCatalogsContainAnOpaque1024Master() throws {
        for relativePath in [
            "KnitNote/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png",
            "KnitNoteWatch/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png"
        ] {
            let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try #require(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            )
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1024)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1024)
            #expect(properties[kCGImagePropertyHasAlpha] as? Bool != true)
        }
    }

    @Test func projectUsesAppIconForBothTargets() throws {
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        #expect(project.components(separatedBy: "ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon").count == 3)
    }

    @Test func originalLemonAssetRemainsTrackedSeparately() {
        let original = repositoryRoot.appendingPathComponent(
            "KnitNote/Assets.xcassets/LemonYarn.imageset/lemon-yarn.png"
        )
        #expect(FileManager.default.fileExists(atPath: original.path))
    }
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
env CLANG_MODULE_CACHE_PATH=/tmp/knitnote-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-module-cache \
swift test --disable-sandbox \
  -Xswiftc -module-cache-path -Xswiftc /tmp/knitnote-module-cache \
  --filter AppIconAssetContractTests
```

Expected: FAIL because neither `AppIcon.appiconset` exists and `project.yml` still contains an empty App icon compiler setting.

- [ ] **Step 3: Commit the failing contract when Git metadata is writable**

```bash
git add Tests/KnitNoteCoreTests/AppIconAssetContractTests.swift
git commit -m "test: define App icon asset contract"
```

Expected: one commit containing only the contract test. If the environment keeps `.git/index` read-only, record that limitation and continue without staging unrelated user changes.

---

### Task 2: Produce the Watercolor Master and Platform Catalogs

**Files:**
- Preserve: `KnitNote/Assets.xcassets/LemonYarn.imageset/lemon-yarn.png`
- Create: `KnitNote/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `KnitNote/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png`
- Create: `KnitNote/Assets.xcassets/AppIcon.appiconset/app-icon-*.png`
- Create: `KnitNoteWatch/Assets.xcassets/Contents.json`
- Create: `KnitNoteWatch/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `KnitNoteWatch/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png`
- Create: `KnitNoteWatch/Assets.xcassets/AppIcon.appiconset/app-icon-*.png`

**Interfaces:**
- Consumes: unchanged 1024-pixel transparent `LemonYarn` artwork and a generated watercolor-only background.
- Produces: opaque main-app and Watch icon catalogs named `AppIcon`.

- [ ] **Step 1: Generate the background-only raster with the built-in image generator**

Use this exact production prompt and do not include Lemon in the generated output:

```text
Use case: logo-brand
Asset type: square App icon background, 1024 by 1024 pixels
Primary request: Create only a quiet hand-painted watercolor background that matches the supplied family knitting illustration.
Scene/backdrop: abstract open sky with no horizon and no objects
Style/medium: delicate family watercolor illustration, soft paper texture, airy hand-painted washes
Composition/framing: square, even visual weight, brightest soft-white area near the center, generous calm edges
Color palette: pale sky blue, very light lavender, and warm soft white
Constraints: background only; opaque edge-to-edge image; no subject; no rabbit; no yarn; no person; no flowers; no text; no border; no logo; no rounded corners; no shadow; no vignette
Avoid: hard geometric gradients, strong saturation, photorealism, identifiable objects, dark corners, watermark
```

Save the chosen generated background inside `/tmp/knitnote-app-icon/` for deterministic compositing. Inspect it before continuing and reject any version containing visible objects, flowers, text, borders, or dark corners.

- [ ] **Step 2: Composite the original Lemon pixels without redrawing them**

Use a small Swift/CoreGraphics utility executed from `/tmp/knitnote-app-icon/` to:

1. render the generated background into a 1024-by-1024 opaque RGB bitmap;
2. draw the existing `lemon-yarn.png` centered over the full 1024-by-1024 canvas, preserving its pixels and alpha edges;
3. export `app-icon-1024.png` without an alpha channel;
4. leave the source `lemon-yarn.png` byte-for-byte unchanged.

Validate the source checksum before and after:

```bash
shasum -a 256 KnitNote/Assets.xcassets/LemonYarn.imageset/lemon-yarn.png
```

Expected: identical SHA-256 values.

- [ ] **Step 3: Inspect the master at full and small sizes**

Create temporary 60-, 40-, 32-, and 20-pixel previews with `sips`. Confirm that both Lemon's ears and the round lavender yarn ball remain recognizable, the subject does not touch the platform-mask edge, and the background stays calm.

```bash
sips -z 60 60 /tmp/knitnote-app-icon/app-icon-1024.png --out /tmp/knitnote-app-icon/preview-60.png
sips -z 40 40 /tmp/knitnote-app-icon/app-icon-1024.png --out /tmp/knitnote-app-icon/preview-40.png
sips -z 32 32 /tmp/knitnote-app-icon/app-icon-1024.png --out /tmp/knitnote-app-icon/preview-32.png
sips -z 20 20 /tmp/knitnote-app-icon/app-icon-1024.png --out /tmp/knitnote-app-icon/preview-20.png
```

Expected: no cropping, no transparency, and a recognizable Lemon/yarn silhouette at every preview size.

- [ ] **Step 4: Build the main-app catalog**

Copy the approved master to `KnitNote/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png`, use `sips` to create the iPhone, iPad, and Mac pixel renditions referenced by `Contents.json`, and include:

- iPhone 20, 29, 40, and 60 point slots at required 2x/3x scales;
- iPad 20, 29, 40, 76, and 83.5 point slots at required 1x/2x scales;
- Mac 16, 32, 128, 256, and 512 point slots at 1x/2x scales;
- one 1024-pixel `ios-marketing` slot.

Each `Contents.json` image entry must contain the exact `filename`, `idiom`, `scale`, and `size`. The file ends with:

```json
"info" : {
  "author" : "xcode",
  "version" : 1
}
```

- [ ] **Step 5: Build the Watch catalog**

Create `KnitNoteWatch/Assets.xcassets` and a Watch `AppIcon.appiconset` using the same approved master. Include Watch notification, companion settings, app launcher, quick look, and `watch-marketing` slots required by watchOS 11.0. Do not introduce a visually different Watch composition.

- [ ] **Step 6: Run the focused tests and verify the image portion is GREEN**

Run the focused command from Task 1.

Expected: the image dimensions, opacity, and original-source-presence tests pass; the project-setting test still fails until Task 3.

- [ ] **Step 7: Commit the icon assets when Git metadata is writable**

```bash
git add KnitNote/Assets.xcassets/AppIcon.appiconset KnitNoteWatch/Assets.xcassets
git commit -m "feat: add Lemon App icon assets"
```

Expected: one asset-only commit. If Git remains read-only, do not stage unrelated changes.

---

### Task 3: Configure Xcode and Verify Every Available Platform

**Files:**
- Modify: `project.yml`
- Modify (generated): `KnitNote.xcodeproj/project.pbxproj`
- Test: `Tests/KnitNoteCoreTests/AppIconAssetContractTests.swift`

**Interfaces:**
- Consumes: both asset catalogs named `AppIcon` from Task 2.
- Produces: main and Watch targets configured with `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` and verified build products.

- [ ] **Step 1: Configure both targets in `project.yml`**

Set the main target's existing value and add the same setting to the Watch target:

```yaml
ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
```

The string must appear exactly twice: once under `KnitNote.settings.base` and once under `KnitNoteWatch.settings.base`.

- [ ] **Step 2: Regenerate the Xcode project**

Run:

```bash
xcodegen generate
```

Expected: `KnitNote.xcodeproj/project.pbxproj` references both asset catalogs and both target build configurations use `AppIcon`.

- [ ] **Step 3: Run the focused tests and verify GREEN**

Run the focused command from Task 1.

Expected: all `AppIconAssetContractTests` pass.

- [ ] **Step 4: Run the complete Swift test suite twice**

Run the full Swift test command from Task 1 without `--filter AppIconAssetContractTests`, twice.

Expected each time: 394 existing tests plus the new App icon contract tests pass with zero failures.

- [ ] **Step 5: Build iOS Simulator, iOS device, and Mac sequentially**

```bash
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/KnitNoteAppIconSim CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/KnitNoteAppIconIOS CODE_SIGNING_ALLOWED=NO build

xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/KnitNoteAppIconMac CODE_SIGNING_ALLOWED=NO build
```

Expected: all three commands exit 0. Run sequentially because concurrent asset builds can destabilize CoreSimulatorService.

- [ ] **Step 6: Verify generated icon metadata**

```bash
plutil -p /tmp/KnitNoteAppIconSim/Build/Products/Debug-iphonesimulator/KnitNote.app/Info.plist | rg 'CFBundleIcon|AppIcon'
plutil -p /tmp/KnitNoteAppIconMac/Build/Products/Debug/KnitNote.app/Contents/Info.plist | rg 'CFBundleIcon|AppIcon'
git diff --check
```

Expected: built products contain icon metadata and `git diff --check` emits no output.

- [ ] **Step 7: Validate Watch when the SDK is available**

```bash
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNoteWatch \
  -destination 'generic/platform=watchOS' \
  -derivedDataPath /tmp/KnitNoteAppIconWatch CODE_SIGNING_ALLOWED=NO build
```

Expected with an installed watchOS 26.5 platform: exit 0. If the SDK remains unavailable, report the exact missing-platform error and retain the structurally validated Watch asset catalog.

- [ ] **Step 8: Commit configuration when Git metadata is writable**

```bash
git add project.yml KnitNote.xcodeproj/project.pbxproj Tests/KnitNoteCoreTests/AppIconAssetContractTests.swift
git commit -m "feat: configure Lemon App icon"
```

Expected: a focused configuration-and-contract commit. If Git remains read-only, leave the verified workspace changes unstaged and report that limitation.
