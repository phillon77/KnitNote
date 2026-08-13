# Project Archive Schema Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fail-open Swift text parser with one canonical schema source file whose complete bytes, compiled symbol, documentation, and release audit all agree on `ProjectArchive.currentVersion == 13`.

**Architecture:** `ProjectArchive` remains defined in `JSONProjectStore.swift`, while a dedicated `ProjectArchiveSchema.swift` extension owns the one runtime version constant. The release audit compares that dedicated file byte-for-byte with a canonical schema-13 payload instead of interpreting Swift syntax. Swift compilation separately proves that the extension resolves to the real type and that no conflicting declaration exists.

**Tech Stack:** Swift 6, Swift Testing, Bash, Python 3 byte comparison, XcodeGen 2.45.4, Xcode build tooling.

## Global Constraints

- Work in `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/knitnote-1.4.1-final` on branch `feature/knitnote-1.5`.
- Begin from the clean plan-tip commit recorded in this plan's SDD ledger immediately before dispatch, and preserve untracked `.superpowers/brainstorm/`, `build/`, and `task-3-report.md`.
- The canonical file bytes are exactly `extension ProjectArchive {\n    public static let currentVersion = 13\n}\n`.
- Do not add SwiftSyntax or another dependency and do not write another partial Swift parser.
- Preserve schema-13 archive, migration, normalization, backup, and public restore behavior already implemented in commits `743c56d..3527cb2`.
- Do not change marketing version `1.5.0`, build `10`, bundle identifiers, signing, entitlements, the 13-locale contract, localized copy, or user-created/imported data.
- Do not archive, export, install, upload, access App Store Connect, submit, publish, merge, or push.
- A complete `swift test --disable-sandbox` run must be wholly green; an isolated rerun does not convert a red complete suite into acceptance.
- Independent review must report no Critical or Important finding before the blocked Pattern Folders Task 2 can be marked complete.

---

### Task 1: Replace schema parsing with a canonical compiled source

**Files:**
- Create: `Sources/KnitNoteCore/Projects/ProjectArchiveSchema.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift:5-9`
- Modify: `AppStore/Verification/release_audit.sh:22,44-87,654-663,700`
- Modify: `Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift:4-95,1900-1910`
- Modify: `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift:19-31`
- Modify if generated output changes: `KnitNote.xcodeproj/project.pbxproj`
- Verify only, normally unchanged: `AppStore/AppStoreSubmission.md`
- Append evidence: `.superpowers/sdd/2026-08-13-pattern-folders/task-2-report.md`
- Update status: `.superpowers/sdd/2026-08-13-pattern-folders/progress.md`

**Interfaces:**
- Consumes: existing public type `ProjectArchive` from `JSONProjectStore.swift` and all existing calls to `ProjectArchive.currentVersion`.
- Produces: `public static let ProjectArchive.currentVersion: Int == 13` from `ProjectArchiveSchema.swift`.
- Produces: test-only environment override `KNITNOTE_PROJECT_ARCHIVE_SCHEMA_SOURCE` pointing to an arbitrary fixture file.
- Produces: `verify_project_archive_schema()` that succeeds only when the schema file bytes equal the canonical payload.

- [ ] **Step 1: Confirm the exact starting boundary**

Run:

```bash
git rev-parse --show-toplevel
git branch --show-current
git rev-parse HEAD
git status --short
```

Expected: the specified linked worktree, branch `feature/knitnote-1.5`, HEAD equal to the plan base recorded in this plan's SDD ledger, and only the three preserved untracked paths.

- [ ] **Step 2: Add the final reviewed parser-bypass regression before changing production**

In `ReleaseAuditLocalizationTests`, add a fixture whose real schema is 12 but whose four-space nested decoy is 13:

```swift
@Test func staticAuditRejectsNestedFourSpaceSchemaDecoyBesideRealSchemaTwelve() throws {
    let result = try runStaticAudit(projectArchiveSchemaSource: """
        public struct ProjectArchive:
                Codable {
                public static let currentVersion = 12
        }

        public enum SchemaDecoy {
            public static let currentVersion = 13
        }
        """)

    #expect(result.status != 0)
    #expect(result.output.contains("project archive schema source is not canonical schema 13"))
}
```

