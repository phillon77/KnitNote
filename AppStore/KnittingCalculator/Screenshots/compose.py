#!/usr/bin/env python3
"""Compose real Knitting Calculator UI into the approved B-style frame."""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


INK = (48, 42, 58)
BERRY = (119, 72, 153)
PALE_BLUE = (235, 242, 255)
LAVENDER = (242, 236, 255)
BLUSH = (252, 232, 246)
SOFT_WHITE = (255, 253, 255)


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
        raise ValueError(f"{field} must be a single safe path component")


def validate_path_fields(frame: dict) -> None:
    for field in ("locale", "platform", "filename"):
        validate_path_component(frame.get(field), field)


def font_for(locale: str, size: int) -> ImageFont.ImageFont:
    candidates = (
        (
            "/System/Library/Fonts/PingFang.ttc",
            "/System/Library/Fonts/STHeiti Medium.ttc",
        )
        if locale == "zh-Hant"
        else (
            "/System/Library/Fonts/SFNS.ttf",
            "/System/Library/Fonts/Helvetica.ttc",
        )
    )
    for candidate in candidates:
        try:
            return ImageFont.truetype(candidate, size=size, index=0)
        except OSError:
            continue
    return ImageFont.load_default()


def fit_font(
    draw: ImageDraw.ImageDraw,
    text: str,
    locale: str,
    max_width: int,
    max_size: int,
    min_size: int,
) -> ImageFont.ImageFont:
    for size in range(max_size, min_size - 1, -2):
        font = font_for(locale, size)
        bounds = draw.textbbox((0, 0), text, font=font)
        if bounds[2] - bounds[0] <= max_width:
            return font
    return font_for(locale, min_size)


def watercolor_background(size: tuple[int, int]) -> Image.Image:
    width, height = size
    background = Image.new("RGB", size, SOFT_WHITE)
    wash = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(wash)
    draw.ellipse(
        (-width // 5, -height // 8, width * 3 // 5, height // 3),
        fill=(*PALE_BLUE, 205),
    )
    draw.ellipse(
        (width * 2 // 5, -height // 7, width * 6 // 5, height // 3),
        fill=(*LAVENDER, 195),
    )
    draw.ellipse(
        (width * 3 // 5, height * 3 // 5, width * 6 // 5, height * 11 // 10),
        fill=(*BLUSH, 150),
    )
    wash = wash.filter(ImageFilter.GaussianBlur(max(18, width // 24)))
    background.paste(wash, mask=wash.getchannel("A"))
    return background


def centered_text_x(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.ImageFont,
    width: int,
) -> int:
    bounds = draw.textbbox((0, 0), text, font=font)
    return (width - (bounds[2] - bounds[0])) // 2


def compose_frame(frame: dict, root: Path) -> Path:
    width, height = int(frame["width"]), int(frame["height"])
    raw_path = (
        root
        / "Raw"
        / frame["locale"]
        / frame["platform"]
        / frame["filename"]
    )
    if not raw_path.is_file():
        raise FileNotFoundError(f"missing raw capture: {raw_path}")

    ui_top = int(height * 0.18)
    ui_height = height - ui_top
    ui_width = round(width * ui_height / height)
    ui_left = (width - ui_width) // 2
    corner_radius = max(22, width // 34)

    canvas = watercolor_background((width, height))
    draw = ImageDraw.Draw(canvas)
    max_text_width = int(width * 0.88)
    headline_font = fit_font(
        draw,
        frame["headline"],
        frame["locale"],
        max_text_width,
        max(32, int(height * 0.034)),
        max(22, int(height * 0.021)),
    )
    subheadline_font = fit_font(
        draw,
        frame["subheadline"],
        frame["locale"],
        max_text_width,
        max(24, int(height * 0.020)),
        max(18, int(height * 0.014)),
    )
    headline_y = int(height * 0.035)
    subheadline_y = int(height * 0.105)
    draw.text(
        (
            centered_text_x(draw, frame["headline"], headline_font, width),
            headline_y,
        ),
        frame["headline"],
        font=headline_font,
        fill=BERRY,
    )
    draw.text(
        (
            centered_text_x(draw, frame["subheadline"], subheadline_font, width),
            subheadline_y,
        ),
        frame["subheadline"],
        font=subheadline_font,
        fill=INK,
    )

    shadow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (ui_left, ui_top, ui_left + ui_width, height + corner_radius),
        radius=corner_radius,
        fill=(48, 42, 58, 48),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(max(10, width // 90)))
    canvas.paste(shadow, mask=shadow.getchannel("A"))

    with Image.open(raw_path) as source:
        expected_size = (width, height)
        if source.size != expected_size:
            raise ValueError(
                f"raw capture has size {source.size}, expected {expected_size}: "
                f"{raw_path}"
            )
        capture = source.convert("RGB").resize(
            (ui_width, ui_height),
            Image.Resampling.LANCZOS,
        )
    mask = Image.new("L", (ui_width, ui_height), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, ui_width - 1, ui_height - 1),
        radius=corner_radius,
        fill=255,
    )
    canvas.paste(capture, (ui_left, ui_top), mask)

    output = (
        root
        / "Generated"
        / frame["locale"]
        / frame["platform"]
        / frame["filename"]
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(output, format="PNG", optimize=True)
    return output


def make_contact_sheet(locale: str, frames: list[dict], root: Path) -> Path:
    columns = 3
    cell_width, cell_height = 420, 580
    rows = math.ceil(len(frames) / columns)
    sheet = Image.new(
        "RGB",
        (columns * cell_width, rows * cell_height),
        SOFT_WHITE,
    )
    draw = ImageDraw.Draw(sheet)
    caption_font = font_for(locale, 20)
    for index, frame in enumerate(frames):
        source_path = (
            root
            / "Generated"
            / locale
            / frame["platform"]
            / frame["filename"]
        )
        with Image.open(source_path) as source:
            thumbnail = ImageOps.contain(
                source.convert("RGB"),
                (cell_width - 32, cell_height - 72),
            )
        column, row = index % columns, index // columns
        x = column * cell_width + (cell_width - thumbnail.width) // 2
        y = row * cell_height + 12
        sheet.paste(thumbnail, (x, y))
        draw.text(
            (column * cell_width + 16, y + thumbnail.height + 12),
            f"{index + 1:02d} · {frame['platform']}",
            font=caption_font,
            fill=INK,
        )

    output = root / "Generated" / locale / "contact-sheet.png"
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output, format="PNG", optimize=True)
    return output


def compose_manifest(manifest_path: Path) -> int:
    manifest_path = Path(manifest_path).resolve()
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    frames = payload["frames"]
    for frame in frames:
        validate_path_fields(frame)
        compose_frame(frame, manifest_path.parent)
    locales = list(dict.fromkeys(frame["locale"] for frame in frames))
    for locale in locales:
        localized_frames = [frame for frame in frames if frame["locale"] == locale]
        make_contact_sheet(locale, localized_frames, manifest_path.parent)
    return 0


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: compose.py <manifest.json>", file=sys.stderr)
        return 2
    try:
        return compose_manifest(Path(sys.argv[1]))
    except (KeyError, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"SCREENSHOT COMPOSITION: FAIL — {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
