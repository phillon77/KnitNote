# Knitting Calculator 1.0.1 Multilingual Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a testable Knitting Calculator `1.0.1 (3)` candidate with complete, natural in-app and App Store metadata localization for the same 13 languages as KnitNote, without changing calculator behavior, layout, privacy, or monetization.

**Architecture:** Keep Apple's String Catalog and system App Language as the only runtime localization mechanism. Add one repository-owned localization contract checker that enforces the exact locale set, completeness, translation state, placeholder integrity, and permitted locale-invariant values. Keep App Store metadata validation separate from app-binary validation because App Store locale identifiers differ from Xcode locale identifiers. Extend the existing release audit so the generated project and archived app must prove the exact `1.0.1 (3)` identity and all 13 localized resources.

**Tech Stack:** Swift 6, SwiftUI, XCTest, Xcode String Catalogs, XcodeGen, Python 3 unittest, Bash, `jq`, `xcodebuild`, `simctl`, `devicectl`.

## File Responsibility Map

- `AppStore/Verification/knitting_calculator_localization_check.py`: exact app-locale, translation-state, invariant-value, and placeholder contract.
- `AppStore/Verification/metadata_check.py`: exact App Store locale-package set and field/length/claim contract.
- `AppStore/Verification/knitting_calculator_release_audit.sh`: project identity, privacy/dependency boundaries, and compiled archive/IPA resource contract.
- `KnittingCalculator/Localization/Localizable.xcstrings`: all app UI, validation, share, help, promotion, and accessibility text.
- `KnittingCalculator/Localization/InfoPlist.xcstrings`: localized display name and bundle-facing text.
- `KnittingCalculator/Model/CalculatorLocalization.swift`: locale-to-bundle routing only; change it only when a failing routing test proves necessary.
- `KnittingCalculator/project.yml`: XcodeGen source of truth for version, build, target membership, and resources.
- `KnittingCalculator.xcodeproj/project.pbxproj`: generated project; never hand-edit.
- `AppStore/KnittingCalculator/Metadata/*.md`: repository-owned localized App Store copy, separate from live App Store Connect state.

## Global Constraints

- Work only in `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/knitting-calculator-independent-project`.
- Preserve the current branch and never stage these pre-existing untracked paths: `.superpowers/brainstorm/`, `AppStore/KnittingCalculator/Screenshots/Generated/en/contact-sheet.png`, `AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/contact-sheet.png`, `AppStore/KnittingCalculator/Screenshots/Raw/`, `AppStore/KnittingCalculator/Screenshots/__pycache__/`, and `AppStore/Verification/__pycache__/`.
- Treat `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/knitnote-1.5.1-build11/AppStore/Localization/KnittingTerminology.csv` as a read-only terminology reference. Do not create a runtime or build dependency on another worktree.
- The exact app locale set is `en`, `zh-Hant`, `zh-Hans`, `de`, `fr`, `ja`, `ko`, `nl`, `nb`, `sv`, `fi`, `da`, and `el`.
- The exact repository App Store metadata filenames are `en-US.md`, `zh-Hant.md`, `zh-Hans.md`, `de-DE.md`, `fr-FR.md`, `ja-JP.md`, `ko-KR.md`, `nl-NL.md`, `nb-NO.md`, `sv-SE.md`, `fi-FI.md`, `da-DK.md`, and `el-GR.md`, matching the current KnitNote packages. Before any remote App Store Connect write, read back Apple's current locale list and confirm that App Info and App Store Version localizations use the same set.
- Do not add an in-app language picker, new dependency, calculator, screen, layout rule, screenshot set, analytics, tracking, advertising, account, purchase, or network behavior.
- Do not translate `KnitNote`, URLs, numeric format placeholders, or user-entered values. Locale-invariant abbreviations may remain identical only when explicitly allowlisted by the contract checker.
- Use TDD for every source, validator, or audit change: add a failing test, run it and confirm the intended failure, make the smallest implementation change, then rerun the focused test.
- Never claim that automated catalog checks prove visual quality. English, Traditional Chinese, Simplified Chinese, German, and Japanese require physical iPhone and iPad acceptance.
- Do not upload, attach, submit, release, publish, merge, or push during this plan. Those are later, separately authorized release actions.

