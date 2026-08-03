# Task 3: Mac yarn editor accessibility verification

## Result

Added distinct, localized accessibility labels to the four macOS yarn range
fields and verified them through an external macOS XCTest UI runner.

The runner now also protects the requested Create/Edit contract: Create checks
all 18 planned elements: `name`, `brand`, `series`, `color`, `colorCode`,
`dyeLot`, `ballWeightGrams`, `lengthMeters`, `fiberContent`, both needle
inputs, both hook inputs, `remainingBalls`, `remainingGrams`,
`storageLocation`, `notes`, and `linkedProjects`;
Edit checks `scan`, `labelPhotos`, and the photo image/replacement action.

| Identifier | English label | Traditional Chinese label |
| --- | --- | --- |
| `macYarnEditor.needleLower` | `Knitting Needle, From` | `建議棒針，最小` |
| `macYarnEditor.needleUpper` | `Knitting Needle, To` | `建議棒針，最大` |
| `macYarnEditor.hookLower` | `Crochet Hook, From` | `建議鉤針，最小` |
| `macYarnEditor.hookUpper` | `Crochet Hook, To` | `建議鉤針，最大` |

## Verification boundary

`KnitNoteMacUITests` is a macOS `bundle.ui-testing` target generated from
`project.yml` and included in the shared `KnitNote` scheme.  Each test launches
`com.phillon.KnitNote`, opens Yarn Library, opens Add Yarn, chooses the manual
entry path, then verifies each runtime AX element by identifier, exact label,
and a non-empty frame. The focused result bundle reports four passing tests
(Create and Edit in English and Traditional Chinese):

```
xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteMacYarnAllFieldsFinal \
  -only-testing:KnitNoteMacUITests/MacYarnEditorAccessibilityUITests
```

The result bundle reports `passedTests: 4`, `failedTests: 0`.

The UI tests launch the existing DEBUG-only Store Screenshot mode, which
recreates a deterministic privacy-safe fixture under the temporary directory
for every launch. Its first yarn has a generated swatch-backed label photo so
Edit exposes the real gallery; no user Application Support data is accessed.

An earlier in-process AppKit accessibility-tree experiment could not observe
the hosted controls reliably and was removed.  It is not used as coverage;
the shipped check is the external UI-runner test above.

TDD first exposed the missing fixture label photo, then empty macOS AX labels
for `brand`, `fiberContent`, and the label-photo gallery. The affected text
fields, `linkedProjects`, and gallery now set explicit localized labels,
asserted through the external runner.

## Additional checks

- `KnitNoteAppTests/MacYarnEditorLayoutTests`: 3 passed, 0 failed.
- `swift test --disable-sandbox`: 1,134 tests passed in 98 suites.
- Clean `xcodebuild build` completed for macOS and generic iOS Simulator with
  `CODE_SIGNING_ALLOWED=NO`.
- `git diff --check` and `plutil -lint KnitNote.xcodeproj/project.pbxproj`
  completed successfully.

`KnitNote 5.xcodeproj/` remains untracked and excluded from this task.
