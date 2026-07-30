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
    def metadata(
        self,
        *,
        copyright_value: str = "© 2026 Chen Chung Lung",
        apple_id: str = "6795877892",
    ) -> str:
        return f"""\
- Name: Gauge Tool
- Subtitle: Even Rows
- Promotional text: Free offline tool.
- Keywords: needle,yarn
- Description: Useful calculator.
- Support URL: https://example.com/support
- Privacy URL: https://example.com/privacy
- What's New: First release.
- Copyright: {copyright_value}
- Apple ID: {apple_id}
"""

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
