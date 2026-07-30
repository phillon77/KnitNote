#!/usr/bin/env python3
"""Validate KnitNote's commercial contract before release work."""

from __future__ import annotations

import argparse
import html
import json
import re
import ssl
import sys
from pathlib import Path
from typing import Sequence
from urllib.error import URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


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

PUBLIC_STOREFRONTS = {
    "tw": {
        "currency": "TWD",
        "freeLabel": "免費",
        "iapLabel": "App內購買",
    },
    "us": {
        "currency": "USD",
        "freeLabel": "Free",
        "iapLabel": "In-App Purchases",
    },
}

SYSTEM_CERTIFICATE_BUNDLES = (
    Path("/etc/ssl/cert.pem"),
    Path("/private/etc/ssl/cert.pem"),
)


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


def lookup_url(country: str, apple_id: str) -> str:
    return "https://itunes.apple.com/lookup?" + urlencode(
        {"id": apple_id, "country": country}
    )


def product_page_url(country: str, apple_id: str) -> str:
    return f"https://apps.apple.com/{country}/app/id{apple_id}"


def certificate_bundle(
    default_cafile: str | None,
    candidates: Sequence[Path],
) -> Path | None:
    if default_cafile:
        default_path = Path(default_cafile)
        if default_path.is_file():
            return default_path
    return next((path for path in candidates if path.is_file()), None)


def verified_ssl_context() -> ssl.SSLContext:
    bundle = certificate_bundle(
        ssl.get_default_verify_paths().cafile,
        SYSTEM_CERTIFICATE_BUNDLES,
    )
    if bundle is None:
        return ssl.create_default_context()
    return ssl.create_default_context(cafile=str(bundle))


def validate_lookup_payload(payload: object, country: str) -> list[str]:
    errors: list[str] = []
    storefront = PUBLIC_STOREFRONTS.get(country)
    if storefront is None:
        return [f"unsupported public storefront: {country}"]
    if not isinstance(payload, dict):
        return [f"{country} public lookup root must be an object"]
    results = payload.get("results")
    if payload.get("resultCount") != 1:
        errors.append(f"{country} public lookup resultCount must be 1")
    if not isinstance(results, list) or len(results) != 1:
        errors.append(f"{country} public lookup must contain exactly one result")
        return errors
    result = results[0]
    if not isinstance(result, dict):
        errors.append(f"{country} public lookup result must be an object")
        return errors
    if result.get("trackId") != 6793023054:
        errors.append(f"{country} public Apple ID must be 6793023054")
    if result.get("bundleId") != "com.phillon.KnitNote":
        errors.append(
            f"{country} public bundle ID must be com.phillon.KnitNote"
        )
    price = result.get("price")
    if isinstance(price, bool) or not isinstance(price, (int, float)):
        errors.append(f"{country} public App price must be numeric")
    elif float(price) != 0.0:
        errors.append(f"{country} public App price must be 0")
    if result.get("currency") != storefront["currency"]:
        errors.append(
            f"{country} public currency must be {storefront['currency']}"
        )
    return errors


def normalized_product_page(source: str) -> str:
    text = html.unescape(source)
    for hyphen in ("‑", "–", "—", "−"):
        text = text.replace(hyphen, "-")
    return re.sub(r"\s+", " ", text.replace("\u00a0", " "))


def validate_product_page(source: str, country: str) -> list[str]:
    storefront = PUBLIC_STOREFRONTS.get(country)
    if storefront is None:
        return [f"unsupported public storefront: {country}"]
    text = normalized_product_page(source)
    errors: list[str] = []
    if storefront["freeLabel"] not in text:
        errors.append(
            f"{country} public product page must identify a free App download"
        )
    if storefront["iapLabel"] not in text:
        errors.append(
            f"{country} public product page must identify {storefront['iapLabel']}"
        )
    return errors


def fetch_lookup(
    country: str,
    apple_id: str,
    timeout: float = 15.0,
) -> dict[str, object]:
    request = Request(
        lookup_url(country, apple_id),
        headers={"User-Agent": "KnitNoteReleaseCheck/1.0"},
    )
    with urlopen(
        request,
        timeout=timeout,
        context=verified_ssl_context(),
    ) as response:
        source = response.read().decode("utf-8")
    payload = json.loads(source)
    if not isinstance(payload, dict):
        raise ValueError("lookup root must be an object")
    return payload


def fetch_product_page(
    country: str,
    apple_id: str,
    timeout: float = 15.0,
) -> str:
    request = Request(
        product_page_url(country, apple_id),
        headers={"User-Agent": "Mozilla/5.0 KnitNoteReleaseCheck/1.0"},
    )
    with urlopen(
        request,
        timeout=timeout,
        context=verified_ssl_context(),
    ) as response:
        return response.read().decode("utf-8")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    mode = result.add_mutually_exclusive_group(required=True)
    mode.add_argument("--offline", action="store_true")
    mode.add_argument("--live", action="store_true")
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
    if options.offline:
        print("COMMERCIAL RELEASE CHECK: PASS (offline)")
        return 0

    apple_id = str(nested_value(configuration, "appleId"))
    for country in ("tw", "us"):
        try:
            payload = fetch_lookup(country, apple_id)
            product_page = fetch_product_page(country, apple_id)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
            reason = error.reason if isinstance(error, URLError) else error
            print(
                f"live lookup failed for {country}: {reason}",
                file=sys.stderr,
            )
            return 1
        errors.extend(validate_lookup_payload(payload, country))
        errors.extend(validate_product_page(product_page, country))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("COMMERCIAL RELEASE CHECK: PASS (live: tw, us)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
