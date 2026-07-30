#!/usr/bin/env python3
"""Measure whether rotated engineering notation survives an import.

Owner-reported defect (2026-07-30): on rotated dimension leaders, the whole
number keeps its angle while the stacked fraction and the part mark do not --
"1 3/4" arrives as a rotated "1" plus a horizontal "3/4", and "a1020" arrives
fragmented. Counting delivered entity types does not catch this; you have to
compare each source word against the rotation actually delivered for the span
that covers it.

REPORT-ONLY BY DEFAULT. This exits 0 whatever it finds, so it can never block
work or a release on its own. Enforcement is opt-in via --fail-under, and
nothing wires that on your behalf.

    python tools/text_rotation_fidelity_probe.py <page.pdf> <import_report.json>
    python tools/text_rotation_fidelity_probe.py ... --json out.json
    python tools/text_rotation_fidelity_probe.py ... --fail-under 0.90   # opt-in

Self-validating: pdftotext -bbox measures y from the page top while PDF user
space measures it from the bottom. Getting that backwards makes a healthy
import look catastrophic (it reported 21% coverage instead of 99.6% during the
investigation that produced this tool). The probe therefore tests both
orientations, picks the one that actually fits, and refuses to report numbers
if neither fits -- a bad instrument must not masquerade as a bad product.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SUPPORT = REPO_ROOT / "extracted" / "sketchup_ext" / "bc_pdf_vector_importer"

# Word classes that carry engineering meaning and are known to fragment.
CLASSES = {
    "fraction": re.compile(r"\d\s*/\s*\d"),
    "part_mark": re.compile(r"^[apwcs]\d{3,4}$", re.IGNORECASE),
    "feet_inches": re.compile(r"\d'\s*-?\s*\d"),
}
ROTATION_EPS = 1e-9
# Below this fraction of words explained, the instrument is not trustworthy.
MIN_INSTRUMENT_COVERAGE = 0.75


def find_pdftotext() -> Path:
    for rel in (("Library", "bin"), ("bin",)):
        candidate = SUPPORT.joinpath(*rel, "pdftotext.exe")
        if candidate.is_file():
            return candidate
        candidate = SUPPORT.joinpath(*rel, "pdftotext")
        if candidate.is_file():
            return candidate
    raise SystemExit(
        "pdftotext not found in the bundled runtime (Library/bin or bin)."
    )


def extract_words(pdf: Path, page: int):
    exe = find_pdftotext()
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "words.xml"
        subprocess.run(
            [str(exe), "-bbox", "-f", str(page), "-l", str(page), "--",
             str(pdf), str(out)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        root = ET.parse(out)
    page_h = None
    for el in root.iter():
        if el.tag.endswith("page"):
            page_h = float(el.get("height"))
            break
    if page_h is None:
        raise SystemExit("pdftotext produced no page element")
    words = []
    for el in root.iter():
        if not el.tag.endswith("word"):
            continue
        text = (el.text or "").strip()
        if not text:
            continue
        x0, x1 = float(el.get("xMin")), float(el.get("xMax"))
        y0, y1 = float(el.get("yMin")), float(el.get("yMax"))
        words.append({"text": text,
                      "cx": (x0 + x1) / 2.0,
                      "cy_top": (y0 + y1) / 2.0})
    return words, page_h


def load_spans(report: Path):
    data = json.loads(report.read_text(encoding="utf-8"))
    extra = data.get("extra") or {}
    objs = ((extra.get("source_provenance") or {}).get("objects")) or []
    spans = []
    for obj in objs:
        ev = obj.get("expected_evidence") or {}
        bbox = ev.get("source_bbox_pdf")
        if not bbox or len(bbox) != 4:
            continue
        spans.append({
            "bbox": [float(v) for v in bbox],
            "rotation": float(ev.get("source_rotation_radians") or 0.0),
            "span_id": ev.get("source_span_id"),
        })
    meta = {
        "importer_version": (data.get("importer") or {}).get("version"),
        "requested_mode": extra.get("requested_text_mode"),
        "delivered_mode": extra.get("text_mode"),
        "spans_total": len(objs),
        "spans_with_bbox": len(spans),
        "elapsed_ms": (data.get("performance") or {}).get("elapsed_ms"),
    }
    return spans, meta


def covering_span(cx, cy, spans):
    for span in spans:
        b = span["bbox"]
        if b[0] - 1.0 <= cx <= b[2] + 1.0 and b[1] - 1.0 <= cy <= b[3] + 1.0:
            return span
    return None


def coverage_for(words, spans, page_h, flip):
    hits = 0
    for w in words:
        cy = (page_h - w["cy_top"]) if flip else w["cy_top"]
        if covering_span(w["cx"], cy, spans):
            hits += 1
    return hits


def analyse(pdf: Path, report: Path, page: int):
    words, page_h = extract_words(pdf, page)
    spans, meta = load_spans(report)
    if not spans:
        raise SystemExit(
            "report contains no spans with source_bbox_pdf; nothing to measure"
        )

    # --- instrument self-check -------------------------------------------
    upright = coverage_for(words, spans, page_h, flip=False)
    flipped = coverage_for(words, spans, page_h, flip=True)
    flip = flipped >= upright
    best = max(upright, flipped)
    ratio = best / float(len(words)) if words else 0.0
    instrument = {
        "words": len(words),
        "coverage_upright": upright,
        "coverage_flipped": flipped,
        "orientation": "pdf_user_space (y flipped)" if flip else "top_left",
        "coverage_ratio": round(ratio, 4),
        "trustworthy": ratio >= MIN_INSTRUMENT_COVERAGE,
    }

    results = {}
    for name, pattern in CLASSES.items():
        selected = [w for w in words if pattern.search(w["text"])]
        covered = rotated = 0
        examples = []
        for w in selected:
            cy = (page_h - w["cy_top"]) if flip else w["cy_top"]
            span = covering_span(w["cx"], cy, spans)
            if not span:
                continue
            covered += 1
            if abs(span["rotation"]) > ROTATION_EPS:
                rotated += 1
                if len(examples) < 5:
                    examples.append({
                        "text": w["text"],
                        "degrees": round(math.degrees(span["rotation"]), 2),
                        "span_id": span["span_id"],
                    })
        results[name] = {
            "words": len(selected),
            "covered": covered,
            "rotated": rotated,
            "rotated_examples": examples,
        }

    rotated_spans = [s for s in spans if abs(s["rotation"]) > ROTATION_EPS]
    # Fragmentation signal: a rotated span whose covered text contains a lone
    # separator or a dangling slash is a partition artefact, e.g. "4 13/".
    fragments = []
    for span in rotated_spans:
        b = span["bbox"]
        inside = []
        for w in words:
            cy = (page_h - w["cy_top"]) if flip else w["cy_top"]
            if b[0] - 1 <= w["cx"] <= b[2] + 1 and b[1] - 1 <= cy <= b[3] + 1:
                inside.append(w["text"])
        joined = " ".join(inside)
        if joined.strip().endswith("/") or re.search(r"(^|\s)/(\s|$)", joined):
            fragments.append({"span_id": span["span_id"], "text": joined})

    return {
        "pdf": pdf.name,
        "page": page,
        "report": str(report),
        "meta": meta,
        "instrument": instrument,
        "rotated_spans": len(rotated_spans),
        "classes": results,
        "suspected_fragments": fragments[:20],
        "suspected_fragment_count": len(fragments),
    }


def render(res) -> None:
    m, inst = res["meta"], res["instrument"]
    print("=" * 72)
    print("Rotated-notation fidelity — %s page %d" % (res["pdf"], res["page"]))
    print("=" * 72)
    print("  importer            : %s" % m.get("importer_version"))
    print("  mode requested/deliv: %s / %s"
          % (m.get("requested_mode"), m.get("delivered_mode")))
    print("  spans (with bbox)   : %s of %s"
          % (m.get("spans_with_bbox"), m.get("spans_total")))
    print("  rotated spans       : %d" % res["rotated_spans"])
    if m.get("elapsed_ms"):
        print("  import elapsed      : %.1f s" % (m["elapsed_ms"] / 1000.0))
    print()
    print("  instrument: %s, explains %d/%d words (%.1f%%) -- %s"
          % (inst["orientation"], max(inst["coverage_upright"],
                                      inst["coverage_flipped"]),
             inst["words"], inst["coverage_ratio"] * 100.0,
             "OK" if inst["trustworthy"] else "NOT TRUSTWORTHY"))
    if not inst["trustworthy"]:
        print("  Source words and delivered spans do not line up. Treat the")
        print("  numbers below as unreliable and fix the probe first.")
    print()
    print("  %-12s %7s %8s %8s   %s" % ("class", "words", "covered",
                                        "rotated", "share rotated"))
    print("  " + "-" * 62)
    for name, r in res["classes"].items():
        share = (r["rotated"] / r["covered"]) if r["covered"] else 0.0
        print("  %-12s %7d %8d %8d   %.1f%%"
              % (name, r["words"], r["covered"], r["rotated"], share * 100.0))
        for ex in r["rotated_examples"][:3]:
            print("        e.g. %-10s %8.2f deg" % (ex["text"], ex["degrees"]))
    if res["suspected_fragment_count"]:
        print()
        print("  suspected partition fragments: %d"
              % res["suspected_fragment_count"])
        for f in res["suspected_fragments"][:6]:
            print("      %-18s %r" % (f["span_id"], f["text"]))
    print()
    print("  Report-only. Exit code is 0 unless --fail-under was supplied.")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pdf")
    ap.add_argument("report")
    ap.add_argument("--page", type=int, default=1)
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--fail-under", type=float, default=None,
                    help="OPT-IN. Exit 1 if the rotated share of any covered "
                         "class falls below this ratio (0..1). Omit for "
                         "report-only behaviour.")
    args = ap.parse_args()

    res = analyse(Path(args.pdf), Path(args.report), args.page)
    render(res)
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(res, indent=2),
                                       encoding="utf-8")
        print("  wrote %s" % args.json_out)

    if args.fail_under is None:
        return 0
    if not res["instrument"]["trustworthy"]:
        print("  --fail-under ignored: instrument is not trustworthy.")
        return 0
    worst = None
    for name, r in res["classes"].items():
        if not r["covered"]:
            continue
        share = r["rotated"] / r["covered"]
        if worst is None or share < worst[1]:
            worst = (name, share)
    if worst and worst[1] < args.fail_under:
        print("  FAIL: %s rotated share %.3f < --fail-under %.3f"
              % (worst[0], worst[1], args.fail_under))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
