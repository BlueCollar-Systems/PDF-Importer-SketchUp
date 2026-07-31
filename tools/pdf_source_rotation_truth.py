#!/usr/bin/env python3
"""Extract per-glyph source rotation directly from a PDF, independent of the importer.

pdftocairo -svg emits one <use> per glyph placement carrying a transform
matrix. The matrix encodes the true baseline angle of that glyph in the source
document, which is the ground truth an import must reproduce.

Everything else we have measures the importer's own opinion of source rotation
(`source_rotation_radians` in its report). This measures the PDF. Comparing the
two separates "the importer misread the source" from "the importer read it
correctly and placed it wrong" -- two very different bugs that look identical
in a screenshot.

    python tools/pdf_source_rotation_truth.py <file.pdf> [--page 1] [--json out.json]

Report-only. Always exits 0.
"""
from __future__ import annotations

import argparse
import collections
import json
import math
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SUPPORT = REPO_ROOT / "extracted" / "sketchup_ext" / "bc_pdf_vector_importer"

USE_RE = re.compile(
    r'<use[^>]*?xlink:href="#([^"]+)"[^>]*?transform="matrix\(([^)]*)\)"',
    re.IGNORECASE)
USE_XY_RE = re.compile(
    r'<use[^>]*?xlink:href="#([^"]+)"[^>]*?x="([-\d.eE]+)"[^>]*?y="([-\d.eE]+)"',
    re.IGNORECASE)
G_MATRIX_RE = re.compile(r'<g[^>]*?transform="matrix\(([^)]*)\)"', re.IGNORECASE)


def find_tool(name: str) -> Path:
    for rel in (("Library", "bin"), ("bin",)):
        for suffix in (".exe", ""):
            cand = SUPPORT.joinpath(*rel, name + suffix)
            if cand.is_file():
                return cand
    raise SystemExit("%s not found in the bundled runtime" % name)


def render_svg(pdf: Path, page: int) -> str:
    exe = find_tool("pdftocairo")
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "page.svg"
        subprocess.run(
            [str(exe), "-svg", "-f", str(page), "-l", str(page), "--",
             str(pdf), str(out)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return out.read_text(encoding="utf-8", errors="replace")


def matrix_angle(values: str):
    parts = [p for p in re.split(r"[,\s]+", values.strip()) if p]
    if len(parts) < 4:
        return None
    try:
        a, b = float(parts[0]), float(parts[1])
    except ValueError:
        return None
    if abs(a) < 1e-12 and abs(b) < 1e-12:
        return None
    return math.degrees(math.atan2(b, a))


def quantise(deg: float) -> float:
    """Fold to a baseline direction in (-90, 90]; text at 180 reads as 0."""
    d = deg % 180.0
    if d > 90.0:
        d -= 180.0
    return round(d, 1)


def analyse(pdf: Path, page: int) -> dict:
    svg = render_svg(pdf, page)
    angles = []
    for _gid, mat in USE_RE.findall(svg):
        ang = matrix_angle(mat)
        if ang is not None:
            angles.append(ang)
    # Glyphs placed without their own matrix inherit the enclosing <g>.
    inherited = 0
    if not angles:
        for mat in G_MATRIX_RE.findall(svg):
            ang = matrix_angle(mat)
            if ang is not None:
                angles.append(ang)
                inherited += 1

    plain_uses = len(USE_XY_RE.findall(svg))
    hist = collections.Counter(quantise(a) for a in angles)
    rotated = sum(n for d, n in hist.items() if abs(d) > 0.5)
    return {
        "pdf": pdf.name,
        "page": page,
        "svg_bytes": len(svg),
        "glyph_placements_with_matrix": len(angles),
        "glyph_placements_plain_xy": plain_uses,
        "inherited_from_group": inherited,
        "rotated_placements": rotated,
        "upright_placements": len(angles) - rotated,
        "angle_histogram": dict(sorted(hist.items())),
    }


def render(res: dict) -> None:
    print("=" * 70)
    print("PDF source rotation truth — %s page %d" % (res["pdf"], res["page"]))
    print("=" * 70)
    print("  glyph placements w/ matrix : %d" % res["glyph_placements_with_matrix"])
    print("  glyph placements plain x/y : %d" % res["glyph_placements_plain_xy"])
    if res["inherited_from_group"]:
        print("  (angles inherited from <g>  : %d)" % res["inherited_from_group"])
    print("  ROTATED placements         : %d" % res["rotated_placements"])
    print("  upright placements         : %d" % res["upright_placements"])
    print()
    print("  baseline angle histogram (degrees, folded to +/-90):")
    for deg, n in sorted(res["angle_histogram"].items()):
        bar = "#" * min(50, max(1, n // 20))
        print("    %8.1f  %6d  %s" % (deg, n, bar))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("--page", type=int, default=1)
    ap.add_argument("--json", dest="json_out")
    args = ap.parse_args()
    res = analyse(Path(args.pdf), args.page)
    render(res)
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(res, indent=2), encoding="utf-8")
        print("\n  wrote %s" % args.json_out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
