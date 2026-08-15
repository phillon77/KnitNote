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


def _phrase_pattern(*phrases: str) -> re.Pattern[str]:
    return re.compile("|".join(re.escape(phrase.casefold()) for phrase in phrases))


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
            r"μετάφραση[ -]+με[ -]+τεχνητή[ -]+νοημοσύνη|"
            r"ai[ -]+vertaling(?:en)?|vertaling(?:en)?[ -]+met[ -]+kunstmatige[ -]+intelligentie"
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
            r"cloud[ -]+synchronisation|"
            r"cloudsynchronisatie(?:s)?|synchronisatie(?:s)?[ -]+met[ -]+de[ -]+cloud"
            r")(?!\w)|(?:雲端|云端)[ -]*同步|クラウド[ -]*同期"
        ),
    ),
    (
        "automatic stitch recognition",
        re.compile(
            r"(?<!\w)(?:"
            r"automatic[ -]+stitch[ -]+(?:recognition|detection)|"
            r"automatische[ -]+maschenerkennung|"
            r"reconnaissance[ -]+automatique[ -]+des[ -]+mailles|"
            r"automatische[ -]+steekherkenning"
            r")(?!\w)|"
            r"自動辨識針目|自动识别针目|"
            r"編み目の自動認識|自動編み目認識"
        ),
    ),
    (
        "subscription",
        re.compile(
            r"(?<!\w)(?:"
            r"subscriptions?|abonnement(?:en|s)?|abonnementsdienst(?:en)?|prenumeration|tilaus|συνδρομή"
            r")(?!\w)|"
            r"訂閱|订阅|サブスクリプション|定期購入|구독"
        ),
    ),
    (
        "trial/free",
        re.compile(
            r"(?<!\w)(?:"
            r"gratis|proefversies?|prøveperiode|provperiod|ilmainen|ilmaiseksi|kokeilujakso|"
            r"δωρεάν|δοκιμαστική[ -]+περίοδοσ"
            r")(?!\w)|(?:무료(?:[ -]*체험)?|체험[ -]*기간)"
        ),
    ),
    (
        "price",
        re.compile(
            r"(?<!\w)(?:pris|prijs|prijzen|kosten|hinta|τιμή)(?!\w)|가격"
        ),
    ),
    (
        "purchase",
        re.compile(
            r"(?<!\w)(?:kjøp|köp|aankoop|aankopen|koop|koopt|kopen|osto|køb|αγορά)(?!\w)|구매"
        ),
    ),
    (
        "cloud/remote service",
        re.compile(
            r"(?<!\w)(?:"
            r"skysynkronisering|molnsynkronisering|pilvisynkronointi|"
            r"fjärrtjänst|etäpalvelu|ekstern[ -]+tjeneste|"
            r"externe[ -]+dienst(?:en)?|services?[ -]+op[ -]+afstand|"
            r"συγχρονισμόσ[ -]+στο[ -]+(?:cloud|νέφοσ)|"
            r"απομακρυσμένη[ -]+υπηρεσία"
            r")(?!\w)|(?:클라우드[ -]*동기화|원격[ -]*서비스)"
        ),
    ),
    (
        "deleted project recovery",
        re.compile(
            r"(?<!\w)(?:"
            r"deleted[ -]+projects?.{0,120}(?:recover\w*|restor\w*)|"
            r"gelöschte[ -]+projekte.{0,120}wiederhergestellt\w*|"
            r"les[ -]+projets?[ -]+supprimés?.{0,120}(?:récupér\w*|restaur\w*)|"
            r"slettede[ -]+prosjekter.{0,120}gjenopprett\w*|"
            r"borttagna[ -]+projekt.{0,120}återställ\w*|"
            r"poistetut[ -]+projektit.{0,120}palaut\w*|"
            r"slettede[ -]+projekter.{0,120}gendann\w*|"
            r"τα[ -]+διαγραμμένα[ -]+έργα.{0,120}(?:ανακτηθ\w*|επαναφερ\w*)"
            r")(?!\w)|"
            r"已刪除的?作品.{0,80}(?:復原|恢復)|"
            r"已删除的?作品.{0,80}(?:恢复|復原)|"
            r"削除した作品.{0,80}復元|"
            r"삭제된[ -]*프로젝트.{0,80}(?:복원|복구)"
        ),
    ),
    (
        "social network",
        re.compile(
            r"(?<!\w)(?:"
            r"social[ -]+network(?:s|ing)?|"
            r"sozial(?:e|er|es|en)[ -]+netzwerk(?:e)?|"
            r"réseaux?[ -]+(?:social|sociaux)|"
            r"sociaal[ -]+netwerk(?:en)?|sociale[ -]+netwerk(?:en|site(?:s)?)"
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
            r"places?[ -]+de[ -]+marché|marktplaats(?:en)?"
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
V151_FORBIDDEN_WHATS_NEW_PATTERNS = (
    (
        "background notifications",
        _phrase_pattern(
            "background notifications", "背景通知", "后台通知",
            "Hintergrundbenachrichtigungen", "notifications en arrière-plan",
            "バックグラウンド通知", "Bakgrunnsvarsler", "Bakgrundsnotiser",
            "Taustailmoituksia", "Baggrundsnotifikationer", "백그라운드 알림",
            "ειδοποιήσεις στο παρασκήνιο", "Achtergrondmeldingen",
        ),
    ),
    ("automatic updates", _phrase_pattern("KnitNote updates itself automatically")),
    ("forced updates", _phrase_pattern("This update is required before KnitNote can open")),
    ("automatic downloads", _phrase_pattern("New versions download automatically")),
    ("cloud/account delivery", _phrase_pattern("Updates are delivered through your cloud account")),
    ("automatic pattern classification", _phrase_pattern("Patterns are classified into folders automatically")),
    ("nested folders", _phrase_pattern("Folders can contain nested folders")),
    ("cross-folder membership", _phrase_pattern("A pattern can appear in several folders at once")),
    ("user-content translation", _phrase_pattern("Imported pattern content is translated automatically")),
    ("AI translation", re.compile(r"(?<!\w)automatic[ -]+pattern[ -]+translations?(?!\w)")),
    ("trial/free", re.compile(r"(?<!\w)(?:free[ -]+trials?|trial[ -]+versions?)(?!\w)")),
    ("price", re.compile(r"(?<!\w)(?:prices?|pricing)(?!\w)")),
    ("purchase", re.compile(r"(?<!\w)(?:purchases?|buy|buying)(?!\w)")),
    (
        "publication",
        _phrase_pattern(
            "published on the App Store", "released on the App Store", "live on the App Store",
            "publication is complete",
            "在 App Store 上架", "im App Store veröffentlicht", "publié sur l’App Store",
            "App Storeで公開", "publisert i App Store", "publicerad i App Store",
            "julkaistu App Storessa", "udgivet i App Store", "App Store에 출시",
            "δημοσιεύτηκε στο App Store", "gepubliceerd in de App Store",
        ),
    ),
    (
        "native acceptance",
        _phrase_pattern(
            "reviewed by native speakers", "native-speaker reviewed", "native reviewed",
            "native Dutch acceptance is complete", "native acceptance has passed",
            "母語人士審核", "母语人士审核", "von Muttersprachlern geprüft",
            "relues par des locuteurs natifs", "ネイティブスピーカーがレビュー",
            "gjennomgått av morsmålsbrukere", "granskats av modersmålstalare",
            "äidinkielisten puhujien tarkistamia", "sproget som modersmål", "원어민이 검수",
            "ελέγχθηκαν από φυσικούς ομιλητές", "beoordeeld door moedertaalsprekers",
        ),
    ),
    (
        "physical acceptance",
        _phrase_pattern(
            "physical-device acceptance", "physical device acceptance", "tested on physical devices",
            "physical acceptance on every device is complete", "physical acceptance has passed",
            "實機驗收", "实机验收", "Abnahme auf echten Geräten",
            "validation sur appareils physiques", "実機験収", "Godkjenning på fysiske enheter",
            "Godkännandet på fysiska enheter", "Fyysisten laitteiden hyväksyntä",
            "Godkendelse på fysiske enheder", "실기기 검수",
            "αποδοχή σε φυσικές συσκευές", "acceptatie op fysieke apparaten",
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
    "nl-NL.md",
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
    "nl-NL.md": {
        "languages": (
            "Engels", "Traditioneel Chinees", "Vereenvoudigd Chinees", "Duits", "Frans", "Japans",
            "Noors Bokmål", "Zweeds", "Fins", "Deens", "Koreaans", "Grieks", "Nederlands",
        ),
        "surfaces": ("Instellingen", "Apple Watch", "deelschermen"),
    },
}
V151_WHATS_NEW_RELATIONSHIPS = {
    "en-US.md": ("organize patterns in custom folders", "Yarn Library title immediately follows your selected app language", "newer version is available on the App Store"),
    "zh-Hant.md": ("自訂資料夾整理織圖", "毛線庫標題會立即跟隨所選 App 語言", "有新版本可用時，也會提供前往 App Store 的提醒"),
    "de-DE.md": ("Anleitungen jetzt in eigenen Ordnern organisieren", "Titel der Wollbibliothek folgt sofort der ausgewählten App-Sprache", "neuere Version verfügbar ist"),
    "fr-FR.md": ("classer vos modèles dans des dossiers personnalisés", "titre de la bibliothèque de fils s’adapte immédiatement à la langue choisie dans l’app", "nouvelle version est disponible dans l’App Store"),
    "ja-JP.md": ("編み図をカスタムフォルダで整理", "毛糸ライブラリのタイトルは選択した App の言語にすぐ切り替わり", "新しいバージョンが App Store で利用できると KnitNote がお知らせ"),
    "zh-Hans.md": ("使用自定义文件夹整理图解", "毛线库标题会立即跟随所选 App 语言", "有新版本可用时，也会提供前往 App Store 的提醒"),
    "nb-NO.md": ("organisere mønstre i egne mapper", "Tittelen på garnbiblioteket følger app-språket du har valgt med én gang", "nyere versjon er tilgjengelig i App Store"),
    "sv-SE.md": ("ordna mönster i egna mappar", "Titeln på garnbiblioteket följer direkt det appspråk du har valt", "nyare version finns i App Store"),
    "fi-FI.md": ("järjestää ohjeet omiin kansioihin", "Lankakirjaston otsikko vaihtuu heti valitun sovelluskielen mukaiseksi", "uudempi versio"),
    "da-DK.md": ("organisere mønstre i dine egne mapper", "Titlen på garnbiblioteket følger straks det valgte app-sprog", "nyere version er tilgængelig i App Store"),
    "ko-KR.md": ("사용자 지정 폴더로 도안을 정리", "실 보관함 제목은 선택한 App 언어로 즉시 바뀌며", "App Store에 새 버전이 있으면 KnitNote가 알려 줍니다"),
    "el-GR.md": ("οργανώνεις τα πατρόν σου σε προσαρμοσμένους φακέλους", "τίτλος της βιβλιοθήκης νημάτων ακολουθεί αμέσως τη γλώσσα", "νεότερη έκδοση στο App Store"),
    "nl-NL.md": ("patronen nu ordenen in eigen mappen", "titel van de garenbibliotheek volgt direct de gekozen app-taal", "nieuwere versie beschikbaar is in de App Store"),
}
V151_APPROVED_WHATS_NEW = {
    "zh-Hant.md": "KnitNote 1.5.1 現在支援自訂資料夾整理織圖。毛線庫標題會立即跟隨所選 App 語言；有新版本可用時，也會提供前往 App Store 的提醒。",
    "en-US.md": "KnitNote 1.5.1 now lets you organize patterns in custom folders. The Yarn Library title immediately follows your selected app language, and KnitNote lets you know when a newer version is available on the App Store.",
    "de-DE.md": "Mit KnitNote 1.5.1 kannst du Anleitungen jetzt in eigenen Ordnern organisieren. Der Titel der Wollbibliothek folgt sofort der ausgewählten App-Sprache, und KnitNote weist dich darauf hin, wenn im App Store eine neuere Version verfügbar ist.",
    "fr-FR.md": "KnitNote 1.5.1 vous permet désormais de classer vos modèles dans des dossiers personnalisés. Le titre de la bibliothèque de fils s’adapte immédiatement à la langue choisie dans l’app, et KnitNote vous avertit lorsqu’une nouvelle version est disponible dans l’App Store.",
    "ja-JP.md": "KnitNote 1.5.1 では、編み図をカスタムフォルダで整理できるようになりました。毛糸ライブラリのタイトルは選択した App の言語にすぐ切り替わり、新しいバージョンが App Store で利用できると KnitNote がお知らせします。",
    "zh-Hans.md": "KnitNote 1.5.1 现在支持使用自定义文件夹整理图解。毛线库标题会立即跟随所选 App 语言；有新版本可用时，也会提供前往 App Store 的提醒。",
    "nb-NO.md": "I KnitNote 1.5.1 kan du nå organisere mønstre i egne mapper. Tittelen på garnbiblioteket følger app-språket du har valgt med én gang, og KnitNote gir beskjed når en nyere versjon er tilgjengelig i App Store.",
    "sv-SE.md": "I KnitNote 1.5.1 kan du nu ordna mönster i egna mappar. Titeln på garnbiblioteket följer direkt det appspråk du har valt, och KnitNote meddelar när en nyare version finns i App Store.",
    "fi-FI.md": "KnitNote 1.5.1:ssä voit nyt järjestää ohjeet omiin kansioihin. Lankakirjaston otsikko vaihtuu heti valitun sovelluskielen mukaiseksi, ja KnitNote ilmoittaa, kun App Storessa on saatavilla uudempi versio.",
    "da-DK.md": "I KnitNote 1.5.1 kan du nu organisere mønstre i dine egne mapper. Titlen på garnbiblioteket følger straks det valgte app-sprog, og KnitNote giver besked, når en nyere version er tilgængelig i App Store.",
    "ko-KR.md": "KnitNote 1.5.1에서는 이제 사용자 지정 폴더로 도안을 정리할 수 있습니다. 실 보관함 제목은 선택한 App 언어로 즉시 바뀌며, App Store에 새 버전이 있으면 KnitNote가 알려 줍니다.",
    "el-GR.md": "Στο KnitNote 1.5.1 μπορείς πλέον να οργανώνεις τα πατρόν σου σε προσαρμοσμένους φακέλους. Ο τίτλος της βιβλιοθήκης νημάτων ακολουθεί αμέσως τη γλώσσα που έχεις επιλέξει στην εφαρμογή και το KnitNote σε ενημερώνει όταν υπάρχει νεότερη έκδοση στο App Store.",
    "nl-NL.md": "In KnitNote 1.5.1 kun je patronen nu ordenen in eigen mappen. De titel van de garenbibliotheek volgt direct de gekozen app-taal en KnitNote laat het weten wanneer er een nieuwere versie beschikbaar is in de App Store.",
}
for filename, relationships in V151_WHATS_NEW_RELATIONSHIPS.items():
    LANGUAGE_CONTRACTS[filename].update({
        "version": "1.5.1",
        "whats_new_languages": (),
        "whats_new_relationships": relationships,
        "approved_whats_new": V151_APPROVED_WHATS_NEW[filename],
    })
FIELD = re.compile(r"^- ([^:]+):\s*(.*)$")
CLAIM_WHITESPACE = re.compile(r"\s+")
CLAIM_DASH = re.compile(r"[\u2010-\u2015\u2212]")
DUTCH_CLAUSE_BOUNDARY = re.compile(r"[.;:!?]+")
DUTCH_TOKEN = re.compile(r"\w+")
DUTCH_RECOVERY_WINDOW = 8
DUTCH_SHARE_WINDOW = 12
DUTCH_NEGATION_WINDOW = 3
DUTCH_NEGATION_TOKENS = {"geen", "niet"}
DUTCH_CONTRAST_TOKEN = "maar"
DUTCH_ADDITIVE_MODIFIERS = frozenset({"vooral", "nu"})
DUTCH_BACKUP_SOURCE_MARKERS = {"met", "vanuit", "via", "uit"}
DUTCH_BACKUP_DETERMINERS = {
    "de", "den", "der", "des", "dit", "die", "een", "het", "mijn", "onze", "uw", "zijn",
    "je", "jouw", "hun", "deze",
}
DUTCH_BACKUP_ADJECTIVES = frozenset({"oude"})
DUTCH_SHARE_STATE_VERBS = {
    "gebruikt", "gebruiken", "werkt", "werken", "volgt", "volgen",
    "staat", "staan", "toont", "tonen", "weergegeven",
}


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


def dutch_claim_clauses(value: str) -> list[list[str]]:
    """Split normalized Dutch copy into bounded token windows."""
    return [
        DUTCH_TOKEN.findall(clause)
        for clause in DUTCH_CLAUSE_BOUNDARY.split(value)
        if clause
    ]


def dutch_contrast_branch_bounds(tokens: list[str], index: int) -> tuple[int, int]:
    """Return the bounded branch that contains an index in a ``maar`` contrast."""
    start = 0
    for candidate in range(index - 1, -1, -1):
        if tokens[candidate] == DUTCH_CONTRAST_TOKEN:
            start = candidate + 1
            break

    end = len(tokens)
    for candidate in range(index + 1, len(tokens)):
        if tokens[candidate] == DUTCH_CONTRAST_TOKEN:
            end = candidate
            break
    return start, end


def dutch_branch_is_negated(
    tokens: list[str], branch_start: int, branch_end: int, *relation_indices: int,
) -> bool:
    """Return whether a bounded relation is negated inside one contrast branch.

    Dutch places ``niet`` either beside a predicate or after its object, while
    ``geen`` can precede the restored object.  The scan stays within its
    ``maar`` branch, so a negated alternative cannot erase a positive branch.
    """
    start = max(branch_start, min(relation_indices) - DUTCH_NEGATION_WINDOW)
    end = min(branch_end, max(relation_indices) + DUTCH_NEGATION_WINDOW + 1)
    return any(
        token in DUTCH_NEGATION_TOKENS
        and not dutch_is_completed_additive_negation(
            tokens, index, branch_end, relation_indices,
        )
        for index, token in enumerate(tokens[start:end], start)
    )


def dutch_is_completed_additive_negation(
    tokens: list[str], negation_index: int, branch_end: int,
    relation_indices: tuple[int, ...],
) -> bool:
    """Recognize ``niet alleen ... maar ook`` after a completed relation."""
    additive_suffix = tokens[branch_end + 1:branch_end + 3]
    has_additive_suffix = (
        additive_suffix[:1] == ["ook"]
        or (
            len(additive_suffix) == 2
            and additive_suffix[0] in DUTCH_ADDITIVE_MODIFIERS
            and additive_suffix[1] == "ook"
        )
    )
    return (
        tokens[negation_index:negation_index + 2] == ["niet", "alleen"]
        and negation_index > max(relation_indices)
        and branch_end < len(tokens)
        and tokens[branch_end] == DUTCH_CONTRAST_TOKEN
        and has_additive_suffix
    )


def dutch_relation_is_positive(
    tokens: list[str], predicate_index: int, object_index: int,
) -> bool:
    """Evaluate a predicate/object relation without crossing ``maar`` polarity.

    A simple relation is safe only when its own branch negates it.  If a
    contrast divides the predicate and object, its right-hand endpoint is the
    asserted alternative; inspect that branch independently.  This covers
    both ``niet X maar Y`` and ``niet alleen X maar Y`` without treating the
    left-side negation as a whole-clause denial.
    """
    predicate_branch = dutch_contrast_branch_bounds(tokens, predicate_index)
    object_branch = dutch_contrast_branch_bounds(tokens, object_index)
    if predicate_branch == object_branch:
        return not dutch_branch_is_negated(
            tokens, *predicate_branch, predicate_index, object_index,
        )

    asserted_index = (
        predicate_index
        if predicate_branch[0] > object_branch[0]
        else object_index
    )
    asserted_branch = dutch_contrast_branch_bounds(tokens, asserted_index)
    return not dutch_branch_is_negated(tokens, *asserted_branch, asserted_index)


def dutch_action_targets_backup(
    tokens: list[str], action_index: int, project_index: int,
) -> bool:
    """Return whether a recovery action's object is a backup, not a project.

    A backup in the action's branch is its direct object unless the deleted
    project is the right-hand contrast alternative. When the project
    introduces the clause, inspect the bounded tokens after the action.
    ``met``, ``vanuit``, ``via``, and ``uit`` denote a backup source, so those
    constructions still describe restoring the project and must block.
    """
    action_branch = dutch_contrast_branch_bounds(tokens, action_index)
    project_branch = dutch_contrast_branch_bounds(tokens, project_index)
    if action_branch[0] < project_branch[0]:
        return False
    if action_index < project_index:
        end = project_index
    else:
        end = min(len(tokens), action_index + DUTCH_RECOVERY_WINDOW + 1)

    for backup_index in range(action_index + 1, end):
        if not tokens[backup_index].startswith("reservekopie"):
            continue
        if dutch_contrast_branch_bounds(tokens, backup_index) != action_branch:
            continue
        return not dutch_backup_has_source_attachment(
            tokens, action_index, backup_index,
        )
    return False


def dutch_backup_has_source_attachment(
    tokens: list[str], action_index: int, backup_index: int,
) -> bool:
    """Return whether a source preposition directly introduces a backup phrase.

    The preposition may be followed by a backup noun directly or by an
    article/possessive and one adjective.  A longer phrase, or one not headed
    by a determiner, is an intervening manner/menu/precaution phrase instead.
    """
    for marker_index in range(backup_index - 1, action_index, -1):
        if tokens[marker_index] not in DUTCH_BACKUP_SOURCE_MARKERS:
            continue
        noun_phrase = tokens[marker_index + 1:backup_index]
        if not noun_phrase:
            return True
        if len(noun_phrase) == 1:
            return noun_phrase[0] in DUTCH_BACKUP_DETERMINERS
        return (
            len(noun_phrase) == 2
            and noun_phrase[0] in DUTCH_BACKUP_DETERMINERS
            and noun_phrase[1] in DUTCH_BACKUP_ADJECTIVES
        )
    return False


def dutch_project_explicitly_remains_deleted(
    tokens: list[str], project_index: int, action_index: int,
) -> bool:
    """Preserve safe copy that says a deleted project remains deleted."""
    start, end = sorted((project_index, action_index))
    relationship = tokens[start:end + 1]
    return any(
        relationship[index] in {"blijft", "blijven"}
        and relationship[index + 1] in {"verwijderd", "verwijderde"}
        for index in range(len(relationship) - 1)
    )


def dutch_deleted_project_recovery_claim(value: str) -> bool:
    """Detect a deleted-project plus restore/put-back relationship per clause."""
    for tokens in dutch_claim_clauses(value):
        project_indices = [
            index + 1
            for index in range(len(tokens) - 1)
            if tokens[index] in {"verwijderd", "verwijderde"}
            and tokens[index + 1] in {"project", "projecten"}
        ]
        action_indices = [
            index
            for index, token in enumerate(tokens)
            if token.startswith(("herstel", "terugzet"))
            or (
                token == "zet"
                and "terug" in tokens[index + 1:index + DUTCH_RECOVERY_WINDOW + 1]
            )
        ]
        for project_index in project_indices:
            for action_index in action_indices:
                if not 0 < abs(action_index - project_index) <= DUTCH_RECOVERY_WINDOW:
                    continue
                if not dutch_relation_is_positive(tokens, action_index, project_index):
                    continue
                if dutch_project_explicitly_remains_deleted(
                    tokens, project_index, action_index,
                ):
                    continue
                if dutch_action_targets_backup(tokens, action_index, project_index):
                    continue
                return True
    return False


def dutch_share_predicate_indices(tokens: list[str]) -> list[int]:
    """Return bounded Share-language predicates, including passive display."""
    predicates = [
        index for index, token in enumerate(tokens)
        if token in DUTCH_SHARE_STATE_VERBS
    ]
    for index, token in enumerate(tokens):
        if token != "ingesteld" or "op" not in tokens[index + 1:index + 3]:
            continue
        if any(marker in {"is", "zijn"} for marker in tokens[max(0, index - 3):index]):
            predicates.append(index)
    return predicates


def dutch_share_subject_is_excluded(
    tokens: list[str], share_index: int, predicate_index: int, language_index: int,
) -> bool:
    """Keep ``Niet het deelscherm maar ...`` out of Share claim detection."""
    share_branch = dutch_contrast_branch_bounds(tokens, share_index)
    if (
        share_branch == dutch_contrast_branch_bounds(tokens, predicate_index)
        or share_branch == dutch_contrast_branch_bounds(tokens, language_index)
    ):
        return False
    if any(
        tokens[index:index + 2] == ["niet", "alleen"]
        for index in range(share_branch[0], share_branch[1] - 1)
    ):
        return False
    return any(
        token in DUTCH_NEGATION_TOKENS
        for token in tokens[share_branch[0]:share_index]
    )


def dutch_share_system_language_claim(value: str) -> bool:
    """Detect a Share surface using or being set to the system language."""
    for tokens in dutch_claim_clauses(value):
        share_indices = [
            index
            for index, token in enumerate(tokens)
            if token in {"deelscherm", "deelschermen"}
            or (
                token == "deel"
                and index + 1 < len(tokens)
                and tokens[index + 1] in {"extensie", "extensies"}
            )
        ]
        system_language_indices = [
            index for index, token in enumerate(tokens) if token == "systeemtaal"
        ]
        for share_index in share_indices:
            for language_index in system_language_indices:
                if abs(share_index - language_index) > DUTCH_SHARE_WINDOW:
                    continue
                if any(
                    max(share_index, predicate_index, language_index)
                    - min(share_index, predicate_index, language_index)
                    <= DUTCH_SHARE_WINDOW
                    and not dutch_share_subject_is_excluded(
                        tokens, share_index, predicate_index, language_index,
                    )
                    and dutch_relation_is_positive(
                        tokens, predicate_index, language_index,
                    )
                    for predicate_index in dutch_share_predicate_indices(tokens)
                ):
                    return True
    return False


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
    if dutch_deleted_project_recovery_claim(searchable):
        errors.append(f"{path}: copy: forbidden release claim: deleted project recovery")
    if dutch_share_system_language_claim(searchable):
        errors.append(f"{path}: copy: forbidden release claim: Share system-only language")

    for name in ("Support URL", "Marketing URL", "Privacy URL"):
        value = fields.get(name, "")
        if value and not value.startswith("https://"):
            errors.append(f"{path}: {name}: must use HTTPS")

    contract = LANGUAGE_CONTRACTS.get(path.name)
    whats_new = fields.get("What's New", "")
    normalized_whats_new = normalized_claim_text(whats_new)
    for concept, pattern in V151_FORBIDDEN_WHATS_NEW_PATTERNS:
        if pattern.search(normalized_whats_new):
            errors.append(f"{path}: copy: forbidden release claim: {concept}")
    if contract is not None:
        description = fields.get("Description", "")
        versions = re.findall(r"(?<![0-9])1\.\d+(?:\.\d+)?(?![0-9])", whats_new)
        version = contract.get("version", "1.4.1")
        if versions != [version]:
            errors.append(f"{path}: What's New: must identify KnitNote {version} exactly")
        if whats_new != contract.get("approved_whats_new", whats_new):
            errors.append(
                f"{path}: What's New: must match the approved {version} release note exactly"
            )
        for language in contract.get("whats_new_languages", contract["languages"][6:]):
            if language.casefold() not in whats_new.casefold():
                errors.append(f"{path}: What's New: missing added language: {language}")
        for relationship in contract.get("whats_new_relationships", ()):
            if relationship.casefold() not in whats_new.casefold():
                errors.append(
                    f"{path}: What's New: missing implemented 1.5.1 behavior: {relationship}"
                )
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
