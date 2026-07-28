#!/usr/bin/env python3
"""Single authority for the extension-local Windows Poppler runtime.

The packaged manifest is an exact allowlist, not a manifest generated from an
untrusted installed tree.  Fetching first verifies the pinned archive, stages
the complete runtime, writes this manifest, verifies it, runs the semantic
smoke, and only then performs a transactional replacement.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import zipfile
from pathlib import Path
from typing import Callable

SCHEMA = 1
PINNED_RELEASE_TAG = "v26.02.0-0"
PINNED_ASSET = "Release-26.02.0-0.zip"
PINNED_ASSET_SHA256 = (
    "993e4a94376ed712fafc7058d724ea0b943d118bbd2305cd9ed55174eb85cda5"
)
PINNED_ARCHIVE_ROOT = "poppler-26.02.0"
PINNED_DATA_VERSION = "0.4.12"
PINNED_DATA_URL = "https://poppler.freedesktop.org/poppler-data-0.4.12.tar.gz"
PINNED_DATA_ARCHIVE_SHA256 = (
    "c835b640a40ce357e1b83666aabd95edffa24ddddd49b8daff63adb851cdab74"
)
PINNED_DATA_FILE_COUNT = 271
PINNED_DATA_TOTAL_BYTES = 12_968_872
# SHA-256 of the canonical JSON serialization of all 300 packaged members
# (path, category, byte count, and SHA-256), derived from the independently
# pinned Windows asset, official poppler-data archive, license text, and notice
# templates.  A generated manifest may describe this inventory; it may never
# redefine it.
PINNED_MEMBER_INVENTORY_SHA256 = (
    "a2c5d125fee4f3af1893556501efd50455a953ed7eb77c8a0d094819db2f5654"
)
GPL3_TEXT_URL = "https://www.gnu.org/licenses/gpl-3.0.txt"
GPL3_TEXT_SHA256 = (
    "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"
)
RELEASE_URL = (
    "https://github.com/oschwartz10612/poppler-windows/releases/tag/"
    + PINNED_RELEASE_TAG
)

BIN_REL = Path("Library/bin")
DATA_REL = Path("share/poppler")
MANIFEST_REL = Path("poppler-runtime-manifest.json")
LEGACY_BIN_REL = Path("bin")
RUNTIME_PAYLOAD_ROOTS = (Path("Library"), DATA_REL, MANIFEST_REL)

REQUIRED_HELPERS = ("pdftocairo.exe", "pdftotext.exe", "pdffonts.exe")
PINNED_BINARY_ALLOWLIST = frozenset(
    {
        "cairo.dll",
        "deflate.dll",
        "fontconfig-1.dll",
        "freetype.dll",
        "jpeg8.dll",
        "lcms2.dll",
        "Lerc.dll",
        "libcrypto-3-x64.dll",
        "libcurl.dll",
        "libexpat.dll",
        "liblzma.dll",
        "libpng16.dll",
        "libssh2.dll",
        "openjp2.dll",
        "pdffonts.exe",
        "pdftocairo.exe",
        "pdftotext.exe",
        "pixman-1-0.dll",
        "poppler.dll",
        "tiff.dll",
        "zlib.dll",
        "zstd.dll",
    }
)

PINNED_NOTICE_LICENSE_ALLOWLIST = frozenset(
    {
        Path("Library/THIRD_PARTY_NOTICES.txt"),
        Path("Library/licenses/README.txt"),
        Path("Library/licenses/share_poppler_COPYING"),
        Path("Library/licenses/share_poppler_COPYING.adobe"),
        Path("Library/licenses/share_poppler_COPYING.gpl2"),
        Path("Library/licenses/share_poppler_COPYING.gpl3"),
        Path("Library/licenses/share_poppler_README"),
    }
)

_COMPONENTS = {
    "cairo.dll": ("cairo", ["LGPL-2.1-or-later", "MPL-1.1"]),
    "deflate.dll": ("libdeflate", ["MIT"]),
    "fontconfig-1.dll": ("fontconfig", ["MIT"]),
    "freetype.dll": ("freetype", ["FTL", "GPL-2.0-only"]),
    "jpeg8.dll": ("libjpeg-turbo", ["BSD-3-Clause", "Zlib"]),
    "lcms2.dll": ("little-cms", ["MIT"]),
    "Lerc.dll": ("lerc", ["Apache-2.0"]),
    "libcrypto-3-x64.dll": ("openssl", ["Apache-2.0"]),
    "libcurl.dll": ("curl", ["curl"]),
    "libexpat.dll": ("expat", ["MIT"]),
    "liblzma.dll": ("xz", ["0BSD"]),
    "libpng16.dll": ("libpng", ["Libpng-2.0"]),
    "libssh2.dll": ("libssh2", ["BSD-3-Clause"]),
    "openjp2.dll": ("openjpeg", ["BSD-2-Clause"]),
    "pdffonts.exe": ("poppler", ["GPL-2.0-or-later"]),
    "pdftocairo.exe": ("poppler", ["GPL-2.0-or-later"]),
    "pdftotext.exe": ("poppler", ["GPL-2.0-or-later"]),
    "pixman-1-0.dll": ("pixman", ["MIT"]),
    "poppler.dll": ("poppler", ["GPL-2.0-or-later"]),
    "tiff.dll": ("libtiff", ["libtiff"]),
    "zlib.dll": ("zlib", ["Zlib"]),
    "zstd.dll": ("zstd", ["BSD-3-Clause"]),
}

GB1_FIXTURE_SCOPE = "Adobe-GB1 deterministic fixture only"
GB1_EXPECTED_LINE = "钢结构 W12X30 梁"


class ContractError(RuntimeError):
    pass


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_relative(value: str) -> Path:
    path = Path(value)
    if (
        not value
        or path.is_absolute()
        or ".." in path.parts
        or path.as_posix() != value
        or value.startswith("/")
    ):
        raise ContractError(f"unsafe runtime manifest path: {value!r}")
    return path


def is_runtime_payload(rel: Path) -> bool:
    rel = Path(rel)
    if rel == MANIFEST_REL:
        return True
    if not rel.parts:
        return False
    if rel.parts[0] in {"Library", "bin"}:
        return True
    return len(rel.parts) >= 2 and rel.parts[:2] == ("share", "poppler")


def _category(rel: Path) -> str:
    if rel.parts[:2] == ("Library", "bin"):
        return "binary"
    if rel.name == "THIRD_PARTY_NOTICES.txt":
        return "notice"
    if rel.parts[:2] == ("Library", "licenses"):
        return "license"
    if rel.parts[:2] == ("share", "poppler") and (
        rel.name.startswith("COPYING") or rel.name == "README"
    ):
        return "license"
    return "data"


def _runtime_files(support_root: Path, *, include_legacy: bool = True) -> list[Path]:
    files: list[Path] = []
    roots = [support_root / "Library", support_root / DATA_REL]
    if include_legacy:
        roots.append(support_root / LEGACY_BIN_REL)
    for root in roots:
        if root.is_symlink():
            raise ContractError(f"runtime root must not be a symlink: {root}")
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if path.is_symlink():
                raise ContractError(f"runtime member must not be a symlink: {path}")
            if path.is_file():
                files.append(path)
    return sorted(files)


def _validate_physical_shape(support_root: Path) -> None:
    bin_dir = support_root / BIN_REL
    actual_binaries = {p.name for p in bin_dir.iterdir() if p.is_file()} if bin_dir.is_dir() else set()
    if actual_binaries != PINNED_BINARY_ALLOWLIST:
        missing = sorted(PINNED_BINARY_ALLOWLIST - actual_binaries)
        extra = sorted(actual_binaries - PINNED_BINARY_ALLOWLIST)
        raise ContractError(f"binary allowlist mismatch; missing={missing}, extra={extra}")
    subdirs = [p.name for p in bin_dir.iterdir() if p.is_dir()] if bin_dir.is_dir() else []
    if subdirs:
        raise ContractError(f"binary directory has unreviewed subdirectories: {sorted(subdirs)}")

    actual_notices = {
        p.relative_to(support_root)
        for p in (support_root / "Library").rglob("*")
        if p.is_file() and p.relative_to(support_root).parts[:2] != ("Library", "bin")
    }
    if actual_notices != PINNED_NOTICE_LICENSE_ALLOWLIST:
        missing = sorted(str(p) for p in PINNED_NOTICE_LICENSE_ALLOWLIST - actual_notices)
        extra = sorted(str(p) for p in actual_notices - PINNED_NOTICE_LICENSE_ALLOWLIST)
        raise ContractError(f"notice/license allowlist mismatch; missing={missing}, extra={extra}")

    data_root = support_root / DATA_REL
    if not data_root.is_dir():
        raise ContractError(f"Poppler data directory missing: {data_root}")
    required = (
        "cMap/Adobe-CNS1",
        "cMap/Adobe-GB1",
        "cMap/Adobe-Japan1",
        "cMap/Adobe-Korea1",
        "cidToUnicode/Adobe-CNS1",
        "cidToUnicode/Adobe-GB1",
        "cidToUnicode/Adobe-Japan1",
        "cidToUnicode/Adobe-Korea1",
        "nameToUnicode",
        "unicodeMap",
        "COPYING",
        "COPYING.adobe",
        "COPYING.gpl2",
        "README",
    )
    missing_required = [rel for rel in required if not (data_root / rel).exists()]
    if missing_required:
        raise ContractError(f"full Poppler data inventory missing required paths: {missing_required}")
    data_files = [p for p in data_root.rglob("*") if p.is_file()]
    data_bytes = sum(p.stat().st_size for p in data_files)
    if len(data_files) != PINNED_DATA_FILE_COUNT or data_bytes != PINNED_DATA_TOTAL_BYTES:
        raise ContractError(
            "pinned Poppler data count/size mismatch; "
            f"expected={PINNED_DATA_FILE_COUNT}/{PINNED_DATA_TOTAL_BYTES}, "
            f"actual={len(data_files)}/{data_bytes}"
        )


def _source_contract() -> dict:
    return {
        "release_tag": PINNED_RELEASE_TAG,
        "asset": PINNED_ASSET,
        "asset_sha256": PINNED_ASSET_SHA256,
        "archive_root": PINNED_ARCHIVE_ROOT,
        "poppler_data_version": PINNED_DATA_VERSION,
        "poppler_data_url": PINNED_DATA_URL,
        "poppler_data_root": f"poppler-data-{PINNED_DATA_VERSION}",
        "poppler_data_archive_sha256": PINNED_DATA_ARCHIVE_SHA256,
        "gpl3_text_url": GPL3_TEXT_URL,
        "gpl3_text_sha256": GPL3_TEXT_SHA256,
        "release_url": RELEASE_URL,
    }


def _layout_contract() -> dict:
    return {
        "bin": BIN_REL.as_posix(),
        "data": DATA_REL.as_posix(),
        "manifest": MANIFEST_REL.as_posix(),
    }


def _component_contract() -> dict:
    return {
        (BIN_REL / name).as_posix(): {
            "component": _COMPONENTS[name][0],
            "license_ids": _COMPONENTS[name][1],
        }
        for name in sorted(PINNED_BINARY_ALLOWLIST)
    }


def _build_member_entries(support_root: Path) -> list[dict]:
    members = []
    for path in _runtime_files(support_root, include_legacy=False):
        rel = path.relative_to(support_root)
        members.append(
            {
                "path": rel.as_posix(),
                "category": _category(rel),
                "bytes": path.stat().st_size,
                "sha256": _sha256(path),
            }
        )
    return members


def _member_inventory_digest(members: list[dict]) -> str:
    canonical = json.dumps(
        sorted(members, key=lambda entry: entry["path"]),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode("ascii")
    return hashlib.sha256(canonical).hexdigest()


def _require_pinned_member_inventory(members: list[dict]) -> None:
    actual = _member_inventory_digest(members)
    if actual != PINNED_MEMBER_INVENTORY_SHA256:
        raise ContractError(
            "pinned member inventory digest mismatch; "
            f"expected={PINNED_MEMBER_INVENTORY_SHA256}, actual={actual}"
        )


def build_manifest(support_root: Path, *, license_review: dict) -> dict:
    support_root = Path(support_root).resolve()
    _validate_physical_shape(support_root)
    members = _build_member_entries(support_root)
    _require_pinned_member_inventory(members)
    return {
        "schema": SCHEMA,
        "source": _source_contract(),
        "layout": _layout_contract(),
        "members": members,
        "binary_components": _component_contract(),
        "license_review": license_review,
        "semantic_validation": {
            "scope": GB1_FIXTURE_SCOPE,
            "expected_line": GB1_EXPECTED_LINE,
            "other_standard_collections": "packaged but not semantically proven",
        },
    }


def write_manifest(support_root: Path, *, license_review: dict) -> dict:
    support_root = Path(support_root).resolve()
    manifest = build_manifest(support_root, license_review=license_review)
    target = support_root / MANIFEST_REL
    target.parent.mkdir(parents=True, exist_ok=True)
    temp = target.with_suffix(target.suffix + ".tmp")
    temp.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temp, target)
    return manifest


def _validate_manifest(manifest: dict, *, require_license_approved: bool) -> dict[str, dict]:
    if not isinstance(manifest, dict) or manifest.get("schema") != SCHEMA:
        raise ContractError("runtime manifest schema must be exactly 1")
    if manifest.get("source") != _source_contract():
        raise ContractError("runtime manifest source pin is not the reviewed asset")
    if manifest.get("layout") != _layout_contract():
        raise ContractError("runtime manifest layout is not the extension-local contract")
    if manifest.get("binary_components") != _component_contract():
        raise ContractError("runtime binary component/license mapping is incomplete")
    semantic = manifest.get("semantic_validation")
    if not isinstance(semantic, dict) or semantic.get("scope") != GB1_FIXTURE_SCOPE:
        raise ContractError("runtime semantic claim exceeds the Adobe-GB1 fixture scope")

    review = manifest.get("license_review")
    if not isinstance(review, dict) or review.get("status") not in {"blocked", "approved"}:
        raise ContractError("runtime license review state is missing or invalid")
    if review.get("status") == "approved" and review.get("missing"):
        raise ContractError("approved license review cannot retain missing obligations")
    if review.get("status") == "approved":
        reviewer = review.get("reviewer")
        reviewed_at = review.get("reviewed_at")
        evidence = review.get("evidence")
        if (
            not isinstance(reviewer, str)
            or not reviewer.strip()
            or not isinstance(evidence, str)
            or not evidence.strip()
            or not isinstance(reviewed_at, str)
            or not re.fullmatch(
                r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", reviewed_at
            )
        ):
            raise ContractError(
                "approved license review requires approval metadata: "
                "reviewer, UTC reviewed_at, and evidence"
            )
    if require_license_approved and review.get("status") != "approved":
        raise ContractError(
            f"runtime license review is {review.get('status')}; release requires approved"
        )

    entries = manifest.get("members")
    if not isinstance(entries, list):
        raise ContractError("runtime manifest members must be a list")
    indexed: dict[str, dict] = {}
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            raise ContractError("runtime manifest contains an invalid member")
        rel = _safe_relative(entry["path"])
        if (
            not is_runtime_payload(rel)
            or rel == MANIFEST_REL
            or (rel.parts and rel.parts[0] == LEGACY_BIN_REL.name)
        ):
            raise ContractError(f"runtime manifest member is outside the payload: {rel}")
        if entry.get("category") != _category(rel):
            raise ContractError(f"runtime manifest category mismatch: {rel}")
        if not isinstance(entry.get("bytes"), int) or entry["bytes"] < 0:
            raise ContractError(f"runtime manifest byte count invalid: {rel}")
        digest = entry.get("sha256")
        if not isinstance(digest, str) or len(digest) != 64:
            raise ContractError(f"runtime manifest hash invalid: {rel}")
        if entry["path"] in indexed:
            raise ContractError(f"runtime manifest duplicate member: {rel}")
        indexed[entry["path"]] = entry

    _require_pinned_member_inventory(entries)

    binary_paths = {
        (BIN_REL / name).as_posix() for name in PINNED_BINARY_ALLOWLIST
    }
    actual_binary_paths = {
        path for path in indexed if Path(path).parts[:2] == ("Library", "bin")
    }
    if actual_binary_paths != binary_paths:
        raise ContractError("runtime manifest binary allowlist is not exact")
    expected_notices = {path.as_posix() for path in PINNED_NOTICE_LICENSE_ALLOWLIST}
    actual_notices = {
        path
        for path in indexed
        if Path(path).parts[0] == "Library"
        and Path(path).parts[:2] != ("Library", "bin")
    }
    if actual_notices != expected_notices:
        raise ContractError("runtime manifest notice/license allowlist is not exact")
    data_entries = [
        entry for path, entry in indexed.items() if Path(path).parts[:2] == ("share", "poppler")
    ]
    if (
        len(data_entries) != PINNED_DATA_FILE_COUNT
        or sum(entry["bytes"] for entry in data_entries) != PINNED_DATA_TOTAL_BYTES
    ):
        raise ContractError("runtime manifest full Poppler data inventory is incomplete")
    return indexed


def _load_manifest(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise ContractError(f"invalid runtime manifest {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ContractError(f"runtime manifest must be an object: {path}")
    return value


def verify_runtime(
    support_root: Path, *, require_license_approved: bool = False
) -> dict:
    support_root = Path(support_root).resolve()
    manifest_path = support_root / MANIFEST_REL
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise ContractError(f"runtime manifest missing or unsafe: {manifest_path}")
    manifest = _load_manifest(manifest_path)
    indexed = _validate_manifest(
        manifest, require_license_approved=require_license_approved
    )
    actual_paths = {
        path.relative_to(support_root).as_posix()
        for path in _runtime_files(support_root, include_legacy=True)
    }
    expected_paths = set(indexed)
    if actual_paths != expected_paths:
        missing = sorted(expected_paths - actual_paths)
        extra = sorted(actual_paths - expected_paths)
        raise ContractError(f"runtime member set mismatch; missing={missing}, extra={extra}")
    _validate_physical_shape(support_root)
    for rel, entry in indexed.items():
        path = support_root / rel
        size = path.stat().st_size
        digest = _sha256(path)
        if size != entry["bytes"] or digest != entry["sha256"]:
            raise ContractError(f"runtime hash/size mismatch: {rel}")
    return manifest


def verify_archive(
    archive: Path,
    support_prefix: str,
    *,
    require_license_approved: bool = False,
) -> dict:
    prefix = support_prefix.strip("/")
    manifest_name = f"{prefix}/{MANIFEST_REL.as_posix()}"
    with zipfile.ZipFile(archive, "r") as zf:
        names = [name for name in zf.namelist() if not name.endswith("/")]
        if len(names) != len(set(names)):
            raise ContractError("archive contains duplicate members")
        if manifest_name not in names:
            raise ContractError(f"archive runtime manifest missing: {manifest_name}")
        try:
            manifest = json.loads(zf.read(manifest_name).decode("utf-8"))
        except (KeyError, UnicodeDecodeError, ValueError) as exc:
            raise ContractError(f"archive runtime manifest invalid: {exc}") from exc
        indexed = _validate_manifest(
            manifest, require_license_approved=require_license_approved
        )
        actual_runtime = set()
        for name in names:
            marker = prefix + "/"
            if not name.startswith(marker):
                continue
            rel_text = name[len(marker) :]
            rel = _safe_relative(rel_text)
            if is_runtime_payload(rel):
                actual_runtime.add(rel_text)
        expected_runtime = set(indexed) | {MANIFEST_REL.as_posix()}
        if actual_runtime != expected_runtime:
            missing = sorted(expected_runtime - actual_runtime)
            extra = sorted(actual_runtime - expected_runtime)
            raise ContractError(
                f"archive runtime member set mismatch; missing={missing}, extra={extra}"
            )
        for rel, entry in indexed.items():
            payload = zf.read(f"{prefix}/{rel}")
            if (
                len(payload) != entry["bytes"]
                or hashlib.sha256(payload).hexdigest() != entry["sha256"]
            ):
                raise ContractError(f"archive runtime hash/size mismatch: {rel}")
    return manifest


def prepare_stage(stage: Path, allowed_parent: Path) -> Path:
    allowed_parent = Path(allowed_parent).resolve()
    stage = Path(stage).resolve()
    if stage.parent != allowed_parent:
        raise ContractError(
            f"staging parent mismatch: expected {allowed_parent}, got {stage.parent}"
        )
    allowed_parent.mkdir(parents=True, exist_ok=True)
    if stage.exists():
        if stage.is_symlink():
            raise ContractError(f"staging directory must not be a symlink: {stage}")
        if stage.is_dir():
            shutil.rmtree(stage)
        else:
            stage.unlink()
    stage.mkdir()
    return stage


def _remove_path(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        return
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()


def _move(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(source), str(destination))


def transactional_install(
    stage_support: Path,
    live_support: Path,
    *,
    step_hook: Callable[[str, int, Path], None] | None = None,
) -> None:
    stage_support = Path(stage_support).resolve()
    live_support = Path(live_support).resolve()
    verify_runtime(stage_support, require_license_approved=False)
    live_support.mkdir(parents=True, exist_ok=True)
    backup = live_support.parent / (live_support.name + ".poppler-backup")
    if backup.exists() or backup.is_symlink():
        raise ContractError(f"transaction backup already exists: {backup}")
    backup.mkdir()
    managed = (LEGACY_BIN_REL, Path("Library"), DATA_REL, MANIFEST_REL)
    installed: list[Path] = []
    try:
        for rel in managed:
            current = live_support / rel
            if current.exists() or current.is_symlink():
                _move(current, backup / rel)
        for index, rel in enumerate((Path("Library"), DATA_REL, MANIFEST_REL)):
            source = stage_support / rel
            if not source.exists():
                raise ContractError(f"verified stage member vanished: {source}")
            destination = live_support / rel
            _move(source, destination)
            installed.append(destination)
            if step_hook:
                step_hook("installed", index, destination)
        verify_runtime(live_support, require_license_approved=False)
    except BaseException:
        for path in reversed(installed):
            _remove_path(path)
        for rel in managed:
            saved = backup / rel
            if saved.exists() or saved.is_symlink():
                destination = live_support / rel
                _remove_path(destination)
                _move(saved, destination)
        _remove_path(backup)
        raise
    _remove_path(backup)


def describe() -> dict:
    return {
        "release_tag": PINNED_RELEASE_TAG,
        "asset": PINNED_ASSET,
        "asset_sha256": PINNED_ASSET_SHA256,
        "archive_root": PINNED_ARCHIVE_ROOT,
        "release_url": RELEASE_URL,
        "poppler_data_url": PINNED_DATA_URL,
        "poppler_data_root": f"poppler-data-{PINNED_DATA_VERSION}",
        "poppler_data_archive_sha256": PINNED_DATA_ARCHIVE_SHA256,
        "gpl3_text_url": GPL3_TEXT_URL,
        "gpl3_text_sha256": GPL3_TEXT_SHA256,
        "bin": BIN_REL.as_posix(),
        "data": DATA_REL.as_posix(),
        "manifest": MANIFEST_REL.as_posix(),
        "helpers": list(REQUIRED_HELPERS),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("describe")
    verify_cmd = sub.add_parser("verify")
    verify_cmd.add_argument("--support-root", type=Path, required=True)
    verify_cmd.add_argument("--require-license-approved", action="store_true")
    write_cmd = sub.add_parser("write-manifest")
    write_cmd.add_argument("--support-root", type=Path, required=True)
    write_cmd.add_argument("--license-status", choices=("blocked", "approved"), default="blocked")
    write_cmd.add_argument("--reviewer")
    write_cmd.add_argument("--reviewed-at")
    write_cmd.add_argument("--evidence")
    install_cmd = sub.add_parser("install")
    install_cmd.add_argument("--stage-support", type=Path, required=True)
    install_cmd.add_argument("--live-support", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "describe":
            print(json.dumps(describe(), sort_keys=True))
        elif args.command == "verify":
            verify_runtime(
                args.support_root,
                require_license_approved=args.require_license_approved,
            )
            print("PASS: exact Poppler runtime manifest")
        elif args.command == "write-manifest":
            review = {
                "status": args.license_status,
                "reason": "qualified binary-license review pending"
                if args.license_status == "blocked"
                else "qualified review approved",
                "missing": ["binary dependency license closure"]
                if args.license_status == "blocked"
                else [],
            }
            if args.license_status == "approved":
                if not (args.reviewer and args.reviewed_at and args.evidence):
                    raise ContractError(
                        "approved manifest requires --reviewer, --reviewed-at, and --evidence"
                    )
                review.update(
                    reviewer=args.reviewer,
                    reviewed_at=args.reviewed_at,
                    evidence=args.evidence,
                )
            write_manifest(
                args.support_root,
                license_review=review,
            )
            print(args.support_root / MANIFEST_REL)
        elif args.command == "install":
            transactional_install(args.stage_support, args.live_support)
            print("PASS: transactional Poppler runtime install")
    except ContractError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
