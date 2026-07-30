# KnitNote Pricing Release Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent KnitNote from being re-listed with a paid App download or stale future App price schedule, while preserving the approved Lifetime Unlock price.

**Architecture:** Store the commercial contract once in machine-readable JSON. A dependency-free Python validator enforces the offline contract and queries Apple's public lookup endpoint only in explicit live mode. The existing release audit invokes offline validation, while a separate evidence checklist gates App Store Connect availability, StoreKit acceptance, and advertising.

**Tech Stack:** JSON, Python 3 standard library, `unittest`, Bash, Markdown, Apple iTunes Lookup API.

## Global Constraints

- App download is free in all 175 storefronts.
- Future App price changes are empty.
- Trial duration is seven days.
- Lifetime Unlock product ID is `com.phillon.KnitNote.lifetimeUnlock`.
- Lifetime Unlock is a non-consumable.
- Lifetime Unlock is US$4.99 in the United States and NT$150 in Taiwan.
- KnitNote has no subscription.
- Existing verified permanent entitlements remain permanent.
- App Store Connect writes require separate explicit authorization.
- The guard performs no pricing, availability, advertising, Git push, submission, or release mutation.
- Live public lookup proves only public App download price propagation; it does not prove In-App Purchase price or restore behavior.

---

## File Map

- Create `AppStore/CommercialConfiguration.json`: single machine-readable commercial contract.
- Create `AppStore/Verification/commercial_release_check.py`: offline configuration validation and explicit live public-storefront verification.
- Create `AppStore/Verification/commercial_release_check_test.py`: dependency-free behavioral tests using temporary files and injected lookup payloads.
- Create `AppStore/Verification/CommercialReleaseChecklist.md`: mandatory evidence gates for every release or re-listing.
- Modify `AppStore/KnitNotePricing.md`: current human-readable contract plus clearly non-executable historical appendix.
- Modify `AppStore/AppStoreSubmission.md`: replace stale pending commercial state with the verified 2026-07-31 public state and point to the mandatory checklist.
- Modify `AppStore/Verification/release_audit.sh`: run the offline commercial guard.

### Task 1: Canonical Commercial Contract and Offline Validator

**Files:**
- Create: `AppStore/CommercialConfiguration.json`
- Create: `AppStore/Verification/commercial_release_check.py`
- Create: `AppStore/Verification/commercial_release_check_test.py`

**Interfaces:**
- Produces: `load_configuration(path: Path) -> dict[str, object]`
- Produces: `validate_configuration(configuration: dict[str, object]) -> list[str]`
- Produces: CLI `python3 AppStore/Verification/commercial_release_check.py --offline`
- CLI success: exit `0`, stdout contains `COMMERCIAL RELEASE CHECK: PASS (offline)`
- CLI validation failure: exit `1`, stderr lists every contract mismatch

- [ ] **Step 1: Write failing tests for the exact approved contract**

Create `AppStore/Verification/commercial_release_check_test.py` with a reusable
literal valid configuration and these first tests:

```python
import copy
import json
import tempfile
import unittest
from pathlib import Path

import commercial_release_check


VALID_CONFIGURATION = {
    "schemaVersion": 1,
    "appleId": "6793023054",
    "bundleId": "com.phillon.KnitNote",
    "appDownload": {
        "model": "free",
        "storefrontCount": 175,
        "baseTerritory": "USA",
        "basePrice": "0.00",
        "futurePriceChanges": [],
    },
    "trial": {"days": 7, "storage": "local"},
    "lifetimeUnlock": {
        "productId": "com.phillon.KnitNote.lifetimeUnlock",
        "type": "non-consumable",
        "status": "approved",
        "prices": {"USA": "4.99", "TWN": "150"},
    },
    "subscriptions": [],
    "permanentEntitlementPolicy": "preserve-verified",
}


class CommercialConfigurationTests(unittest.TestCase):
    def test_approved_contract_has_no_errors(self):
        self.assertEqual(
            commercial_release_check.validate_configuration(VALID_CONFIGURATION),
            [],
        )

    def test_paid_app_download_is_rejected(self):
        configuration = copy.deepcopy(VALID_CONFIGURATION)
        configuration["appDownload"]["model"] = "paid"
        configuration["appDownload"]["basePrice"] = "2.99"
        errors = commercial_release_check.validate_configuration(configuration)
        self.assertIn("appDownload.model must be free", errors)
        self.assertIn("appDownload.basePrice must be 0.00", errors)

    def test_future_app_price_change_is_rejected(self):
        configuration = copy.deepcopy(VALID_CONFIGURATION)
        configuration["appDownload"]["futurePriceChanges"] = [
            {"effectiveDate": "2026-08-23", "price": "4.99"}
        ]
        self.assertIn(
            "appDownload.futurePriceChanges must be empty",
            commercial_release_check.validate_configuration(configuration),
        )

    def test_wrong_lifetime_product_or_prices_are_rejected(self):
        configuration = copy.deepcopy(VALID_CONFIGURATION)
        configuration["lifetimeUnlock"]["productId"] = "wrong.product"
        configuration["lifetimeUnlock"]["prices"] = {"USA": "2.99", "TWN": "90"}
        errors = commercial_release_check.validate_configuration(configuration)
        self.assertIn(
            "lifetimeUnlock.productId must be com.phillon.KnitNote.lifetimeUnlock",
            errors,
        )
        self.assertIn("lifetimeUnlock.prices.USA must be 4.99", errors)
        self.assertIn("lifetimeUnlock.prices.TWN must be 150", errors)
```

