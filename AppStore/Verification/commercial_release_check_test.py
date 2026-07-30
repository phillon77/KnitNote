#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import copy
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from urllib.error import URLError
from unittest.mock import patch

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

APPROVED_PRICING_DOCUMENT = """# KnitNote commercial pricing

Source: `AppStore/CommercialConfiguration.json`

- App download: Free
- Future App price changes: None

## Historical

NOT EXECUTABLE.
"""

APPROVED_SUBMISSION_DOCUMENT = """# Submission

Every release requires `Verification/CommercialReleaseChecklist.md`.
"""

COMPLETE_CHECKLIST = """# Commercial release checklist

Candidate SHA
175 storefronts
No future App price changes
Lifetime Unlock price
public storefront
seven-day trial
restore purchase
iOS acceptance
macOS acceptance
advertising remains blocked
"""

VALID_TW_LOOKUP = {
    "resultCount": 1,
    "results": [
        {
            "trackId": 6793023054,
            "bundleId": "com.phillon.KnitNote",
            "price": 0.0,
            "formattedPrice": "免費",
            "currency": "TWD",
        }
    ],
}

VALID_US_LOOKUP = {
    "resultCount": 1,
    "results": [
        {
            "trackId": 6793023054,
            "bundleId": "com.phillon.KnitNote",
            "price": 0.0,
            "formattedPrice": "Free",
            "currency": "USD",
        }
    ],
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

    def test_subscriptions_are_rejected(self):
        configuration = copy.deepcopy(VALID_CONFIGURATION)
        configuration["subscriptions"] = [{"productId": "monthly"}]

        self.assertIn(
            "subscriptions must be empty",
            commercial_release_check.validate_configuration(configuration),
        )

    def test_offline_cli_passes_valid_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "commercial.json"
            path.write_text(json.dumps(VALID_CONFIGURATION), encoding="utf-8")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                result = commercial_release_check.main(
                    ["--offline", "--configuration", str(path)]
                )

        self.assertEqual(result, 0)
        self.assertIn("COMMERCIAL RELEASE CHECK: PASS (offline)", stdout.getvalue())

    def test_offline_cli_fails_closed_for_malformed_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "commercial.json"
            path.write_text("[]", encoding="utf-8")
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                result = commercial_release_check.main(
                    ["--offline", "--configuration", str(path)]
                )

        self.assertEqual(result, 1)
        self.assertIn("configuration root must be an object", stderr.getvalue())


def write_repository_documents(
    root: Path,
    *,
    pricing: str,
    checklist: str,
    submission: str,
) -> None:
    app_store = root / "AppStore"
    verification = app_store / "Verification"
    verification.mkdir(parents=True)
    (app_store / "KnitNotePricing.md").write_text(pricing, encoding="utf-8")
    (app_store / "AppStoreSubmission.md").write_text(
        submission,
        encoding="utf-8",
    )
    (verification / "CommercialReleaseChecklist.md").write_text(
        checklist,
        encoding="utf-8",
    )


class CommercialDocumentTests(unittest.TestCase):
    def test_approved_documents_have_no_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository_documents(
                root,
                pricing=APPROVED_PRICING_DOCUMENT,
                checklist=COMPLETE_CHECKLIST,
                submission=APPROVED_SUBMISSION_DOCUMENT,
            )

            errors = commercial_release_check.validate_repository_documents(root)

        self.assertEqual(errors, [])

    def test_current_documents_require_all_release_gates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository_documents(
                root,
                pricing=APPROVED_PRICING_DOCUMENT,
                checklist=(
                    "Candidate SHA\n"
                    "175 storefronts\n"
                    "No future App price changes\n"
                ),
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
                pricing=(
                    "# Current\n\n"
                    "Source: `AppStore/CommercialConfiguration.json`\n\n"
                    "- App download: US$2.99\n"
                    "- Future App price changes: None\n"
                ),
                checklist=COMPLETE_CHECKLIST,
                submission=APPROVED_SUBMISSION_DOCUMENT,
            )

            errors = commercial_release_check.validate_repository_documents(root)

        self.assertIn(
            "current pricing instructions must say the App download is free",
            errors,
        )

    def test_current_pricing_requires_no_future_changes_and_canonical_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository_documents(
                root,
                pricing="# Current\n\n- App download: Free\n",
                checklist=COMPLETE_CHECKLIST,
                submission=APPROVED_SUBMISSION_DOCUMENT,
            )

            errors = commercial_release_check.validate_repository_documents(root)

        self.assertIn(
            "current pricing instructions must forbid future App price changes",
            errors,
        )
        self.assertIn(
            "pricing document must point to AppStore/CommercialConfiguration.json",
            errors,
        )

    def test_submission_document_requires_the_commercial_checklist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository_documents(
                root,
                pricing=APPROVED_PRICING_DOCUMENT,
                checklist=COMPLETE_CHECKLIST,
                submission="# Submission\n",
            )

            errors = commercial_release_check.validate_repository_documents(root)

        self.assertIn(
            "submission document must require CommercialReleaseChecklist.md",
            errors,
        )


class PublicStorefrontTests(unittest.TestCase):
    def test_certificate_bundle_falls_back_to_existing_system_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            missing = root / "missing.pem"
            system_bundle = root / "system.pem"
            system_bundle.write_text("test certificate bundle", encoding="utf-8")

            result = commercial_release_check.certificate_bundle(
                None,
                (missing, system_bundle),
            )

        self.assertEqual(result, system_bundle)

    def test_certificate_bundle_prefers_existing_python_default(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            python_default = root / "python.pem"
            system_bundle = root / "system.pem"
            python_default.write_text("python certificates", encoding="utf-8")
            system_bundle.write_text("system certificates", encoding="utf-8")

            result = commercial_release_check.certificate_bundle(
                str(python_default),
                (system_bundle,),
            )

        self.assertEqual(result, python_default)

    def test_valid_taiwan_and_united_states_lookup_payloads_pass(self):
        self.assertEqual(
            commercial_release_check.validate_lookup_payload(
                VALID_TW_LOOKUP,
                "tw",
            ),
            [],
        )
        self.assertEqual(
            commercial_release_check.validate_lookup_payload(
                VALID_US_LOOKUP,
                "us",
            ),
            [],
        )

    def test_paid_public_prices_are_rejected(self):
        taiwan = copy.deepcopy(VALID_TW_LOOKUP)
        taiwan["results"][0]["price"] = 90.0
        united_states = copy.deepcopy(VALID_US_LOOKUP)
        united_states["results"][0]["price"] = 2.99

        self.assertIn(
            "tw public App price must be 0",
            commercial_release_check.validate_lookup_payload(taiwan, "tw"),
        )
        self.assertIn(
            "us public App price must be 0",
            commercial_release_check.validate_lookup_payload(
                united_states,
                "us",
            ),
        )

    def test_lookup_payload_rejects_wrong_identity_currency_and_shape(self):
        wrong_identity = copy.deepcopy(VALID_TW_LOOKUP)
        wrong_identity["results"][0]["trackId"] = 1
        wrong_identity["results"][0]["bundleId"] = "wrong.bundle"
        wrong_identity["results"][0]["currency"] = "USD"

        errors = commercial_release_check.validate_lookup_payload(
            wrong_identity,
            "tw",
        )

        self.assertIn("tw public Apple ID must be 6793023054", errors)
        self.assertIn(
            "tw public bundle ID must be com.phillon.KnitNote",
            errors,
        )
        self.assertIn("tw public currency must be TWD", errors)
        for payload in (
            [],
            {},
            {"resultCount": 0, "results": []},
            {"resultCount": 2, "results": [{}, {}]},
            {"resultCount": 1, "results": []},
            {"resultCount": 1, "results": [None]},
        ):
            with self.subTest(payload=payload):
                self.assertTrue(
                    commercial_release_check.validate_lookup_payload(
                        payload,
                        "tw",
                    )
                )

    def test_lookup_payload_rejects_boolean_and_missing_price(self):
        boolean_price = copy.deepcopy(VALID_US_LOOKUP)
        boolean_price["results"][0]["price"] = False
        missing_price = copy.deepcopy(VALID_US_LOOKUP)
        del missing_price["results"][0]["price"]

        self.assertIn(
            "us public App price must be numeric",
            commercial_release_check.validate_lookup_payload(
                boolean_price,
                "us",
            ),
        )
        self.assertIn(
            "us public App price must be numeric",
            commercial_release_check.validate_lookup_payload(
                missing_price,
                "us",
            ),
        )

    def test_public_urls_are_stable(self):
        self.assertEqual(
            commercial_release_check.lookup_url("tw", "6793023054"),
            "https://itunes.apple.com/lookup?id=6793023054&country=tw",
        )
        self.assertEqual(
            commercial_release_check.product_page_url("tw", "6793023054"),
            "https://apps.apple.com/tw/app/id6793023054",
        )

    def test_product_pages_require_free_and_in_app_purchase_labels(self):
        self.assertEqual(
            commercial_release_check.validate_product_page(
                "<p>免費&nbsp;·&nbsp;App內購買</p>",
                "tw",
            ),
            [],
        )
        self.assertEqual(
            commercial_release_check.validate_product_page(
                "<p>Free · In‑App Purchases</p>",
                "us",
            ),
            [],
        )

        self.assertIn(
            "tw public product page must identify App內購買",
            commercial_release_check.validate_product_page(
                "<p>免費</p>",
                "tw",
            ),
        )
        self.assertIn(
            "us public product page must identify In-App Purchases",
            commercial_release_check.validate_product_page(
                "<p>Free</p>",
                "us",
            ),
        )
        self.assertIn(
            "us public product page must identify a free App download",
            commercial_release_check.validate_product_page(
                "<p>$2.99 · In-App Purchases</p>",
                "us",
            ),
        )

    def test_live_cli_fails_closed_on_network_error(self):
        root = Path(__file__).resolve().parents[2]
        stderr = io.StringIO()
        with patch.object(
            commercial_release_check,
            "urlopen",
            side_effect=URLError("offline"),
        ):
            with contextlib.redirect_stderr(stderr):
                result = commercial_release_check.main(
                    [
                        "--live",
                        "--configuration",
                        str(root / "AppStore/CommercialConfiguration.json"),
                        "--repository-root",
                        str(root),
                    ]
                )

        self.assertEqual(result, 1)
        self.assertIn("live lookup failed for tw: offline", stderr.getvalue())


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
                [
                    "bash",
                    "AppStore/Verification/release_audit.sh",
                    "--static-only",
                ],
                cwd=root,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("appDownload.model must be free", result.stderr)
        self.assertNotIn("RELEASE AUDIT: PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
