#!/usr/bin/env python3
"""Fail-closed empirical smoke for the bundled Windows Poppler helpers.

The smoke generates a deterministic two-page PDF in a private temporary
directory. Page 2 uses an unembedded Adobe-GB1 Type 0 font and the exact text
that exposed RC=0 partial output in the release-candidate fixture. Success
requires semantic text, two raster pages with ink in expected glyph regions,
and a matching CID font inventory -- return codes alone are insufficient.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import poppler_runtime_contract as runtime_contract  # noqa: E402

SUPPORT_DIR = REPO_ROOT / "extracted" / "sketchup_ext" / "bc_pdf_vector_importer"
BIN_DIR = SUPPORT_DIR / runtime_contract.BIN_REL
HELPERS = runtime_contract.REQUIRED_HELPERS

ASCII_EXPECTED_LINE = "SMOKE PAGE ONE"
CID_EXPECTED_LINE = "钢结构 W12X30 梁"
CID_HEX = "94A27ED36784002000570031003200580033003000206881"

# At 72 dpi a PDF point maps to one pixel. The fixture page is 240 x 200 pt.
# Page 1 text is at PDF y=150; page 2 CID text is at PDF y=100.
EXPECTED_PNG_SIZE = (240, 200)
EXPECTED_PNG_ROIS = {
    1: (10, 25, 230, 80),
    2: (10, 75, 230, 130),
}

_ISOLATED_ENV_KEYS = (
    "POPPLER_DATADIR",
    "FONTCONFIG_FILE",
    "FONTCONFIG_PATH",
    "XDG_DATA_DIRS",
)


def _stream(payload: bytes) -> bytes:
    return b"<< /Length %d >>\nstream\n" % len(payload) + payload + b"endstream"


def _build_smoke_pdf() -> bytes:
    """Build a byte-stable two-page PDF without external PDF libraries."""
    page_one = b"BT /F1 20 Tf 20 150 Td (SMOKE PAGE ONE) Tj ET\n"
    page_two = (
        b"BT /F2 18 Tf 20 100 Td <" + CID_HEX.encode("ascii") + b"> Tj ET\n"
    )
    objects = {
        1: b"<< /Type /Catalog /Pages 2 0 R >>",
        2: b"<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
        3: (
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 200] "
            b"/Contents 5 0 R /Resources << /Font << /F1 7 0 R >> >> >>"
        ),
        4: (
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 200] "
            b"/Contents 6 0 R /Resources << /Font << /F2 8 0 R >> >> >>"
        ),
        5: _stream(page_one),
        6: _stream(page_two),
        7: b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        8: (
            b"<< /Type /Font /Subtype /Type0 /BaseFont /Heiti "
            b"/Encoding /UniGB-UTF16-H /DescendantFonts [9 0 R] >>"
        ),
        9: (
            b"<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Heiti "
            b"/CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 5 >> "
            b"/FontDescriptor 10 0 R /DW 1000 >>"
        ),
        10: (
            b"<< /Type /FontDescriptor /FontName /Heiti /Flags 4 "
            b"/FontBBox [0 -250 1000 1000] /ItalicAngle 0 /Ascent 880 "
            b"/Descent -120 /CapHeight 700 /StemV 80 >>"
        ),
    }

    payload = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = {0: 0}
    for number in sorted(objects):
        offsets[number] = len(payload)
        payload.extend(f"{number} 0 obj\n".encode("ascii"))
        payload.extend(objects[number])
        payload.extend(b"\nendobj\n")

    xref_offset = len(payload)
    payload.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    payload.extend(b"0000000000 65535 f \n")
    for number in sorted(objects):
        payload.extend(f"{offsets[number]:010d} 00000 n \n".encode("ascii"))
    payload.extend(
        (
            f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
            f"startxref\n{xref_offset}\n%%EOF\n"
        ).encode("ascii")
    )
    return bytes(payload)


_SMOKE_PDF_BYTES = _build_smoke_pdf()
_SMOKE_PDF_SHA256 = hashlib.sha256(_SMOKE_PDF_BYTES).hexdigest()


def _support_dir_for_bin(bin_dir: Path) -> Path:
    if bin_dir.name.lower() == "bin" and bin_dir.parent.name.lower() == "library":
        return bin_dir.parent.parent
    return bin_dir.parent


def _verify_runtime_for_smoke(*, support_dir: Path, required: bool = True):
    try:
        return runtime_contract.verify_runtime(
            support_dir, require_license_approved=False
        )
    except runtime_contract.ContractError:
        if required:
            raise
        return None


def _isolated_environment(bin_dir: Path, temp_home: Path) -> dict[str, str]:
    env = dict(os.environ)
    for key in _ISOLATED_ENV_KEYS:
        env.pop(key, None)

    path_entries = [str(bin_dir)]
    system_root = env.get("SystemRoot") or env.get("SYSTEMROOT")
    if system_root:
        path_entries.append(str(Path(system_root) / "System32"))
    env["PATH"] = os.pathsep.join(path_entries)

    # Do not inherit user-local Poppler/fontconfig caches or configuration.
    for key in ("HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA"):
        env[key] = str(temp_home)
    env["XDG_CONFIG_HOME"] = str(temp_home / "xdg-config")
    env["XDG_DATA_HOME"] = str(temp_home / "xdg-data")
    return env


def _has_fatal_cid_cluster(stderr: str) -> bool:
    return all(
        fragment in (stderr or "")
        for fragment in (
            "Missing language pack for 'Adobe-GB1' mapping",
            "Unknown font tag 'china-s'",
            "No font in show/space",
        )
    )


def _console_safe(text: str, stream=None) -> str:
    """Preserve diagnostics on legacy Windows consoles such as cp1252."""
    stream = stream or sys.stdout
    encoding = getattr(stream, "encoding", None)
    if not encoding:
        return text
    return text.encode(encoding, errors="backslashreplace").decode(encoding)


def _bbox_semantics(path: Path) -> tuple[int, list[str]]:
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as exc:
        raise ValueError(f"unreadable bbox XML: {exc}")

    pages = [node for node in root.iter() if node.tag.rsplit("}", 1)[-1] == "page"]
    page_semantics = []
    for page in pages:
        words = [
            " ".join((child.text or "").split())
            for child in page.iter()
            if child.tag.rsplit("}", 1)[-1] == "word" and (child.text or "").strip()
        ]
        if words:
            page_semantics.append(" ".join(words))
    return len(pages), page_semantics


def _paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    dl = abs(estimate - left)
    da = abs(estimate - above)
    du = abs(estimate - upper_left)
    if dl <= da and dl <= du:
        return left
    if da <= du:
        return above
    return upper_left


def _decode_png(path: Path) -> tuple[int, int, int, list[bytes], bytes | None]:
    payload = path.read_bytes()
    if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("not a PNG")
    cursor = 8
    width = height = bit_depth = color_type = interlace = None
    compressed = bytearray()
    palette = None
    while cursor + 12 <= len(payload):
        size = struct.unpack(">I", payload[cursor : cursor + 4])[0]
        kind = payload[cursor + 4 : cursor + 8]
        data = payload[cursor + 8 : cursor + 8 + size]
        cursor += 12 + size
        if kind == b"IHDR":
            width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
                ">IIBBBBB", data
            )
            if compression != 0 or filtering != 0:
                raise ValueError("unsupported PNG compression/filter method")
        elif kind == b"PLTE":
            palette = data
        elif kind == b"IDAT":
            compressed.extend(data)
        elif kind == b"IEND":
            break

    if None in (width, height, bit_depth, color_type, interlace):
        raise ValueError("missing PNG IHDR")
    if bit_depth != 8 or interlace != 0:
        raise ValueError("smoke supports only non-interlaced 8-bit PNG")
    channels_by_type = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
    if color_type not in channels_by_type:
        raise ValueError(f"unsupported PNG color type {color_type}")
    channels = channels_by_type[color_type]
    stride = width * channels
    raw = zlib.decompress(bytes(compressed))
    if len(raw) != height * (stride + 1):
        raise ValueError("unexpected PNG scanline size")

    rows = []
    previous = bytearray(stride)
    cursor = 0
    for _ in range(height):
        filter_type = raw[cursor]
        filtered = raw[cursor + 1 : cursor + 1 + stride]
        cursor += stride + 1
        row = bytearray(stride)
        for index, value in enumerate(filtered):
            left = row[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                predictor = _paeth(left, above, upper_left)
            else:
                raise ValueError(f"unsupported PNG filter {filter_type}")
            row[index] = (value + predictor) & 0xFF
        rows.append(bytes(row))
        previous = row
    return width, height, color_type, rows, palette


def _png_roi_has_ink(path: Path, roi: tuple[int, int, int, int]) -> bool:
    width, height, color_type, rows, palette = _decode_png(path)
    if (width, height) != EXPECTED_PNG_SIZE:
        raise ValueError(
            f"unexpected PNG size {width}x{height}; expected "
            f"{EXPECTED_PNG_SIZE[0]}x{EXPECTED_PNG_SIZE[1]}"
        )
    x0, y0, x1, y1 = roi
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    for y in range(max(0, y0), min(height, y1)):
        row = rows[y]
        for x in range(max(0, x0), min(width, x1)):
            pixel = row[x * channels : (x + 1) * channels]
            if color_type == 0:
                rgb, alpha = (pixel[0],) * 3, 255
            elif color_type == 2:
                rgb, alpha = pixel[:3], 255
            elif color_type == 3:
                offset = pixel[0] * 3
                if palette is None or offset + 3 > len(palette):
                    raise ValueError("invalid PNG palette index")
                rgb, alpha = palette[offset : offset + 3], 255
            elif color_type == 4:
                rgb, alpha = (pixel[0],) * 3, pixel[1]
            else:
                rgb, alpha = pixel[:3], pixel[3]
            if alpha > 0 and min(rgb) < 245:
                return True
    return False


def _run_step(run_command, cmd: list[str], *, cwd: Path, env: dict[str, str]):
    return run_command(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        cwd=str(cwd),
        env=env,
        timeout=60,
    )


def run_smoke(
    *,
    bin_dir: Path = BIN_DIR,
    platform_name: str = os.name,
    run_command=subprocess.run,
    runtime_data_verifier=_verify_runtime_for_smoke,
    required: bool = False,
) -> int:
    missing = [helper for helper in HELPERS if not (bin_dir / helper).is_file()]
    if missing:
        message = f"Poppler helpers absent in {bin_dir}: {', '.join(missing)}"
        if required:
            print(f"FAIL: {message}", file=sys.stderr)
            return 1
        print(f"SKIP: {message}")
        print(
            "  Run: powershell -ExecutionPolicy Bypass -File "
            "tools/fetch_third_party_binaries.ps1"
        )
        return 0

    if platform_name != "nt":
        message = (
            "Poppler helper smoke requires Windows (bundled .exe); "
            f"platform_name={platform_name!r}"
        )
        if required:
            print(f"FAIL: {message}", file=sys.stderr)
            return 1
        print(f"SKIP: {message}")
        return 0

    support_dir = _support_dir_for_bin(bin_dir)
    try:
        runtime_data_verifier(support_dir=support_dir, required=True)
    except RuntimeError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="su_poppler_cid_smoke_") as tmp:
        tmp_path = Path(tmp)
        smoke_pdf = tmp_path / "poppler_cid_smoke.pdf"
        smoke_pdf.write_bytes(_SMOKE_PDF_BYTES)
        xml_out = tmp_path / "out.xml"
        png_stem = tmp_path / "page"
        env = _isolated_environment(bin_dir, tmp_path)

        text_cmd = [
            str(bin_dir / "pdftotext.exe"),
            "-bbox-layout",
            str(smoke_pdf),
            str(xml_out),
        ]
        print(f"RUN: {' '.join(text_cmd)}")
        proc = _run_step(run_command, text_cmd, cwd=tmp_path, env=env)
        if proc.returncode != 0:
            sys.stderr.write(proc.stdout or "")
            sys.stderr.write(proc.stderr or "")
            print(f"FAIL: pdftotext RC={proc.returncode}")
            return 1
        text_has_fixture_cluster = _has_fatal_cid_cluster(proc.stderr or "")
        try:
            page_count, lines = _bbox_semantics(xml_out)
        except ValueError as exc:
            print(f"FAIL: pdftotext {exc}")
            return 1
        if (
            page_count != 2
            or ASCII_EXPECTED_LINE not in lines
            or CID_EXPECTED_LINE not in lines
        ):
            diagnostic = (
                "emitted fatal CID diagnostic cluster; "
                if text_has_fixture_cluster
                else ""
            )
            message = (
                f"FAIL: pdftotext {diagnostic}CID semantics incomplete; expected exact line "
                f"{CID_EXPECTED_LINE!r}, pages=2, observed pages={page_count}, "
                f"lines={lines!r}"
            )
            print(_console_safe(message))
            return 1

        cairo_cmd = [
            str(bin_dir / "pdftocairo.exe"),
            "-png",
            "-r",
            "72",
            str(smoke_pdf),
            str(png_stem),
        ]
        print(f"RUN: {' '.join(cairo_cmd)}")
        proc = _run_step(run_command, cairo_cmd, cwd=tmp_path, env=env)
        if proc.returncode != 0:
            sys.stderr.write(proc.stdout or "")
            sys.stderr.write(proc.stderr or "")
            print(f"FAIL: pdftocairo RC={proc.returncode}")
            return 1
        expected_pngs = {tmp_path / "page-1.png", tmp_path / "page-2.png"}
        actual_pngs = set(tmp_path.glob("page-*.png"))
        if actual_pngs != expected_pngs or (tmp_path / "page.png").exists():
            print(
                "FAIL: pdftocairo multi-page PNG set incomplete; "
                f"observed={[path.name for path in sorted(actual_pngs)]}"
            )
            return 1
        for page, roi in EXPECTED_PNG_ROIS.items():
            try:
                has_ink = _png_roi_has_ink(tmp_path / f"page-{page}.png", roi)
            except (OSError, ValueError, zlib.error) as exc:
                print(f"FAIL: pdftocairo page {page} PNG invalid: {exc}")
                return 1
            if not has_ink:
                label = "CID glyph ROI" if page == 2 else "glyph ROI"
                print(f"FAIL: pdftocairo page {page} {label} is blank")
                return 1

        fonts_cmd = [str(bin_dir / "pdffonts.exe"), str(smoke_pdf)]
        print(f"RUN: {' '.join(fonts_cmd)}")
        proc = _run_step(run_command, fonts_cmd, cwd=tmp_path, env=env)
        if proc.returncode != 0:
            sys.stderr.write(proc.stdout or "")
            sys.stderr.write(proc.stderr or "")
            print(f"FAIL: pdffonts RC={proc.returncode}")
            return 1
        cid_font_lines = [
            line
            for line in (proc.stdout or "").splitlines()
            if "Heiti" in line and "CID" in line and "UniGB-UTF16-H" in line
        ]
        if len(cid_font_lines) != 1:
            diagnostic = (
                " emitted fatal CID diagnostic cluster;"
                if _has_fatal_cid_cluster(proc.stderr or "")
                else ""
            )
            print(
                f"FAIL: pdffonts{diagnostic} CID inventory incomplete; expected one Heiti "
                "CID / UniGB-UTF16-H row"
            )
            return 1

    print(
        "PASS: Adobe-GB1 fixture text + 2-page PNG ROI + font inventory on deterministic "
        f"PDF sha256={_SMOKE_PDF_SHA256}"
    )
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Empirical post-prune Poppler Adobe-GB1 fixture smoke check."
    )
    parser.add_argument(
        "--required",
        action="store_true",
        help=(
            "Exit 1 when helpers/data are missing or this is not Windows "
            "(default only visible-skips when helpers/platform are unavailable)."
        ),
    )
    parser.add_argument(
        "--support-root",
        type=Path,
        default=SUPPORT_DIR,
        help="Extension support root to smoke (default: repository support tree).",
    )
    args = parser.parse_args(argv)
    return run_smoke(
        bin_dir=args.support_root.resolve() / runtime_contract.BIN_REL,
        required=args.required,
    )


if __name__ == "__main__":
    sys.exit(main())
