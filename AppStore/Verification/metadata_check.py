#!/usr/bin/env python3
"""Validate the repository-owned App Store metadata sources."""

from __future__ import annotations

import hashlib
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
CALCULATOR_REQUIRED = ("Copyright", "Apple ID")
EXPECTED_COPYRIGHT = "© 2026 Chen Chung Lung"
EXPECTED_APPLE_ID = "6795877892"
GENERAL_METADATA_FILENAMES: tuple[str, ...] = ("zh-Hant.md", "en-US.md")
CALCULATOR_METADATA_FILENAMES: tuple[str, ...] = (
    "en-US.md",
    "zh-Hant.md",
    "zh-Hans.md",
    "de-DE.md",
    "fr-FR.md",
    "ja-JP.md",
    "ko-KR.md",
    "nl-NL.md",
    "nb-NO.md",
    "sv-SE.md",
    "fi-FI.md",
    "da-DK.md",
    "el-GR.md",
)
CALCULATOR_WHATS_NEW: dict[str, str] = {
    "en-US.md": "Version 1.0.1 adds support for Simplified Chinese, German, French, Japanese, Korean, Dutch, Norwegian Bokmål, Swedish, Finnish, Danish, and Greek.",
    "zh-Hant.md": "1.0.1 版新增簡體中文、德文、法文、日文、韓文、荷蘭文、挪威書面語、瑞典文、芬蘭文、丹麥文與希臘文支援。",
    "zh-Hans.md": "1.0.1 版新增简体中文、德语、法语、日语、韩语、荷兰语、挪威书面语、瑞典语、芬兰语、丹麦语和希腊语支持。",
    "de-DE.md": "Version 1.0.1 unterstützt jetzt vereinfachtes Chinesisch, Deutsch, Französisch, Japanisch, Koreanisch, Niederländisch, Norwegisch (Bokmål), Schwedisch, Finnisch, Dänisch und Griechisch.",
    "fr-FR.md": "La version 1.0.1 est maintenant disponible en chinois simplifié, allemand, français, japonais, coréen, néerlandais, norvégien bokmål, suédois, finnois, danois et grec.",
    "ja-JP.md": "バージョン 1.0.1 では、簡体字中国語、ドイツ語、フランス語、日本語、韓国語、オランダ語、ノルウェー語（ブークモール）、スウェーデン語、フィンランド語、デンマーク語、ギリシャ語に対応しました。",
    "ko-KR.md": "1.0.1 버전부터 간체 중국어, 독일어, 프랑스어, 일본어, 한국어, 네덜란드어, 노르웨이어(보크몰), 스웨덴어, 핀란드어, 덴마크어, 그리스어를 지원합니다.",
    "nl-NL.md": "Versie 1.0.1 ondersteunt nu vereenvoudigd Chinees, Duits, Frans, Japans, Koreaans, Nederlands, Noors (Bokmål), Zweeds, Fins, Deens en Grieks.",
    "nb-NO.md": "Versjon 1.0.1 støtter nå forenklet kinesisk, tysk, fransk, japansk, koreansk, nederlandsk, norsk bokmål, svensk, finsk, dansk og gresk.",
    "sv-SE.md": "Version 1.0.1 har nu stöd för förenklad kinesiska, tyska, franska, japanska, koreanska, nederländska, norskt bokmål, svenska, finska, danska och grekiska.",
    "fi-FI.md": "Versio 1.0.1 tukee nyt kiinaa (yksinkertaistettu), saksaa, ranskaa, japania, koreaa, hollantia, norjan bokmålia, ruotsia, suomea, tanskaa ja kreikkaa.",
    "da-DK.md": "Version 1.0.1 understøtter nu forenklet kinesisk, tysk, fransk, japansk, koreansk, hollandsk, norsk bokmål, svensk, finsk, dansk og græsk.",
    "el-GR.md": "Η έκδοση 1.0.1 υποστηρίζει πλέον απλοποιημένα κινεζικά, γερμανικά, γαλλικά, ιαπωνικά, κορεατικά, ολλανδικά, νορβηγικά μποκμάλ, σουηδικά, φινλανδικά, δανικά και ελληνικά.",
}
CALCULATOR_CLAIM_FIELDS = (
    "Name",
    "Subtitle",
    "Promotional text",
    "Keywords",
    "Description",
    "Review Notes",
    "Territory positioning",
)
# These fingerprints lock the human-reviewed, locale-specific semantic copy.
# Release notes, URLs, and identity fields have separate explicit contracts.
CALCULATOR_APPROVED_CLAIM_DIGESTS: dict[str, str] = {
    "en-US.md": "3ade17be85f1e56bef7d942cf388adb5a7aeeae5d5a32bcdc3654b4b3c4943c0",
    "zh-Hant.md": "67bffdb34372fe464348d7de117ff9fcca4dc60ddacfbabb93f4d8b9789ece1a",
    "zh-Hans.md": "0494d013b682ee677d39c19b745ebda6f41de6b0c7ff66e766fd30c4332414ce",
    "de-DE.md": "78c9da729033018971d953cd5c1d8f41504ec30005b04eb6dd24f5b1e41165ca",
    "fr-FR.md": "61b734baf5efc1dd55ca4071381f4787d440b61582b4dd10249e436f6eb2efef",
    "ja-JP.md": "378267ab9ddb00b6f0e3573ed9782bdb99822e6ff2b184a95d31bdb59b0857f4",
    "ko-KR.md": "20743c3c83899d2ba15d55aff66b4b5be71cc5aa7d094cbf2fedd2f7415e25c7",
    "nl-NL.md": "b43a1e170043aff969c29db48f59eb48722107af475015465c37bd988790f1ce",
    "nb-NO.md": "ddb9a5340468aa4593c6cce004c36e8c4a54d5247439c8aea0b71958de63a509",
    "sv-SE.md": "d054f8b94e99c05f7a999fba9bd8f6524dc911d07553bc28a410c1613d46f857",
    "fi-FI.md": "dcc90a3a56d553911b9be45f66bd21395f4019cddaa00a77144194325e0e3d54",
    "da-DK.md": "036698e4ad2c2b5f640b84e6257e4e1327175fddd0a1bb62e29858dd5088288c",
    "el-GR.md": "d36abc5cc481786f2c103c8ef11162f7dc18b8fce1ea503cf714918a9523f12f",
}
FORBIDDEN = (
    " ai ",
    "cloud sync",
    "automatic stitch recognition",
    "social network",
    "marketplace",
    "subscription",
)
FIELD = re.compile(r"^- ([^:]+):\s*(.*)$")


