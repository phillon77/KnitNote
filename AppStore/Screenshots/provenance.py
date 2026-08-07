#!/usr/bin/env python3
"""Strict candidate identity and screenshot byte provenance."""

from __future__ import annotations

import hashlib
import argparse
import json
import os
import plistlib
from pathlib import Path, PurePosixPath


PRODUCT_IDS = {"ios": "com.phillon.KnitNote", "watch": "com.phillon.KnitNote.watch", "macos": "com.phillon.KnitNote"}
PRODUCT_EXECUTABLES = {"ios": "KnitNote", "watch": "KnitNoteWatch", "macos": "KnitNote"}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest_keys(frames: list[dict]) -> list[str]:
    keys = []
    for frame in frames:
        filename = frame["filename"]
        if PurePosixPath(filename).name != filename or filename in {"", ".", ".."}:
            raise ValueError(f"unsafe screenshot filename: {filename}")
        keys.append(f"{frame['locale']}/{frame['platform']}/{filename}")
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate screenshot inventory key")
    return sorted(keys)


def product_snapshot(apps: dict[str, Path], commit: str, version: str, build: str) -> dict:
    products = {}
    for name, app in apps.items():
        plist_path = app / ("Contents/Info.plist" if name == "macos" else "Info.plist")
        info = plistlib.loads(plist_path.read_bytes())
        executable_name = info.get("CFBundleExecutable")
        executable = app / (f"Contents/MacOS/{executable_name}" if name == "macos" else executable_name or "")
        expected = (PRODUCT_IDS[name], version, build, commit)
        actual = (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"), str(info.get("CFBundleVersion", "")), info.get("KnitNoteSourceRevision"))
        if actual != expected or not executable_name or not executable.is_file() or executable.is_symlink():
            raise ValueError(f"{name} screenshot product identity does not match candidate")
        products[name] = {
            "bundleIdentifier": actual[0], "version": actual[1], "build": actual[2],
            "sourceRevision": actual[3], "executable": executable_name,
            "executableSHA256": sha256(executable),
        }
    return products


def file_inventory(root: Path, keys: list[str]) -> dict[str, str]:
    actual = sorted(path.relative_to(root).as_posix() for path in root.rglob("*.png") if path.is_file() and not path.is_symlink())
    if actual != keys:
        raise ValueError(f"screenshot inventory differs from manifest; expected {len(keys)}, found {len(actual)}")
    return {key: sha256(root / key) for key in keys}


def canonical(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def load(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if path.read_bytes() != canonical(value):
        raise ValueError(f"non-canonical provenance: {path}")
    return value


def create_raw(manifest: Path, raw: Path, commit: str, version: str, build: str, products: dict) -> dict:
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    keys = manifest_keys(payload["frames"])
    return {
        "schemaVersion": 1,
        "candidate": {"commit": commit, "version": version, "build": build},
        "manifestSHA256": sha256(manifest),
        "locales": list(dict.fromkeys(frame["locale"] for frame in payload["frames"])),
        "products": products,
        "rawScreenshots": file_inventory(raw, keys),
    }


def validate_candidate_evidence(provenance: dict) -> None:
    candidate = provenance.get("candidate", {})
    commit = candidate.get("commit", "")
    version = candidate.get("version", "")
    build = candidate.get("build", "")
    products = provenance.get("products", {})
    if (
        len(commit) != 40
        or any(character not in "0123456789abcdef" for character in commit)
        or not version
        or not build
        or set(products) != set(PRODUCT_IDS)
    ):
        raise ValueError("raw candidate provenance schema is invalid")
    for name, product in products.items():
        if (
            product.get("bundleIdentifier") != PRODUCT_IDS[name]
            or product.get("version") != version
            or product.get("build") != build
            or product.get("sourceRevision") != commit
            or product.get("executable") != PRODUCT_EXECUTABLES[name]
            or len(product.get("executableSHA256", "")) != 64
            or any(character not in "0123456789abcdef" for character in product.get("executableSHA256", ""))
        ):
            raise ValueError(f"raw {name} product provenance is invalid")


def validate_expected_candidate(
    provenance: dict,
    expected_commit: str | None,
    expected_version: str | None,
    expected_build: str | None,
) -> None:
    expected = (expected_commit, expected_version, expected_build)
    if expected == (None, None, None):
        return
    if any(value is None for value in expected):
        raise ValueError("expected immutable candidate identity is incomplete")
    candidate = provenance.get("candidate", {})
    actual = (
        candidate.get("commit"),
        candidate.get("version"),
        candidate.get("build"),
    )
    if actual != expected:
        raise ValueError("generated screenshots do not match the expected immutable candidate")


def verify_raw(manifest: Path, raw: Path) -> dict:
    provenance = load(raw / "candidate-provenance.json")
    validate_candidate_evidence(provenance)
    candidate = provenance["candidate"]
    commit = candidate["commit"]
    version = candidate["version"]
    build = candidate["build"]
    products = provenance["products"]
    expected = create_raw(manifest, raw, commit, version, build, products)
    if provenance != expected:
        raise ValueError("raw screenshot provenance mismatch")
    return provenance


def create_generated(manifest: Path, raw: Path, generated: Path, composer: Path) -> dict:
    provenance = verify_raw(manifest, raw)
    frames = json.loads(manifest.read_text(encoding="utf-8"))["frames"]
    result = dict(provenance)
    result["rawProvenanceSHA256"] = sha256(raw / "candidate-provenance.json")
    result["compositionToolSHA256"] = sha256(composer)
    result["generatedScreenshots"] = file_inventory(generated, manifest_keys(frames))
    return result


def verify_generated(
    manifest: Path,
    raw: Path,
    generated: Path,
    composer: Path,
    *,
    expected_commit: str | None = None,
    expected_version: str | None = None,
    expected_build: str | None = None,
) -> dict:
    provenance = load(generated / "candidate-provenance.json")
    if (raw / "candidate-provenance.json").is_file():
        expected = create_generated(manifest, raw, generated, composer)
        if provenance != expected:
            raise ValueError("generated screenshot provenance mismatch")
    else:
        validate_candidate_evidence(provenance)
        frames = json.loads(manifest.read_text(encoding="utf-8"))["frames"]
        keys = manifest_keys(frames)
        locales = list(dict.fromkeys(frame["locale"] for frame in frames))
        raw_hashes = provenance.get("rawScreenshots", {})
        raw_provenance_hash = provenance.get("rawProvenanceSHA256", "")
        if (
            set(provenance) != {"schemaVersion", "candidate", "manifestSHA256", "locales", "products", "rawScreenshots", "rawProvenanceSHA256", "compositionToolSHA256", "generatedScreenshots"}
            or provenance.get("schemaVersion") != 1
            or provenance.get("locales") != locales
            or provenance.get("manifestSHA256") != sha256(manifest)
            or sorted(raw_hashes) != keys
            or any(len(value) != 64 or any(character not in "0123456789abcdef" for character in value) for value in raw_hashes.values())
            or provenance.get("compositionToolSHA256") != sha256(composer)
            or provenance.get("generatedScreenshots") != file_inventory(generated, keys)
            or len(raw_provenance_hash) != 64
            or any(character not in "0123456789abcdef" for character in raw_provenance_hash)
        ):
            raise ValueError("durable generated screenshot provenance mismatch")
    validate_expected_candidate(
        provenance,
        expected_commit,
        expected_version,
        expected_build,
    )
    return provenance


def atomic_write(path: Path, value: dict) -> None:
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    temporary.write_bytes(canonical(value))
    os.replace(temporary, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    snapshot = sub.add_parser("snapshot")
    raw = sub.add_parser("create-raw")
    for command in (snapshot, raw):
        command.add_argument("--commit", required=True)
        command.add_argument("--version", required=True)
        command.add_argument("--build", required=True)
        command.add_argument("--ios-app", type=Path, required=True)
        command.add_argument("--watch-app", type=Path, required=True)
        command.add_argument("--macos-app", type=Path, required=True)
        command.add_argument("--output", type=Path, required=True)
    raw.add_argument("--manifest", type=Path, required=True)
    raw.add_argument("--raw-root", type=Path, required=True)
    arguments = parser.parse_args()
    apps = {"ios": arguments.ios_app, "watch": arguments.watch_app, "macos": arguments.macos_app}
    products = product_snapshot(apps, arguments.commit, arguments.version, arguments.build)
    if arguments.command == "snapshot":
        atomic_write(arguments.output, products)
    else:
        atomic_write(arguments.output, create_raw(arguments.manifest, arguments.raw_root, arguments.commit, arguments.version, arguments.build, products))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
