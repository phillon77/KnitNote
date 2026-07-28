#!/usr/bin/env python3
"""Regression tests for complete Knitting Calculator support-page coverage."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class SiteCheckTests(unittest.TestCase):
    def test_calculator_support_page_gets_structural_and_link_checks(self) -> None:
        valid_page = "<html lang=\"en\"><body><h1>Support</h1><a href=\"mailto:lzz.1999@icloud.com\">Email</a></body></html>"
        privacy_page = """<html lang=\"en\"><body><h1>Privacy</h1><a href=\"mailto:lzz.1999@icloud.com\">Email</a>
        不需要帳號 不含廣告 不會跨 App 或網站追蹤 requires no account no advertising does not track you across apps or websites
        </body></html>"""
        invalid_calculator_page = "<html lang=\"en\"><body><script src=\"https://example.com/a.js\"></script><a href=\"missing.html\">Missing</a><a href=\"mailto:lzz.1999@icloud.com\">Email</a></body></html>"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "styles.css").write_text(":focus-visible {} @media (prefers-reduced-motion: reduce) {}", encoding="utf-8")
            for name in ("index.html", "support.html", "404.html"):
                (root / name).write_text(valid_page, encoding="utf-8")
            (root / "privacy.html").write_text(privacy_page, encoding="utf-8")
            (root / "knitting-calculator.html").write_text(invalid_calculator_page, encoding="utf-8")
            (root / "knitting-calculator-privacy.html").write_text(invalid_calculator_page, encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("site_check.py")), str(root)],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("knitting-calculator.html: missing h1", result.stderr)
        self.assertIn("knitting-calculator.html: scripts and iframes are forbidden", result.stderr)
        self.assertIn("knitting-calculator.html: broken relative link: missing.html", result.stderr)
        self.assertIn("knitting-calculator.html: external resource: https://example.com/a.js", result.stderr)
        self.assertIn("knitting-calculator-privacy.html: missing h1", result.stderr)
        self.assertIn("knitting-calculator-privacy.html: scripts and iframes are forbidden", result.stderr)


if __name__ == "__main__":
    unittest.main()