def normalized(value: str) -> str:
    return "".join(character for character in value.casefold() if character.isalnum())


def calculator_claim_digest(fields: dict[str, str]) -> str:
    approved_copy = "\x1f".join(
        f"{name}\x1e{fields.get(name, '')}" for name in CALCULATOR_CLAIM_FIELDS
    )
    return hashlib.sha256(approved_copy.encode("utf-8")).hexdigest()


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


def is_calculator_metadata(path: Path) -> bool:
    return (
        path.parent.name == "Metadata"
        and path.parent.parent.name == "KnittingCalculator"
    )


def validate(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        fields = parse(path)
    except (OSError, UnicodeError) as error:
        return [f"{path}: file: {error}"]

    calculator_metadata = is_calculator_metadata(path)
    required = REQUIRED + (CALCULATOR_REQUIRED if calculator_metadata else ())
    for name in required:
        if not fields.get(name):
            errors.append(f"{path}: {name}: required non-empty field")

    if (
        calculator_metadata
        and fields.get("Copyright")
        and fields["Copyright"] != EXPECTED_COPYRIGHT
    ):
        errors.append(f"{path}: Copyright: must be {EXPECTED_COPYRIGHT}")
    if (
        calculator_metadata
        and fields.get("Apple ID")
        and fields["Apple ID"] != EXPECTED_APPLE_ID
    ):
        errors.append(f"{path}: Apple ID: must be {EXPECTED_APPLE_ID}")

    approved_whats_new = CALCULATOR_WHATS_NEW.get(path.name) if calculator_metadata else None
    if approved_whats_new and fields.get("What's New") != approved_whats_new:
        errors.append(
            f"{path}: What's New: must contain only the approved 1.0.1 language expansion"
        )

    approved_claim_digest = (
        CALCULATOR_APPROVED_CLAIM_DIGESTS.get(path.name) if calculator_metadata else None
    )
    if approved_claim_digest and calculator_claim_digest(fields) != approved_claim_digest:
        errors.append(f"{path}: copy: does not match approved localized claims")

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

    reserved = "".join(
        normalized(fields.get(name, ""))
        for name in ("Name", "Subtitle", "Primary Category", "Secondary Category")
    )
    repeated = [keyword for keyword in keywords if keyword and normalized(keyword) in reserved]
    if repeated:
        errors.append(
            f"{path}: Keywords: repeats Name, Subtitle, or category term: {', '.join(repeated)}"
        )

    searchable = " " + "\n".join(fields.values()).casefold() + " "
    searchable = searchable.replace("no subscription", "")
    for phrase in FORBIDDEN:
        if phrase in searchable:
            errors.append(f"{path}: copy: forbidden release claim: {phrase.strip()}")

    for name in ("Support URL", "Privacy URL"):
        value = fields.get(name, "")
        if value and not value.startswith("https://"):
            errors.append(f"{path}: {name}: must use HTTPS")
    return errors


def validate_root(root: Path) -> list[str]:
    if root.name != "Metadata" or root.parent.name != "KnittingCalculator":
        established = [root / name for name in GENERAL_METADATA_FILENAMES]
        additional = sorted(
            path
            for path in root.glob("*.md")
            if path.name not in GENERAL_METADATA_FILENAMES
        )
        return [error for path in established + additional for error in validate(path)]

    expected = set(CALCULATOR_METADATA_FILENAMES)
    actual = {path.name for path in root.glob("*.md")}
    errors: list[str] = []
    if missing := sorted(expected - actual):
        errors.append(f"{root}: missing metadata locales: {', '.join(missing)}")
    if extra := sorted(actual - expected):
        errors.append(f"{root}: unexpected metadata locales: {', '.join(extra)}")
    errors.extend(
        error
        for name in sorted(expected & actual)
        for error in validate(root / name)
    )
    return errors


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: metadata_check.py AppStore/Metadata", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    errors = validate_root(root)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("METADATA CHECK: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
