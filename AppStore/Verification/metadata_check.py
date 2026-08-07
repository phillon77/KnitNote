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
            r"traductions?[ -]+(?:par[ -]+)?ia|ia[ -]+traduction|"
            r"automatisk[ -]+oversettelse|ki[ -]+oversettelse|"
            r"automatisk[ -]+översättning|ai[ -]+översättning|"
            r"automaattinen[ -]+käännös|tekoälykäännös|"
            r"automatisk[ -]+oversættelse|ai[ -]+oversættelse|"
            r"αυτόματη[ -]+μετάφραση|"
            r"μετάφραση[ -]+με[ -]+τεχνητή[ -]+νοημοσύνη"
            r")(?!\w)|"
            r"(?:ai[ -]*(?:翻譯|翻译|翻訳|による[ -]*翻訳)|"
            r"(?:人工智慧|人工智能|人工知能)[ -]*(?:翻譯|翻译|翻訳)|"
            r"(?:자동|인공지능)[ -]*번역)"
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
            r"(?<!\w)(?:"
            r"subscriptions?|abonnements?|prenumeration|tilaus|συνδρομή"
            r")(?!\w)|"
            r"訂閱|订阅|サブスクリプション|定期購入|구독"
        ),
    ),
    (
        "trial/free",
        re.compile(
            r"(?<!\w)(?:"
            r"gratis|prøveperiode|provperiod|ilmainen|ilmaiseksi|kokeilujakso|"
            r"δωρεάν|δοκιμαστική[ -]+περίοδοσ"
            r")(?!\w)|(?:무료(?:[ -]*체험)?|체험[ -]*기간)"
        ),
    ),
    (
        "price",
        re.compile(
            r"(?<!\w)(?:pris|hinta|τιμή)(?!\w)|가격"
        ),
    ),
    (
        "purchase",
        re.compile(
            r"(?<!\w)(?:kjøp|köp|osto|køb|αγορά)(?!\w)|구매"
        ),
    ),
    (
        "cloud/remote service",
        re.compile(
            r"(?<!\w)(?:"
            r"skysynkronisering|molnsynkronisering|pilvisynkronointi|"
            r"fjärrtjänst|etäpalvelu|ekstern[ -]+tjeneste|"
            r"συγχρονισμόσ[ -]+στο[ -]+(?:cloud|νέφοσ)|"
            r"απομακρυσμένη[ -]+υπηρεσία"
            r")(?!\w)|(?:클라우드[ -]*동기화|원격[ -]*서비스)"
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
    (
        "Share system-only language",
        re.compile(
            r"(?:share[ -]+extension|sharing[ -]+screens?).{0,120}"
            r"uses?.{0,40}system[ -]+(?:language|locale)|"
            r"(?:teilen-erweiterung|ansichten[ -]+zum[ -]+teilen).{0,120}"
            r"verwend(?:et|en).{0,30}systemsprache|"
            r"(?:extension[ -]+de[ -]+partage|écrans?[ -]+de[ -]+partage).{0,120}"
            r"utilise(?:nt)?.{0,30}langue[ -]+du[ -]+système|"
            r"共有画面.{0,80}システムの言語で表示|"
            r"(?:分享扩展|分享界面).{0,80}(?:按|使用).{0,30}系统语言.{0,20}显示|"
            r"(?:分享延伸功能|分享畫面).{0,80}依.{0,30}系統語言.{0,20}顯示|"
            r"(?:delingsutvidelsen|delingsvisningene).{0,120}systemspråket|"
            r"(?:delningstillägget|delningsvyerna).{0,120}systemspråket|"
            r"(?:jakolaajennus|jakonäkymät).{0,120}järjestelmän[ -]+kieltä|"
            r"(?:delingsudvidelsen|delingsvisningerne).{0,120}systemets[ -]+sprog|"
            r"(?:공유[ -]+확장[ -]+프로그램|공유[ -]+화면).{0,80}시스템[ -]+언어|"
            r"(?:επέκταση|προβολέσ)[ -]+κοινήσ[ -]+χρήσησ.{0,120}"
            r"γλώσσα[ -]+του[ -]+συστήματοσ"
        ),
    ),
)
V140_LOCALES = (
    "en-US.md",
    "zh-Hant.md",
    "zh-Hans.md",
    "de-DE.md",
    "fr-FR.md",
    "ja-JP.md",
)
EXPECTED_LOCALES = V140_LOCALES + (
    "nb-NO.md",
    "sv-SE.md",
    "fi-FI.md",
    "da-DK.md",
    "ko-KR.md",
    "el-GR.md",
)
LANGUAGE_CONTRACTS = {
    "en-US.md": {
        "languages": (
            "English", "Traditional Chinese", "Simplified Chinese", "German", "French", "Japanese",
            "Norwegian Bokmål", "Swedish", "Finnish", "Danish", "Korean", "Greek",
        ),
        "surfaces": ("Settings", "Apple Watch", "sharing"),
    },
    "zh-Hant.md": {
        "languages": (
            "英文", "繁體中文", "簡體中文", "德文", "法文", "日文",
            "挪威博克馬爾文", "瑞典文", "芬蘭文", "丹麥文", "韓文", "希臘文",
        ),
        "surfaces": ("設定", "Apple Watch", "分享"),
    },
    "zh-Hans.md": {
        "languages": (
            "英语", "繁体中文", "简体中文", "德语", "法语", "日语",
            "挪威博克马尔语", "瑞典语", "芬兰语", "丹麦语", "韩语", "希腊语",
        ),
        "surfaces": ("设置", "Apple Watch", "分享"),
    },
    "de-DE.md": {
        "languages": (
            "Englisch", "traditionelles Chinesisch", "vereinfachtes Chinesisch", "Deutsch",
            "Französisch", "Japanisch", "Norwegisch (Bokmål)", "Schwedisch", "Finnisch",
            "Dänisch", "Koreanisch", "Griechisch",
        ),
        "surfaces": ("Einstellungen", "Apple Watch", "Teilen"),
    },
    "fr-FR.md": {
        "languages": (
            "anglais", "chinois traditionnel", "chinois simplifié", "allemand", "français",
            "japonais", "norvégien bokmål", "suédois", "finnois", "danois", "coréen", "grec",
        ),
        "surfaces": ("réglages", "Apple Watch", "partage"),
    },
    "ja-JP.md": {
        "languages": (
            "英語", "繁体字中国語", "簡体字中国語", "ドイツ語", "フランス語", "日本語",
            "ノルウェー語（ブークモール）", "スウェーデン語", "フィンランド語", "デンマーク語", "韓国語", "ギリシャ語",
        ),
        "surfaces": ("設定", "Apple Watch", "共有"),
    },
    "nb-NO.md": {
        "languages": (
            "engelsk", "tradisjonell kinesisk", "forenklet kinesisk", "tysk", "fransk", "japansk",
            "norsk bokmål", "svensk", "finsk", "dansk", "koreansk", "gresk",
        ),
        "surfaces": ("innstillingene", "Apple Watch", "delings"),
    },
    "sv-SE.md": {
        "languages": (
            "engelska", "traditionell kinesiska", "förenklad kinesiska", "tyska", "franska",
            "japanska", "norskt bokmål", "svenska", "finska", "danska", "koreanska", "grekiska",
        ),
        "surfaces": ("inställningarna", "Apple Watch", "delnings"),
    },
    "fi-FI.md": {
        "languages": (
            "englanti", "perinteinen kiina", "yksinkertaistettu kiina", "saksa", "ranska", "japani",
            "norjan bokmål", "ruotsi", "suomi", "tanska", "korea", "kreikka",
        ),
        "surfaces": ("asetuksissa", "Apple Watch", "jakonäkym"),
    },
    "da-DK.md": {
        "languages": (
            "engelsk", "traditionelt kinesisk", "forenklet kinesisk", "tysk", "fransk", "japansk",
            "norsk bokmål", "svensk", "finsk", "dansk", "koreansk", "græsk",
        ),
        "surfaces": ("indstillingerne", "Apple Watch", "delings"),
    },
    "ko-KR.md": {
        "languages": (
            "영어", "중국어 번체", "중국어 간체", "독일어", "프랑스어", "일본어",
            "노르웨이어(보크몰)", "스웨덴어", "핀란드어", "덴마크어", "한국어", "그리스어",
        ),
        "surfaces": ("설정", "Apple Watch", "공유"),
    },
    "el-GR.md": {
        "languages": (
            "αγγλικά", "παραδοσιακά κινεζικά", "απλοποιημένα κινεζικά", "γερμανικά",
            "γαλλικά", "ιαπωνικά", "νορβηγικά μποκμάλ", "σουηδικά", "φινλανδικά",
            "δανικά", "κορεατικά", "ελληνικά",
        ),
        "surfaces": ("ρυθμίσεις", "Apple Watch", "κοινής χρήσης"),
    },
}
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
        if keyword and keyword_length < 3:
            unit = "character" if keyword_length == 1 else "characters"
            errors.append(
                f"{path}: Keywords: keyword '{keyword}' has "
                f"{keyword_length} {unit}; minimum is 3"
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

    contract = LANGUAGE_CONTRACTS.get(path.name)
    if contract is not None:
        whats_new = fields.get("What's New", "")
        description = fields.get("Description", "")
        versions = re.findall(r"(?<![0-9])1\.\d+(?:\.\d+)?(?![0-9])", whats_new)
        if versions != ["1.4.1"]:
            errors.append(f"{path}: What's New: must identify KnitNote 1.4.1 exactly")
        for language in contract["languages"][6:]:
            if language.casefold() not in whats_new.casefold():
                errors.append(f"{path}: What's New: missing added language: {language}")
        for language in contract["languages"]:
            if language.casefold() not in description.casefold():
                errors.append(f"{path}: Description: missing supported language: {language}")
        for token in contract["surfaces"]:
            if token.casefold() not in description.casefold():
                errors.append(
                    f"{path}: Description: missing Settings/Watch/Share contract token: {token}"
                )
    return errors


def main() -> int:
    if len(sys.argv) > 2:
        print("usage: metadata_check.py AppStore/Metadata", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]) if len(sys.argv) == 2 else Path("AppStore/Metadata")
    expected = set(EXPECTED_LOCALES)
    actual = {
        path.name
        for path in root.iterdir()
        if path.is_file() and path.suffix == ".md"
    } if root.is_dir() else set()
    errors = [
        f"{root}: missing metadata locale package: {filename}"
        for filename in sorted(expected - actual)
    ]
    errors.extend(
        f"{root}: unexpected metadata locale package: {filename}"
        for filename in sorted(actual - expected)
    )
    paths = [root / filename for filename in EXPECTED_LOCALES if filename in actual]
    errors.extend(error for path in paths for error in validate(path))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("METADATA CHECK: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
