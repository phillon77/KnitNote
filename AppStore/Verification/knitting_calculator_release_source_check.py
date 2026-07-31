#!/usr/bin/env python3
"""Formatting-independent source checks for the calculator release audit."""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path


STOREKIT_IMPORT = re.compile(
    r"(?m)^[ \t]*import[ \t]+"
    r"(?:(?:class|enum|func|protocol|struct|typealias|var|let)[ \t]+)?"
    r"StoreKit(?:\.[A-Za-z_][A-Za-z0-9_]*)*[ \t]*$"
)
ALLOWED_STOREKIT_IMPORT = "import enum StoreKit.AppStore"
ALLOWED_RATING_EXECUTABLE_SURFACE_SHA256 = (
    "e8dff65d6b72b4fd45e1da5e099d9aee2569391014040b55c3a6df88893115f9"
)


def strip_swift_comments_and_strings(source: str) -> str:
    """Replace comments and string literals with spaces, preserving newlines."""

    stripped = list(source)
    length = len(source)
    interpolation_found = False

    def blank(start: int, end: int) -> None:
        for position in range(start, min(end, length)):
            if stripped[position] != "\n":
                stripped[position] = " "

    position = 0
    while position < length:
        if source.startswith("//", position):
            end = source.find("\n", position + 2)
            if end == -1:
                end = length
            blank(position, end)
            position = end
            continue

        if source.startswith("/*", position):
            depth = 1
            end = position + 2
            while end < length and depth > 0:
                if source.startswith("/*", end):
                    depth += 1
                    end += 2
                elif source.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            blank(position, end)
            position = end
            continue

        hash_count = 0
        quote_position = position
        if source[position] == "#":
            while (
                quote_position < length
                and source[quote_position] == "#"
            ):
                hash_count += 1
                quote_position += 1

        if (
            quote_position < length
            and source[quote_position] == '"'
            and (position == quote_position or hash_count > 0)
        ):
            triple_quoted = source.startswith('"""', quote_position)
            quote = '"""' if triple_quoted else '"'
            terminator = quote + ("#" * hash_count)
            interpolation = "\\" + ("#" * hash_count) + "("
            end = quote_position + len(quote)
            while end < length:
                if source.startswith(terminator, end):
                    end += len(terminator)
                    break
                if source.startswith(interpolation, end):
                    interpolation_found = True
                    end += len(interpolation)
                    continue
                if (
                    hash_count == 0
                    and source[end] == "\\"
                    and end + 1 < length
                ):
                    end += 2
                else:
                    end += 1
            blank(position, end)
            position = end
            continue

        position += 1

    sanitized = "".join(stripped)
    if interpolation_found:
        sanitized += "\n__swift_string_interpolation__"
    return sanitized


def verify_rating_storekit_surface(path: Path) -> bool:
    source = strip_swift_comments_and_strings(path.read_text(encoding="utf-8"))
    imports = [
        " ".join(match.group(0).split())
        for match in STOREKIT_IMPORT.finditer(source)
    ]
    if imports != [ALLOWED_STOREKIT_IMPORT]:
        return False

    body = STOREKIT_IMPORT.sub("", source)
    if re.search(r"\bStoreKit\b", body):
        return False

    app_store_members = re.findall(
        r"\bAppStore\b(?:[ \t\r\n]*\.[ \t\r\n]*"
        r"([A-Za-z_][A-Za-z0-9_]*))?",
        body,
    )
    if app_store_members != ["requestReview"]:
        return False

    # RatingEligibility.swift is the sole StoreKit exception in the product.
    # Lock its complete executable token surface so a newly introduced,
    # unqualified StoreKit API cannot bypass an API-name denylist. Comments,
    # string contents, and formatting remain intentionally outside the lock.
    normalized = re.sub(r"\s+", " ", source).strip()
    digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
    return digest == ALLOWED_RATING_EXECUTABLE_SURFACE_SHA256


def verify_package_manifest(path: Path) -> bool:
    source = strip_swift_comments_and_strings(path.read_text(encoding="utf-8"))
    normalized = re.sub(r"\s+", " ", source)
    return re.search(r"\btype\s*:\s*\.dynamic\b", normalized) is None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "check",
        choices=("rating-storekit", "package-manifest"),
    )
    parser.add_argument("path", type=Path)
    arguments = parser.parse_args()

    if arguments.check == "rating-storekit":
        valid = verify_rating_storekit_surface(arguments.path)
    else:
        valid = verify_package_manifest(arguments.path)
    return 0 if valid else 1


if __name__ == "__main__":
    sys.exit(main())