Temporarily retain the existing test-only override so this test exercises the current parser.

- [ ] **Step 3: Run the regression to witness RED**

Run:

```bash
swift test --disable-sandbox --filter staticAuditRejectsNestedFourSpaceSchemaDecoyBesideRealSchemaTwelve
```

Expected: FAIL because the current indentation-based parser exits zero for this decoy.

- [ ] **Step 4: Move the runtime constant to the dedicated source**

Create `ProjectArchiveSchema.swift` with exactly these bytes, including the final newline:

```swift
extension ProjectArchive {
    public static let currentVersion = 13
}
```

Delete only this line from `ProjectArchive` in `JSONProjectStore.swift`:

```swift
public static let currentVersion = 13
```

Leave `minimumSupportedVersion`, `patternLibraryIntroducedVersion`, and `patternFoldersIntroducedVersion` in place.

- [ ] **Step 5: Replace the parser with an exact-byte audit**

Rename the production source variable and test-only override:

```bash
PROJECT_ARCHIVE_SCHEMA_SOURCE="Sources/KnitNoteCore/Projects/ProjectArchiveSchema.swift"
```

```bash
PROJECT_ARCHIVE_SCHEMA_SOURCE="${KNITNOTE_PROJECT_ARCHIVE_SCHEMA_SOURCE:-$PROJECT_ARCHIVE_SCHEMA_SOURCE}"
```

Replace `verify_project_archive_schema()` with:

```bash
verify_project_archive_schema() {
  python3 - "$PROJECT_ARCHIVE_SCHEMA_SOURCE" <<'PY' \
    || fail "project archive schema source is not canonical schema 13"
from pathlib import Path
import sys

expected = (
    b"extension ProjectArchive {\n"
    b"    public static let currentVersion = 13\n"
    b"}\n"
)
try:
    actual = Path(sys.argv[1]).read_bytes()
except OSError:
    raise SystemExit(1)
raise SystemExit(0 if actual == expected else 1)
PY
}
```

Keep the existing call site. Remove the obsolete regular-expression, comment, string, indentation, and brace-scanning code entirely.

- [ ] **Step 6: Rewrite mutation tests around exact file bytes**

Rename the fixture helper to:

```swift
private func runStaticAudit(projectArchiveSchemaSource sourceText: String) throws -> AuditResult
```

Write its temporary fixture as `ProjectArchiveSchema.swift` and pass:

```swift
environment: ["KNITNOTE_PROJECT_ARCHIVE_SCHEMA_SOURCE": source.path]
```

Define the canonical fixture once:

```swift
private let canonicalProjectArchiveSchemaSource = """
extension ProjectArchive {
    public static let currentVersion = 13
}

"""
```

Require canonical success and table-drive exact failures for at least these payloads:

```swift
[
    canonical.replacingOccurrences(of: "= 13", with: "= 12"),
    canonical.replacingOccurrences(of: "= 13", with: "= 14"),
    canonical + "extension ProjectArchive { public static let decoy = 13 }\n",
    "// public static let currentVersion = 13\n" + canonical,
    "let decoy = \"public static let currentVersion = 13\"\n" + canonical,
    "enum Decoy {\n    extension ProjectArchive {\n        public static let currentVersion = 13\n    }\n}\n",
    canonical + canonical,
]
```

Every negative case must assert nonzero status and the exact failure text `project archive schema source is not canonical schema 13`. Keep the Step 2 historical bypass regression and adapt it to the dedicated file helper; it must now pass as a rejection.

- [ ] **Step 7: Bind runtime/config contracts to the new source**

In `ReleaseConfigurationContractTests.releaseCandidateUsesCurrentPatternAndBackupFormats`, replace the substring check with exact assertions:

```swift
let schema = try sourceText(
    "Sources/KnitNoteCore/Projects/ProjectArchiveSchema.swift"
)
let archive = try sourceText(
    "Sources/KnitNoteCore/Projects/JSONProjectStore.swift"
)

#expect(schema == """
extension ProjectArchive {
    public static let currentVersion = 13
}

""")
#expect(!archive.contains("static let currentVersion"))
#expect(ProjectArchive.currentVersion == 13)
```

