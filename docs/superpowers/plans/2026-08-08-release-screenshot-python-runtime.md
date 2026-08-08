# Release Screenshot Python Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make KnitNote 1.4.1 screenshot validation deterministic by selecting a local Python interpreter that can actually import Pillow before running screenshot tools.

**Architecture:** Add one checked-in Bash launcher beside the screenshot tools. The launcher probes a fixed list of trusted local Python paths, selects the first interpreter that imports the exact Pillow modules used by the compositor, and executes the requested Python command. Screenshot scripts and Swift screenshot tests route through this launcher, while unrelated release Python tools remain unchanged.

**Tech Stack:** Bash 3.2, Python 3 with Pillow, Swift Testing, Swift Package Manager, Xcode Archive, existing KnitNote release-audit scripts.

## Global Constraints

- Developer tooling only; no Python or Pillow content may enter an App bundle.
- No network access, package download, or mutation of the user's Python installation.
- No production environment override for candidate selection.
- App behavior, data schema, localization catalogs, version `1.4.1`, and build `8` remain unchanged.
- The formal release audit must continue running the complete Swift and screenshot suites.

---

### Task 1: Deterministic Pillow-Capable Python Launcher

**Files:**
- Create: `AppStore/Screenshots/python_runtime.sh`
- Modify: `Tests/KnitNoteCoreTests/StoreScreenshotFixturesTests.swift`

**Interfaces:**
- Produces: `select_screenshot_python candidate... -> stdout path` and executable `python_runtime.sh PYTHON_ARGUMENT...`.
- Selection contract: a candidate is accepted only when it is executable and `from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps` exits successfully.

- [ ] **Step 1: Write the failing launcher selection test**

Add a Swift test that creates two executable fixture scripts. The first exits nonzero for the Pillow probe; the second exits zero for the probe and prints a marker for normal execution. Source `python_runtime.sh`, call `select_screenshot_python` with both paths, and assert that the second path is selected. The test must also assert that running the selected path returns the expected marker.

```swift
@Test func screenshotPythonRuntimeSkipsAnIncompatibleCandidate() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "knitnote-python-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let incompatible = root.appending(path: "incompatible-python")
    let compatible = root.appending(path: "compatible-python")
    try "#!/bin/sh\nexit 1\n".write(to: incompatible, atomically: true, encoding: .utf8)
    try "#!/bin/sh\nif [ \"$1\" = -c ]; then exit 0; fi\nprintf 'compatible:%s\\n' \"$*\"\n"
        .write(to: compatible, atomically: true, encoding: .utf8)
    for path in [incompatible, compatible] {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }
    let launcher = screenshotRepositoryRoot.appending(path: "AppStore/Screenshots/python_runtime.sh")
    let result = try screenshotProcess(
        executable: "/bin/bash",
        arguments: ["-c", "source \"$1\"; selected=$(select_screenshot_python \"$2\" \"$3\"); \"$selected\" payload", "test", launcher.path, incompatible.path, compatible.path]
    )
    #expect(result.status == 0)
    #expect(result.output.contains("compatible:payload"))
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter StoreScreenshotFixturesTests.screenshotPythonRuntimeSkipsAnIncompatibleCandidate
```

Expected: FAIL because `AppStore/Screenshots/python_runtime.sh` does not exist or `select_screenshot_python` is undefined.

- [ ] **Step 3: Implement the minimal launcher**

Create an executable Bash script with:

```bash
#!/bin/bash
set -euo pipefail

probe_screenshot_python() {
  "$1" -c 'from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps' >/dev/null 2>&1
}

select_screenshot_python() {
  local candidate
  for candidate in "$@"; do
    [[ -x "$candidate" ]] || continue
    if probe_screenshot_python "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

screenshot_python_candidates() {
  printf '%s\n' \
    /opt/homebrew/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/3.9/bin/python3 \
    /usr/local/bin/python3 \
    /usr/bin/python3
}

main() {
  local candidates=()
  while IFS= read -r candidate; do candidates+=("$candidate"); done < <(screenshot_python_candidates)
  local selected
  selected="$(select_screenshot_python "${candidates[@]}")" || {
    echo "KnitNote screenshot tools require a local Python 3 runtime with Pillow; see AppStore/Screenshots/requirements.txt" >&2
    exit 69
  }
  exec "$selected" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
```

Set mode `0755`.

- [ ] **Step 4: Run the focused test and launcher probe**

Run:

```bash
swift test --filter StoreScreenshotFixturesTests.screenshotPythonRuntimeSkipsAnIncompatibleCandidate
AppStore/Screenshots/python_runtime.sh -c 'from PIL import Image; print(Image.__version__)'
```

Expected: focused test PASS and launcher prints the installed Pillow version.

- [ ] **Step 5: Commit Task 1**

```bash
git add AppStore/Screenshots/python_runtime.sh Tests/KnitNoteCoreTests/StoreScreenshotFixturesTests.swift
git commit -m "fix: select a compatible screenshot Python runtime"
```

---

### Task 2: Route Every Screenshot Tool Through the Launcher

