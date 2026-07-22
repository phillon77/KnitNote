#!/usr/bin/env python3
"""Compose real KnitNote UI captures onto a restrained watercolor frame."""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


BERRY = (166, 57, 115)
INK = (48, 58, 82)
PALE_BLUE = (229, 239, 255)
LAVENDER = (241, 235, 255)
SOFT_WHITE = (255, 253, 255)


def font_for(locale: str, size: int) -> ImageFont.FreeTypeFont:
    candidates = (
        ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Medium.ttc"]
        if locale == "zh-Hant"
        else ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"]
    )
    for candidate in candidates:
        try:
            return ImageFont.truetype(candidate, size=size, index=0)
        except OSError:
            continue
    return ImageFont.load_default(size=size)


def fit_font(draw: ImageDraw.ImageDraw, text: str, locale: str, max_width: int, max_size: int) -> ImageFont.ImageFont:
    for size in range(max_size, max(12, max_size // 2), -2):
        font = font_for(locale, size)
        if draw.textbbox((0, 0), text, font=font)[2] <= max_width:
            return font
    return font_for(locale, max(12, max_size // 2))


def watercolor_background(size: tuple[int, int]) -> Image.Image:
    width, height = size
    background = Image.new("RGB", size, SOFT_WHITE)
    wash = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(wash)
    blobs = [
        (-0.12, -0.08, 0.62, 0.34, (*PALE_BLUE, 180)),
        (0.46, -0.09, 1.16, 0.30, (*LAVENDER, 175)),
        (-0.18, 0.72, 0.52, 1.10, (221, 239, 255, 150)),
        (0.56, 0.70, 1.16, 1.12, (248, 224, 244, 135)),
    ]
    for x0, y0, x1, y1, color in blobs:
        draw.ellipse((int(x0 * width), int(y0 * height), int(x1 * width), int(y1 * height)), fill=color)
    wash = wash.filter(ImageFilter.GaussianBlur(max(14, width // 30)))
    background.paste(wash, mask=wash.getchannel("A"))
    return background


def draw_flower(draw: ImageDraw.ImageDraw, center: tuple[int, int], radius: int) -> None:
    x, y = center
    petal = (255, 255, 255, 205)
    for angle in range(0, 360, 90):
        dx = math.cos(math.radians(angle)) * radius
        dy = math.sin(math.radians(angle)) * radius
        draw.ellipse((x + dx - radius * .55, y + dy - radius * .55,
                      x + dx + radius * .55, y + dy + radius * .55), fill=petal)
    draw.ellipse((x - radius * .42, y - radius * .42, x + radius * .42, y + radius * .42), fill=(249, 195, 83, 235))


def compose_frame(frame: dict, root: Path) -> Path:
    width, height = frame["width"], frame["height"]
    raw_path = root / "Raw" / frame["locale"] / frame["platform"] / frame["filename"]
    if not raw_path.is_file():
        raise FileNotFoundError(f"missing raw capture: {raw_path}")

    canvas = watercolor_background((width, height))
    draw = ImageDraw.Draw(canvas, "RGBA")
    scale = 0.89 if frame["platform"] == "watch" else 0.90
    box_width, box_height = int(width * scale), int(height * scale)
    left, top = (width - box_width) // 2, height - box_height
    radius = max(14, width // 38)

    shadow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle((left, top, left + box_width, top + box_height), radius=radius, fill=(52, 59, 87, 45))
    shadow = shadow.filter(ImageFilter.GaussianBlur(max(8, width // 95)))
    canvas.paste(shadow, mask=shadow.getchannel("A"))

    with Image.open(raw_path) as source:
        capture = ImageOps.fit(source.convert("RGB"), (box_width, box_height), method=Image.Resampling.LANCZOS)
    mask = Image.new("L", (box_width, box_height), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, box_width, box_height), radius=radius, fill=255)
    canvas.paste(capture, (left, top), mask)

    headline_y = max(4, int(top * .18))
    max_font = max(14, int(top * (0.34 if frame["platform"] != "watch" else 0.24)))
    font = fit_font(draw, frame["headline"], frame["locale"], int(width * .86), max_font)
    bbox = draw.textbbox((0, 0), frame["headline"], font=font)
    text_x = (width - (bbox[2] - bbox[0])) // 2
    draw.text((text_x, headline_y), frame["headline"], font=font, fill=(*BERRY, 255))

    accent = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    accent_draw = ImageDraw.Draw(accent, "RGBA")
    flower_radius = max(3, width // 130)
    draw_flower(accent_draw, (int(width * .055), max(flower_radius * 2, int(top * .47))), flower_radius)
    draw_flower(accent_draw, (int(width * .945), max(flower_radius * 2, int(top * .56))), flower_radius)
    canvas.paste(accent, mask=accent.getchannel("A"))

    output = root / "Generated" / frame["locale"] / frame["platform"] / frame["filename"]
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(output, format="PNG", optimize=True)
    return output


def make_contact_sheet(locale: str, frames: list[dict], root: Path) -> Path:
    columns = 4
    cell_width, cell_height = 360, 470
    rows = math.ceil(len(frames) / columns)
    sheet = Image.new("RGB", (columns * cell_width, rows * cell_height), SOFT_WHITE)
    draw = ImageDraw.Draw(sheet)
    caption_font = font_for(locale, 20)
    for index, frame in enumerate(frames):
        source_path = root / "Generated" / locale / frame["platform"] / frame["filename"]
        with Image.open(source_path) as source:
            thumbnail = ImageOps.contain(source.convert("RGB"), (cell_width - 28, cell_height - 68))
        x = index % columns * cell_width + (cell_width - thumbnail.width) // 2
        y = index // columns * cell_height + 12
        sheet.paste(thumbnail, (x, y))
        caption = f"{index + 1:02d} · {frame['platform']}"
        draw.text((index % columns * cell_width + 14, y + thumbnail.height + 12), caption, font=caption_font, fill=INK)
    output = root / "Generated" / locale / "contact-sheet.jpg"
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output, format="JPEG", quality=90, optimize=True)
    return output


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: compose.py <manifest.json>", file=sys.stderr)
        return 2
    manifest_path = Path(sys.argv[1]).resolve()
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    try:
        for frame in payload["frames"]:
            print(compose_frame(frame, manifest_path.parent))
        for locale in ("zh-Hant", "en"):
            localized_frames = [frame for frame in payload["frames"] if frame["locale"] == locale]
            print(make_contact_sheet(locale, localized_frames, manifest_path.parent))
    except (KeyError, OSError, ValueError) as error:
        print(f"SCREENSHOT COMPOSITION: FAIL — {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