Retain the backup manifest format-2 assertion. Confirm `AppStoreSubmission.md` still states current project archive schema 13; do not edit historical sections.

- [ ] **Step 8: Run focused GREEN tests**

Run exactly once after the implementation stabilizes:

```bash
swift test --disable-sandbox --filter 'ReleaseConfigurationContractTests|staticAuditRejectsNestedFourSpaceSchemaDecoyBesideRealSchemaTwelve|staticAuditRejectsNoncanonicalProjectArchiveSchemaSource|staticAuditAcceptsCanonicalProjectArchiveSchemaSource'
```

Expected: all selected tests PASS, including every mutation argument.

- [ ] **Step 9: Regenerate project membership twice and prove determinism**

Run:

```bash
xcodegen generate
shasum -a 256 KnitNote.xcodeproj/project.pbxproj
xcodegen generate
shasum -a 256 KnitNote.xcodeproj/project.pbxproj
git diff --check
```

Expected: both hashes match; generated membership includes `ProjectArchiveSchema.swift`; no whitespace errors. Stage `project.pbxproj` only if generation changed it.

- [ ] **Step 10: Run release and schema regression gates**

Run serially, with no duplicate long process:

```bash
bash -n AppStore/Verification/release_audit.sh
bash AppStore/Verification/release_audit.sh --static-only
swift test --disable-sandbox --filter 'PatternLibraryModelTests|PatternLibraryMigrationTests|KnitNoteBackupServiceTests|JSONProjectStoreTests|ReleaseConfigurationContractTests'
swift test --disable-sandbox --filter ReleaseAuditLocalizationTests
```

Expected: Bash syntax PASS, `STATIC RELEASE AUDIT: PASS`, all Task 2 focused tests PASS, and the complete focused ReleaseAudit suite PASS. Capture exact counts, duration, and exit status.

- [ ] **Step 11: Prove the compiled extension is present in every consuming app target**

Run serially with separate Derived Data paths:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteSchemaSource-iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteSchemaSource-macOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Debug -destination 'generic/platform=watchOS Simulator' -derivedDataPath /tmp/KnitNoteSchemaSource-Watch CODE_SIGNING_ALLOWED=NO build
```

Expected: all three end with `** BUILD SUCCEEDED **`. Do not build/archive for device distribution and do not sign.

- [ ] **Step 12: Run the single complete-suite acceptance gate**

Run once and retain its final output:

```bash
swift test --disable-sandbox
```

Expected: exit 0 with every test in every suite passing. If any test fails, record the exact failure and stop; do not claim acceptance based only on an isolated rerun.

- [ ] **Step 13: Commit the atomic implementation**

Inspect scope first:

```bash
git status --short
git diff --check
TASK_BASE="$(git log -1 --format=%H -- docs/superpowers/plans/2026-08-14-project-archive-schema-source.md)"
git diff --stat "$TASK_BASE"
```

Stage only the allowed tracked files:

```bash
git add Sources/KnitNoteCore/Projects/ProjectArchiveSchema.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift AppStore/Verification/release_audit.sh Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift
git add KnitNote.xcodeproj/project.pbxproj
git commit -m "fix: bind archive schema to canonical source"
```

If `project.pbxproj` is byte-identical, omit its `git add`. Do not stage the three preserved untracked paths.

- [ ] **Step 14: Record evidence and request independent review**

Append a new authorized design-cycle section to `.superpowers/sdd/2026-08-13-pattern-folders/task-2-report.md` with:

- design and plan paths;
- RED evidence for the final nested/direct-member bypass;
- exact focused, ReleaseAudit, build, static-audit, and full-suite results;
- XcodeGen hashes;
- commit SHA and final status;
- confirmation that no archive/export/upload/ASC/release action occurred.

Update `.superpowers/sdd/2026-08-13-pattern-folders/progress.md` from BLOCKED to review-pending, not complete. Generate a fresh review package from the task base recorded immediately before dispatch to the new HEAD and request independent spec/quality review. Mark Task 2 complete only if that review reports no Critical or Important finding.
