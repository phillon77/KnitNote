#!/usr/bin/env python3
"""Create or verify the deterministic byte inventory for a release candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
from pathlib import Path, PurePosixPath


CANONICAL_PROVENANCE = Path("provenance.json")
REQUIRED_ARCHIVE_ROOTS = (
    Path("KnitNote-iOS-Privacy.xcarchive"),
    Path("KnitNote-macOS-Privacy.xcarchive"),
)
REQUIRED_ARCHIVE_INFO_PLISTS = (
    Path("KnitNote-iOS-Privacy.xcarchive/Info.plist"),
    Path("KnitNote-macOS-Privacy.xcarchive/Info.plist"),
)
REQUIRED_ARCHIVE_APP_ROOTS = (
    Path("KnitNote-iOS-Privacy.xcarchive/Products/Applications/KnitNote.app"),
    Path("KnitNote-macOS-Privacy.xcarchive/Products/Applications/KnitNote.app"),
)
DEFAULT_EXPORT_OPTIONS = Path(__file__).with_name("ExportOptions-AppStore.plist")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def reject_lexical_symlink_components(root: Path, path: Path, label: str) -> None:
    lexical_root = root.absolute()
    lexical_path = path.absolute()
    try:
        relative = lexical_path.relative_to(lexical_root)
    except ValueError as error:
        raise ValueError(f"release artifact escapes archive root: {label}") from error
    current = lexical_root
    for component in relative.parts:
        current = current / component
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError as error:
            raise ValueError(f"missing release artifact: {label}") from error
        if stat.S_ISLNK(mode):
            raise ValueError(f"release artifact contains an unsafe symlink: {label}")


def require_regular_file(path: Path, label: str, root: Path | None = None) -> None:
    if root is not None:
        reject_lexical_symlink_components(root, path, label)
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"missing or unsafe release artifact: {label}")
    if root is not None:
        try:
            path.resolve(strict=True).relative_to(root.resolve(strict=True))
        except ValueError as error:
            raise ValueError(f"release artifact escapes archive root: {label}") from error


def inventory(root: Path) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    if root.is_symlink() or not root.is_dir():
        raise ValueError("release archive root is missing or unsafe")
    for relative in REQUIRED_ARCHIVE_ROOTS + REQUIRED_ARCHIVE_APP_ROOTS:
        path = root / relative
        reject_lexical_symlink_components(root, path, relative.as_posix())
        if path.is_symlink() or not path.is_dir():
            raise ValueError(f"missing release archive directory: {relative.as_posix()}")
    for relative in REQUIRED_ARCHIVE_INFO_PLISTS:
        require_regular_file(root / relative, relative.as_posix(), root)
    candidates: list[Path] = []
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if relative == CANONICAL_PROVENANCE:
            continue
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            reject_lexical_symlink_components(root, path, relative.as_posix())
            continue
        candidates.append(relative)
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


def export_options_record(path: Path) -> dict[str, str]:
    require_regular_file(path, "AppStore/Verification/ExportOptions-AppStore.plist")
    return {
        "path": "AppStore/Verification/ExportOptions-AppStore.plist",
        "sha256": digest(path.read_bytes()),
    }


def payload(root: Path, commit: str, export_options: Path) -> dict:
    if len(commit) != 40 or any(character not in "0123456789abcdef" for character in commit):
        raise ValueError("source commit must be forty lowercase hexadecimal characters")
    return {
        "schemaVersion": 2,
        "sourceCommit": commit,
        "exportOptions": export_options_record(export_options),
        "inventory": inventory(root),
    }


def canonical(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("create")
    create.add_argument("--archives", type=Path, required=True)
    create.add_argument("--source-commit", required=True)
    create.add_argument("--output", type=Path, required=True)
    create.add_argument("--export-options", type=Path, default=DEFAULT_EXPORT_OPTIONS)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--archives", type=Path, required=True)
    verify.add_argument("--source-commit", required=True)
    verify.add_argument("--input", type=Path, required=True)
    verify.add_argument("--export-options", type=Path, default=DEFAULT_EXPORT_OPTIONS)
    arguments = parser.parse_args()
    if arguments.archives.is_symlink():
        raise SystemExit("release archive root must not be a symlink")
    expected = payload(
        arguments.archives.resolve(),
        arguments.source_commit,
        arguments.export_options,
    )
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
