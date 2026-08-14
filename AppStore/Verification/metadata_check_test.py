#!/usr/bin/env python3
"""Regression tests for the repository App Store metadata validator."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


def metadata_check_module():
    path = Path(__file__).with_name("metadata_check.py")
    spec = importlib.util.spec_from_file_location("metadata_check", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MetadataCheckTests(unittest.TestCase):
    CALCULATOR_METADATA_FILENAMES = (
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

    def metadata(
        self,
        *,
        copyright_value: str = "© 2026 Chen Chung Lung",
        apple_id: str = "6795877892",
        whats_new: str = "Version 1.0.1 adds support for Simplified Chinese, German, French, Japanese, Korean, Dutch, Norwegian Bokmål, Swedish, Finnish, Danish, and Greek.",
    ) -> str:
        return f"""\
- Name: Gauge Tool
- Subtitle: Even Rows
- Promotional text: Free offline tool.
- Keywords: needle,yarn
- Description: Useful calculator.
- Support URL: https://example.com/support
- Privacy URL: https://example.com/privacy
- What's New: {whats_new}
- Copyright: {copyright_value}
- Apple ID: {apple_id}
"""

    def write_complete_calculator_metadata(self, directory: Path) -> Path:
        root = directory / "AppStore/KnittingCalculator/Metadata"
        root.mkdir(parents=True)
        for filename in self.CALCULATOR_METADATA_FILENAMES:
            (root / filename).write_text(self.metadata(), encoding="utf-8")
        return root

    def validate_calculator_text(self, metadata: str, filename: str = "en-US.md") -> list[str]:
        module = metadata_check_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "AppStore/KnittingCalculator/Metadata"
            root.mkdir(parents=True)
            path = root / filename
            path.write_text(metadata, encoding="utf-8")
            return module.validate(path)

    def test_calculator_metadata_exports_canonical_locale_filenames(self) -> None:
        module = metadata_check_module()
        self.assertEqual(self.CALCULATOR_METADATA_FILENAMES, module.CALCULATOR_METADATA_FILENAMES)

    def test_repository_calculator_metadata_package_is_valid(self) -> None:
        module = metadata_check_module()
        root = Path(__file__).parents[1] / "KnittingCalculator/Metadata"
        self.assertEqual([], module.validate_root(root))

    def test_general_metadata_root_does_not_require_calculator_locale_set(self) -> None:
        module = metadata_check_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "AppStore/Metadata"
            root.mkdir(parents=True)
            (root / "en-US.md").write_text(self.metadata(), encoding="utf-8")
            (root / "zh-Hant.md").write_text(self.metadata(), encoding="utf-8")
            errors = module.validate_root(root)
        self.assertFalse(any("metadata locales" in error for error in errors), errors)

    def test_nonexistent_general_metadata_root_requires_both_established_files(self) -> None:
        module = metadata_check_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "AppStore/Metadata"
            errors = module.validate_root(root)
        self.assertTrue(any("en-US.md: file:" in error for error in errors), errors)
        self.assertTrue(any("zh-Hant.md: file:" in error for error in errors), errors)

    def test_empty_general_metadata_root_requires_both_established_files(self) -> None:
        module = metadata_check_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "AppStore/Metadata"
            root.mkdir(parents=True)
            errors = module.validate_root(root)
        self.assertTrue(any("en-US.md: file:" in error for error in errors), errors)
        self.assertTrue(any("zh-Hant.md: file:" in error for error in errors), errors)

    def test_general_metadata_root_rejects_each_missing_established_file(self) -> None:
        module = metadata_check_module()
        for present, missing in (("en-US.md", "zh-Hant.md"), ("zh-Hant.md", "en-US.md")):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "AppStore/Metadata"
                root.mkdir(parents=True)
                (root / present).write_text(self.metadata(), encoding="utf-8")
                errors = module.validate_root(root)
            self.assertTrue(any(f"{missing}: file:" in error for error in errors), errors)

    def test_general_metadata_root_validates_additional_markdown_files(self) -> None:
        module = metadata_check_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "AppStore/Metadata"
            root.mkdir(parents=True)
            (root / "en-US.md").write_text(self.metadata(), encoding="utf-8")
            (root / "zh-Hant.md").write_text(self.metadata(), encoding="utf-8")
            additional = root / "it-IT.md"
            additional.write_text("- Name: Broken\n", encoding="utf-8")
            errors = module.validate_root(root)
        self.assertIn(f"{additional}: Subtitle: required non-empty field", errors)

    def test_calculator_metadata_requires_exact_locale_set(self) -> None:
        module = metadata_check_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "AppStore/KnittingCalculator/Metadata"
            root.mkdir(parents=True)
            (root / "en-US.md").write_text(self.metadata(), encoding="utf-8")
            errors = module.validate_root(root)
        self.assertTrue(any("missing metadata locales" in error for error in errors), errors)

    def test_calculator_metadata_rejects_extra_locale(self) -> None:
        module = metadata_check_module()
        with tempfile.TemporaryDirectory() as directory:
            root = self.write_complete_calculator_metadata(Path(directory))
            (root / "it-IT.md").write_text(self.metadata(), encoding="utf-8")
            errors = module.validate_root(root)
        self.assertTrue(any("unexpected metadata locales" in error for error in errors), errors)

    def test_calculator_metadata_rejects_non_language_release_note(self) -> None:
        module = metadata_check_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "AppStore/KnittingCalculator/Metadata"
            root.mkdir(parents=True)
            path = root / "en-US.md"
            path.write_text(self.metadata(whats_new="First release."), encoding="utf-8")
            errors = module.validate(path)
        self.assertIn(
            f"{path}: What's New: must contain only the approved 1.0.1 language expansion",
            errors,
        )

    def test_calculator_metadata_requires_every_structured_field(self) -> None:
        required = (
            "Name",
            "Subtitle",
            "Promotional text",
            "Keywords",
            "Description",
            "Support URL",
            "Privacy URL",
            "What's New",
            "Copyright",
            "Apple ID",
        )
        for field in required:
            with self.subTest(field=field):
                metadata = "\n".join(
                    line
                    for line in self.metadata().splitlines()
                    if not line.startswith(f"- {field}:")
                )
                errors = self.validate_calculator_text(metadata)
                self.assertTrue(
                    any(f": {field}: required non-empty field" in error for error in errors),
                    errors,
                )

    def test_rejects_storefront_fields_over_character_limits(self) -> None:
        cases = {
            "Name": "N" * 31,
            "Subtitle": "S" * 31,
            "Promotional text": "P" * 171,
        }
        for field, value in cases.items():
            with self.subTest(field=field):
                metadata = self.metadata().replace(
                    next(line for line in self.metadata().splitlines() if line.startswith(f"- {field}:")),
                    f"- {field}: {value}",
                )
                errors = self.validate_calculator_text(metadata)
                self.assertTrue(any(f": {field}:" in error and "limit is" in error for error in errors), errors)

    def test_rejects_keywords_over_utf8_byte_limit(self) -> None:
        metadata = self.metadata().replace(
            "- Keywords: needle,yarn",
            f"- Keywords: {'線' * 34}",
        )
        errors = self.validate_calculator_text(metadata)
        self.assertTrue(any("Keywords: 102 UTF-8 bytes; limit is 100" in error for error in errors), errors)

    def test_rejects_non_https_support_and_privacy_urls(self) -> None:
        metadata = self.metadata().replace("https://example.com", "http://example.com")
        errors = self.validate_calculator_text(metadata)
        self.assertTrue(any(": Support URL: must use HTTPS" in error for error in errors), errors)
        self.assertTrue(any(": Privacy URL: must use HTTPS" in error for error in errors), errors)

    def test_rejects_duplicate_keywords(self) -> None:
        metadata = self.metadata().replace("- Keywords: needle,yarn", "- Keywords: needle,yarn,needle")
        errors = self.validate_calculator_text(metadata)
        self.assertTrue(any("Keywords: duplicates: needle" in error for error in errors), errors)

    def test_rejects_unsupported_release_claim(self) -> None:
        metadata = self.metadata().replace("Free offline tool.", "Cloud sync for every project.")
        errors = self.validate_calculator_text(metadata)
        self.assertTrue(any("forbidden release claim: cloud sync" in error for error in errors), errors)

    def test_rejects_unapproved_claims_in_every_calculator_locale(self) -> None:
        added_claims = {
            "en-US.md": "Your drafts are backed up online.",
            "zh-Hant.md": "支援跨裝置雲端同步。",
            "zh-Hans.md": "支持跨设备云端同步。",
            "de-DE.md": "Ein Abonnement schaltet weitere Funktionen frei.",
            "fr-FR.md": "Un compte est nécessaire pour sauvegarder les calculs.",
            "ja-JP.md": "広告が表示されます。",
            "ko-KR.md": "사용 분석 정보를 수집합니다.",
            "nl-NL.md": "Activiteit wordt gevolgd voor personalisatie.",
            "nb-NO.md": "Ekstra verktøy kan kjøpes i appen.",
            "sv-SE.md": "Utkast synkroniseras via molnet.",
            "fi-FI.md": "Tilaus avaa lisäominaisuuksia.",
            "da-DK.md": "En konto er nødvendig for at gemme beregninger.",
            "el-GR.md": "Η εφαρμογή εμφανίζει διαφημίσεις.",
        }
        metadata_root = Path(__file__).parents[1] / "KnittingCalculator/Metadata"
        for filename, claim in added_claims.items():
            with self.subTest(filename=filename):
                metadata = (metadata_root / filename).read_text(encoding="utf-8")
                metadata = metadata.replace(
                    "- Description: |",
                    f"- Description: |\n  {claim}",
                    1,
                )
                errors = self.validate_calculator_text(metadata, filename)
                self.assertTrue(
                    any("does not match approved localized claims" in error for error in errors),
                    errors,
                )

    def test_rejects_keyword_that_repeats_name_or_subtitle(self) -> None:
        module = metadata_check_module()
        metadata = """\