---

### Task 1: Define one exact 13-locale localization contract

**Files:**
- Create: `AppStore/Verification/knitting_calculator_localization_check.py`
- Create: `AppStore/Verification/knitting_calculator_localization_check_test.py`

**Interfaces:**
- Produces: `SUPPORTED_APP_LOCALES: tuple[str, ...]`.
- Produces: `validate_catalog(path: Path) -> list[str]`.
- Produces: `validate_catalog_pair(localizable: Path, info_plist: Path) -> list[str]`.
- Produces CLI: `python3 AppStore/Verification/knitting_calculator_localization_check.py LOCALIZABLE INFO_PLIST`, returning `0` only when both catalogs pass.

- [ ] **Step 1: Write failing contract tests**

Create fixtures for small String Catalogs and assert that validation rejects:

- a missing or extra locale;
- a missing localization for one key;
- an empty value or any state other than `translated`;
- a placeholder mismatch, including changed positional specifiers;
- an untranslated value copied from English unless its key/value pair is explicitly locale-invariant;
- a catalog whose source language is not English;
- different locale sets between `Localizable.xcstrings` and `InfoPlist.xcstrings`.

Also add a valid fixture containing a nested variation so the checker handles String Catalog variation structures rather than only flat `stringUnit` objects.

Use explicit assertions such as:

```python
def test_rejects_missing_locale(self) -> None:
    catalog = self.catalog(locales=("en", "zh-Hant"))
    errors = self.validate(catalog)
    self.assertTrue(any("missing locales" in error and "zh-Hans" in error for error in errors), errors)

def test_rejects_placeholder_change(self) -> None:
    catalog = self.catalog(
        english="Increase %lld stitch every %lld rows",
        german="%lld Maschen zunehmen",
    )
    errors = self.validate(catalog)
    self.assertTrue(any("placeholder mismatch" in error for error in errors), errors)
```

- [ ] **Step 2: Run the focused test and confirm RED**

```bash
python3 -m unittest AppStore/Verification/knitting_calculator_localization_check_test.py
```

Expected: import or behavior failures because the checker does not exist yet.

- [ ] **Step 3: Implement the smallest checker**

- Parse both catalogs as JSON.
- Keep `SUPPORTED_APP_LOCALES` in one Python constant.
- Recursively collect every `stringUnit` value and state.
- Compare printf/interpolation placeholder sequences exactly with English.
- Require the exact locale set for every non-empty key.
- Allow identical values only for reviewed invariants such as `KnitNote`, URLs, and unit symbols; keep the allowlist explicit and narrow.
- Print actionable `catalog : key : locale : reason` failures and return nonzero on any defect.

Start from these public contracts so later tasks do not invent a second locale list:

```python
SUPPORTED_APP_LOCALES = (
    "en", "zh-Hant", "zh-Hans", "de", "fr", "ja", "ko",
    "nl", "nb", "sv", "fi", "da", "el",
)
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:[-+0 #]*\d*(?:\.\d+)?)?(?:hh|h|ll|l|L|z|t|j)?[@diuoxXfFeEgGaAcCsSp]")

def string_units(node: object) -> list[dict[str, object]]:
    if isinstance(node, dict):
        units = [node["stringUnit"]] if isinstance(node.get("stringUnit"), dict) else []
        return units + [unit for value in node.values() for unit in string_units(value)]
    if isinstance(node, list):
        return [unit for value in node for unit in string_units(value)]
    return []

def validate_catalog(path: Path) -> list[str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    errors: list[str] = []
    if payload.get("sourceLanguage") != "en":
        errors.append(f"{path}: sourceLanguage: expected en")
    expected = set(SUPPORTED_APP_LOCALES)
    for key, entry in payload.get("strings", {}).items():
        localizations = entry.get("localizations", {})
        actual = set(localizations)
        if actual != expected:
            errors.append(f"{path}: {key}: locales: expected {sorted(expected)}, got {sorted(actual)}")
            continue
        english_units = string_units(localizations["en"])
        english_placeholders = [PLACEHOLDER.findall(str(unit.get("value", ""))) for unit in english_units]
        for locale in SUPPORTED_APP_LOCALES:
            units = string_units(localizations[locale])
            if any(unit.get("state") != "translated" or not unit.get("value") for unit in units):
                errors.append(f"{path}: {key}: {locale}: incomplete translation")
            placeholders = [PLACEHOLDER.findall(str(unit.get("value", ""))) for unit in units]
            if placeholders != english_placeholders:
                errors.append(f"{path}: {key}: {locale}: placeholder mismatch")
    return errors

def validate_catalog_pair(localizable: Path, info_plist: Path) -> list[str]:
    return validate_catalog(localizable) + validate_catalog(info_plist)
```

