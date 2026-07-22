#!/usr/bin/env python3
"""Validate KnitNote's App Store screenshot manifest and generated images."""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

from PIL import Image


DENYLIST = ("lzz.1999", "/Users/", "IMG_", "截圖", "GPSLatitude", "GPSLongitude")
EXPECTED_COUNTS = {"iphone": 5, "ipad": 4, "mac": 3, "watch": 2}
EXPECTED_SIZES = {
    "iphone": (1320, 2868),
    "ipad": (2064, 2752),
    "mac": (2880, 1800),
    "watch": (416, 496),
}


def fail(message: str) -> None:
    raise ValueError(message)


def load_manifest(path: Path) -> list[dict]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    frames = payload.get("frames")
    if payload.get("schemaVersion") != 1 or not isinstance(frames, list):
        fail("manifest schemaVersion must be 1 and frames must be an array")
    return frames


def validate_manifest(frames: list[dict]) -> None:
    if len(frames) != 28:
        fail(f"expected 28 frames, found {len(frames)}")
    required = {"locale", "platform", "scene", "device", "width", "height", "headline", "filename"}
    for index, frame in enumerate(frames, 1):
        missing = required - frame.keys()
        if missing:
            fail(f"frame {index} missing: {', '.join(sorted(missing))}")
        if frame["locale"] not in {"zh-Hant", "en"}:
            fail(f"frame {index} has unsupported locale")
        platform = frame["platform"]
        if platform not in EXPECTED_SIZES:
            fail(f"frame {index} has unsupported platform")
        if (frame["width"], frame["height"]) != EXPECTED_SIZES[platform]:
            fail(f"frame {index} has incorrect dimensions")
        serialized = json.dumps(frame, ensure_ascii=False)
        if any(term in serialized for term in DENYLIST):
            fail(f"frame {index} contains private-data marker")
        if frame["locale"] == "zh-Hant" and "圖解" in frame["headline"]:
            fail(f"frame {index} uses the retired term 圖解; use 織圖")

    for locale in ("zh-Hant", "en"):
        localized = [frame for frame in frames if frame["locale"] == locale]
        if len(localized) != 14:
            fail(f"{locale} must contain 14 frames")
        counts = Counter(frame["platform"] for frame in localized)
        if dict(counts) != EXPECTED_COUNTS:
            fail(f"{locale} platform counts are incorrect: {dict(counts)}")
        filenames = [frame["filename"] for frame in localized]
        if len(filenames) != len(set(filenames)):
            fail(f"{locale} contains duplicate filenames")
        for frame in localized:
            headline = frame["headline"]
            if locale == "zh-Hant" and not any("\u4e00" <= char <= "\u9fff" for char in headline):
                fail(f"{frame['filename']} is missing a Traditional Chinese headline")
            if locale == "en" and not headline.isascii():
                fail(f"{frame['filename']} is not an English headline")


def validate_images(root: Path, frames: list[dict]) -> None:
    for frame in frames:
        path = root / "Generated" / frame["locale"] / frame["platform"] / frame["filename"]
        if not path.is_file():
            fail(f"missing generated screenshot: {path}")
        with Image.open(path) as image:
            if image.size != (frame["width"], frame["height"]):
                fail(f"incorrect image size: {path} is {image.size}")
            if image.mode != "RGB":
                fail(f"image must be opaque RGB without alpha: {path} is {image.mode}")
            metadata = json.dumps(image.info, ensure_ascii=False, default=str)
            if any(term in metadata for term in DENYLIST):
                fail(f"private-data marker in image metadata: {path}")


def main() -> int:
    if len(sys.argv) not in {2, 3} or (len(sys.argv) == 3 and sys.argv[2] != "--manifest-only"):
        print("usage: validate.py <manifest.json> [--manifest-only]", file=sys.stderr)
        return 2
    manifest_path = Path(sys.argv[1]).resolve()
    try:
        frames = load_manifest(manifest_path)
        validate_manifest(frames)
        if "--manifest-only" not in sys.argv:
            validate_images(manifest_path.parent, frames)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"SCREENSHOT VALIDATION: FAIL — {error}", file=sys.stderr)
        return 1
    print("28 screenshot definitions valid" if "--manifest-only" in sys.argv else "28 screenshots valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