Add CLI tests that write JSON to `tempfile.TemporaryDirectory()` and call
`commercial_release_check.main(["--offline", "--configuration", str(path)])`.
Capture stdout and stderr with `contextlib.redirect_stdout` and
`contextlib.redirect_stderr`, and assert exact exit codes rather than testing
source text.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
cd AppStore/Verification
python3 -m unittest -v commercial_release_check_test.py
```

Expected: import failure for missing `commercial_release_check`, proving the
production validator does not exist yet.

- [ ] **Step 3: Implement the minimal offline validator**

Create `AppStore/Verification/commercial_release_check.py` with:

```python
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence


EXPECTED = {
    "schemaVersion": 1,
    "appleId": "6793023054",
    "bundleId": "com.phillon.KnitNote",
    "appDownload.model": "free",
    "appDownload.storefrontCount": 175,
    "appDownload.baseTerritory": "USA",
    "appDownload.basePrice": "0.00",
    "trial.days": 7,
    "trial.storage": "local",
    "lifetimeUnlock.productId": "com.phillon.KnitNote.lifetimeUnlock",
    "lifetimeUnlock.type": "non-consumable",
    "lifetimeUnlock.status": "approved",
    "lifetimeUnlock.prices.USA": "4.99",
    "lifetimeUnlock.prices.TWN": "150",
    "permanentEntitlementPolicy": "preserve-verified",
}


def nested_value(configuration: dict[str, object], key: str) -> object:
    value: object = configuration
    for component in key.split("."):
        if not isinstance(value, dict) or component not in value:
            return None
        value = value[component]
    return value


