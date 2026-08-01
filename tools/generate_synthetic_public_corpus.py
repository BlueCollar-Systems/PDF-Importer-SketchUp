#!/usr/bin/env python3
"""Generate a deterministic, privacy-safe multi-page PDF CI corpus."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


SCHEMA = "bcs.synthetic_public_pdf_corpus/1.0"
PROVENANCE = "generated solely from literal public test instructions"
FEATURES = [
    "rotation",
    "crop_box",
    "clipping",
    "type3_font",
    "soft_mask",
    "zero_ink",
    "inline_image",
    "page_2_plus",
    "malformed_input",
]


def stream(dictionary: bytes, content: bytes) -> bytes:
    prefix = dictionary.rstrip()
    if prefix == b"<<":
        prefix = b""
    else:
        prefix = prefix.removeprefix(b"<<").removesuffix(b">>").strip()
    entries = (prefix + b" " if prefix else b"") + f"/Length {len(content)}".encode()
    return b"<< " + entries + b" >>\nstream\n" + content + b"\nendstream"


def build_pdf() -> bytes:
    page_one = (
        b"q 10 10 280 180 re W n\n"
        b"/GS1 gs 0.9 0.9 0.9 rg 10 10 280 180 re f\n"
        b"BT /F1 12 Tf 20 150 Td (ROTATED PAGE) Tj 0 -20 Td (   ) Tj ET\n"
        b"BT /T3 18 Tf 20 90 Td (A) Tj ET\nQ"
    )
    page_two = (
        b"q\nBI /W 1 /H 1 /CS /RGB /BPC 8 ID "
        + bytes((255, 0, 0))
        + b" EI\nQ\nBT /F1 12 Tf 20 120 Td (PAGE TWO INLINE IMAGE) Tj ET"
    )
    page_three = (
        b"q 25 25 250 140 re W n 0 0 m 300 180 l S Q\n"
        b"BT /F1 12 Tf 20 80 Td (PAGE THREE CLIPPED) Tj ET"
    )
    char_proc = b"0 0 600 700 d1 0 0 m 600 0 l 300 700 l h f"
    mask_form = b"0.5 g 0 0 300 200 re f"

    objects = {
        1: b"<< /Type /Catalog /Pages 2 0 R >>",
        2: b"<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
        3: (
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] "
            b"/CropBox [10 10 290 190] /Rotate 90 "
            b"/Resources << /Font << /F1 6 0 R /T3 7 0 R >> "
            b"/ExtGState << /GS1 12 0 R >> >> /Contents 8 0 R >>"
        ),
        4: (
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] "
            b"/Resources << /Font << /F1 6 0 R >> >> /Contents 9 0 R >>"
        ),
        5: (
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] "
            b"/Resources << /Font << /F1 6 0 R >> >> /Contents 10 0 R >>"
        ),
        6: b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        7: (
            b"<< /Type /Font /Subtype /Type3 /FontBBox [0 0 600 700] "
            b"/FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /A 11 0 R >> "
            b"/Encoding << /Type /Encoding /Differences [65 /A] >> "
            b"/FirstChar 65 /LastChar 65 /Widths [600] /Resources << >> >>"
        ),
        8: stream(b"<<", page_one),
        9: stream(b"<<", page_two),
        10: stream(b"<<", page_three),
        11: stream(b"<<", char_proc),
        12: b"<< /Type /ExtGState /SMask << /S /Luminosity /G 13 0 R >> >>",
        13: stream(
            b"<< /Type /XObject /Subtype /Form /BBox [0 0 300 200] "
            b"/Group << /S /Transparency /CS /DeviceGray >> >>",
            mask_form,
        ),
    }

    output = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = {0: 0}
    for number in sorted(objects):
        offsets[number] = len(output)
        output.extend(f"{number} 0 obj\n".encode())
        output.extend(objects[number])
        output.extend(b"\nendobj\n")
    xref = len(output)
    output.extend(f"xref\n0 {len(objects) + 1}\n".encode())
    output.extend(b"0000000000 65535 f \n")
    for number in range(1, len(objects) + 1):
        output.extend(f"{offsets[number]:010d} 00000 n \n".encode())
    output.extend(
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref}\n%%EOF\n".encode()
    )
    return bytes(output)


def file_record(path: Path) -> dict:
    data = path.read_bytes()
    return {
        "name": path.name,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def generate(output_dir: Path) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    valid = output_dir / "synthetic-multipage.pdf"
    malformed = output_dir / "synthetic-malformed.pdf"
    valid.write_bytes(build_pdf())
    malformed.write_bytes(
        b"%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 99 0 R >>\nendobj\n"
    )
    manifest = {
        "schema": SCHEMA,
        "provenance": PROVENANCE,
        "features": FEATURES,
        "files": [file_record(valid), file_record(malformed)],
    }
    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return manifest_path


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)
    print(generate(args.out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