Add the explicit locale-invariant allowlist and copied-English rejection around this core, covered by the tests above; do not broaden the allowlist merely to make production data pass.

- [ ] **Step 4: Run focused tests and confirm GREEN**

```bash
python3 -m unittest AppStore/Verification/knitting_calculator_localization_check_test.py
```

Expected: all checker tests pass. Running the checker against the production catalogs should still report the expected missing locales until Task 2 populates them.

- [ ] **Step 5: Commit**

```bash
git add AppStore/Verification/knitting_calculator_localization_check.py \
  AppStore/Verification/knitting_calculator_localization_check_test.py
git commit -m "test: enforce calculator localization contract"
```

---

### Task 2: Localize the complete app and bundle-facing text

**Files:**
- Create: `KnittingCalculatorTests/CalculatorLocalizationTests.swift`
- Modify: `KnittingCalculatorTests/CalculatorShareTextTests.swift`
- Modify: `KnittingCalculatorTests/LocalizedNumberCodecTests.swift`
- Modify: `KnittingCalculator/Localization/Localizable.xcstrings`
- Modify: `KnittingCalculator/Localization/InfoPlist.xcstrings`
- Regenerate: `KnittingCalculator.xcodeproj/project.pbxproj`
- Modify only if a focused test proves necessary: `KnittingCalculator/Model/CalculatorLocalization.swift`

**Interfaces:**
- Consumes: `SUPPORTED_APP_LOCALES` and the catalog CLI from Task 1.
- Consumes: `CalculatorLocalization.string(_:locale:)` and `CalculatorLocalization.formatted(_:_:locale:)`.
- Produces: both String Catalogs with the exact 13-locale contract.
- Produces: runtime test matrix `CalculatorLocalizationTests.supportedLocales` matching Task 1 exactly.

- [ ] **Step 1: Add failing runtime behavior tests**

Add table-driven tests that prove:

- a representative home, gauge, adjustment, validation, accessibility, privacy, and KnitNote promotion key resolves in every supported locale;
- `zh_CN` resolves through `zh-Hans`, while `zh_TW`, `zh_HK`, and `zh_MO` resolve through `zh-Hant`;
- share attribution and adjustment instructions are localized for all 13 languages while calculator and KnitNote URLs remain unchanged;
- decimal-comma locales accept both `10,5` and `10.5` and format with a comma;
- decimal-point locales continue to accept both separators and format with a point;
- user-provided numbers and saved unit choices do not change when only the locale changes.

Regenerate the project with `xcodegen generate --spec KnittingCalculator/project.yml --project . --project-root .` so the new test file is in the test target before the RED run. Inspect the generated diff and reject unrelated project changes.

Use table-driven XCTest code, including these exact routing cases:

```swift
final class CalculatorLocalizationTests: XCTestCase {
    let supportedLocales = [
        "en", "zh-Hant", "zh-Hans", "de", "fr", "ja", "ko",
        "nl", "nb", "sv", "fi", "da", "el",
    ]

    func testRepresentativeKeysResolveForEverySupportedLocale() {
        let keys = [
            "app.title", "calculator.gauge.title", "calculator.adjustment.current",
            "calculator.adjustment.validation.positiveInteger",
            "calculator.settings.privacy", "calculator.promotion.action",
        ]
        for identifier in supportedLocales {
            for key in keys {
                let value = CalculatorLocalization.string(key, locale: Locale(identifier: identifier))
                XCTAssertNotEqual(value, key, "Missing \(identifier) localization for \(key)")
            }
        }
    }

    func testChineseRegionRouting() {
        XCTAssertEqual(
            CalculatorLocalization.string("app.title", locale: Locale(identifier: "zh_CN")),
            CalculatorLocalization.string("app.title", locale: Locale(identifier: "zh-Hans"))
        )
        for identifier in ["zh_TW", "zh_HK", "zh_MO"] {
            XCTAssertEqual(
                CalculatorLocalization.string("app.title", locale: Locale(identifier: identifier)),
                CalculatorLocalization.string("app.title", locale: Locale(identifier: "zh-Hant"))
            )
        }
    }
}
```

- [ ] **Step 2: Confirm RED before translating**

```bash
xcodebuild test -project KnittingCalculator.xcodeproj -scheme KnittingCalculator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:KnittingCalculatorTests/CalculatorLocalizationTests \
  -only-testing:KnittingCalculatorTests/CalculatorShareTextTests \
  -only-testing:KnittingCalculatorTests/LocalizedNumberCodecTests
```

Expected: the 11 new locales resolve to keys or English and the new share assertions fail.

- [ ] **Step 3: Populate both String Catalogs**

- Preserve the current English and Traditional Chinese meanings and all existing keys.
- Add `zh-Hans`, `de`, `fr`, `ja`, `ko`, `nl`, `nb`, `sv`, `fi`, `da`, and `el` translations to every entry.
- Use the reviewed KnitNote terminology for stitches, rows, gauge, increases, decreases, edge stitches, repeats, knitting, and crochet, adapted naturally to calculator sentences.
- Keep every placeholder byte-for-byte compatible with English.
- Localize the display name naturally while keeping it recognizably the same calculator product.
- Mark every finished entry `translated`; do not leave stale, needs-review, or empty entries.

Every localization entry must use this String Catalog shape; values and placeholders come from the reviewed terminology and the English source meaning:

```json
"de": {
  "stringUnit": {
    "state": "translated",
    "value": "Maschenprobe berechnen"
  }
}
```

- [ ] **Step 4: Run catalog and runtime checks**

```bash
python3 AppStore/Verification/knitting_calculator_localization_check.py \
  KnittingCalculator/Localization/Localizable.xcstrings \
  KnittingCalculator/Localization/InfoPlist.xcstrings
xcodebuild test -project KnittingCalculator.xcodeproj -scheme KnittingCalculator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:KnittingCalculatorTests/CalculatorLocalizationTests \
  -only-testing:KnittingCalculatorTests/CalculatorShareTextTests \
  -only-testing:KnittingCalculatorTests/LocalizedNumberCodecTests
```

Expected: localization contract and focused tests pass. If `CalculatorLocalization.swift` needs a locale-routing fix, first preserve the failing routing test, then make only that fix and rerun these commands.

- [ ] **Step 5: Commit**

```bash
git add KnittingCalculator/Localization/Localizable.xcstrings \
  KnittingCalculator/Localization/InfoPlist.xcstrings \
  KnittingCalculator.xcodeproj/project.pbxproj \
  KnittingCalculatorTests/CalculatorLocalizationTests.swift \
  KnittingCalculatorTests/CalculatorShareTextTests.swift \
  KnittingCalculatorTests/LocalizedNumberCodecTests.swift
git commit -m "feat: localize calculator in thirteen languages"
```

Before committing, inspect the staged paths. If and only if the focused routing test required a production fix made during this task, explicitly add `KnittingCalculator/Model/CalculatorLocalization.swift` before committing.

---

### Task 3: Create and validate all 13 App Store metadata packages