def load_configuration(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("configuration root must be an object")
    return value


def validate_configuration(configuration: dict[str, object]) -> list[str]:
    errors = [
        f"{key} must be {expected}"
        for key, expected in EXPECTED.items()
        if nested_value(configuration, key) != expected
    ]
    if nested_value(configuration, "appDownload.futurePriceChanges") != []:
        errors.append("appDownload.futurePriceChanges must be empty")
    if nested_value(configuration, "subscriptions") != []:
        errors.append("subscriptions must be empty")
    return errors


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--offline", action="store_true")
    result.add_argument(
        "--configuration",
        type=Path,
        default=Path("AppStore/CommercialConfiguration.json"),
    )
    return result


def main(arguments: Sequence[str] | None = None) -> int:
    options = parser().parse_args(arguments)
    try:
        configuration = load_configuration(options.configuration)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        print(f"{options.configuration}: {error}", file=sys.stderr)
        return 1
    errors = validate_configuration(configuration)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("COMMERCIAL RELEASE CHECK: PASS (offline)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Create `AppStore/CommercialConfiguration.json` with the exact
`VALID_CONFIGURATION` structure above.

- [ ] **Step 4: Run focused tests and offline CLI to verify GREEN**

Run:

```bash
cd AppStore/Verification
python3 -m unittest -v commercial_release_check_test.py
cd ../..
python3 AppStore/Verification/commercial_release_check.py --offline
```

Expected: all focused tests pass; CLI prints
`COMMERCIAL RELEASE CHECK: PASS (offline)`.

- [ ] **Step 5: Commit the canonical contract and offline validator**

```bash
git add AppStore/CommercialConfiguration.json \
  AppStore/Verification/commercial_release_check.py \
  AppStore/Verification/commercial_release_check_test.py
git commit -m "feat: add KnitNote commercial contract guard"
```

### Task 2: Mandatory Checklist and Stale-Documentation Guard

**Files:**
- Modify: `AppStore/Verification/commercial_release_check.py`
- Modify: `AppStore/Verification/commercial_release_check_test.py`
- Create: `AppStore/Verification/CommercialReleaseChecklist.md`
- Modify: `AppStore/KnitNotePricing.md`
- Modify: `AppStore/AppStoreSubmission.md`

**Interfaces:**
- Consumes: `validate_configuration(configuration) -> list[str]`
- Produces: `validate_repository_documents(root: Path) -> list[str]`
- Offline CLI now validates both configuration and release-document structure
- Human evidence remains untrusted until each release row contains candidate-specific data

- [ ] **Step 1: Write failing tests for executable-document safety**

Add tests using a temporary repository root:

```python
def write_repository_documents(root: Path, pricing: str, checklist: str, submission: str):
    app_store = root / "AppStore"
    verification = app_store / "Verification"
    verification.mkdir(parents=True)
    (app_store / "KnitNotePricing.md").write_text(pricing, encoding="utf-8")
    (app_store / "AppStoreSubmission.md").write_text(submission, encoding="utf-8")
    (verification / "CommercialReleaseChecklist.md").write_text(
        checklist,
        encoding="utf-8",
    )


def test_current_documents_require_all_release_gates(self):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        write_repository_documents(
            root,
            pricing=APPROVED_PRICING_DOCUMENT,
            checklist="Candidate SHA\nApp price 0\nNo future App price changes\n",
            submission=APPROVED_SUBMISSION_DOCUMENT,
        )
        errors = commercial_release_check.validate_repository_documents(root)
        self.assertIn("commercial checklist missing: Lifetime Unlock price", errors)
        self.assertIn("commercial checklist missing: public storefront", errors)
        self.assertIn("commercial checklist missing: restore purchase", errors)


def test_current_pricing_instructions_reject_paid_download_language(self):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        write_repository_documents(
            root,
            pricing="# Current\n- App download: US$2.99\n",
            checklist=COMPLETE_CHECKLIST,
            submission=APPROVED_SUBMISSION_DOCUMENT,
        )
        self.assertIn(
            "current pricing instructions must say the App download is free",
            commercial_release_check.validate_repository_documents(root),
        )
```

`APPROVED_PRICING_DOCUMENT`, `APPROVED_SUBMISSION_DOCUMENT`, and
`COMPLETE_CHECKLIST` are literal Markdown fixtures containing all semantic
headings consumed by `validate_repository_documents`; expected values are not
generated by production helpers.

- [ ] **Step 2: Run document tests and verify RED**

Run:

```bash
cd AppStore/Verification
python3 -m unittest -v \
  commercial_release_check_test.CommercialDocumentTests
```

Expected: failure because `validate_repository_documents` is missing.

- [ ] **Step 3: Implement semantic document validation**

Implement:

```python
REQUIRED_CHECKLIST_PHRASES = {
    "Candidate SHA": "candidate identity",
    "175 storefronts": "175-storefront App price",
    "No future App price changes": "future App price schedule",
    "Lifetime Unlock price": "Lifetime Unlock price",
    "public storefront": "public storefront",
    "seven-day trial": "seven-day trial",
    "restore purchase": "restore purchase",
    "iOS acceptance": "iOS acceptance",
    "macOS acceptance": "macOS acceptance",
    "advertising remains blocked": "advertising hold",
}


def validate_repository_documents(root: Path) -> list[str]:
    errors: list[str] = []
    pricing_path = root / "AppStore/KnitNotePricing.md"
    checklist_path = root / "AppStore/Verification/CommercialReleaseChecklist.md"
    submission_path = root / "AppStore/AppStoreSubmission.md"
    try:
        pricing = pricing_path.read_text(encoding="utf-8")
        checklist = checklist_path.read_text(encoding="utf-8")
        submission = submission_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        return [f"commercial documentation: {error}"]
    current_pricing = pricing.split("## Historical", 1)[0]
    if "App download: Free" not in current_pricing:
        errors.append("current pricing instructions must say the App download is free")
    if "Future App price changes: None" not in current_pricing:
        errors.append("current pricing instructions must forbid future App price changes")
    if "AppStore/CommercialConfiguration.json" not in pricing:
        errors.append("pricing document must point to AppStore/CommercialConfiguration.json")
    for phrase, label in REQUIRED_CHECKLIST_PHRASES.items():
        if phrase not in checklist:
            errors.append(f"commercial checklist missing: {label}")
    if "CommercialReleaseChecklist.md" not in submission:
        errors.append("submission document must require CommercialReleaseChecklist.md")
    return errors
```

Call this function from offline CLI after configuration validation, using a
new `--repository-root` option defaulting to `Path(".")`.

- [ ] **Step 4: Replace stale current pricing and submission state**

Rewrite the current section of `AppStore/KnitNotePricing.md` to:

- name `AppStore/CommercialConfiguration.json` as the only executable source;
- show free App download, 175 storefronts, no future App price changes;
- show seven-day trial and Lifetime Unlock US$4.99/NT$150;
- state that availability does not clear prices or schedules;
- state the mandatory order: verify price, delete future changes, enable
  availability, verify public storefronts, test StoreKit, then advertise.

Keep the old paid-download timeline only below heading
`## Historical — KnitNote 1.0 paid-download record` and label it
`NOT EXECUTABLE`.

Update `AppStore/AppStoreSubmission.md` commercial state to record:

- iOS/macOS 1.2.1 were publicly available on 2026-07-31;
- App download was verified free in Taiwan and the United States;
- Lifetime Unlock remained approved at US$4.99/NT$150;
- any future release or re-listing requires
  `Verification/CommercialReleaseChecklist.md`;
- this repository record does not replace a fresh live check.

- [ ] **Step 5: Add the mandatory checklist**

Create `AppStore/Verification/CommercialReleaseChecklist.md` with a fresh,
unchecked template and a separate 2026-07-31 incident record. The reusable
template must include these exact fields:

```markdown
## Candidate identity

- [ ] Candidate SHA:
- [ ] Version and build:
- [ ] iOS archive identity:
- [ ] macOS archive identity:
- [ ] App Store Connect selected builds:

## App price and availability

- [ ] App download price is 0 in all 175 storefronts.
- [ ] United States App price is US$0.00.
- [ ] Taiwan App price is NT$0.
- [ ] No future App price changes are scheduled.
- [ ] Availability matches the intended 175 storefronts.

## Lifetime Unlock

- [ ] Product ID is `com.phillon.KnitNote.lifetimeUnlock`.
- [ ] Type is non-consumable and status is approved.
- [ ] Lifetime Unlock price is US$4.99 in the United States.
- [ ] Lifetime Unlock price is NT$150 in Taiwan.

## Public and device acceptance

- [ ] Taiwan public storefront shows free App download and App內購買.
- [ ] United States public storefront shows Free and In-App Purchases.
- [ ] A fresh public install shows the seven-day trial.
- [ ] Purchase sheet shows the expected local Lifetime Unlock price.
- [ ] Lifetime Unlock survives relaunch.
- [ ] Restore purchase succeeds without a second charge.
- [ ] iOS acceptance passed on the exact public candidate.
- [ ] macOS acceptance passed on the exact public candidate.

## Advertising gate

- [ ] Advertising remains blocked until every item above has dated evidence.
```

- [ ] **Step 6: Run focused tests and offline CLI to verify GREEN**

Run:

```bash
cd AppStore/Verification
python3 -m unittest -v commercial_release_check_test.py
cd ../..
python3 AppStore/Verification/commercial_release_check.py --offline
git diff --check
```

Expected: all tests pass; offline CLI passes; no whitespace errors.

- [ ] **Step 7: Commit documents and semantic guard**

```bash
git add AppStore/KnitNotePricing.md \
  AppStore/AppStoreSubmission.md \
  AppStore/Verification/CommercialReleaseChecklist.md \
  AppStore/Verification/commercial_release_check.py \
  AppStore/Verification/commercial_release_check_test.py
git commit -m "docs: enforce KnitNote commercial release gates"
```

### Task 3: Live Public Storefront Verification

**Files:**
- Modify: `AppStore/Verification/commercial_release_check.py`
- Modify: `AppStore/Verification/commercial_release_check_test.py`

**Interfaces:**
- Produces: `lookup_url(country: str, apple_id: str) -> str`
- Produces: `validate_lookup_payload(payload: dict[str, object], country: str) -> list[str]`
- Produces: `fetch_lookup(country: str, apple_id: str, timeout: float = 15.0) -> dict[str, object]`
- Produces: `product_page_url(country: str, apple_id: str) -> str`
- Produces: `validate_product_page(source: str, country: str) -> list[str]`
- Produces: `fetch_product_page(country: str, apple_id: str, timeout: float = 15.0) -> str`
- CLI `--live` checks `tw` and `us` only after offline validation passes
- Live success stdout contains `COMMERCIAL RELEASE CHECK: PASS (live: tw, us)`

- [ ] **Step 1: Write failing tests for public lookup behavior**

Add literal complete lookup payloads:

```python
VALID_TW_LOOKUP = {
    "resultCount": 1,
    "results": [{
        "trackId": 6793023054,
        "bundleId": "com.phillon.KnitNote",
        "price": 0.0,
        "formattedPrice": "免費",
        "currency": "TWD",
    }],
}
VALID_US_LOOKUP = {
    "resultCount": 1,
    "results": [{
        "trackId": 6793023054,
        "bundleId": "com.phillon.KnitNote",
        "price": 0.0,
        "formattedPrice": "Free",
        "currency": "USD",
    }],
}
```

Test:

- both valid payloads return no errors;
- price `90.0` in Taiwan reports `tw public App price must be 0`;
- price `2.99` in the United States reports
  `us public App price must be 0`;
- result count zero, two results, missing fields, wrong Apple ID, wrong bundle
  ID, wrong currency, malformed root, and nonnumeric price each fail closed;
- `lookup_url("tw", "6793023054")` equals
  `https://itunes.apple.com/lookup?id=6793023054&country=tw`;
- `product_page_url("tw", "6793023054")` equals
  `https://apps.apple.com/tw/app/id6793023054`;
- a Taiwan product page containing `免費 · App內購買` passes and one missing
  `App內購買` fails;
- a United States product page containing `Free · In-App Purchases` passes and
  one missing `In-App Purchases` fails;
- an injected opener raising `URLError("offline")` makes CLI return `1` and
  stderr contain `live lookup failed for tw: offline`.

- [ ] **Step 2: Run live-boundary tests and verify RED**

Run:

```bash
cd AppStore/Verification
python3 -m unittest -v \
  commercial_release_check_test.PublicStorefrontTests
```

Expected: failure because lookup functions and `--live` mode are missing.

- [ ] **Step 3: Implement the live lookup boundary**

Use only standard-library `urllib.request.urlopen`, `urllib.error.URLError`,
`urllib.parse.urlencode`, and `html.unescape`.

`validate_lookup_payload` must:

- require an object root;
- require `resultCount == 1`;
- require exactly one result object;
- require numeric `trackId == 6793023054`;
- require bundle ID `com.phillon.KnitNote`;
- reject `bool` as a numeric price;
- require numeric price exactly `0.0`;
- require `TWD` for `tw` and `USD` for `us`.

`fetch_lookup` must decode UTF-8 JSON and raise `ValueError` with storefront
context for malformed data.

`validate_product_page` must normalize HTML entities, whitespace, nonbreaking
spaces, and hyphen variants, then require both the localized free-download
label and localized In-App Purchase label. It must report independent errors
for a paid/missing free label and a missing In-App Purchase label.

CLI parser rules:

- exactly one of `--offline` or `--live` is required;
- `--live` first runs all offline checks;
- live mode checks countries in stable order `("tw", "us")`;
- each country must pass both lookup JSON validation and product-page label
  validation;
- any network or validation error returns `1`;
- the command never retries or writes external state.

- [ ] **Step 4: Run focused tests and mutation checks**

Run:

```bash
cd AppStore/Verification
python3 -m unittest -v commercial_release_check_test.py
```

Then temporarily change a copied test fixture price from `0.0` to `2.99` and
confirm the real validator rejects it; restore the fixture before continuing.
Also temporarily change production expected bundle ID in a disposable copy of
the configuration passed to the test and confirm the validator rejects it.

Expected: test suite passes after restoration, and both mutations produce the
named failures.

- [ ] **Step 5: Run the real live check**

Run:

```bash
python3 AppStore/Verification/commercial_release_check.py --live
```

Expected when Apple's public endpoint is reachable and synchronized:

```text
COMMERCIAL RELEASE CHECK: PASS (live: tw, us)
```

If the network is unavailable or either public storefront is paid, record the
actual failure and do not weaken the validator.

- [ ] **Step 6: Commit live verification**

```bash
git add AppStore/Verification/commercial_release_check.py \
  AppStore/Verification/commercial_release_check_test.py
git commit -m "feat: verify KnitNote public download price"
```

### Task 4: Release Audit Integration and Final Verification

**Files:**
- Modify: `AppStore/Verification/release_audit.sh`
- Modify: `AppStore/Verification/commercial_release_check_test.py`
- Update: `AppStore/Verification/CommercialReleaseChecklist.md`

**Interfaces:**
- Consumes: offline CLI contract from Tasks 1 and 2
- Produces: every `release_audit.sh` run fails before release success if the commercial contract or required document structure is invalid

- [ ] **Step 1: Write a failing release-audit integration test**

Add a subprocess test that executes the real static audit with an environment
override pointing at a temporary paid configuration:

```python
import os
import subprocess


class ReleaseAuditIntegrationTests(unittest.TestCase):
    def test_static_audit_rejects_paid_commercial_configuration(self):
        configuration = copy.deepcopy(VALID_CONFIGURATION)
        configuration["appDownload"]["model"] = "paid"
        configuration["appDownload"]["basePrice"] = "2.99"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "paid.json"
            path.write_text(json.dumps(configuration), encoding="utf-8")
            root = Path(__file__).resolve().parents[2]
            environment = os.environ.copy()
            environment["KNITNOTE_COMMERCIAL_CONFIGURATION"] = str(path)
            result = subprocess.run(
                ["bash", "AppStore/Verification/release_audit.sh", "--static-only"],
                cwd=root,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("appDownload.model must be free", result.stderr)
        self.assertNotIn("RELEASE AUDIT: PASS", result.stdout)
```

This executes the release artifact rather than asserting on Bash source text.

- [ ] **Step 2: Run the integration test and verify RED**

Run:

```bash
cd AppStore/Verification
python3 -m unittest -v \
  commercial_release_check_test.ReleaseAuditIntegrationTests
```

Expected: failure because the audit integration wrapper is not yet present.

- [ ] **Step 3: Invoke the commercial guard from release audit**

In `AppStore/Verification/release_audit.sh`, immediately after metadata
validation, add:

```bash
python3 AppStore/Verification/commercial_release_check.py \
  --offline \
  --configuration \
  "${KNITNOTE_COMMERCIAL_CONFIGURATION:-AppStore/CommercialConfiguration.json}"
```

Do not invoke live network access from the static or default release audit.
Live propagation remains an explicit release/re-listing gate.

- [ ] **Step 4: Record the verified 2026-07-31 incident outcome**

In the incident section of
`AppStore/Verification/CommercialReleaseChecklist.md`, record only evidence
already observed:

- App price zero in all 175 storefronts;
- no future App price schedule;
- Lifetime Unlock approved, US$4.99 and NT$150;
- public Taiwan free/App內購買;
- public United States Free/In-App Purchases;
- iOS TestFlight purchase and relaunch persistence evidence, explicitly labeled
  as TestFlight rather than the new public-build acceptance.

Leave fresh public-install iOS and macOS acceptance unchecked. Do not claim the
commercial gate is fully passed until those exact public flows are run.

- [ ] **Step 5: Run complete verification**

Run:

```bash
cd AppStore/Verification
python3 -m unittest -v commercial_release_check_test.py
cd ../..
python3 AppStore/Verification/commercial_release_check.py --offline
python3 AppStore/Verification/commercial_release_check.py --live
bash AppStore/Verification/release_audit.sh --static-only
swift test --disable-sandbox
git diff --check
git status --short
```

Required evidence:

- all commercial guard tests pass;
- offline commercial check passes;
- live Taiwan/United States check passes or is reported as an external blocker;
- static release audit passes;
- complete Swift suite reports 966 tests in 78 suites with zero failures;
- `git diff --check` returns no output;
- only intended files are modified.

- [ ] **Step 6: Commit audit integration**

```bash
git add AppStore/Verification/release_audit.sh \
  AppStore/Verification/commercial_release_check_test.py \
  AppStore/Verification/CommercialReleaseChecklist.md
git commit -m "chore: gate releases on commercial configuration"
```

- [ ] **Step 7: Final branch review**

Run:

```bash
git log --oneline --decorate -5
git diff c1ffcd19c7b71fae8e16eb4eaedd7720c479e0f6...HEAD --stat
git diff c1ffcd19c7b71fae8e16eb4eaedd7720c479e0f6...HEAD --check
```

Confirm the branch contains the design, implementation plan, canonical
configuration, validator, tests, current pricing document, checklist,
submission-state correction, and release-audit integration only.
