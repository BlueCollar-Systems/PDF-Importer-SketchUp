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

Output:
  SketchUp-PDF-Importer_v<VERSION>.rbz
"""

import argparse
import re
import zipfile
from pathlib import Path

REPO_ROOT   = Path(__file__).parent.resolve()
EXT_ROOT    = REPO_ROOT / "extracted" / "sketchup_ext"
LOADER_FILE = EXT_ROOT / "bc_pdf_vector_importer.rb"
SUPPORT_DIR = EXT_ROOT / "bc_pdf_vector_importer"

EXCLUDE_DIRS  = {".git", ".github", "test", "__pycache__", ".ruff_cache"}
EXCLUDE_FILES = {"build_release.py", ".gitignore", ".gitattributes"}
EXCLUDE_SUFFIXES = {".bak", ".swp", ".pyo", ".pyc"}


def _should_exclude(rel: Path) -> bool:
    for part in rel.parts:
        if part in EXCLUDE_DIRS:
            return True
    if rel.name in EXCLUDE_FILES:
        return True
    if rel.suffix.lower() in EXCLUDE_SUFFIXES:
        return True
    return False


def _read_version() -> str:
    if LOADER_FILE.exists():
        text = LOADER_FILE.read_text(encoding="utf-8", errors="replace")
        m = re.search(r"PLUGIN_VERSION\s*=\s*'([^']+)'", text)
        if m:
            return m.group(1).strip()
    return "0.0.0"


def build(out_dir: Path) -> Path:
    version  = _read_version()
    rbz_name = f"SketchUp-PDF-Importer_v{version}.rbz"
    rbz_path = out_dir / rbz_name

    out_dir.mkdir(parents=True, exist_ok=True)

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
            zf.write(abs_path, str(rel))
            file_count += 1

    print(f"Built: {rbz_path}")
    print(f"  {file_count} files included, {skipped} excluded")
    return rbz_path


def main() -> None:
    parser = argparse.ArgumentParser(description="Build SU PDFVectorImporter .rbz")
    parser.add_argument("--out", default=str(REPO_ROOT),
                        help="Output directory (default: repo root)")
    args   = parser.parse_args()
    out    = Path(args.out).resolve()
    rbz    = build(out)
    print(f"\nRelease ready: {rbz}")


if __name__ == "__main__":
    main()