**Files:**
- Modify: `AppStore/Verification/metadata_check.py`
- Modify: `AppStore/Verification/metadata_check_test.py`
- Modify: `AppStore/KnittingCalculator/Metadata/en-US.md`
- Modify: `AppStore/KnittingCalculator/Metadata/zh-Hant.md`
- Create: `AppStore/KnittingCalculator/Metadata/zh-Hans.md`
- Create: `AppStore/KnittingCalculator/Metadata/de-DE.md`
- Create: `AppStore/KnittingCalculator/Metadata/fr-FR.md`
- Create: `AppStore/KnittingCalculator/Metadata/ja-JP.md`
- Create: `AppStore/KnittingCalculator/Metadata/ko-KR.md`
- Create: `AppStore/KnittingCalculator/Metadata/nl-NL.md`
- Create: `AppStore/KnittingCalculator/Metadata/nb-NO.md`
- Create: `AppStore/KnittingCalculator/Metadata/sv-SE.md`
- Create: `AppStore/KnittingCalculator/Metadata/fi-FI.md`
- Create: `AppStore/KnittingCalculator/Metadata/da-DK.md`
- Create: `AppStore/KnittingCalculator/Metadata/el-GR.md`

**Interfaces:**
- Produces: `CALCULATOR_METADATA_FILENAMES: tuple[str, ...]` with the exact 13 storefront filenames.
- Consumes: existing `parse(path: Path) -> dict[str, str]` and `validate(path: Path) -> list[str]`.
- Produces: `validate_root(root: Path) -> list[str]`, used by the CLI and the release audit.

- [ ] **Step 1: Add failing metadata-set tests**

Extend the validator tests to require:

- exactly the 13 canonical calculator metadata filenames, rejecting missing and extra files;
- the same structured required fields for every locale;
- `What's New` describing only the 1.0.1 language expansion;
- App Store name/subtitle/promotional-text/keyword limits per locale;
- HTTPS support and privacy URLs, exact Apple ID, and exact copyright;
- no unsupported claims, keyword duplicates, or repetition of localized name/subtitle/category terms;
- UTF-8 byte limits for keywords.

Add explicit set-boundary tests:

```python
def test_calculator_metadata_requires_exact_locale_set(self) -> None:
    module = metadata_check_module()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory) / "AppStore/KnittingCalculator/Metadata"
        root.mkdir(parents=True)
        (root / "en-US.md").write_text(self.metadata(), encoding="utf-8")
        errors = module.validate_root(root)
    self.assertTrue(any("missing metadata locales" in error for error in errors), errors)

def test_calculator_metadata_rejects_extra_locale(self) -> None:
    module = metadata_check_module()
    with tempfile.TemporaryDirectory() as directory:
        root = self.write_complete_calculator_metadata(Path(directory))
        (root / "it-IT.md").write_text(self.metadata(), encoding="utf-8")
        errors = module.validate_root(root)
    self.assertTrue(any("unexpected metadata locales" in error for error in errors), errors)
```

- [ ] **Step 2: Confirm RED**

```bash
python3 -m unittest AppStore/Verification/metadata_check_test.py
python3 AppStore/Verification/metadata_check.py AppStore/KnittingCalculator/Metadata
```

Expected: exact-set validation fails because only English and Traditional Chinese exist.

- [ ] **Step 3: Implement exact-set validation and natural metadata**

- Update `metadata_check.py` to enumerate and compare the calculator directory against the exact filename set.
- Update English and Traditional Chinese `What's New` for 1.0.1.
- Create the other 11 localized files using the current English and Traditional Chinese claims as the semantic source.
- Keep KnitNote clearly described as a separate app.
- Reuse the existing screenshots; do not modify the screenshot manifest or generated image files.
- Review each locale's name, subtitle, and keywords independently rather than translating keywords word-for-word.

Use one canonical filename constant and root validator:

```python
CALCULATOR_METADATA_FILENAMES = (
    "en-US.md", "zh-Hant.md", "zh-Hans.md", "de-DE.md", "fr-FR.md",
    "ja-JP.md", "ko-KR.md", "nl-NL.md", "nb-NO.md", "sv-SE.md",
    "fi-FI.md", "da-DK.md", "el-GR.md",
)

def validate_root(root: Path) -> list[str]:
    expected = set(CALCULATOR_METADATA_FILENAMES)
    actual = {path.name for path in root.glob("*.md")}
    errors: list[str] = []
    if missing := sorted(expected - actual):
        errors.append(f"{root}: missing metadata locales: {', '.join(missing)}")
    if extra := sorted(actual - expected):
        errors.append(f"{root}: unexpected metadata locales: {', '.join(extra)}")
    errors.extend(error for name in sorted(expected & actual) for error in validate(root / name))
    return errors
```