- Name: Gauge Tool
- Subtitle: Even Rows
- Promotional text: Free offline tool.
- Keywords: gauge,needle
- Description: Useful calculator.
- Support URL: https://example.com/support
- Privacy URL: https://example.com/privacy
- What's New: First release.
- Copyright: © 2026 Chen Chung Lung
- Apple ID: 6795877892
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "en-US.md"
            path.write_text(metadata, encoding="utf-8")
            errors = module.validate(path)
        self.assertTrue(any("repeats Name, Subtitle, or category" in error for error in errors), errors)

    def test_requires_exact_calculator_copyright(self) -> None:
        module = metadata_check_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "AppStore/KnittingCalculator/Metadata"
            root.mkdir(parents=True)
            path = root / "en-US.md"
            path.write_text(
                self.metadata(copyright_value="© 2026 Another Developer"),
                encoding="utf-8",
            )
            errors = module.validate(path)
        self.assertIn(
            f"{path}: Copyright: must be © 2026 Chen Chung Lung",
            errors,
        )

    def test_requires_exact_calculator_apple_id(self) -> None:
        module = metadata_check_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "AppStore/KnittingCalculator/Metadata"
            root.mkdir(parents=True)
            path = root / "zh-Hant.md"
            path.write_text(self.metadata(apple_id="6793023054"), encoding="utf-8")
            errors = module.validate(path)
        self.assertIn(f"{path}: Apple ID: must be 6795877892", errors)

    def test_requires_structured_calculator_identity_fields(self) -> None:
        module = metadata_check_module()
        metadata = self.metadata()
        metadata = "\n".join(
            line
            for line in metadata.splitlines()
            if not line.startswith(("- Copyright:", "- Apple ID:"))
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "AppStore/KnittingCalculator/Metadata"
            root.mkdir(parents=True)
            path = root / "en-US.md"
            path.write_text(metadata, encoding="utf-8")
            errors = module.validate(path)
        self.assertIn(f"{path}: Copyright: required non-empty field", errors)
        self.assertIn(f"{path}: Apple ID: required non-empty field", errors)

    def test_general_metadata_does_not_require_calculator_identity(self) -> None:
        module = metadata_check_module()
        metadata = self.metadata()
        metadata = "\n".join(
            line
            for line in metadata.splitlines()
            if not line.startswith(("- Copyright:", "- Apple ID:"))
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "AppStore/Metadata"
            root.mkdir(parents=True)
            path = root / "en-US.md"
            path.write_text(metadata, encoding="utf-8")
            errors = module.validate(path)
        self.assertFalse(
            any("Copyright" in error or "Apple ID" in error for error in errors),
            errors,
        )


if __name__ == "__main__":
    unittest.main()
