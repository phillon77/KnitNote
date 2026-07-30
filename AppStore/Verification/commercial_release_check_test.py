#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import copy
import io
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


if __name__ == "__main__":
    unittest.main()