- [ ] **Step 4: Confirm GREEN**

```bash
python3 -m unittest AppStore/Verification/metadata_check_test.py
python3 AppStore/Verification/metadata_check.py AppStore/KnittingCalculator/Metadata
```

Expected: all metadata tests pass and the validator prints `METADATA CHECK: PASS`.

- [ ] **Step 5: Commit**

```bash
git add AppStore/Verification/metadata_check.py \
  AppStore/Verification/metadata_check_test.py \
  AppStore/KnittingCalculator/Metadata
git commit -m "docs: localize calculator store metadata"
```

---

### Task 4: Advance the independent project to 1.0.1 Build 3

**Files:**
- Modify: `AppStore/Verification/knitting_calculator_release_audit_test.py`
- Modify: `AppStore/Verification/knitting_calculator_release_audit.sh`
- Modify: `KnittingCalculator/project.yml`
- Regenerate: `KnittingCalculator.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: the exact 13 app locales from Task 1.
- Produces: XcodeGen target identity `com.phillon.KnittingCalculator` `1.0.1 (3)`.
- Produces: generated `knownRegions` containing the exact supported app locales plus Xcode's required `Base` region.

- [ ] **Step 1: Add failing identity and generated-project tests**

Update release-audit fixtures and expectations to require:

- marketing version `1.0.1`;
- build number `3`;
- all 13 known regions/localized build products;
- rejection of either the old `1.0.0 (2)` identity or a partially updated Xcode project.

Change the existing `write_archive` and `write_ipa` default arguments from `version="1.0.0", build="2"` to `version="1.0.1", build="3"`, then add explicit old-candidate rejection:

```python
def test_rejects_build_two_archive(self) -> None:
    archive = self.fixture.write_archive(version="1.0.0", build="2")
    result = self.fixture.run("--archive", str(archive))
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("archive marketing version is not 1.0.1", result.stderr)
```

- [ ] **Step 2: Confirm RED**

```bash
python3 -m unittest AppStore/Verification/knitting_calculator_release_audit_test.py
```

Expected: tests fail against the current `1.0.0 (2)` XcodeGen source and generated project.

- [ ] **Step 3: Update the source of truth and regenerate**

- Set `MARKETING_VERSION: 1.0.1` and `CURRENT_PROJECT_VERSION: 3` in `KnittingCalculator/project.yml`.
- Set the release audit's expected identity to version `1.0.1`, build `3`.
- Run `xcodegen generate --spec KnittingCalculator/project.yml --project . --project-root .`.
- Inspect the generated diff to ensure it contains only expected identity, localization-region, and test-file membership changes.
- Do not hand-edit generated UUIDs or project structure.

- [ ] **Step 4: Confirm GREEN**

```bash
python3 -m unittest AppStore/Verification/knitting_calculator_release_audit_test.py
xcodebuild -list -json -project KnittingCalculator.xcodeproj
plutil -lint KnittingCalculator.xcodeproj/project.pbxproj
```

Expected: audit behavior tests pass, the project contains only the calculator app and tests, and the generated project parses.

- [ ] **Step 5: Commit**

```bash
git add KnittingCalculator/project.yml \
  KnittingCalculator.xcodeproj/project.pbxproj \
  AppStore/Verification/knitting_calculator_release_audit_test.py \
  AppStore/Verification/knitting_calculator_release_audit.sh
