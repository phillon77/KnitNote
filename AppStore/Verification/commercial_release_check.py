#!/usr/bin/env python3
"""Validate KnitNote's commercial contract before release work."""

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
        errors.append(
            "current pricing instructions must forbid future App price changes"
        )
    if "AppStore/CommercialConfiguration.json" not in pricing:
        errors.append(
            "pricing document must point to AppStore/CommercialConfiguration.json"
        )
    for phrase, label in REQUIRED_CHECKLIST_PHRASES.items():
        if phrase not in checklist:
            errors.append(f"commercial checklist missing: {label}")
    if "CommercialReleaseChecklist.md" not in submission:
        errors.append(
            "submission document must require CommercialReleaseChecklist.md"
        )
    return errors


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--offline", action="store_true")
    result.add_argument(
        "--configuration",
        type=Path,
        default=Path("AppStore/CommercialConfiguration.json"),
    )
    result.add_argument(
        "--repository-root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
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
    errors.extend(validate_repository_documents(options.repository_root))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("COMMERCIAL RELEASE CHECK: PASS (offline)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
