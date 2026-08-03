#!/usr/bin/env python3
"""Build a deterministic, privacy-checked SketchUp steel-shape archive."""

from __future__ import annotations

import argparse
import hashlib
import re
import shutil
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


TAG_RE = re.compile(r"^steel-v\d+\.\d+\.\d+$")
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
FORBIDDEN_ARTIFACT_SUFFIXES = {".pdf", ".dxf", ".dwg", ".fcstd", ".blend"}
MACHINE_PATH_MARKERS = (b"c:\\users\\", b"c:/users/")
TEXT_METADATA_NAMES = {"copying", "license", "notice"}
TEXT_METADATA_SUFFIXES = {".md", ".txt"}


@dataclass(frozen=True)
class BuildArtifacts:
    versioned: Path
    latest: Path
    checksums: Path


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _release_member_bytes(path: Path) -> bytes:
    content = path.read_bytes()
    if (
        path.name.casefold() in TEXT_METADATA_NAMES
        or path.suffix.casefold() in TEXT_METADATA_SUFFIXES
    ):
        try:
            text = content.decode("utf-8")
        except UnicodeDecodeError as error:
            raise RuntimeError(
                f"steel release member is not valid UTF-8 text metadata: {path.name}"
            ) from error
        if "\x00" in text:
            raise RuntimeError(
                f"steel release text metadata contains a NUL byte: {path.name}"
            )
        return text.replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")
    return content


def _source_files(source_dir: Path) -> tuple[Path, ...]:
    source = source_dir.resolve(strict=True)
    candidates = sorted(
        source.rglob("*"), key=lambda candidate: candidate.relative_to(source).as_posix()
    )
    files: list[Path] = []
    for candidate in candidates:
        if candidate.is_symlink():
            raise RuntimeError("steel release payload contains a linked entry")
        if not candidate.is_file():
            continue
        relative = candidate.relative_to(source)
        if candidate.suffix.casefold() in FORBIDDEN_ARTIFACT_SUFFIXES:
            raise RuntimeError("steel release payload contains a private CAD/PDF artifact extension")
        content = _release_member_bytes(candidate)
        folded = content.lower()
        if any(marker in folded for marker in MACHINE_PATH_MARKERS):
            raise RuntimeError("steel release payload contains a machine-bound path")
        if relative.parts and any(part in {"__pycache__", ".pytest_cache"} for part in relative.parts):
            raise RuntimeError("steel release payload contains generated cache data")
        files.append(candidate)
    if not files:
        raise RuntimeError("steel release payload is empty")
    return tuple(files)


def build(source_dir: Path, out_dir: Path, tag: str) -> BuildArtifacts:
    if not TAG_RE.fullmatch(tag):
        raise ValueError("a canonical steel release tag is required")
    source = Path(source_dir).resolve(strict=True)
    destination = Path(out_dir).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    version = tag.removeprefix("steel-")
    versioned = destination / f"Structural-Steel-SU-Shapes-{version}.zip"
    latest = destination / "Structural-Steel-SU-Shapes-latest.zip"
    checksums = destination / "SHA256SUMS.txt"

    files = _source_files(source)
    with zipfile.ZipFile(
        versioned,
        mode="w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as archive:
        for path in files:
            relative = path.relative_to(source).as_posix()
            info = zipfile.ZipInfo(relative, ZIP_TIMESTAMP)
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, _release_member_bytes(path), compresslevel=9)

    shutil.copyfile(versioned, latest)
    digest = _sha256(versioned)
    checksums.write_text(
        f"{digest}  {versioned.name}\n{digest}  {latest.name}\n",
        encoding="ascii",
        newline="\n",
    )
    return BuildArtifacts(versioned=versioned, latest=latest, checksums=checksums)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--source", type=Path, default=Path("steel_shapes"))
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    artifacts = build(args.source, args.out_dir, args.tag)
    for path in (artifacts.versioned, artifacts.latest, artifacts.checksums):
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
