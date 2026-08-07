#!/usr/bin/env python3
"""Create or verify the deterministic byte inventory for a release candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath


APP_ROOTS = (
    Path("KnitNote-iOS-Privacy.xcarchive/Products/Applications/KnitNote.app"),
    Path("KnitNote-macOS-Privacy.xcarchive/Products/Applications/KnitNote.app"),
)
ARCHIVE_PLISTS = (
    Path("KnitNote-iOS-Privacy.xcarchive/Info.plist"),
    Path("KnitNote-macOS-Privacy.xcarchive/Info.plist"),
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def inventory(root: Path) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    candidates: list[Path] = list(ARCHIVE_PLISTS)
    for relative_root in APP_ROOTS:
        absolute_root = root / relative_root
        if not absolute_root.is_dir():
            raise ValueError(f"missing release bundle: {relative_root.as_posix()}")
        candidates.extend(
            path.relative_to(root)
            for path in absolute_root.rglob("*")
            if path.is_symlink() or not path.is_dir()
        )
    for relative in sorted(set(candidates), key=lambda value: value.as_posix().encode()):
        normalized = PurePosixPath(relative.as_posix())
        if normalized.is_absolute() or ".." in normalized.parts:
            raise ValueError(f"unsafe inventory path: {relative}")
        path = root / relative
        if path.is_symlink():
            target = os.readlink(path)
            resolved = (path.parent / target).resolve()
            try:
                resolved.relative_to(root.resolve())
            except ValueError as error:
                raise ValueError(f"inventory symlink escapes archive root: {relative}") from error
            entries.append({"path": normalized.as_posix(), "type": "symlink", "sha256": digest(target.encode())})
        elif path.is_file():
            entries.append({"path": normalized.as_posix(), "type": "file", "sha256": digest(path.read_bytes())})
        else:
            raise ValueError(f"missing or special inventory entry: {relative}")
    return entries


def payload(root: Path, commit: str) -> dict:
    if len(commit) != 40 or any(character not in "0123456789abcdef" for character in commit):
        raise ValueError("source commit must be forty lowercase hexadecimal characters")
    return {"schemaVersion": 1, "sourceCommit": commit, "inventory": inventory(root)}


def canonical(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("create")
    create.add_argument("--archives", type=Path, required=True)
    create.add_argument("--source-commit", required=True)
    create.add_argument("--output", type=Path, required=True)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--archives", type=Path, required=True)
    verify.add_argument("--source-commit", required=True)
    verify.add_argument("--input", type=Path, required=True)
    arguments = parser.parse_args()
    expected = payload(arguments.archives.resolve(), arguments.source_commit)
    if arguments.command == "create":
        temporary = arguments.output.with_name(f".{arguments.output.name}.tmp.{os.getpid()}")
        temporary.write_bytes(canonical(expected))
        os.replace(temporary, arguments.output)
        return 0
    actual = json.loads(arguments.input.read_text(encoding="utf-8"))
    if actual != expected or arguments.input.read_bytes() != canonical(actual):
        raise SystemExit("release archive provenance inventory mismatch")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
