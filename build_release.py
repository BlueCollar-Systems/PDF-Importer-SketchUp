#!/usr/bin/env python3
"""build_release.py — BlueCollar Systems (SketchUp)
Produces a clean .rbz release archive for SketchUp Extension Warehouse
distribution and manual install.

An .rbz is a zip file whose root contains:
  bc_pdf_vector_importer.rb        (loader/entrypoint)
  bc_pdf_vector_importer/         (support folder with all source files)

Excluded:
  .git/, .github/
  test/ (smoke tests — not shipped)
  *.bak
  __pycache__, .ruff_cache (should not exist in SU repo, but just in case)

Usage:
  python build_release.py
  python build_release.py --out /path/to/output_dir
  python build_release.py --require-poppler-smoke --out /path/to/output_dir

Windows releases ship a free zero-ceremony Poppler runtime under
Library/bin + share/poppler with an approved integrity manifest. Legacy
direct bin/ trees are rejected. Helper smoke is required for release builds.

Output:
  SketchUp-PDF-Importer_v<VERSION>.rbz
"""

import argparse
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

REPO_ROOT   = Path(__file__).parent.resolve()
EXT_ROOT    = REPO_ROOT / "extracted" / "sketchup_ext"
LOADER_FILE = EXT_ROOT / "bc_pdf_vector_importer.rb"
SUPPORT_DIR = EXT_ROOT / "bc_pdf_vector_importer"

EXCLUDE_DIRS  = {".git", ".github", "test", "__pycache__", ".ruff_cache"}
EXCLUDE_FILES = {"build_release.py", ".gitignore", ".gitattributes"}
EXCLUDE_SUFFIXES = {".bak", ".swp", ".pyo", ".pyc"}

SMOKE_SCRIPT = REPO_ROOT / "tools" / "smoke_poppler_helpers.py"
REQUIRED_HELPERS = ("pdftocairo.exe", "pdftotext.exe", "pdffonts.exe")
REQUIRED_DATA = (
    "share/poppler/cidToUnicode/Adobe-GB1",
    "share/poppler/cidToUnicode/Adobe-CNS1",
    "share/poppler/cidToUnicode/Adobe-Japan1",
    "share/poppler/cidToUnicode/Adobe-Korea1",
)


def _should_exclude(rel: Path) -> bool:
    for part in rel.parts:
        if part in EXCLUDE_DIRS:
            return True
    if rel.name in EXCLUDE_FILES:
        return True
    if rel.suffix.lower() in EXCLUDE_SUFFIXES:
        return True
    return False


def _is_legacy_bin_payload(rel: Path) -> bool:
    """Legacy direct bin/ trees are forbidden; Library/bin is required."""
    parts = rel.parts
    return (
        len(parts) >= 2
        and parts[0] == SUPPORT_DIR.name
        and parts[1] == "bin"
    )


def _read_version() -> str:
    if LOADER_FILE.exists():
        text = LOADER_FILE.read_text(encoding="utf-8", errors="replace")
        m = re.search(r"PLUGIN_VERSION\s*=\s*'([^']+)'", text)
        if m:
            return m.group(1).strip()
    return "0.0.0"


def _run_poppler_smoke(*, required: bool = False) -> None:
    """Run tools/smoke_poppler_helpers.py; fail the build when required."""
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


def _require_bundled_runtime() -> None:
    legacy = SUPPORT_DIR / "bin"
    if legacy.exists():
        raise RuntimeError(
            f"Legacy direct bin/ payload is forbidden: {legacy}. "
            "Use Library/bin + share/poppler."
        )
    manifest = SUPPORT_DIR / "poppler-runtime-manifest.json"
    if not manifest.is_file():
        raise RuntimeError(
            "Missing poppler-runtime-manifest.json. "
            "Run: powershell -ExecutionPolicy Bypass -File "
            "tools/fetch_third_party_binaries.ps1"
        )
    for name in REQUIRED_HELPERS:
        path = SUPPORT_DIR / "Library" / "bin" / name
        if not path.is_file():
            raise RuntimeError(f"Missing bundled Poppler helper: {path}")
    for rel in REQUIRED_DATA:
        path = SUPPORT_DIR / Path(*rel.split("/"))
        if not path.is_file():
            raise RuntimeError(f"Missing bundled Poppler data: {rel}")


def build(
    out_dir: Path,
    *,
    require_helpers: bool = True,
    require_poppler_smoke: bool = True,
) -> Path:
    version  = _read_version()
    rbz_name = f"SketchUp-PDF-Importer_v{version}.rbz"
    rbz_path = out_dir / rbz_name

    out_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            sys.executable,
            str(REPO_ROOT / "tools" / "check_su2017_ruby_compat.py"),
            str(EXT_ROOT),
        ],
        check=True,
    )
    if require_helpers:
        _require_bundled_runtime()
    if require_poppler_smoke:
        if os.name == "nt":
            _run_poppler_smoke(required=True)
        else:
            print(
                "SKIP: Poppler helper smoke requires Windows; "
                "bundled runtime files are still required and archived"
            )

    file_count = 0
    skipped    = 0

    with zipfile.ZipFile(rbz_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        # Root loader file
        if LOADER_FILE.exists():
            zf.write(LOADER_FILE, LOADER_FILE.name)
            file_count += 1

        # Support folder (includes approved Poppler runtime)
        for abs_path in sorted(SUPPORT_DIR.rglob("*")):
            if not abs_path.is_file():
                continue
            rel = abs_path.relative_to(EXT_ROOT)
            if _should_exclude(rel):
                skipped += 1
                continue
            if _is_legacy_bin_payload(rel):
                raise RuntimeError(
                    f"Refusing to archive legacy bin/ member: {rel.as_posix()}"
                )
            zf.write(abs_path, str(rel))
            file_count += 1

    print(f"Built: {rbz_path}")
    print(f"  {file_count} files included, {skipped} excluded")
    return rbz_path


def main() -> None:
    parser = argparse.ArgumentParser(description="Build SU PDFVectorImporter .rbz")
    parser.add_argument("--out", default=str(REPO_ROOT),
                        help="Output directory (default: repo root)")
    parser.add_argument("--allow-missing-bundled-poppler", action="store_true",
                        help=argparse.SUPPRESS)
    parser.add_argument("--require-poppler-smoke", action="store_true",
                        default=True,
                        help="Require Poppler helper smoke (default: on).")
    parser.add_argument("--skip-poppler-smoke", action="store_true",
                        help="Skip Poppler helper smoke (debug only).")
    args   = parser.parse_args()
    out    = Path(args.out).resolve()
    require_helpers = not args.allow_missing_bundled_poppler
    require_smoke = args.require_poppler_smoke and not args.skip_poppler_smoke
    rbz    = build(out, require_helpers=require_helpers,
                   require_poppler_smoke=require_smoke)
    print(f"\nRelease ready: {rbz}")


if __name__ == "__main__":
    main()
