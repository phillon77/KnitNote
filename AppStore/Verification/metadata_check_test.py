from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from AppStore.Verification.metadata_check import (
    dutch_backup_has_source_attachment,
    dutch_is_completed_additive_negation,
    parse,
    validate,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
METADATA = REPOSITORY_ROOT / "AppStore" / "Metadata"
LOCALIZATION_CATALOG = REPOSITORY_ROOT / "KnitNote" / "Localization" / "Localizable.xcstrings"
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
    "nl-NL.md",
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
    "nl-NL.md": (
        "Engels", "Traditioneel Chinees", "Vereenvoudigd Chinees", "Duits", "Frans", "Japans",
        "Noors Bokmål", "Zweeds", "Fins", "Deens", "Koreaans", "Grieks", "Nederlands",
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
    "nl-NL.md": ("Instellingen", "Apple Watch", "deelschermen"),
}
V151_APPROVED_WHATS_NEW = {
    "zh-Hant.md": "KnitNote 1.5.1 現在支援自訂資料夾整理織圖。毛線庫標題會立即跟隨所選 App 語言；有新版本可用時，也會提供前往 App Store 的提醒。",
    "en-US.md": "KnitNote 1.5.1 now lets you organize patterns in custom folders. The Yarn Library title immediately follows your selected app language, and KnitNote lets you know when a newer version is available on the App Store.",
    "de-DE.md": "Mit KnitNote 1.5.1 kannst du Anleitungen jetzt in eigenen Ordnern organisieren. Der Titel der Garnbibliothek folgt sofort der ausgewählten App-Sprache, und KnitNote weist dich darauf hin, wenn im App Store eine neuere Version verfügbar ist.",
    "fr-FR.md": "KnitNote 1.5.1 vous permet désormais de classer vos modèles dans des dossiers personnalisés. Le titre de la bibliothèque de fils s’adapte immédiatement à la langue choisie dans l’app, et KnitNote vous avertit lorsqu’une nouvelle version est disponible dans l’App Store.",
    "ja-JP.md": "KnitNote 1.5.1 では、編み図をカスタムフォルダで整理できるようになりました。毛糸ライブラリのタイトルは選択した App の言語にすぐ切り替わり、新しいバージョンが App Store で利用できると KnitNote がお知らせします。",
    "zh-Hans.md": "KnitNote 1.5.1 现在支持使用自定义文件夹整理图解。毛线库标题会立即跟随所选 App 语言；有新版本可用时，也会提供前往 App Store 的提醒。",
    "nb-NO.md": "I KnitNote 1.5.1 kan du nå organisere mønstre i egne mapper. Tittelen på garnbiblioteket følger app-språket du har valgt med én gang, og KnitNote gir beskjed når en nyere versjon er tilgjengelig i App Store.",
    "sv-SE.md": "I KnitNote 1.5.1 kan du nu ordna mönster i egna mappar. Titeln på garnbiblioteket följer direkt det appspråk du har valt, och KnitNote meddelar när en nyare version finns i App Store.",
    "fi-FI.md": "KnitNote 1.5.1:ssä voit nyt järjestää ohjeet omiin kansioihin. Lankakirjaston otsikko vaihtuu heti valitun sovelluskielen mukaiseksi, ja KnitNote ilmoittaa, kun App Storessa on saatavilla uudempi versio.",
    "da-DK.md": "I KnitNote 1.5.1 kan du nu organisere mønstre i dine egne mapper. Titlen på garnbiblioteket følger straks det valgte app-sprog, og KnitNote giver besked, når en nyere version er tilgængelig i App Store.",
    "ko-KR.md": "KnitNote 1.5.1에서는 이제 사용자 지정 폴더로 도안을 정리할 수 있습니다. 실 라이브러리 제목은 선택한 App 언어로 즉시 바뀌며, App Store에 새 버전이 있으면 KnitNote가 알려 줍니다.",
    "el-GR.md": "Στο KnitNote 1.5.1 μπορείς πλέον να οργανώνεις τα πατρόν σου σε προσαρμοσμένους φακέλους. Ο τίτλος της βιβλιοθήκης νημάτων ακολουθεί αμέσως τη γλώσσα που έχεις επιλέξει στην εφαρμογή και το KnitNote σε ενημερώνει όταν υπάρχει νεότερη έκδοση στο App Store.",
    "nl-NL.md": "In KnitNote 1.5.1 kun je patronen nu ordenen in eigen mappen. De titel van de garenbibliotheek volgt direct de gekozen app-taal en KnitNote laat het weten wanneer er een nieuwere versie beschikbaar is in de App Store.",
}
UNCHANGED_FIELDS = (
    "Name", "Subtitle", "Promotional text", "Keywords", "Description",
    "Support URL", "Marketing URL", "Privacy URL",
)
UNCHANGED_FIELD_HASHES = {
    "da-DK.md": "8c39962cc5938b49449ce95bc6976241d519369b655d5e29c637adf5af1ffdef",
    "de-DE.md": "e37b6540e9b04239b75926dd510e2bcf4935d92ccdbd5b184571749d865a5818",
    "el-GR.md": "cfff91ee36899eacf5beb84bfc3fcd122dd3b0b21467f1732bd2749fdd75a14e",
    "en-US.md": "2ba1464413b7f0338d91d1ecf0abe6d4255c9ed1394af3796002962f529443b5",
    "fi-FI.md": "bb18b3f63adf6abbf23322c9d3f32d39b6c55e1dbc7f9812cc0d1362deb22f92",
    "fr-FR.md": "9cf1963c021661b64b9d00f2305d072b5b9e84e324806ea8e146b91cca43f4fd",
    "ja-JP.md": "f05eb5957335c066af84edb74042176cf95b8e16c637f962e7a19cc7fe83dbfe",
    "ko-KR.md": "cb83dd32d50b2c45bc3469ae2a759201284c4f4fae63ee6db62caa5b7d2714d0",
    "nb-NO.md": "85cfe34f0fa500b10d65a46a4412c053d11dd4a50de29730a139691e667c22e9",
    "nl-NL.md": "aeaaa395fa56ed0246d9b0b263cb9a5b242350c22fa8586f51ec9ab385fc2782",
    "sv-SE.md": "a3b97941b7c726208b85a3449065e26a5ab3a44c0f8f2015d2456de867bf51e8",
    "zh-Hans.md": "34b41ab1ea773d0d417ecf0fc2e69d56a45d9b57f17022676c696af0757f7800",
    "zh-Hant.md": "6035b9ffc91217d299628069ec700ea55be4fe9f1dd73bd219f80cd3d78fbc26",
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
    "nl-NL.md": "Een verwijderd project kan worden hersteld.",
}


class MetadataLocaleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.fixture_index = 0

    def test_every_expected_locale_is_valid(self) -> None:
        for filename in EXPECTED_LOCALES:
            with self.subTest(filename=filename):
                self.assertEqual(validate(METADATA / filename), [])

    def test_current_notes_and_supported_languages(self) -> None:
        expected = {
            "zh-Hant.md": "分享編織日記，留住作品的每一步。 • 新增日記分享圖卡，提供 4:5 貼文與 9:16 直式兩種比例。 • 分享前可調整文字與圖卡顯示內容，不影響原始日記。 • 可將圖卡儲存至照片、複製分享文字，或透過系統分享選單分享至其他 App。",
            "en-US.md": "Share your knitting journal and capture every step of your project. • Create shareable journal cards in 4:5 post and 9:16 vertical formats. • Adjust the text and what appears on your card before sharing, without changing the original journal entry. • Save cards to Photos, copy the sharing text, or share to other apps using the system share menu.",
            "zh-Hans.md": "分享编织日记，留住作品的每一步。 • 新增日记分享图卡，提供 4:5 帖子与 9:16 竖版两种比例。 • 分享前可调整文字与图卡显示内容，不影响原始日记。 • 可将图卡保存至照片、复制分享文字，或通过系统分享菜单分享至其他 App。",
            "de-DE.md": "Teile dein Stricktagebuch und halte jeden Schritt deines Projekts fest. • Erstelle teilbare Tagebuchkarten im Beitragsformat 4:5 oder im Hochformat 9:16. • Passe vor dem Teilen den Text und die angezeigten Inhalte deiner Karte an, ohne den ursprünglichen Tagebucheintrag zu verändern. • Speichere Karten in Fotos, kopiere den Begleittext oder teile sie über das Teilen-Menü des Systems mit anderen Apps.",
            "fr-FR.md": "Partagez votre journal de tricot et gardez une trace de chaque étape de votre projet. • Créez des cartes à partager à partir de votre journal, au format publication 4:5 ou vertical 9:16. • Ajustez le texte et les éléments affichés sur la carte avant de la partager, sans modifier l’entrée d’origine du journal. • Enregistrez les cartes dans Photos, copiez le texte de partage ou partagez-les avec d’autres apps via le menu de partage du système.",
            "ja-JP.md": "編み物日記を共有して、作品づくりの一歩一歩を残しましょう。 • 日記を共有用の画像カードにできます。投稿向けの 4:5 と縦長の 9:16 の2種類に対応しています。 • 元の日記を変更せずに、共有前にカードのテキストや表示内容を調整できます。 • カードを「写真」に保存したり、共有用のテキストをコピーしたり、システムの共有メニューからほかのアプリに共有したりできます。",
            "nb-NO.md": "Del strikkedagboken din og ta vare på hvert steg i prosjektet. • Lag delbare dagbokkort i innleggsformatet 4:5 eller det stående formatet 9:16. • Tilpass teksten og innholdet som vises på kortet før du deler, uten å endre det opprinnelige dagbokinnlegget. • Lagre kort i Bilder, kopier teksten som skal deles, eller del med andre apper via systemets delingsmeny.",
            "sv-SE.md": "Dela din stickdagbok och bevara varje steg i ditt projekt. • Skapa delbara dagbokskort i inläggsformatet 4:5 eller det stående formatet 9:16. • Anpassa texten och innehållet som visas på kortet innan du delar, utan att ändra den ursprungliga dagboksanteckningen. • Spara kort i Bilder, kopiera texten som ska delas eller dela till andra appar via systemets delningsmeny.",
            "fi-FI.md": "Jaa neulepäiväkirjasi ja tallenna projektisi jokainen vaihe. • Luo päiväkirjastasi jaettavia kuvakortteja julkaisuihin sopivassa 4:5-muodossa tai pystysuuntaisessa 9:16-muodossa. • Muokkaa kortin tekstiä ja siinä näkyvää sisältöä ennen jakamista muuttamatta alkuperäistä päiväkirjamerkintää. • Tallenna kortit Kuvat-appiin, kopioi jaettava teksti tai jaa kortit muihin appeihin järjestelmän jakovalikon kautta.",
            "da-DK.md": "Del din strikkedagbog, og gem hvert trin i dit projekt. • Opret dagbogskort til deling i opslagsformatet 4:5 eller det lodrette format 9:16. • Tilpas teksten og det indhold, der vises på kortet, før du deler, uden at ændre det oprindelige dagbogsindlæg. • Gem kort i Fotos, kopiér teksten til deling, eller del med andre apps via systemets delingsmenu.",
            "ko-KR.md": "뜨개 일기를 공유하고 작품을 만드는 모든 과정을 간직하세요. • 일기를 공유용 이미지 카드로 만들 수 있습니다. 게시물용 4:5와 세로형 9:16 두 가지 비율을 제공합니다. • 원본 일기는 변경하지 않고, 공유 전에 카드의 글과 표시 내용을 조정할 수 있습니다. • 카드를 사진 앱에 저장하거나 공유할 글을 복사하고, 시스템 공유 메뉴를 통해 다른 앱으로 공유할 수 있습니다.",
            "el-GR.md": "Μοιραστείτε το ημερολόγιο πλεξίματός σας και κρατήστε κάθε βήμα του έργου σας. • Δημιουργήστε κάρτες από το ημερολόγιό σας για κοινοποίηση, σε μορφή ανάρτησης 4:5 ή κατακόρυφη μορφή 9:16. • Προσαρμόστε το κείμενο και το περιεχόμενο που εμφανίζεται στην κάρτα πριν από την κοινοποίηση, χωρίς να αλλάξετε την αρχική καταχώριση του ημερολογίου. • Αποθηκεύστε τις κάρτες στις Φωτογραφίες, αντιγράψτε το κείμενο κοινοποίησης ή μοιραστείτε τις με άλλες εφαρμογές μέσω του μενού κοινοποίησης του συστήματος.",
            "nl-NL.md": "Deel je breidagboek en leg elke stap van je project vast. • Maak deelbare dagboekkaarten in het berichtformaat 4:5 of het verticale formaat 9:16. • Pas vóór het delen de tekst en de weergegeven inhoud van je kaart aan, zonder het oorspronkelijke dagboekbericht te wijzigen. • Bewaar kaarten in Foto’s, kopieer de tekst om te delen of deel ze met andere apps via het deelmenu van het systeem."
        }
        for filename, note in expected.items():
            with self.subTest(filename=filename):
                fields = parse(METADATA / filename)
                self.assertEqual(fields["What's New"], note)
                self.assertEqual(validate(METADATA / filename), [])
                for token in LANGUAGE_NAMES[filename] + SETTINGS_AND_SURFACE_TOKENS[filename]:
                    self.assertIn(token, fields["Description"])

    def test_every_package_preserves_non_release_note_store_fields(self) -> None:
        for filename, expected_hash in UNCHANGED_FIELD_HASHES.items():
            with self.subTest(filename=filename):
                fields = parse(METADATA / filename)
                protected_fields = "\0".join(fields[field] for field in UNCHANGED_FIELDS)
                self.assertEqual(
                    hashlib.sha256(protected_fields.encode("utf-8")).hexdigest(),
                    expected_hash,
                )

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

    def test_expected_locales_include_dutch_last(self) -> None:
        self.assertEqual(EXPECTED_LOCALES[-1], "nl-NL.md")
        self.assertEqual(len(EXPECTED_LOCALES), 13)

    def test_validator_rejects_stale_or_modified_current_notes(self) -> None:
        for filename in EXPECTED_LOCALES:
            current = parse(METADATA / filename)
            for note in (
                V151_APPROVED_WHATS_NEW[filename],
                "", current["What's New"] + "!", "KnitNote 1.7.0",
                "Not " + current["What's New"],
                "Data optimization", "資料優化",
                current["What's New"].replace("4:5", "1:1"),
                current["What's New"].replace("9:16", "16:9"),
            ):
                with self.subTest(filename=filename, note=note):
                    fields = dict(current)
                    fields["What's New"] = note
                    path = self.write_named_metadata(filename, fields)
                    self.assertIn(
                        f"{path}: What's New: must match the approved 1.7.0 release note exactly",
                        validate(path),
                    )

    def test_validator_rejects_v151_prohibited_update_claims(self) -> None:
        prohibited = {
            "background notifications": "Background notifications announce every update.",
            "automatic updates": "KnitNote updates itself automatically.",
            "forced updates": "This update is required before KnitNote can open.",
            "automatic downloads": "New versions download automatically.",
            "cloud/account delivery": "Updates are delivered through your cloud account.",
            "automatic pattern classification": "Patterns are classified into folders automatically.",
            "nested folders": "Folders can contain nested folders.",
            "cross-folder membership": "A pattern can appear in several folders at once.",
            "user-content translation": "Imported pattern content is translated automatically.",
            "publication": "KnitNote 1.5.1 is now live on the App Store.",
        }
        for concept, claim in prohibited.items():
            with self.subTest(concept=concept):
                fields = parse(METADATA / "en-US.md")
                fields["What's New"] = V151_APPROVED_WHATS_NEW["en-US.md"] + " " + claim
                path = self.write_named_metadata("en-US.md", fields)
                self.assertIn(
                    f"{path}: copy: forbidden release claim: {concept}",
                    validate(path),
                )

    def test_validator_rejects_missing_supported_language_for_every_package(self) -> None:
        for filename in EXPECTED_LOCALES:
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

    def test_v150_forbidden_claim_families_are_rejected_in_english(self) -> None:
        claims = (
            ("background notifications", "Background notifications alert you when a target is reached."),
            ("AI translation", "Automatic pattern translation is included."),
            ("trial/free", "Start a free trial."),
            ("price", "See the price in the app."),
            ("purchase", "Purchase KnitNote today."),
            ("publication", "KnitNote is now published on the App Store."),
            ("publication", "Publication is complete."),
            ("native acceptance", "All translations were reviewed by native speakers."),
            ("native acceptance", "Native Dutch acceptance is complete."),
            ("native acceptance", "Native acceptance has passed."),
            ("physical acceptance", "All features passed physical-device acceptance."),
            ("physical acceptance", "Physical acceptance on every device is complete."),
            ("physical acceptance", "Physical acceptance has passed."),
        )

        for concept, claim in claims:
            with self.subTest(concept=concept, claim=claim):
                path = self.write_metadata(**{"What's New": claim})
                self.assertIn(
                    f"{path}: copy: forbidden release claim: {concept}",
                    validate(path),
                )

    def test_v150_acceptance_and_publication_claims_are_forbidden_in_every_locale(self) -> None:
        claims = (
            ("background notifications", "Background notifications are supported."),
            ("background notifications", "支援背景通知。"),
            ("background notifications", "支持后台通知。"),
            ("background notifications", "Hintergrundbenachrichtigungen werden unterstützt."),
            ("background notifications", "Les notifications en arrière-plan sont prises en charge."),
            ("background notifications", "バックグラウンド通知に対応します。"),
            ("background notifications", "Bakgrunnsvarsler støttes."),
            ("background notifications", "Bakgrundsnotiser stöds."),
            ("background notifications", "Taustailmoituksia tuetaan."),
            ("background notifications", "Baggrundsnotifikationer understøttes."),
            ("background notifications", "백그라운드 알림을 지원합니다."),
            ("background notifications", "Υποστηρίζονται ειδοποιήσεις στο παρασκήνιο."),
            ("background notifications", "Achtergrondmeldingen worden ondersteund."),
            ("publication", "KnitNote is published on the App Store."),
            ("publication", "KnitNote 已在 App Store 上架。"),
            ("publication", "KnitNote 已在 App Store 上架。"),
            ("publication", "KnitNote wurde im App Store veröffentlicht."),
            ("publication", "KnitNote est publié sur l’App Store."),
            ("publication", "KnitNoteはApp Storeで公開済みです。"),
            ("publication", "KnitNote er publisert i App Store."),
            ("publication", "KnitNote är publicerad i App Store."),
            ("publication", "KnitNote on julkaistu App Storessa."),
            ("publication", "KnitNote er udgivet i App Store."),
            ("publication", "KnitNote가 App Store에 출시되었습니다."),
            ("publication", "Το KnitNote δημοσιεύτηκε στο App Store."),
            ("publication", "KnitNote is gepubliceerd in de App Store."),
            ("native acceptance", "Translations were reviewed by native speakers."),
            ("native acceptance", "翻譯已由母語人士審核。"),
            ("native acceptance", "翻译已由母语人士审核。"),
            ("native acceptance", "Die Übersetzungen wurden von Muttersprachlern geprüft."),
            ("native acceptance", "Les traductions ont été relues par des locuteurs natifs."),
            ("native acceptance", "翻訳はネイティブスピーカーがレビューしました。"),
            ("native acceptance", "Oversettelsene er gjennomgått av morsmålsbrukere."),
            ("native acceptance", "Översättningarna har granskats av modersmålstalare."),
            ("native acceptance", "Käännökset ovat äidinkielisten puhujien tarkistamia."),
            ("native acceptance", "Oversættelserne er gennemgået af personer med sproget som modersmål."),
            ("native acceptance", "번역은 원어민이 검수했습니다."),
            ("native acceptance", "Οι μεταφράσεις ελέγχθηκαν από φυσικούς ομιλητές."),
            ("native acceptance", "De vertalingen zijn beoordeeld door moedertaalsprekers."),
            ("physical acceptance", "Physical-device acceptance passed."),
            ("physical acceptance", "已通過實機驗收。"),
            ("physical acceptance", "已通过实机验收。"),
            ("physical acceptance", "Die Abnahme auf echten Geräten ist bestanden."),
            ("physical acceptance", "La validation sur appareils physiques est réussie."),
            ("physical acceptance", "実機験収に合格しました。"),
            ("physical acceptance", "Godkjenning på fysiske enheter er bestått."),
            ("physical acceptance", "Godkännandet på fysiska enheter är klart."),
            ("physical acceptance", "Fyysisten laitteiden hyväksyntä on läpäisty."),
            ("physical acceptance", "Godkendelse på fysiske enheder er bestået."),
            ("physical acceptance", "실기기 검수를 통과했습니다."),
            ("physical acceptance", "Η αποδοχή σε φυσικές συσκευές ολοκληρώθηκε."),
            ("physical acceptance", "De acceptatie op fysieke apparaten is geslaagd."),
        )

        for concept, claim in claims:
            with self.subTest(concept=concept, claim=claim):
                path = self.write_metadata(**{"What's New": claim})
                self.assertIn(
                    f"{path}: copy: forbidden release claim: {concept}",
                    validate(path),
                )

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

    def test_dutch_forbidden_claims_are_rejected(self) -> None:
        claims = (
            ("AI translation", "AI-vertaling"),
            ("AI translation", "Vertaling met kunstmatige intelligentie"),
            ("cloud sync", "Cloudsynchronisatie"),
            ("cloud sync", "Synchronisatie met de cloud"),
            ("cloud/remote service", "Externe dienst"),
            ("cloud/remote service", "Service op afstand"),
            ("automatic stitch recognition", "Automatische steekherkenning"),
            ("subscription", "Abonnement"),
            ("subscription", "Abonnementsdienst"),
            ("trial/free", "Gratis proefperiode"),
            ("trial/free", "Proefversie"),
            ("price", "Prijs"),
            ("price", "Kosten"),
            ("purchase", "Aankoop"),
            ("purchase", "Kopen"),
            ("deleted project recovery", "Een verwijderd project herstellen"),
            ("deleted project recovery", "Een verwijderd project terugzetten"),
            ("social network", "Sociaal netwerk"),
            ("social network", "Sociale netwerksite"),
            ("marketplace", "Marktplaats"),
            ("Share system-only language", "Deel-extensie gebruikt de systeemtaal"),
            ("Share system-only language", "Deelschermen gebruiken de systeemtaal"),
            ("AI translation", "AI-vertalingen voor patronen"),
            ("cloud sync", "Cloudsynchronisaties voor al je apparaten"),
            ("cloud/remote service", "Werkt met externe diensten"),
            ("subscription", "Kies uit meerdere abonnementen"),
            ("price", "Vergelijk prijzen voordat je koopt"),
            ("purchase", "Beheer aankopen vanuit de app"),
            ("deleted project recovery", "Herstel een verwijderd project"),
            ("deleted project recovery", "Verwijderde projecten herstellen"),
            ("social network", "Maak verbinding met sociale netwerken"),
            ("social network", "Deel via sociale netwerksites"),
            ("marketplace", "Ontdek marktplaatsen voor patronen"),
            ("Share system-only language", "Deel-extensie werkt uitsluitend in de systeemtaal"),
            ("Share system-only language", "Het deelscherm volgt de systeemtaal"),
            ("AI translation", "Vertalingen met kunstmatige intelligentie"),
            ("cloud sync", "Synchronisaties met de cloud"),
            ("cloud/remote service", "Services op afstand"),
            ("subscription", "Kies uit abonnementsdiensten"),
            ("trial/free", "Proefversies zijn beschikbaar"),
            ("deleted project recovery", "Verwijderde projecten eenvoudig herstellen"),
            ("deleted project recovery", "Zet een verwijderd project terug"),
            ("Share system-only language", "Het deelscherm staat uitsluitend in de systeemtaal"),
        )
        self.assert_forbidden_claims_by_concept(claims)

    def test_dutch_allowlists_reject_unapproved_boundary_tokens(self) -> None:
        with self.subTest(kind="unapproved additive modifier"):
            self.assertFalse(
                dutch_is_completed_additive_negation(
                    ["herstel", "project", "niet", "alleen", "snel", "maar", "soms", "ook"],
                    2,
                    5,
                    (0, 1),
                )
            )
        with self.subTest(kind="multiple additive modifiers"):
            self.assertFalse(
                dutch_is_completed_additive_negation(
                    ["herstel", "project", "niet", "alleen", "snel", "maar", "nu", "vooral", "ook"],
                    2,
                    5,
                    (0, 1),
                )
            )
        with self.subTest(kind="unapproved backup adjective"):
            self.assertFalse(
                dutch_backup_has_source_attachment(
                    ["herstellen", "via", "deze", "nieuwe", "reservekopie"], 0, 4,
                )
            )
        with self.subTest(kind="backup phrase beyond determiner plus adjective"):
            self.assertFalse(
                dutch_backup_has_source_attachment(
                    ["herstellen", "via", "deze", "oude", "veilige", "reservekopie"], 0, 5,
                )
            )

    def test_dutch_recovery_and_share_concept_matrix(self) -> None:
        forbidden_cases = (
            ("action first", "deleted project recovery", "Herstel een verwijderd project"),
            (
                "action first with modifier",
                "deleted project recovery",
                "Herstel met één tik een verwijderd project",
            ),
            ("plural modifier", "deleted project recovery", "Verwijderde projecten snel herstellen"),
            (
                "project first with source",
                "deleted project recovery",
                "Verwijderde projecten vanuit een reservekopie herstellen",
            ),
            (
                "separable verb with modifier",
                "deleted project recovery",
                "Zet een verwijderd project eenvoudig terug",
            ),
            (
                "contrast restores project instead of backup",
                "deleted project recovery",
                "Herstel geen reservekopie maar een verwijderd project.",
            ),
            (
                "contrast restores project instead of named backup",
                "deleted project recovery",
                "Herstel niet de reservekopie maar een verwijderd project.",
            ),
            (
                "not-only contrast restores project",
                "deleted project recovery",
                "Een verwijderd project niet alleen bekijken maar herstellen.",
            ),
            (
                "contrast with backup modifier restores project",
                "deleted project recovery",
                "Herstel geen oude reservekopie maar een verwijderd project.",
            ),
            (
                "not-only contrast with modifiers restores project",
                "deleted project recovery",
                "Een verwijderd project niet alleen rustig bekijken maar daarna herstellen.",
            ),
            (
                "backup via source restores project",
                "deleted project recovery",
                "Verwijderde projecten herstellen via een reservekopie.",
            ),
            (
                "backup uit source restores project",
                "deleted project recovery",
                "Verwijderde projecten herstellen uit een reservekopie.",
            ),
            (
                "completed recovery relation before not-only contrast",
                "deleted project recovery",
                "Herstel een verwijderd project niet alleen snel maar ook veilig.",
            ),
            (
                "completed plural recovery relation before not-only contrast",
                "deleted project recovery",
                "Verwijderde projecten herstel je niet alleen snel maar ook volledig.",
            ),
            (
                "completed recovery relation with vooral ook",
                "deleted project recovery",
                "Herstel een verwijderd project niet alleen snel maar vooral ook veilig.",
            ),
            (
                "completed plural recovery relation with nu ook",
                "deleted project recovery",
                "Verwijderde projecten herstel je niet alleen snel maar nu ook volledig.",
            ),
            (
                "backup met source attached to noun phrase",
                "deleted project recovery",
                "Verwijderde projecten herstellen met een reservekopie.",
            ),
            (
                "backup vanuit source attached to adjective phrase",
                "deleted project recovery",
                "Verwijderde projecten herstellen vanuit de oude reservekopie.",
            ),
            (
                "backup source with informal possessive",
                "deleted project recovery",
                "Verwijderde projecten herstellen via je reservekopie.",
            ),
            (
                "backup source with formal possessive",
                "deleted project recovery",
                "Verwijderde projecten herstellen vanuit jouw reservekopie.",
            ),
            (
                "backup source with plural possessive",
                "deleted project recovery",
                "Verwijderde projecten herstellen uit hun reservekopie.",
            ),
            (
                "backup source with demonstrative",
                "deleted project recovery",
                "Verwijderde projecten herstellen via deze reservekopie.",
            ),
            (
                "system-language display",
                "Share system-only language",
                "Het deelscherm toont uitsluitend de systeemtaal",
            ),
            (
                "system-language configuration",
                "Share system-only language",
                "De deel-extensie is ingesteld op de systeemtaal",
            ),
            (
                "plural Share extension",
                "Share system-only language",
                "De deel-extensies gebruiken uitsluitend de systeemtaal",
            ),
            (
                "passive system-language display",
                "Share system-only language",
                "Het deelscherm wordt uitsluitend weergegeven in de systeemtaal",
            ),
            (
                "Share contrast uses system language",
                "Share system-only language",
                "Het deelscherm gebruikt niet de app-taal maar uitsluitend de systeemtaal.",
            ),
            (
                "Share contrast follows system language",
                "Share system-only language",
                "Het deelscherm volgt niet de app-taal maar de systeemtaal.",
            ),
            (
                "Share passive contrast displays system language",
                "Share system-only language",
                "Het deelscherm wordt niet in de app-taal maar uitsluitend in de systeemtaal weergegeven.",
            ),
            (
                "Share configuration contrast sets system language",
                "Share system-only language",
                "De deel-extensie is niet ingesteld op de app-taal maar op de systeemtaal.",
            ),
            (
                "Share contrast display modifier",
                "Share system-only language",
                "Het deelscherm toont niet de app-taal maar altijd de systeemtaal.",
            ),
            (
                "Share not-only contrast uses system language",
                "Share system-only language",
                "Het deelscherm gebruikt niet alleen de app-taal maar ook de systeemtaal.",
            ),
            (
                "completed Share relation before not-only contrast",
                "Share system-only language",
                "De deel-extensie gebruikt uitsluitend de systeemtaal niet alleen voor titels maar ook voor knoppen.",
            ),
            (
                "completed Share display before not-only contrast",
                "Share system-only language",
                "Het deelscherm toont uitsluitend de systeemtaal niet alleen in menu's maar ook in meldingen.",
            ),
            (
                "completed Share relation with vooral ook",
                "Share system-only language",
                "De deel-extensie gebruikt uitsluitend de systeemtaal niet alleen voor titels maar vooral ook voor knoppen.",
            ),
            (
                "completed Share relation with nu ook",
                "Share system-only language",
                "Het deelscherm toont uitsluitend de systeemtaal niet alleen in menu's maar nu ook in meldingen.",
            ),
        )
        for label, concept, description in forbidden_cases:
            with self.subTest(label=label):
                path = self.write_metadata(Description=description)
                self.assertIn(
                    f"{path}: copy: forbidden release claim: {concept}",
                    validate(path),
                )

        safe_recovery_cases = (
            "Een verwijderd project blijft verwijderd; alleen een gekozen "
            "reservekopie kan worden hersteld.",
            "Een verwijderd project blijft verwijderd. Herstel alleen de "
            "reservekopie die je zelf kiest.",
            "Herstel een reservekopie van een verwijderd project.",
            "Zet een reservekopie terug; een verwijderd project blijft verwijderd.",
            "Verwijderde projecten blijven verwijderd en herstel alleen een reservekopie.",
            "Een verwijderd project kan niet worden hersteld.",
            "Verwijderde projecten zijn niet te herstellen.",
            "Herstel geen verwijderd project.",
            "Zet geen verwijderd project terug.",
            "Een verwijderd project hoeft niet te worden hersteld.",
            "Bij een verwijderd project herstel je alleen de reservekopie.",
            "Bij een verwijderd project zet je alleen de reservekopie terug.",
            "Een verwijderd project kan vandaag echt niet worden hersteld.",
            "Herstel vandaag geen verwijderd project.",
            "Bij een verwijderd project herstel je direct de reservekopie.",
            "Bij een verwijderd project herstel je met één tik de reservekopie.",
            "Bij een verwijderd project herstel je via het menu de reservekopie.",
            "Bij een verwijderd project herstel je uit voorzorg de reservekopie.",
            "Bij een verwijderd project herstel je via het menu reservekopieën.",
            "Bij een verwijderd project herstel je met een tik reservekopieën.",
        )
        for description in safe_recovery_cases:
            with self.subTest(kind="recovery safe", description=description):
                path = self.write_metadata(Description=description)
                self.assertNotIn(
                    f"{path}: copy: forbidden release claim: deleted project recovery",
                    validate(path),
                )

        safe_share_cases = (
            "Het deelscherm gebruikt niet de systeemtaal.",
            "De deel-extensie staat niet op de systeemtaal.",
            "Het deelscherm volgt de systeemtaal niet.",
            "Het deelscherm volgt de gekozen app-taal, niet de systeemtaal.",
            "Het deelscherm gebruikt absoluut niet de systeemtaal.",
            "De deel-extensie is helemaal niet ingesteld op de systeemtaal.",
            "Het deelscherm wordt niet uitsluitend weergegeven in de systeemtaal.",
            "Niet het deelscherm maar de app gebruikt de systeemtaal.",
        )
        for description in safe_share_cases:
            with self.subTest(kind="Share safe", description=description):
                path = self.write_metadata(Description=description)
                self.assertNotIn(
                    f"{path}: copy: forbidden release claim: Share system-only language",
                    validate(path),
                )

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

    def assert_forbidden_claims_by_concept(
        self,
        claims: tuple[tuple[str, str], ...],
    ) -> None:
        for concept, claim in claims:
            with self.subTest(concept=concept, claim=claim):
                path = self.write_metadata(Description=claim)
                self.assertIn(
                    f"{path}: copy: forbidden release claim: {concept}",
                    validate(path),
                )


if __name__ == "__main__":
    unittest.main()
