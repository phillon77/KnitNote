import json
import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).parent))
from knitting_calculator_localization_check import SUPPORTED_APP_LOCALES, validate_catalog, validate_catalog_pair


class LocalizationContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self) -> None:
        self.directory.cleanup()

    def catalog(
        self,
        locales=SUPPORTED_APP_LOCALES,
        *,
        english="Calculate %lld stitches",
        values=None,
        source_language="en",
        nested=False,
        variation_values=None,
        key="calculator.title",
    ) -> Path:
        values = values or {locale: (english if locale == "en" else f"{locale} translation") for locale in locales}
        localizations = {
            locale: {"stringUnit": {"state": "translated", "value": values.get(locale, "")}}
            for locale in locales
        }
        entry = {"localizations": localizations}
        if nested:
            entry = {
                "localizations": {
                    locale: {
                        "variations": {
                            "device": {
                                "iphone": {"stringUnit": {"state": "translated", "value": (variation_values or {}).get(locale, (unit["stringUnit"]["value"], unit["stringUnit"]["value"]))[0]}},
                                "ipad": {"stringUnit": {"state": "translated", "value": (variation_values or {}).get(locale, (unit["stringUnit"]["value"], unit["stringUnit"]["value"]))[1]}},
                            }
                        }
                    }
                    for locale, unit in localizations.items()
                }
            }
        payload = {"sourceLanguage": source_language, "strings": {key: entry}}
        path = self.root / "Localizable.xcstrings"
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def validate(self, path: Path) -> list[str]:
        return validate_catalog(path)

    def test_rejects_missing_locale(self) -> None:
        catalog = self.catalog(locales=("en", "zh-Hant"))
        errors = self.validate(catalog)
        self.assertTrue(any("missing locales" in error and "zh-Hans" in error for error in errors), errors)

    def test_rejects_extra_locale(self) -> None:
        catalog = self.catalog(locales=SUPPORTED_APP_LOCALES + ("es",))
        errors = self.validate(catalog)
        self.assertTrue(any("extra locales" in error and "es" in error for error in errors), errors)

    def test_rejects_missing_localization_for_key(self) -> None:
        catalog = self.catalog()
        payload = json.loads(catalog.read_text(encoding="utf-8"))
        del payload["strings"]["calculator.title"]["localizations"]["de"]
        catalog.write_text(json.dumps(payload), encoding="utf-8")
        errors = self.validate(catalog)
        self.assertTrue(any("de" in error and "missing locales" in error for error in errors), errors)

    def test_rejects_empty_or_untranslated_value(self) -> None:
        catalog = self.catalog(values={locale: ("" if locale == "de" else ("source" if locale == "fr" else ("Calculate %lld stitches" if locale == "en" else f"{locale} translation"))) for locale in SUPPORTED_APP_LOCALES})
        payload = json.loads(catalog.read_text(encoding="utf-8"))
        payload["strings"]["calculator.title"]["localizations"]["fr"]["stringUnit"]["state"] = "needs_review"
        catalog.write_text(json.dumps(payload), encoding="utf-8")
        errors = self.validate(catalog)
        self.assertTrue(any(": de: incomplete translation" in error for error in errors), errors)
        self.assertTrue(any(": fr: incomplete translation" in error for error in errors), errors)

    def test_rejects_placeholder_change(self) -> None:
        catalog = self.catalog(
            english="Increase %lld stitch every %lld rows",
            values={locale: ("Increase %lld stitch every %lld rows" if locale == "en" else ("%lld Maschen zunehmen" if locale == "de" else f"{locale} translation")) for locale in SUPPORTED_APP_LOCALES},
        )
        errors = self.validate(catalog)
        self.assertTrue(any("placeholder mismatch" in error for error in errors), errors)

    def test_rejects_copied_english_unless_invariant(self) -> None:
        catalog = self.catalog(values={locale: ("Calculate %lld stitches" if locale in ("en", "de") else f"{locale} translation") for locale in SUPPORTED_APP_LOCALES})
        errors = self.validate(catalog)
        self.assertTrue(any(": de: copied English" in error for error in errors), errors)

    def test_allows_explicit_locale_invariant(self) -> None:
        catalog = self.catalog(values={locale: ("KnitNote" if locale != "en" else "KnitNote") for locale in SUPPORTED_APP_LOCALES})
        errors = self.validate(catalog)
        self.assertFalse(any("copied English" in error for error in errors), errors)

    def test_rejects_copied_english_for_ordinary_unit_key(self) -> None:
        catalog = self.catalog(
            key="unit.setupGuide",
            values={locale: ("Read the full setup guide" if locale != "en" else "Read the full setup guide") for locale in SUPPORTED_APP_LOCALES},
        )
        errors = self.validate(catalog)
        self.assertTrue(any(": de: copied English" in error for error in errors), errors)

    def test_rejects_url_with_unapproved_trailing_text(self) -> None:
        catalog = self.catalog(
            key="support.url",
            values={locale: ("https://example.com/help - learn more" if locale != "en" else "https://example.com/help - learn more") for locale in SUPPORTED_APP_LOCALES},
        )
        errors = self.validate(catalog)
        self.assertTrue(any(": de: copied English" in error for error in errors), errors)

    def test_rejects_partially_copied_nested_variation(self) -> None:
        catalog = self.catalog(
            nested=True,
            variation_values={
                "en": ("One %lld", "Many %lld"),
                "de": ("One %lld", "Viele %lld"),
                **{locale: (f"{locale} one %lld", f"{locale} many %lld") for locale in SUPPORTED_APP_LOCALES if locale not in ("en", "de")},
            },
        )
        errors = self.validate(catalog)
        self.assertTrue(any(": de: copied English" in error for error in errors), errors)

    def test_rejects_non_english_source_language(self) -> None:
        catalog = self.catalog(source_language="zh-Hant")
        errors = self.validate(catalog)
        self.assertTrue(any("sourceLanguage" in error and "expected en" in error for error in errors), errors)

    def test_rejects_different_locale_sets_between_catalogs(self) -> None:
        localizable = self.catalog()
        info = self.root / "InfoPlist.xcstrings"
        payload = json.loads(localizable.read_text(encoding="utf-8"))
        del payload["strings"]["calculator.title"]["localizations"]["fi"]
        info.write_text(json.dumps(payload), encoding="utf-8")
        errors = validate_catalog_pair(localizable, info)
        self.assertTrue(any("catalog locale set mismatch" in error for error in errors), errors)

    def test_accepts_nested_variation(self) -> None:
        catalog = self.catalog(english="KnitNote", values={locale: "KnitNote" for locale in SUPPORTED_APP_LOCALES}, nested=True)
        self.assertEqual([], self.validate(catalog))


if __name__ == "__main__":
    unittest.main()
