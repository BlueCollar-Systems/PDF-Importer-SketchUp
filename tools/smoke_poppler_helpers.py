#!/usr/bin/env python3
"""smoke_poppler_helpers.py — R21-8 empirical post-prune Poppler helper check.

Runs pdftotext -bbox / pdftocairo -png / pdffonts against a tiny synthetic
neutral PDF written at runtime (PRIV-1 — no shop files on CI logs).

Visible-skip (exit 0) when:
  - bin/ helpers are absent, or
  - running on a non-Windows host where .exe cannot execute (R4-2).

Fail (exit 1) on nonzero helper RC when the smoke is armed.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BIN_DIR = (
    REPO_ROOT
    / "extracted"
    / "sketchup_ext"
    / "bc_pdf_vector_importer"
    / "Library"
    / "bin"
)
HELPERS = ("pdftotext.exe", "pdftocairo.exe", "pdffonts.exe")

# Minimal valid one-page PDF (Helvetica "OK") — regenerated each run so we
# never depend on a committed *.pdf (repo gitignores PDFs).
_SMOKE_PDF_BYTES = b"""%PDF-1.4
1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj
2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj
3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources<< /Font<< /F1 5 0 R >> >> >>endobj
4 0 obj<< /Length 44 >>stream
BT /F1 24 Tf 50 100 Td (OK) Tj ET
endstream
endobj
5 0 obj<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>endobj
xref
0 6
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000266 00000 n 
0000000360 00000 n 
trailer<< /Size 6 /Root 1 0 R >>
startxref
429
%%EOF
"""


def run_smoke(
    *,
    bin_dir: Path = BIN_DIR,
    platform_name: str = os.name,
    run_command=subprocess.run,
    required: bool = False,
) -> int:
    missing = [h for h in HELPERS if not (bin_dir / h).is_file()]
    if missing:
        message = f"Poppler helpers absent in {bin_dir}: {', '.join(missing)}"
        if required:
            print(f"FAIL: {message}", file=sys.stderr)
            return 1
        print(f"SKIP: {message}")
        print("  Run: powershell -ExecutionPolicy Bypass -File tools/fetch_third_party_binaries.ps1")
        return 0

    if platform_name != "nt":
        message = f"Poppler helper smoke requires Windows (bundled .exe); platform_name={platform_name!r}"
        if required:
            print(f"FAIL: {message}", file=sys.stderr)
            return 1
        print(f"SKIP: {message}")
        return 0

    with tempfile.TemporaryDirectory(prefix="su_poppler_smoke_") as tmp:
        tmp_path = Path(tmp)
        smoke_pdf = tmp_path / "poppler_helper_smoke.pdf"
        smoke_pdf.write_bytes(_SMOKE_PDF_BYTES)
        xml_out = tmp_path / "out.xml"
        png_stem = tmp_path / "page"

        steps = [
            ([str(bin_dir / "pdftotext.exe"), "-bbox", str(smoke_pdf), str(xml_out)], "pdftotext"),
            (
                [str(bin_dir / "pdftocairo.exe"), "-png", "-singlefile", str(smoke_pdf), str(png_stem)],
                "pdftocairo",
            ),
            ([str(bin_dir / "pdffonts.exe"), str(smoke_pdf)], "pdffonts"),
        ]
        for cmd, label in steps:
            print(f"RUN: {' '.join(cmd)}")
            proc = run_command(cmd, capture_output=True, text=True)
            if proc.returncode != 0:
                sys.stderr.write(proc.stdout or "")
                sys.stderr.write(proc.stderr or "")
                print(f"FAIL: {label} RC={proc.returncode}")
                return 1

    print("PASS: pdftotext / pdftocairo / pdffonts RC=0 on synthetic PDF")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Empirical post-prune Poppler helper smoke check."
    )
    parser.add_argument(
        "--required",
        action="store_true",
        help="Exit 1 when helpers are missing or this is not Windows (default: visible skip with exit 0).",
    )
    args = parser.parse_args(argv)
    return run_smoke(bin_dir=BIN_DIR, required=args.required)


if __name__ == "__main__":
    sys.exit(main())
