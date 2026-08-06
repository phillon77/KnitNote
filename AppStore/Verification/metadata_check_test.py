from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from AppStore.Verification.metadata_check import validate


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
METADATA = REPOSITORY_ROOT / "AppStore" / "Metadata"
EXPECTED_LOCALES = (
    "en-US.md",
    "zh-Hant.md",
    "zh-Hans.md",
    "de-DE.md",
    "fr-FR.md",
    "ja-JP.md",
)


class MetadataLocaleTests(unittest.TestCase):
    def test_every_v140_locale_is_valid(self) -> None:
        for filename in EXPECTED_LOCALES:
            with self.subTest(filename=filename):
                self.assertEqual(validate(METADATA / filename), [])

    def test_cli_rejects_a_directory_missing_any_v140_locale(self) -> None:
        checker = Path(__file__).with_name("metadata_check.py")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for filename in ("en-US.md", "zh-Hant.md"):
                (root / filename).write_text(
                    (METADATA / filename).read_text(encoding="utf-8"),
                    encoding="utf-8",
                )

            result = subprocess.run(
                [sys.executable, str(checker), str(root)],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        for filename in ("zh-Hans.md", "de-DE.md", "fr-FR.md", "ja-JP.md"):
            with self.subTest(filename=filename):
                self.assertIn(filename, result.stderr)


class MetadataValidationTests(unittest.TestCase):
    def test_every_store_field_is_required(self) -> None:
        required = (
            "Name",
            "Subtitle",
            "Promotional text",
            "Keywords",
            "Support URL",
            "Marketing URL",
            "Privacy URL",
            "What's New",
            "Description",
        )
        for field in required:
            with self.subTest(field=field):
                path = self.write_metadata(**{field: ""})
                self.assertIn(
                    f"{path}: {field}: required non-empty field",
                    validate(path),
                )

    def test_every_store_url_must_use_https(self) -> None:
        for field in ("Support URL", "Marketing URL", "Privacy URL"):
            with self.subTest(field=field):
                path = self.write_metadata(**{field: "http://example.com"})
                self.assertIn(
                    f"{path}: {field}: must use HTTPS",
                    validate(path),
                )

    def test_apple_character_and_keyword_byte_limits_are_enforced(self) -> None:
        cases = (
            ("Name", "編" * 30, "編" * 31, "31 characters; limit is 30"),
            ("Subtitle", "編" * 30, "編" * 31, "31 characters; limit is 30"),
            (
                "Promotional text",
                "編" * 170,
                "編" * 171,
                "171 characters; limit is 170",
            ),
            (
                "Keywords",
                "é" * 50,
                "é" * 51,
                "102 UTF-8 bytes; limit is 100",
            ),
            (
                "What's New",
                "編" * 4_000,
                "編" * 4_001,
                "4001 characters; limit is 4000",
            ),
            (
                "Description",
                "編" * 4_000,
                "編" * 4_001,
                "4001 characters; limit is 4000",
            ),
        )
        for field, boundary, over_limit, expected_error in cases:
            with self.subTest(field=field, length="boundary"):
                self.assertEqual(validate(self.write_metadata(**{field: boundary})), [])
            with self.subTest(field=field, length="over"):
                errors = validate(self.write_metadata(**{field: over_limit}))
                self.assertTrue(
                    any(expected_error in error for error in errors),
                    errors,
                )

    def test_apple_name_and_individual_keyword_minimums_are_enforced(self) -> None:
        one_character_name = self.write_metadata(Name="K")
        self.assertIn(
            f"{one_character_name}: Name: 1 character; minimum is 2",
            validate(one_character_name),
        )
        decomposed_one_character_name = self.write_metadata(Name="e\u0301")
        self.assertIn(
            f"{decomposed_one_character_name}: Name: 1 character; minimum is 2",
            validate(decomposed_one_character_name),
        )
        self.assertEqual(validate(self.write_metadata(Name="KN")), [])

        for one_character, two_characters in (
            ("x", "xy"),
            ("編", "編織"),
            ("e\u0301", "ée"),
        ):
            with self.subTest(keyword=one_character):
                path = self.write_metadata(Keywords=f"{one_character},pattern")
                self.assertIn(
                    f"{path}: Keywords: keyword '{one_character}' has 1 character; minimum is 2",
                    validate(path),
                )
                self.assertEqual(
                    validate(self.write_metadata(Keywords=f"{two_characters},pattern")),
                    [],
                )

    def test_forbidden_claim_variants_are_normalized_and_bounded(self) -> None:
        claims = (
            ("AI translation", "en", "AI-powered translation"),
            ("AI translation", "zh-Hant", "ＡＩ 翻譯"),
            ("AI translation", "zh-Hans", "人工智能翻译"),
            ("AI translation", "de", "KI–Übersetzung"),
            ("AI translation", "fr", "traduction\u00a0par\u00a0IA"),
            ("AI translation", "ja", "ＡＩ翻訳"),
            ("AI translation", "en", "AI translations"),
            ("AI translation", "en", "AI-powered translations"),
            ("AI translation", "de", "KI-gestützte Übersetzung"),
            ("AI translation", "fr", "traductions par IA"),
            ("AI translation", "ja", "AIによる翻訳"),
            ("cloud sync", "en", "cloud synchronization"),
            ("cloud sync", "zh-Hant", "雲端 同步"),
            ("cloud sync", "zh-Hans", "云端同步"),
            ("cloud sync", "de", "Cloud‑Synchronisation"),
            ("cloud sync", "fr", "synchronisation cloud"),
            ("cloud sync", "ja", "クラウド同期"),
            ("cloud sync", "en", "cloud syncing"),
            ("cloud sync", "en", "iCloud sync"),
            ("automatic stitch recognition", "en", "automatic stitch recognition"),
            ("automatic stitch recognition", "en", "automatic stitch detection"),
            ("automatic stitch recognition", "zh-Hant", "自動辨識針目"),
            ("automatic stitch recognition", "zh-Hans", "自动识别针目"),
            ("automatic stitch recognition", "de", "automatische Maschenerkennung"),
            ("automatic stitch recognition", "fr", "reconnaissance automatique des mailles"),
            ("automatic stitch recognition", "ja", "編み目の自動認識"),
            ("subscription", "en", "subscriptions"),
            ("subscription", "zh-Hant", "訂閱"),
            ("subscription", "zh-Hans", "订阅"),
            ("subscription", "de", "Abonnements"),
            ("subscription", "fr", "abonnements"),
            ("subscription", "ja", "サブスクリプション"),
            ("social network", "en", "social networking"),
            ("social network", "zh-Hant", "社群網路"),
            ("social network", "zh-Hans", "社交网络"),
            ("social network", "de", "soziales Netzwerk"),
            ("social network", "fr", "re\u0301seau social"),
            ("social network", "ja", "ソーシャルネットワーク"),
            ("marketplace", "en", "market place"),
            ("marketplace", "zh-Hant", "編織市集"),
            ("marketplace", "zh-Hans", "编织商城"),
            ("marketplace", "de", "Marktplatz"),
            ("marketplace", "fr", "place de marché"),
            ("marketplace", "ja", "マーケットプレイス"),
        )
        for concept, locale, claim in claims:
            with self.subTest(concept=concept, locale=locale, claim=claim):
                path = self.write_metadata(Description=claim)
                self.assertIn(
                    f"{path}: copy: forbidden release claim: {concept}",
                    validate(path),
                )

        safe_copy = (
            "Translations are manual. Apple Watch syncing is supported. "
            "Export a file to iCloud Drive. Detect a dropped stitch manually. "
            "KI-gestützte Diagramme and AIによる検索 are not translation claims. "
            "Detailed maille notes make this a marketable companion."
        )
        self.assertEqual(validate(self.write_metadata(Description=safe_copy)), [])

    def test_duplicate_keywords_are_compared_with_unicode_normalization(self) -> None:
        path = self.write_metadata(Keywords="tricot,échantillon,e\u0301chantillon")

        self.assertIn(
            f"{path}: Keywords: duplicates: échantillon",
            validate(path),
        )

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.fixture_index = 0

    def write_metadata(self, **overrides: str) -> Path:
        fields = {
            "Name": "KnitNote",
            "Subtitle": "Knitting counter",
            "Promotional text": "Count rows and read patterns.",
            "Keywords": "knitting,yarn,pattern",
            "Support URL": "https://example.com/support",
            "Marketing URL": "https://example.com",
            "Privacy URL": "https://example.com/privacy",
            "What's New": "Localized interface.",
            "Description": "A knitting project companion.",
        }
        fields.update(overrides)
        self.fixture_index += 1
        path = Path(self.temporary_directory.name) / f"metadata-{self.fixture_index}.md"
        lines = [
            "# Metadata fixture",
            "",
            *(f"- {name}: {value}" for name, value in fields.items()),
        ]
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path


if __name__ == "__main__":
    unittest.main()
