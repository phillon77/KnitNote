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
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "en-US.md"
            path.write_text(metadata, encoding="utf-8")
            errors = module.validate(path)
        self.assertTrue(any("repeats Name, Subtitle, or category" in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main()