**Files:**
- Modify: `AppStore/Screenshots/capture.sh`
- Modify: `Tests/KnitNoteCoreTests/StoreScreenshotFixturesTests.swift`
- Modify: `AppStore/Screenshots/README.md`

**Interfaces:**
- Consumes: executable `AppStore/Screenshots/python_runtime.sh` from Task 1.
- Produces: every screenshot Python subprocess uses the checked-in launcher; no screenshot workflow depends on ambient `python3` resolution.

- [ ] **Step 1: Write the failing no-ambient-Python contract test**

Add a Swift source-contract test that reads `capture.sh` and `StoreScreenshotFixturesTests.swift`, then rejects direct screenshot command invocations of ambient `python3`.

```swift
@Test func screenshotWorkflowsUseTheCheckedInPythonRuntime() throws {
    let capture = try screenshotSourceText("AppStore/Screenshots/capture.sh")
    let tests = try screenshotSourceText("Tests/KnitNoteCoreTests/StoreScreenshotFixturesTests.swift")
    #expect(capture.contains("PYTHON_RUNTIME=\"$ROOT/python_runtime.sh\""))
    #expect(!capture.contains("python3 \"$ROOT/"))
    #expect(!tests.contains("\"python3\","))
}
```

- [ ] **Step 2: Run the contract test and verify RED**

Run:

```bash
swift test --filter StoreScreenshotFixturesTests.screenshotWorkflowsUseTheCheckedInPythonRuntime
```

Expected: FAIL because `capture.sh` and the Swift tests still invoke ambient `python3`.

- [ ] **Step 3: Replace ambient screenshot Python invocations**

In `capture.sh`, define:

```bash
PYTHON_RUNTIME="$ROOT/python_runtime.sh"
```

Replace every screenshot-owned `python3` command with `"$PYTHON_RUNTIME"`. In `StoreScreenshotFixturesTests.swift`, replace each `/usr/bin/env python3 ...` invocation with the absolute checked-in launcher path followed by the existing Python arguments. Preserve every existing assertion and exit-code expectation.

Update `README.md` to state that `python_runtime.sh` selects an installed compatible interpreter offline and that `requirements.txt` remains the dependency declaration.

- [ ] **Step 4: Run focused screenshot tests under the production trusted PATH**

Run:

```bash
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin swift test --filter StoreScreenshotFixturesTests
```

Expected: the entire `StoreScreenshotFixturesTests` suite passes, including manifest validation, contact-sheet composition, and Korean glyph rendering.

- [ ] **Step 5: Commit Task 2**

```bash
git add AppStore/Screenshots/capture.sh AppStore/Screenshots/README.md Tests/KnitNoteCoreTests/StoreScreenshotFixturesTests.swift
git commit -m "fix: isolate screenshot tools from ambient Python"
```

---

### Task 3: Verify and Rebuild the Exact 1.4.1 Candidate

**Files:**
- No source changes expected.
- Generate outside repository: `/tmp/KnitNoteRelease-1.4.1-Build8-<short-sha>/`

**Interfaces:**
- Consumes: Tasks 1 and 2 commits.
- Produces: exact-commit signed iOS/Watch and macOS archives plus `provenance.json`, accepted by the formal release audit.

- [ ] **Step 1: Verify source integrity and focused tests**

Run:

```bash
git diff --check
git status --short
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin swift test --filter StoreScreenshotFixturesTests
```

Expected: no diff errors, clean worktree, focused suite PASS.

- [ ] **Step 2: Run the complete source verification**

Run:

```bash
swift test --disable-sandbox
AppStore/Verification/release_audit.sh --static-only
```

Expected: `1348 tests in 122 suites passed`, metadata PASS, commercial offline PASS, and `STATIC RELEASE AUDIT: PASS`.

- [ ] **Step 3: Create the signed exact-commit candidate**

Compute the current short SHA and run:

```bash
SHORT_SHA="$(git rev-parse --short=7 HEAD)"
AppStore/Verification/create_release_candidate.sh "/tmp/KnitNoteRelease-1.4.1-Build8-$SHORT_SHA"
```

Expected: both archives succeed, the formal suite passes, `RELEASE AUDIT: PASS` appears, and the script publishes the final candidate directory.

- [ ] **Step 4: Independently verify candidate identity**

Check `provenance.json`, archive bundle IDs, version `1.4.1`, build `8`, embedded exact source revision, twelve localization directories, privacy manifests, and signing entitlements. Re-run:

```bash
AppStore/Verification/release_audit.sh \
  --archives "/tmp/KnitNoteRelease-1.4.1-Build8-$SHORT_SHA" \
  --expected-commit "$(git rev-parse HEAD)" \
  --provenance "/tmp/KnitNoteRelease-1.4.1-Build8-$SHORT_SHA/provenance.json"
```

Expected: `RELEASE AUDIT: PASS`.

- [ ] **Step 5: Stop before distribution**

Report the exact SHA, version/build, archive path, and remaining physical/App Store gates. Do not upload, submit, change pricing, select a build, or alter App Store Connect without separate explicit approval.

