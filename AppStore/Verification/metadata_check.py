#!/usr/bin/env python3
"""Validate the repository-owned App Store metadata sources."""

from __future__ import annotations

import re
import sys
import unicodedata
from pathlib import Path


LIMITS = {
    "Name": 30,
    "Subtitle": 30,
    "Promotional text": 170,
    "Keywords": 100,
    "What's New": 4_000,
    "Description": 4_000,
}
REQUIRED = (
    "Name",
    "Subtitle",
    "Promotional text",
    "Keywords",
    "Description",
    "Support URL",
    "Marketing URL",
    "Privacy URL",
    "What's New",
)
FORBIDDEN_PATTERNS = (
    (
        "AI translation",
        re.compile(
            r"(?<!\w)(?:"
            r"ai(?:[ -]+powered)?[ -]*translat(?:e|ed|ing|ions?)|"
            r"ki[ -]+gestützte[ -]+übersetzung|"
            r"(?:ki|künstliche intelligenz)[ -]+(?:übersetzung|übersetzen)|"
            r"traductions?[ -]+(?:par[ -]+)?ia|ia[ -]+traduction"
            r")(?!\w)|"
            r"(?:ai[ -]*(?:翻譯|翻译|翻訳|による[ -]*翻訳)|"
            r"(?:人工智慧|人工智能|人工知能)[ -]*(?:翻譯|翻译|翻訳))"
        ),
    ),
    (
        "cloud sync",
        re.compile(
            r"(?<!\w)(?:"
            r"i?cloud[ -]+(?:sync(?:s|ed|ing)?|synchronization)|"
            r"cloud[ -]*synchronis(?:ation|ierung)|"
            r"synchronisation[ -]+(?:dans[ -]+le[ -]+)?cloud|"
            r"cloud[ -]+synchronisation"
            r")(?!\w)|(?:雲端|云端)[ -]*同步|クラウド[ -]*同期"
        ),
    ),
    (
        "automatic stitch recognition",
        re.compile(
            r"(?<!\w)(?:"
            r"automatic[ -]+stitch[ -]+(?:recognition|detection)|"
            r"automatische[ -]+maschenerkennung|"
            r"reconnaissance[ -]+automatique[ -]+des[ -]+mailles"
            r")(?!\w)|"
            r"自動辨識針目|自动识别针目|"
            r"編み目の自動認識|自動編み目認識"
        ),
    ),
    (
        "subscription",
        re.compile(
            r"(?<!\w)(?:subscriptions?|abonnements?)(?!\w)|"
            r"訂閱|订阅|サブスクリプション|定期購入"
        ),
    ),
    (
        "social network",
        re.compile(
            r"(?<!\w)(?:"
            r"social[ -]+network(?:s|ing)?|"
            r"sozial(?:e|er|es|en)[ -]+netzwerk(?:e)?|"
            r"réseaux?[ -]+(?:social|sociaux)"
            r")(?!\w)|"
            r"社群網路|社交網路|社交网络|"
            r"ソーシャルネットワーク"
        ),
    ),
    (
        "marketplace",
        re.compile(
            r"(?<!\w)(?:"
            r"market[ -]*places?|marktpl(?:atz|ätze)|"
            r"places?[ -]+de[ -]+marché"
            r")(?!\w)|"
            r"市集|商城|市場平台|市场平台|マーケットプレイス"
        ),
    ),
)
EXPECTED_LOCALES = (
    "en-US.md",
    "zh-Hant.md",
    "zh-Hans.md",
    "de-DE.md",
    "fr-FR.md",
    "ja-JP.md",
)
FIELD = re.compile(r"^- ([^:]+):\s*(.*)$")
CLAIM_WHITESPACE = re.compile(r"\s+")
CLAIM_DASH = re.compile(r"[\u2010-\u2015\u2212]")


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


def normalized_claim_text(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    normalized = CLAIM_DASH.sub("-", normalized)
    return CLAIM_WHITESPACE.sub(" ", normalized)


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

    name_value = fields.get("Name", "")
    name_length = len(unicodedata.normalize("NFKC", name_value))
    if name_value and name_length < 2:
        errors.append(f"{path}: Name: {name_length} character; minimum is 2")

    keyword_values = [item.strip() for item in fields.get("Keywords", "").split(",")]
    for keyword in keyword_values:
        keyword_length = len(unicodedata.normalize("NFKC", keyword))
        if keyword and keyword_length < 2:
            errors.append(
                f"{path}: Keywords: keyword '{keyword}' has "
                f"{keyword_length} character; minimum is 2"
            )

    keywords = [
        unicodedata.normalize("NFC", item.strip()).casefold()
        for item in fields.get("Keywords", "").split(",")
    ]
    duplicates = sorted({item for item in keywords if item and keywords.count(item) > 1})
    if duplicates:
        errors.append(f"{path}: Keywords: duplicates: {', '.join(duplicates)}")

    searchable = normalized_claim_text("\n".join(fields.values()))
    for concept, pattern in FORBIDDEN_PATTERNS:
        if pattern.search(searchable):
            errors.append(f"{path}: copy: forbidden release claim: {concept}")

    for name in ("Support URL", "Marketing URL", "Privacy URL"):
        value = fields.get(name, "")
        if value and not value.startswith("https://"):
            errors.append(f"{path}: {name}: must use HTTPS")
    return errors


def main() -> int:
    if len(sys.argv) > 2:
        print("usage: metadata_check.py AppStore/Metadata", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]) if len(sys.argv) == 2 else Path("AppStore/Metadata")
    paths = [root / filename for filename in EXPECTED_LOCALES]
    errors = [error for path in paths for error in validate(path)]
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("METADATA CHECK: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
