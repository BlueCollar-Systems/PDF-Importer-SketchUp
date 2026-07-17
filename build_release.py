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

Every RBZ is source-only. Current and legacy Poppler runtime payloads are
always excluded; installed extensions use only explicitly approved environment
or system helper paths discovered by the importer.

Output:
  SketchUp-PDF-Importer_v<VERSION>.rbz
"""

import argparse
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

def _should_exclude(rel: Path) -> bool:
    for part in rel.parts:
        if part in EXCLUDE_DIRS:
            return True
    if rel.name in EXCLUDE_FILES:
        return True
    if rel.suffix.lower() in EXCLUDE_SUFFIXES:
        return True
    return False


def _is_poppler_payload(rel: Path) -> bool:
    """Identify runtime members that a source-only RBZ must never contain."""
    parts = rel.parts
    if len(parts) < 2 or parts[0] != SUPPORT_DIR.name:
        return False

    payload = parts[1:]
    if payload == ("poppler-runtime-manifest.json",):
        return True
    if payload[0] in {"bin", "Library"}:
        return True
    return len(payload) >= 2 and payload[:2] == ("share", "poppler")


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


def build(out_dir: Path, *, require_helpers: bool = False, require_poppler_smoke: bool = False) -> Path:
    if require_helpers:
        raise RuntimeError(
            "RBZ builds are source-only; bundled runtime inclusion is forbidden"
        )
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
    if require_poppler_smoke:
        # An explicit smoke request remains authoritative for the approved
        # system/development helper, but its payload is never archived.
        _run_poppler_smoke(required=True)

    file_count = 0
    skipped    = 0

    with zipfile.ZipFile(rbz_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        # Root loader file
        if LOADER_FILE.exists():
            zf.write(LOADER_FILE, LOADER_FILE.name)
            file_count += 1

        # Support folder
        for abs_path in sorted(SUPPORT_DIR.rglob("*")):
            if not abs_path.is_file():
                continue
            rel = abs_path.relative_to(EXT_ROOT)
            if _should_exclude(rel):
                skipped += 1
                continue
            if _is_poppler_payload(rel):
                skipped += 1
                continue
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
                        help="Require Poppler helper smoke to pass (Windows release gate).")
    args   = parser.parse_args()
    out    = Path(args.out).resolve()
    rbz    = build(out, require_helpers=False,
                   require_poppler_smoke=args.require_poppler_smoke)
    print(f"\nRelease ready: {rbz}")


if __name__ == "__main__":
    main()
