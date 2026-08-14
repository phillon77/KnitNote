#!/usr/bin/env python3
from __future__ import annotations
"""Contract checks for the Knitting Calculator String Catalogs."""

import argparse
import json
import re
import sys
from pathlib import Path


SUPPORTED_APP_LOCALES = (
    "en", "zh-Hant", "zh-Hans", "de", "fr", "ja", "ko",
    "nl", "nb", "sv", "fi", "da", "el",
)
PLACEHOLDER = re.compile(
    r"%(?:\d+\$)?(?:[-+0 #]*\d*(?:\.\d+)?)?(?:hh|h|ll|l|L|z|t|j)?[@diuoxXfFeEgGaAcCsSp]"
)
INVARIANT_PAIRS = frozenset({
    ("calculator.title", "KnitNote"),
    ("app.name", "KnitNote"),
    ("support.url", "https://knitnote.app"),
    ("unit.stitches", "st"),
    ("unit.rows", "rows"),
    ("symbol.increase", "+"),
})


def string_units(node: object) -> list[dict[str, object]]:
    """Recursively collect stringUnit dictionaries, including variations."""
    if isinstance(node, dict):
        units = [node["stringUnit"]] if isinstance(node.get("stringUnit"), dict) else []
        return units + [unit for value in node.values() for unit in string_units(value)]
    if isinstance(node, list):
        return [unit for value in node for unit in string_units(value)]
    return []


def _invariant(key: str, value: str) -> bool:
    """Values intentionally unchanged across locales, kept deliberately narrow."""
    return (key, value) in INVARIANT_PAIRS


def _catalog_payload(path: Path) -> tuple[dict[str, object] | None, list[str]]:
    try:
        return json.loads(path.read_text(encoding="utf-8")), []
    except (OSError, json.JSONDecodeError) as exc:
        return None, [f"{path}: catalog: unable to parse ({exc})"]


def _locale_set(payload: dict[str, object]) -> set[str]:
    strings = payload.get("strings", {})
    if not isinstance(strings, dict):
        return set()
    locales: set[str] = set()
    for entry in strings.values():
        if isinstance(entry, dict) and isinstance(entry.get("localizations"), dict):
            locales.update(entry["localizations"])
    return locales


def validate_catalog(path: Path) -> list[str]:
    payload, errors = _catalog_payload(path)
    if payload is None:
        return errors
    if payload.get("sourceLanguage") != "en":
        errors.append(f"{path}: sourceLanguage: expected en")
    strings = payload.get("strings", {})
    if not isinstance(strings, dict):
        return errors + [f"{path}: strings: expected object"]
    expected = set(SUPPORTED_APP_LOCALES)
    for key, entry in strings.items():
        if not isinstance(entry, dict):
            errors.append(f"{path}: {key}: entry: expected object")
            continue
        localizations = entry.get("localizations", {})
        if not isinstance(localizations, dict):
            errors.append(f"{path}: {key}: localizations: expected object")
            continue
        actual = set(localizations)
        missing, extra = expected - actual, actual - expected
        if missing:
            errors.append(f"{path}: {key}: locales: missing locales {sorted(missing)}")
        if extra:
            errors.append(f"{path}: {key}: locales: extra locales {sorted(extra)}")
        if missing or extra or "en" not in localizations:
            continue
        english_units = string_units(localizations["en"])
        english_values = [str(unit.get("value", "")) for unit in english_units]
        english_placeholders = [PLACEHOLDER.findall(value) for value in english_values]
        for locale in SUPPORTED_APP_LOCALES:
            units = string_units(localizations[locale])
            if any(unit.get("state") != "translated" or not unit.get("value") for unit in units) or not units:
                errors.append(f"{path}: {key}: {locale}: incomplete translation")
            values = [str(unit.get("value", "")) for unit in units]
            if [PLACEHOLDER.findall(value) for value in values] != english_placeholders:
                errors.append(f"{path}: {key}: {locale}: placeholder mismatch")
            if locale != "en":
                for english_value, value in zip(english_values, values):
                    if value == english_value and not _invariant(str(key), value):
                        errors.append(f"{path}: {key}: {locale}: copied English")
    return errors


def validate_catalog_pair(localizable: Path, info_plist: Path) -> list[str]:
    errors = validate_catalog(localizable) + validate_catalog(info_plist)
    left, left_errors = _catalog_payload(localizable)
    right, right_errors = _catalog_payload(info_plist)
    errors.extend(left_errors + right_errors)
    if left is not None and right is not None and _locale_set(left) != _locale_set(right):
        errors.append(f"catalog locale set mismatch: {localizable} vs {info_plist}")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("localizable", type=Path)
    parser.add_argument("info_plist", type=Path)
    args = parser.parse_args(argv)
    errors = validate_catalog_pair(args.localizable, args.info_plist)
    for error in errors:
        print(error, file=sys.stderr)
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