git commit -m "chore: set calculator version 1.0.1 build 3"
```

---

### Task 5: Require all 13 localized resources in release artifacts

**Files:**
- Modify: `AppStore/Verification/knitting_calculator_release_audit_test.py`
- Modify: `AppStore/Verification/knitting_calculator_release_audit.sh`

**Interfaces:**
- Consumes: Task 1 localization-check CLI and Task 3 `metadata_check.py` CLI.
- Produces: shell constant `EXPECTED_APP_LOCALES=(en zh-Hant zh-Hans de fr ja ko nl nb sv fi da el)`.
- Produces: `verify_app_bundle APP_PATH`, requiring both compiled strings files in every locale directory.

- [ ] **Step 1: Add failing archive and IPA boundary tests**

Update the fixture app-bundle writer to create all 13 `.lproj` directories, then add tests proving the audit rejects:

- any one missing `Localizable.strings`;
- any one missing `InfoPlist.strings`;
- an unexpected locale substituted for a required locale;
- version/build mismatches in both `.xcarchive` and `.ipa` paths;
- a release artifact whose catalog checks pass in source but whose compiled resources are incomplete.
- a source catalog contract failure propagated through `--static-only`.

Use one helper so archive and IPA tests exercise the same missing-resource boundary:

```python
def remove_localized_resource(self, app: Path, locale: str, filename: str) -> None:
    (app / f"{locale}.lproj" / filename).unlink()

def test_archive_rejects_missing_german_info_plist_strings(self) -> None:
    archive = self.fixture.write_archive()
    app = archive / "Products/Applications/KnittingCalculator.app"
    self.remove_localized_resource(app, "de", "InfoPlist.strings")
    result = self.fixture.run("--archive", str(archive))
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("de.lproj/InfoPlist.strings", result.stderr)
```

- [ ] **Step 2: Confirm RED**

```bash
python3 -m unittest AppStore/Verification/knitting_calculator_release_audit_test.py
```

Expected: new resource-boundary cases fail because the audit currently checks only `en` and `zh-Hant`.

- [ ] **Step 3: Extend the release audit**

- Keep the locale list in one shell array and use it for archive and IPA resource verification.
- Invoke the dedicated localization checker and the 13-file metadata validator during `--static-only`.
- Update the release-audit fixture to copy the dedicated localization checker, metadata validator, and calculator metadata directory so its static fixture is self-contained.
- Keep privacy, signing, dependency, App Store ID, and full-screen project-isolation checks unchanged.

Replace the two-locale loop with one shared array:

```bash
EXPECTED_APP_LOCALES=(en zh-Hant zh-Hans de fr ja ko nl nb sv fi da el)

for locale in "${EXPECTED_APP_LOCALES[@]}"; do
  require_file "$resources/$locale.lproj/Localizable.strings"
  require_file "$resources/$locale.lproj/InfoPlist.strings"
done
```

- [ ] **Step 4: Confirm GREEN**

```bash
python3 -m unittest AppStore/Verification/knitting_calculator_release_audit_test.py
AppStore/Verification/knitting_calculator_release_audit.sh --static-only
```

Expected: all audit behavior tests and the real static audit pass.

- [ ] **Step 5: Commit**

```bash
git add AppStore/Verification/knitting_calculator_release_audit_test.py \
  AppStore/Verification/knitting_calculator_release_audit.sh
git commit -m "test: audit thirteen calculator locales"
```

---

### Task 6: Run the complete automated candidate matrix

**Files:**
- No production file changes expected.

**Interfaces:**
- Consumes: all source, metadata, generated-project, and audit contracts from Tasks 1–5.
- Produces: one recorded Git SHA and one audited `1.0.1 (3)` `.xcarchive` path.

- [ ] **Step 1: Verify repository scope before expensive builds**

```bash
git status --short
git diff --check
python3 -m unittest discover AppStore/Verification -p '*_test.py'
swift test --package-path Packages/KnittingCalculatorCore
AppStore/Verification/knitting_calculator_release_audit.sh --static-only
```

Expected: only the known pre-existing untracked paths remain; every automated validator and core test passes.

- [ ] **Step 2: Run the full iPhone and iPad test/build matrix**

```bash
xcodebuild test -project KnittingCalculator.xcodeproj -scheme KnittingCalculator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild test -project KnittingCalculator.xcodeproj -scheme KnittingCalculator \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
xcodebuild build -project KnittingCalculator.xcodeproj -scheme KnittingCalculator \
  -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild build -project KnittingCalculator.xcodeproj -scheme KnittingCalculator \
  -configuration Release \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
