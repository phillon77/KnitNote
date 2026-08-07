from __future__ import annotations

import hashlib
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

from PIL import Image, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compose import compose_frame, font_for


class KoreanHeadlineRenderingTests(unittest.TestCase):
    def test_korean_font_selection_rejects_a_tofu_only_font(self) -> None:
        missing_font = ImageFont.truetype(
            "/System/Library/Fonts/SFNS.ttf",
            size=48,
            index=0,
        )
        with patch("compose.ImageFont.truetype", return_value=missing_font):
            with self.assertRaisesRegex(OSError, "required ko glyph"):
                font_for("ko", 48)

    def test_hangul_pixels_are_distinct_from_the_missing_glyph_mask(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw = root / "Raw" / "ko" / "iphone" / "raw.png"
            raw.parent.mkdir(parents=True)
            Image.new("RGB", (320, 640), (255, 255, 255)).save(raw)
            frame = {
                "locale": "ko",
                "platform": "iphone",
                "scene": "projects",
                "device": "fixture",
                "width": 320,
                "height": 640,
                "filename": "raw.png",
            }
            hangul = compose_frame(
                {**frame, "headline": "프"},
                root,
                root / "Hangul",
            )
            tofu = compose_frame(
                {**frame, "headline": chr(0x10FFFF)},
                root,
                root / "Tofu",
            )
            with Image.open(hangul) as rendered, Image.open(tofu) as missing:
                self.assertNotEqual(
                    hashlib.sha256(rendered.tobytes()).digest(),
                    hashlib.sha256(missing.tobytes()).digest(),
                    "Hangul rendered with the missing-glyph tofu mask",
                )


if __name__ == "__main__":
    unittest.main()
