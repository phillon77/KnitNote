from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from AppStore.Verification.metadata_check import parse, validate


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
METADATA = REPOSITORY_ROOT / "AppStore" / "Metadata"
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
LANGUAGE_NAMES = {
    "en-US.md": (
        "English", "Traditional Chinese", "Simplified Chinese", "German", "French", "Japanese",
        "Norwegian Bokmål", "Swedish", "Finnish", "Danish", "Korean", "Greek",
    ),
    "zh-Hant.md": (
        "英文", "繁體中文", "簡體中文", "德文", "法文", "日文",
        "挪威博克馬爾文", "瑞典文", "芬蘭文", "丹麥文", "韓文", "希臘文",
    ),
    "zh-Hans.md": (
        "英语", "繁体中文", "简体中文", "德语", "法语", "日语",
        "挪威博克马尔语", "瑞典语", "芬兰语", "丹麦语", "韩语", "希腊语",
    ),
    "de-DE.md": (
        "Englisch", "traditionelles Chinesisch", "vereinfachtes Chinesisch", "Deutsch",
        "Französisch", "Japanisch", "Norwegisch (Bokmål)", "Schwedisch", "Finnisch",
        "Dänisch", "Koreanisch", "Griechisch",
    ),
    "fr-FR.md": (
        "anglais", "chinois traditionnel", "chinois simplifié", "allemand", "français",
        "japonais", "norvégien bokmål", "suédois", "finnois", "danois", "coréen", "grec",
    ),
    "ja-JP.md": (
        "英語", "繁体字中国語", "簡体字中国語", "ドイツ語", "フランス語", "日本語",
        "ノルウェー語（ブークモール）", "スウェーデン語", "フィンランド語", "デンマーク語", "韓国語", "ギリシャ語",
    ),
    "nb-NO.md": (
        "engelsk", "tradisjonell kinesisk", "forenklet kinesisk", "tysk", "fransk", "japansk",
        "norsk bokmål", "svensk", "finsk", "dansk", "koreansk", "gresk",
    ),
    "sv-SE.md": (
        "engelska", "traditionell kinesiska", "förenklad kinesiska", "tyska", "franska",
        "japanska", "norskt bokmål", "svenska", "finska", "danska", "koreanska", "grekiska",
    ),
    "fi-FI.md": (
        "englanti", "perinteinen kiina", "yksinkertaistettu kiina", "saksa", "ranska", "japani",
        "norjan bokmål", "ruotsi", "suomi", "tanska", "korea", "kreikka",
    ),
    "da-DK.md": (
        "engelsk", "traditionelt kinesisk", "forenklet kinesisk", "tysk", "fransk", "japansk",
        "norsk bokmål", "svensk", "finsk", "dansk", "koreansk", "græsk",
    ),
    "ko-KR.md": (
        "영어", "중국어 번체", "중국어 간체", "독일어", "프랑스어", "일본어",
        "노르웨이어(보크몰)", "스웨덴어", "핀란드어", "덴마크어", "한국어", "그리스어",
    ),
    "el-GR.md": (
        "αγγλικά", "παραδοσιακά κινεζικά", "απλοποιημένα κινεζικά", "γερμανικά",
        "γαλλικά", "ιαπωνικά", "νορβηγικά μποκμάλ", "σουηδικά", "φινλανδικά",
        "δανικά", "κορεατικά", "ελληνικά",
    ),
}
SETTINGS_AND_SURFACE_TOKENS = {
    "en-US.md": ("Settings", "Apple Watch", "sharing"),
    "zh-Hant.md": ("設定", "Apple Watch", "分享"),
    "zh-Hans.md": ("设置", "Apple Watch", "分享"),
    "de-DE.md": ("Einstellungen", "Apple Watch", "Teilen"),
    "fr-FR.md": ("réglages", "Apple Watch", "partage"),
    "ja-JP.md": ("設定", "Apple Watch", "共有"),
    "nb-NO.md": ("innstillingene", "Apple Watch", "delings"),
    "sv-SE.md": ("inställningarna", "Apple Watch", "delnings"),
    "fi-FI.md": ("asetuksissa", "Apple Watch", "jakonäkym"),
    "da-DK.md": ("indstillingerne", "Apple Watch", "delings"),
    "ko-KR.md": ("설정", "Apple Watch", "공유"),
    "el-GR.md": ("ρυθμίσεις", "Apple Watch", "κοινής χρήσης"),
}
DELETION_PROTECTION_COPY = {
    "en-US.md": "Completed projects are now protected from accidental deletion; restore one to in progress before deleting it.",
    "zh-Hant.md": "已完成作品現在有防誤刪保護；如需刪除，請先恢復為進行中。",
    "zh-Hans.md": "已完成作品现在有防误删保护；如需删除，请先恢复为进行中。",
    "de-DE.md": "Abgeschlossene Projekte sind jetzt vor versehentlichem Löschen geschützt. Setze ein Projekt vor dem Löschen zuerst auf „In Bearbeitung“ zurück.",
    "fr-FR.md": "Les projets terminés sont désormais protégés contre les suppressions accidentelles. Remettez-les en cours avant de les supprimer.",
    "ja-JP.md": "完了した作品の誤削除を防ぐ保護を追加しました。削除するには、先に「進行中」に戻してください。",
    "nb-NO.md": "Fullførte prosjekter er nå beskyttet mot utilsiktet sletting. Gjenoppta et prosjekt før du sletter det.",
    "sv-SE.md": "Slutförda projekt skyddas nu mot oavsiktlig radering. Återuppta ett projekt innan du tar bort det.",
    "fi-FI.md": "Valmiit projektit on nyt suojattu tahattomalta poistamiselta. Jatka projektia ennen kuin poistat sen.",
    "da-DK.md": "Afsluttede projekter er nu beskyttet mod utilsigtet sletning. Genoptag et projekt, før du sletter det.",
    "ko-KR.md": "완료된 프로젝트를 실수로 삭제하지 않도록 보호합니다. 삭제하려면 먼저 진행 중으로 되돌리세요.",
    "el-GR.md": "Τα ολοκληρωμένα έργα προστατεύονται πλέον από κατά λάθος διαγραφή. Επαναφέρετε πρώτα ένα έργο σε εξέλιξη για να το διαγράψετε.",
}
DELETED_PROJECT_RECOVERY_CLAIMS = {
    "en-US.md": "Deleted projects can be restored from Trash.",
    "zh-Hant.md": "已刪除的作品可從垃圾桶復原。",
    "zh-Hans.md": "已删除的作品可从废纸篓恢复。",
    "de-DE.md": "Gelöschte Projekte können aus dem Papierkorb wiederhergestellt werden.",
    "fr-FR.md": "Les projets supprimés peuvent être restaurés depuis la corbeille.",
    "ja-JP.md": "削除した作品はゴミ箱から復元できます。",
    "nb-NO.md": "Slettede prosjekter kan gjenopprettes fra papirkurven.",
    "sv-SE.md": "Borttagna projekt kan återställas från papperskorgen.",
    "fi-FI.md": "Poistetut projektit voidaan palauttaa roskakorista.",
    "da-DK.md": "Slettede projekter kan gendannes fra papirkurven.",
    "ko-KR.md": "삭제된 프로젝트는 휴지통에서 복원할 수 있습니다.",
    "el-GR.md": "Τα διαγραμμένα έργα μπορούν να ανακτηθούν από τον κάδο απορριμμάτων.",
}


class MetadataLocaleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.fixture_index = 0

    def test_every_v141_locale_is_valid(self) -> None:
        for filename in EXPECTED_LOCALES:
            with self.subTest(filename=filename):
                self.assertEqual(validate(METADATA / filename), [])

    def test_every_package_describes_one_v141_twelve_language_settings_contract(self) -> None:
        for filename in EXPECTED_LOCALES:
            with self.subTest(filename=filename):
                fields = parse(METADATA / filename)
                whats_new = fields["What's New"]
                description = fields["Description"]
                self.assertEqual(
                    re.findall(r"(?<![0-9])1\.\d+(?:\.\d+)?(?![0-9])", whats_new),
                    ["1.4.1"],
                )
                for language in LANGUAGE_NAMES[filename][6:]:
                    self.assertIn(language, whats_new)
                for language in LANGUAGE_NAMES[filename]:
                    self.assertIn(language, description)
                for token in SETTINGS_AND_SURFACE_TOKENS[filename]:
                    self.assertIn(token, description)

    def test_every_v141_whats_new_describes_completed_project_deletion_protection(self) -> None:
        for filename in EXPECTED_LOCALES:
            with self.subTest(filename=filename):
                whats_new = parse(METADATA / filename)["What's New"]
                self.assertIn(DELETION_PROTECTION_COPY[filename], whats_new)

    def test_validator_rejects_deleted_project_recovery_claims_in_every_locale(self) -> None:
        for filename in EXPECTED_LOCALES:
            with self.subTest(filename=filename):
                fields = parse(METADATA / filename)
                fields["What's New"] += " " + DELETED_PROJECT_RECOVERY_CLAIMS[filename]
                path = self.write_named_metadata(filename, fields)
                self.assertIn(
                    f"{path}: copy: forbidden release claim: deleted project recovery",
                    validate(path),
                )

    def test_validator_rejects_wrong_version_and_missing_language_semantics_for_every_package(self) -> None:
        for filename in EXPECTED_LOCALES:
            with self.subTest(filename=filename, mutation="version"):
                fields = parse(METADATA / filename)
                fields["What's New"] = fields["What's New"].replace("1.4.1", "1.4.0")
                path = self.write_named_metadata(filename, fields)
                self.assertTrue(
                    any("What's New: must identify KnitNote 1.4.1" in error for error in validate(path)),
                    validate(path),
                )
            with self.subTest(filename=filename, mutation="language"):
                fields = parse(METADATA / filename)
                missing = LANGUAGE_NAMES[filename][-1]
                fields["Description"] = fields["Description"].replace(missing, "")
                path = self.write_named_metadata(filename, fields)
                self.assertTrue(
                    any(f"Description: missing supported language: {missing}" in error for error in validate(path)),
                    validate(path),
                )

    def write_named_metadata(self, filename: str, fields: dict[str, str]) -> Path:
        root = Path(self.temporary_directory.name) / str(self.fixture_index)
        root.mkdir(parents=True)
        self.fixture_index += 1
        path = root / filename
        lines = ["# Metadata fixture", ""]
        for name, value in fields.items():
            if name == "Description":
                lines.append("- Description: |")
                lines.extend(f"  {line}" if line else "" for line in value.splitlines())
            else:
                lines.append(f"- {name}: {value}")
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    def test_cli_rejects_a_directory_missing_any_v141_locale(self) -> None:
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
        for filename in EXPECTED_LOCALES[2:]:
            with self.subTest(filename=filename):
                self.assertIn(filename, result.stderr)

    def test_cli_rejects_an_unexpected_locale_package(self) -> None:
        checker = Path(__file__).with_name("metadata_check.py")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for filename in EXPECTED_LOCALES:
                (root / filename).write_text(
                    (METADATA / filename).read_text(encoding="utf-8"),
                    encoding="utf-8",
                )
            (root / "es-ES.md").write_text(
                (METADATA / "en-US.md").read_text(encoding="utf-8"),
                encoding="utf-8",
            )

            result = subprocess.run(
                [sys.executable, str(checker), str(root)],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected metadata locale package: es-ES.md", result.stderr)


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

        for one_character, two_characters, three_characters in (
            ("x", "xy", "xyz"),
            ("編", "編織", "編織圖"),
            ("e\u0301", "e\u0301x", "e\u0301xy"),
        ):
            with self.subTest(keyword=one_character):
                path = self.write_metadata(Keywords=f"{one_character},pattern")
                self.assertIn(
                    f"{path}: Keywords: keyword '{one_character}' has 1 character; minimum is 3",
                    validate(path),
                )
            with self.subTest(keyword=two_characters):
                path = self.write_metadata(Keywords=f"{two_characters},pattern")
                self.assertIn(
                    f"{path}: Keywords: keyword '{two_characters}' has 2 characters; minimum is 3",
                    validate(path),
                )
            with self.subTest(keyword=three_characters):
                self.assertEqual(
                    validate(self.write_metadata(Keywords=f"{three_characters},pattern")),
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

    def test_share_system_only_language_claims_are_forbidden_in_every_locale(self) -> None:
        claims = (
            "The Share extension uses the system language.",
            "Die Teilen-Erweiterung verwendet die Systemsprache.",
            "L’extension de partage utilise la langue du système.",
            "共有画面はシステムの言語で表示されます。",
            "分享扩展按系统语言显示。",
            "分享延伸功能依系統語言顯示。",
        )

        for claim in claims:
            with self.subTest(claim=claim):
                path = self.write_metadata(Description=claim)
                self.assertIn(
                    f"{path}: copy: forbidden release claim: Share system-only language",
                    validate(path),
                )

    def test_v141_trial_and_free_claims_are_forbidden(self) -> None:
        claims = (
            ("nb", "Gratis"),
            ("nb", "Prøveperiode"),
            ("sv", "Gratis"),
            ("sv", "Provperiod"),
            ("fi", "Ilmainen"),
            ("fi", "Kokeilujakso"),
            ("da", "Gratis"),
            ("da", "Prøveperiode"),
            ("ko", "무료"),
            ("ko", "체험 기간"),
            ("el", "Δωρεάν"),
            ("el", "Δοκιμαστική περίοδος"),
        )
        self.assert_forbidden_claims("trial/free", claims)

    def test_v141_price_claims_are_forbidden(self) -> None:
        claims = (
            ("nb", "Pris"),
            ("sv", "Pris"),
            ("fi", "Hinta"),
            ("da", "Pris"),
            ("ko", "가격"),
            ("el", "Τιμή"),
        )
        self.assert_forbidden_claims("price", claims)

    def test_v141_purchase_claims_are_forbidden(self) -> None:
        claims = (
            ("nb", "Kjøp"),
            ("sv", "Köp"),
            ("fi", "Osto"),
            ("da", "Køb"),
            ("ko", "구매"),
            ("el", "Αγορά"),
        )
        self.assert_forbidden_claims("purchase", claims)

    def test_v141_subscription_claims_are_forbidden(self) -> None:
        claims = (
            ("nb", "Abonnement"),
            ("sv", "Prenumeration"),
            ("fi", "Tilaus"),
            ("da", "Abonnement"),
            ("ko", "구독"),
            ("el", "Συνδρομή"),
        )
        self.assert_forbidden_claims("subscription", claims)

    def test_v141_automatic_and_ai_translation_claims_are_forbidden(self) -> None:
        claims = (
            ("nb", "Automatisk oversettelse"),
            ("nb", "KI-oversettelse"),
            ("sv", "Automatisk översättning"),
            ("sv", "AI-översättning"),
            ("fi", "Automaattinen käännös"),
            ("fi", "Tekoälykäännös"),
            ("da", "Automatisk oversættelse"),
            ("da", "AI-oversættelse"),
            ("ko", "자동 번역"),
            ("ko", "인공지능 번역"),
            ("el", "Αυτόματη μετάφραση"),
            ("el", "Μετάφραση με τεχνητή νοημοσύνη"),
        )
        self.assert_forbidden_claims("AI translation", claims)

    def test_v141_cloud_and_remote_service_claims_are_forbidden(self) -> None:
        claims = (
            ("nb", "Skysynkronisering"),
            ("nb", "Ekstern tjeneste"),
            ("sv", "Molnsynkronisering"),
            ("sv", "Fjärrtjänst"),
            ("fi", "Pilvisynkronointi"),
            ("fi", "Etäpalvelu"),
            ("da", "Skysynkronisering"),
            ("da", "Ekstern tjeneste"),
            ("ko", "클라우드 동기화"),
            ("ko", "원격 서비스"),
            ("el", "Συγχρονισμός στο cloud"),
            ("el", "Απομακρυσμένη υπηρεσία"),
        )
        self.assert_forbidden_claims("cloud/remote service", claims)

    def test_v141_share_system_only_language_claims_are_forbidden(self) -> None:
        claims = (
            ("nb", "Delingsvisningene bruker systemspråket."),
            ("sv", "Delningsvyerna använder systemspråket."),
            ("fi", "Jakonäkymät käyttävät järjestelmän kieltä."),
            ("da", "Delingsvisningerne bruger systemets sprog."),
            ("ko", "공유 화면은 시스템 언어를 사용합니다."),
            ("el", "Οι προβολές κοινής χρήσης χρησιμοποιούν τη γλώσσα του συστήματος."),
        )
        self.assert_forbidden_claims("Share system-only language", claims)

    def test_v141_offline_watch_transfer_and_explicit_backup_wording_is_allowed(self) -> None:
        safe_copy = (
            (
                "nb",
                "Endringer gjort uten nett overføres til iPhone når forbindelsen er tilbake. "
                "Eksporter en fullstendig sikkerhetskopi.",
            ),
            (
                "sv",
                "Ändringar som görs utan nätanslutning överförs till iPhone när anslutningen är tillbaka. "
                "Exportera en fullständig säkerhetskopia.",
            ),
            (
                "fi",
                "Ilman verkkoyhteyttä tehdyt muutokset siirretään iPhoneen, kun yhteys palaa. "
                "Vie täydellinen varmuuskopio.",
            ),
            (
                "da",
                "Ændringer uden netværksforbindelse overføres til iPhone, når forbindelsen er tilbage. "
                "Eksporter en komplet sikkerhedskopi.",
            ),
            (
                "ko",
                "오프라인에서 변경한 내용은 다시 연결되면 iPhone으로 전송됩니다. "
                "전체 백업을 내보냅니다.",
            ),
            (
                "el",
                "Οι αλλαγές εκτός σύνδεσης μεταφέρονται στο iPhone όταν επανέλθει η σύνδεση. "
                "Εξαγάγετε ένα πλήρες αντίγραφο ασφαλείας.",
            ),
        )

        for locale, description in safe_copy:
            with self.subTest(locale=locale):
                self.assertEqual(
                    validate(self.write_metadata(Description=description)),
                    [],
                )

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

    def assert_forbidden_claims(
        self,
        concept: str,
        claims: tuple[tuple[str, str], ...],
    ) -> None:
        for locale, claim in claims:
            with self.subTest(concept=concept, locale=locale, claim=claim):
                path = self.write_metadata(Description=claim)
                self.assertIn(
                    f"{path}: copy: forbidden release claim: {concept}",
                    validate(path),
                )


if __name__ == "__main__":
    unittest.main()