xcodebuild build -project KnittingCalculator.xcodeproj -scheme KnittingCalculator \
  -configuration Release -destination 'generic/platform=iOS'
```

Resolve the two simulator names with `xcrun simctl list devices available` before running the matrix. If either listed name is unavailable, substitute the exact current iPhone and iPad simulator names and record them with the result; do not silently skip a device class.

Also launch the built app in one iPhone and one iPad simulator for each of the 13 locales, capture a home-screen diagnostic image, and inspect it for launch coverage. These simulator images are temporary evidence under `/tmp`; do not add them to the App Store screenshot package.

Expected: all tests and builds pass; every locale launches. Simulator launch coverage does not count as physical visual acceptance.

- [ ] **Step 3: Create and audit one immutable distribution candidate**

After confirming signing availability, record `git rev-parse HEAD`, then archive without changing source:

```bash
xcodebuild archive -project KnittingCalculator.xcodeproj -scheme KnittingCalculator \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /tmp/KnittingCalculator-1.0.1-Build3.xcarchive
AppStore/Verification/knitting_calculator_release_audit.sh \
  --archive /tmp/KnittingCalculator-1.0.1-Build3.xcarchive
```

Expected: the audited archive is exactly `com.phillon.KnittingCalculator` `1.0.1 (3)`, signed for App Store distribution, and contains both localized strings files for all 13 locales. Stop if the SHA, archive identity, or signing evidence disagrees.

---

### Task 7: Complete physical iPhone and iPad language acceptance

**Files:**
- No source changes. Record observations outside the candidate commit until the acceptance matrix is complete.

**Interfaces:**
- Consumes: the exact Git SHA and candidate identity produced by Task 6.
- Produces: scoped physical acceptance results for five languages on one iPhone and one iPad.

- [ ] **Step 1: Install the exact accepted candidate**

- Install one candidate derived from the recorded SHA on the user's iPhone and unlocked iPad.
- Read back the installed bundle identifier, version, and build before testing.
- Do not substitute a later build or a simulator result.

- [ ] **Step 2: Test the five agreed sample languages on both devices**

For English, Traditional Chinese, Simplified Chinese, German, and Japanese, verify on both iPhone and iPad:

1. true full-screen launch with no half-screen sheet/window defect;
2. home and settings without clipping, overlap, or untranslated keys;
3. gauge calculation and result explanation;
4. single-row and across-row increase/decrease flows;
5. validation/error messages;
6. copy/share content;
7. KnitNote link;
8. rotation, background/foreground, and reopen persistence.

Change the language through the iOS/iPadOS App Language setting only. Do not add or simulate an in-app language selector.

- [ ] **Step 3: Hold the release boundary**

- Any half-screen layout, clipping, incorrect terminology, fallback key, placeholder defect, calculation change, or persistence loss is a blocker and returns to the smallest relevant TDD task.
- Passing this matrix accepts only the exact SHA and installed `1.0.1 (3)` candidate on the tested iPhone/iPad targets.
- After acceptance, report the remaining release steps and request separate authorization before any App Store Connect metadata write, build upload, attachment, or submission.

---

## Completion Criteria

Implementation is complete only when:

- both String Catalogs contain the exact 13 locales with no incomplete entry or placeholder mismatch;
- all automated localization, metadata, audit, core, app, iPhone, and iPad checks pass;
- the generated project and audited archive are exactly version `1.0.1`, build `3`;
- all 13 App Store metadata source files pass repository validation;
- the exact candidate passes the agreed five-language physical matrix on both iPhone and iPad;
- no App Store upload, submission, or publication claim is made without a later explicit authorization and live read-back.

## Apple References

- [Localize app information](https://developer.apple.com/help/app-store-connect/manage-app-information/localize-app-information/)
- [App Store Version Localizations](https://developer.apple.com/documentation/appstoreconnectapi/app-store-version-localizations)
- [Create an App Store Version Localization](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-appstoreversionlocalizations)
