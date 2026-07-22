#!/usr/bin/env python3
"""Check the dependency-free KnitNote support site."""

from __future__ import annotations

import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.tags: list[str] = []
        self.attrs: list[tuple[str, dict[str, str]]] = []
        self.text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.tags.append(tag)
        self.attrs.append((tag, {key: value or "" for key, value in attrs}))

    def handle_data(self, data: str) -> None:
        self.text.append(data)


def check_page(path: Path, root: Path) -> list[str]:
    errors: list[str] = []
    source = path.read_text(encoding="utf-8")
    parser = PageParser()
    parser.feed(source)
    text = " ".join(parser.text)
    if "script" in parser.tags or "iframe" in parser.tags:
        errors.append(f"{path}: scripts and iframes are forbidden")
    if "h1" not in parser.tags:
        errors.append(f"{path}: missing h1")
    html_attrs = next((attrs for tag, attrs in parser.attrs if tag == "html"), {})
    if not html_attrs.get("lang"):
        errors.append(f"{path}: missing html lang")
    if not any(attrs.get("href", "").startswith("mailto:lzz.1999@icloud.com") for _, attrs in parser.attrs):
        errors.append(f"{path}: missing support mail link")
    if "http://" in source:
        errors.append(f"{path}: insecure URL")
    for tag, attrs in parser.attrs:
        for name in ("href", "src"):
            value = attrs.get(name, "")
            if not value or value.startswith(("#", "mailto:", "https://")):
                continue
            target = value.split("#", 1)[0]
            if target and not (root / target).exists():
                errors.append(f"{path}: broken relative link: {value}")
        if tag in {"script", "img", "link", "iframe"}:
            resource = attrs.get("src") or attrs.get("href", "")
            if urlparse(resource).scheme in {"http", "https"}:
                errors.append(f"{path}: external resource: {resource}")
    if path.name == "privacy.html":
        required = ["不需要帳號", "不含廣告", "不會跨 App 或網站追蹤", "requires no account", "no advertising", "does not track you across apps or websites"]
        for claim in required:
            if claim not in text:
                errors.append(f"{path}: missing privacy claim: {claim}")
    return errors


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: site_check.py AppStore/SupportSite", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    pages = [root / name for name in ("index.html", "support.html", "privacy.html", "404.html")]
    errors = [error for page in pages for error in check_page(page, root)]
    css = (root / "styles.css").read_text(encoding="utf-8")
    if ":focus-visible" not in css:
        errors.append(f"{root / 'styles.css'}: missing visible keyboard focus")
    if "prefers-reduced-motion" not in css:
        errors.append(f"{root / 'styles.css'}: missing reduced-motion policy")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("SITE CHECK: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
