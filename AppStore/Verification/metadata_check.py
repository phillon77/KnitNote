#!/usr/bin/env python3
"""Validate the repository-owned App Store metadata sources."""

from __future__ import annotations

import re
import sys
from pathlib import Path


LIMITS = {
    "Name": 30,
    "Subtitle": 30,
    "Promotional text": 170,
    "Keywords": 100,
}
REQUIRED = (
    "Name",
    "Subtitle",
    "Promotional text",
    "Keywords",
    "Description",
    "Support URL",
    "Privacy URL",
    "What's New",
)
FORBIDDEN = (
    " ai ",
    "cloud sync",
    "automatic stitch recognition",
    "social network",
    "marketplace",
    "subscription",
)
FIELD = re.compile(r"^- ([^:]+):\s*(.*)$")


def parse(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    lines = path.read_text(encoding="utf-8").splitlines()
    index = 0
    while index < len(lines):
        match = FIELD.match(lines[index])
        if not match:
            index += 1
            continue
        name, value = match.groups()
        if name == "Description" and value == "|":
            block: list[str] = []
            index += 1
            while index < len(lines) and (lines[index].startswith("  ") or not lines[index]):
                block.append(lines[index][2:] if lines[index].startswith("  ") else "")
                index += 1
            fields[name] = "\n".join(block).strip()
            continue
        fields[name] = value.strip()
        index += 1
    return fields


def validate(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        fields = parse(path)
    except (OSError, UnicodeError) as error:
        return [f"{path}: file: {error}"]

    for name in REQUIRED:
        if not fields.get(name):
            errors.append(f"{path}: {name}: required non-empty field")

    for name, limit in LIMITS.items():
        value = fields.get(name, "")
        length = len(value.encode("utf-8")) if name == "Keywords" else len(value)
        if length > limit:
            unit = "UTF-8 bytes" if name == "Keywords" else "characters"
            errors.append(f"{path}: {name}: {length} {unit}; limit is {limit}")

    keywords = [item.strip().casefold() for item in fields.get("Keywords", "").split(",")]
    duplicates = sorted({item for item in keywords if item and keywords.count(item) > 1})
    if duplicates:
        errors.append(f"{path}: Keywords: duplicates: {', '.join(duplicates)}")

    searchable = " " + "\n".join(fields.values()).casefold() + " "
    for phrase in FORBIDDEN:
        if phrase in searchable:
            errors.append(f"{path}: copy: forbidden release claim: {phrase.strip()}")

    for name in ("Support URL", "Privacy URL"):
        value = fields.get(name, "")
        if value and not value.startswith("https://"):
            errors.append(f"{path}: {name}: must use HTTPS")
    return errors


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: metadata_check.py AppStore/Metadata", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    paths = [root / "zh-Hant.md", root / "en-US.md"]
    errors = [error for path in paths for error in validate(path)]
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("METADATA CHECK: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
