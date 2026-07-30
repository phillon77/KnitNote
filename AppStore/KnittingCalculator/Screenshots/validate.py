#!/usr/bin/env python3
"""Validate Knitting Calculator App Store screenshot inputs and outputs."""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

from PIL import Image


EXPECTED_COUNTS = {"iphone": 5, "ipad": 4}
EXPECTED_SIZES = {"iphone": (1284, 2778), "ipad": (2064, 2752)}
LOCALES = {"zh-Hant", "en"}
CAPTURE_ENVIRONMENT = {
    "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    "iphoneDeviceTypeIdentifier": (
        "com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max"
    ),
    "ipadDeviceTypeIdentifier": (
        "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
    ),
    "statusBarTime": "9:41",
    "cropSystemDate": True,
}
DENYLIST = ("lzz.1999", "/Users/", "IMG_", "截圖", "GPSLatitude", "GPSLongitude")
REQUIRED_FIELDS = {
    "locale", "platform", "scene", "device", "width", "height", "headline",
    "subheadline", "filename",
}
PATH_FIELDS = ("locale", "platform", "filename")


def fail(message: str) -> None:
    raise ValueError(message)


def contains_denylisted_marker(value: str) -> bool:
    return any(marker in value for marker in DENYLIST)


def contains_denylisted_bytes(value: bytes) -> bool:
    return any(marker.encode("utf-8") in value for marker in DENYLIST)


def validate_path_component(value: object, field: str) -> None:
    if (
        not isinstance(value, str)
        or not value
        or value in {".", ".."}
        or value.startswith("/")
        or "/" in value
        or "\\" in value
        or any(character in value for character in "\t\r\n")
    ):
        fail(f"{field} must be a single safe path component")


def validate_path_fields(frame: dict) -> None:
    for field in PATH_FIELDS:
        validate_path_component(frame.get(field), field)


def validate_capture_environment(environment: object) -> None:
    if not isinstance(environment, dict):
        fail("manifest captureEnvironment must be an object")
    if environment != CAPTURE_ENVIRONMENT:
        fail("manifest captureEnvironment must pin the approved screenshot environment")


def load_manifest(path: Path) -> list[dict]:
    raw = path.read_text(encoding="utf-8")
    if contains_denylisted_marker(raw):
        fail("manifest contains private-data marker")
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        fail("manifest payload must be an object")
    frames = payload.get("frames")
    if payload.get("schemaVersion") != 2 or not isinstance(frames, list):
        fail("manifest schemaVersion must be 2 and frames must be an array")
    validate_capture_environment(payload.get("captureEnvironment"))
    return frames


def validate_manifest(frames: list[dict]) -> None:
    if len(frames) != 18:
        fail(f"expected 18 frames, found {len(frames)}")

    filenames: set[tuple[str, str, str]] = set()
    for index, frame in enumerate(frames, 1):
        if not isinstance(frame, dict):
            fail(f"frame {index} must be an object")
        missing = REQUIRED_FIELDS - frame.keys()
        if missing:
            fail(f"frame {index} missing: {', '.join(sorted(missing))}")
        validate_path_fields(frame)
        if frame["locale"] not in LOCALES:
            fail(f"frame {index} has unsupported locale")
        platform = frame["platform"]
        if platform not in EXPECTED_SIZES:
            fail(f"frame {index} has unsupported platform")
        if (frame["width"], frame["height"]) != EXPECTED_SIZES[platform]:
            fail(f"frame {index} has incorrect dimensions")
        if contains_denylisted_marker(json.dumps(frame, ensure_ascii=False)):
            fail(f"frame {index} contains private-data marker")
        key = (frame["locale"], platform, frame["filename"])
        if key in filenames:
            fail(f"{frame['locale']} {platform} contains duplicate filenames")
        filenames.add(key)
        headline = frame["headline"]
        if frame["locale"] == "zh-Hant" and not any("\u4e00" <= character <= "\u9fff" for character in headline):
            fail(f"{frame['filename']} is missing a Traditional Chinese headline")
        if frame["locale"] == "en" and not headline.isascii():
            fail(f"{frame['filename']} is not an English headline")

    for locale in LOCALES:
        counts = Counter(frame["platform"] for frame in frames if frame["locale"] == locale)
        if dict(counts) != EXPECTED_COUNTS:
            fail(f"{locale} platform counts are incorrect: {dict(counts)}")


def validate_images(root: Path, frames: list[dict]) -> None:
    for frame in frames:
        raw_path = root / "Raw" / frame["locale"] / frame["platform"] / frame["filename"]
        generated_path = root / "Generated" / frame["locale"] / frame["platform"] / frame["filename"]
        for label, path in (("raw", raw_path), ("generated", generated_path)):
            if not path.is_file():
                fail(f"missing {label} screenshot: {path}")
            if contains_denylisted_bytes(path.read_bytes()):
                fail(f"private-data marker in encoded image: {path}")
        with Image.open(raw_path) as raw:
            if raw.size != (frame["width"], frame["height"]):
                fail(f"incorrect raw image size: {raw_path} is {raw.size}")
        with Image.open(generated_path) as generated:
            if generated.size != (frame["width"], frame["height"]):
                fail(f"incorrect image size: {generated_path} is {generated.size}")
            if generated.mode != "RGB":
                fail(f"generated image must be opaque RGB: {generated_path} is {generated.mode}")
            metadata = json.dumps(generated.info, ensure_ascii=False, default=str)
            if contains_denylisted_marker(metadata):
                fail(f"private-data marker in image metadata: {generated_path}")


def main() -> int:
    if len(sys.argv) not in {2, 3} or (len(sys.argv) == 3 and sys.argv[2] != "--manifest-only"):
        print("usage: validate.py <manifest.json> [--manifest-only]", file=sys.stderr)
        return 2
    manifest_path = Path(sys.argv[1]).resolve()
    try:
        frames = load_manifest(manifest_path)
        validate_manifest(frames)
        manifest_only = "--manifest-only" in sys.argv
        if not manifest_only:
            validate_images(manifest_path.parent, frames)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"SCREENSHOT VALIDATION: FAIL — {error}", file=sys.stderr)
        return 1
    print("18 screenshot definitions valid" if manifest_only else "18 screenshots valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
