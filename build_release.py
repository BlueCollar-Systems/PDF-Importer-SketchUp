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

Optional (Windows release with bundled Poppler):
  powershell -ExecutionPolicy Bypass -File tools/fetch_third_party_binaries.ps1

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

BUNDLED_HELPERS = {
    "pdftocairo.exe",
    "pdftotext.exe",
    "pdffonts.exe",
    "poppler.dll",
    "THIRD_PARTY_NOTICES.txt",
    "licenses/README.txt",
}


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


def _verify_bundled_helpers(required: bool = True) -> None:
    """Fail release builds that accidentally omit bundled Windows helpers."""
    bin_dir = SUPPORT_DIR / "bin"
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


def build(out_dir: Path, *, require_helpers: bool = True) -> Path:
    version  = _read_version()
    rbz_name = f"SketchUp-PDF-Importer_v{version}.rbz"
    rbz_path = out_dir / rbz_name

    out_dir.mkdir(parents=True, exist_ok=True)
    _verify_bundled_helpers(required=require_helpers)

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
    parser.add_argument("--allow-missing-bundled-poppler", action="store_true",
                        help="Build without bundled Windows Poppler helpers (source/dev only).")
    args   = parser.parse_args()
    out    = Path(args.out).resolve()
    rbz    = build(out, require_helpers=not args.allow_missing_bundled_poppler)
    print(f"\nRelease ready: {rbz}")


if __name__ == "__main__":
    main()
