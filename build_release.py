#!/usr/bin/env python3
"""Build the SketchUp PDF Vector Importer RBZ.

Helper-bearing builds ship one exact extension-local Poppler runtime:
Library/bin, share/poppler, and poppler-runtime-manifest.json. They require an
approved license review. Source/development builds exclude every current and
legacy runtime path.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).parent.resolve()
EXT_ROOT = REPO_ROOT / "extracted" / "sketchup_ext"
LOADER_FILE = EXT_ROOT / "bc_pdf_vector_importer.rb"
SUPPORT_DIR = EXT_ROOT / "bc_pdf_vector_importer"

EXCLUDE_DIRS = {".git", ".github", "test", "__pycache__", ".ruff_cache"}
EXCLUDE_FILES = {"build_release.py", ".gitignore", ".gitattributes"}
EXCLUDE_SUFFIXES = {".bak", ".swp", ".pyo", ".pyc"}

SMOKE_SCRIPT = REPO_ROOT / "tools" / "smoke_poppler_helpers.py"
sys.path.insert(0, str(REPO_ROOT / "tools"))
import poppler_runtime_contract as poppler_contract  # noqa: E402

# Compatibility aliases used by release-lock tests and maintenance tooling.
POPLER_PINNED_TAG = poppler_contract.PINNED_RELEASE_TAG
POPLER_PINNED_ASSET = poppler_contract.PINNED_ASSET
POPLER_PINNED_ASSET_SHA256 = poppler_contract.PINNED_ASSET_SHA256
BUNDLED_HELPERS = set(poppler_contract.REQUIRED_HELPERS)


def _should_exclude(rel: Path) -> bool:
    if any(part in EXCLUDE_DIRS for part in rel.parts):
        return True
    if rel.name in EXCLUDE_FILES:
        return True
    return rel.suffix.lower() in EXCLUDE_SUFFIXES


def _is_poppler_payload(rel: Path) -> bool:
    """Return true for support-tree paths omitted by source-only builds."""
    parts = rel.parts
    if len(parts) < 2 or parts[0] != SUPPORT_DIR.name:
        return False
    return poppler_contract.is_runtime_payload(Path(*parts[1:]))


def _verify_poppler_runtime_data(
    *,
    support_dir: Path | None = None,
    required: bool = True,
    require_license_approved: bool = False,
) -> dict | None:
    """Verify the exact binary/data/license inventory from one manifest."""
    support_dir = SUPPORT_DIR if support_dir is None else support_dir
    try:
        return poppler_contract.verify_runtime(
            support_dir,
            require_license_approved=require_license_approved,
        )
    except poppler_contract.ContractError as exc:
        if required:
            raise RuntimeError(str(exc)) from exc
        return None


def _verify_poppler_data_archive(
    archive: Path, *, require_license_approved: bool = False
) -> dict:
    """Verify the exact same runtime manifest inside an RBZ."""
    try:
        return poppler_contract.verify_archive(
            archive,
            SUPPORT_DIR.name,
            require_license_approved=require_license_approved,
        )
    except poppler_contract.ContractError as exc:
        raise RuntimeError(str(exc)) from exc


def _read_version() -> str:
    if LOADER_FILE.exists():
        text = LOADER_FILE.read_text(encoding="utf-8", errors="replace")
        match = re.search(r"PLUGIN_VERSION\s*=\s*'([^']+)'", text)
        if match:
            return match.group(1).strip()
    return "0.0.0"


def _verify_bundled_helpers(required: bool = True) -> None:
    """Fail release builds that accidentally omit bundled Windows helpers."""
    bin_dir = SUPPORT_DIR / poppler_contract.BIN_REL
    missing = sorted(name for name in BUNDLED_HELPERS if not (bin_dir / name).is_file())
    if not missing:
        return

    message = (
        "Bundled Poppler helper files are missing from "
        f"{bin_dir}: {', '.join(missing)}. "
        "Run tools/fetch_third_party_binaries.ps1 before building the release RBZ."
    )
    if required:
        raise RuntimeError(message)
    print(f"WARNING: {message}")


def _require_windows_helper_build() -> None:
    if sys.platform != "win32":
        raise RuntimeError(
            "Helper-bearing RBZ builds require a Windows host so the exact "
            "packaged runtime can pass its required semantic smoke."
        )


def _run_poppler_smoke(*, required: bool = False) -> None:
    """Run the deterministic Adobe-GB1 fixture smoke."""
    if not SMOKE_SCRIPT.is_file():
        if required:
            raise RuntimeError(
                f"Poppler smoke script not found: {SMOKE_SCRIPT}. "
                "The release build requires it."
            )
        return

    command = [sys.executable, str(SMOKE_SCRIPT)]
    if required:
        command.append("--required")
    subprocess.run(command, check=True)


def build(
    out_dir: Path,
    *,
    require_helpers: bool = True,
    require_poppler_smoke: bool = False,
) -> Path:
    version = _read_version()
    rbz_path = out_dir / f"SketchUp-PDF-Importer_v{version}.rbz"

    out_dir.mkdir(parents=True, exist_ok=True)
    if require_helpers:
        _require_windows_helper_build()
    subprocess.run(
        [
            sys.executable,
            str(REPO_ROOT / "tools" / "check_su2017_ruby_compat.py"),
            str(EXT_ROOT),
        ],
        check=True,
    )
    if require_helpers:
        _verify_bundled_helpers(required=True)
        _verify_poppler_runtime_data(
            required=True,
            require_license_approved=True,
        )
        _run_poppler_smoke(required=True)
    elif require_poppler_smoke:
        _run_poppler_smoke(required=True)

    file_count = 0
    skipped = 0
    with zipfile.ZipFile(rbz_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        if LOADER_FILE.exists():
            archive.write(LOADER_FILE, LOADER_FILE.name)
            file_count += 1

        for abs_path in sorted(SUPPORT_DIR.rglob("*")):
            if not abs_path.is_file():
                continue
            rel = abs_path.relative_to(EXT_ROOT)
            if _should_exclude(rel):
                skipped += 1
                continue
            if not require_helpers and _is_poppler_payload(rel):
                skipped += 1
                continue
            archive.write(abs_path, rel.as_posix())
            file_count += 1

    if require_helpers:
        _verify_poppler_data_archive(
            rbz_path,
            require_license_approved=True,
        )

    print(f"Built: {rbz_path}")
    print(f"  {file_count} files included, {skipped} excluded")
    return rbz_path


def main() -> None:
    parser = argparse.ArgumentParser(description="Build SU PDFVectorImporter .rbz")
    parser.add_argument(
        "--out",
        default=str(REPO_ROOT),
        help="Output directory (default: repo root)",
    )
    parser.add_argument(
        "--allow-missing-bundled-poppler",
        action="store_true",
        help="Build without bundled Windows Poppler helpers (source/dev only).",
    )
    parser.add_argument(
        "--require-poppler-smoke",
        action="store_true",
        help="Require Poppler helper smoke to pass (Windows release gate).",
    )
    args = parser.parse_args()
    rbz = build(
        Path(args.out).resolve(),
        require_helpers=not args.allow_missing_bundled_poppler,
        require_poppler_smoke=args.require_poppler_smoke,
    )
    print(f"\nRelease ready: {rbz}")


if __name__ == "__main__":
    main()
