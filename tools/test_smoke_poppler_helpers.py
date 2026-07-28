#!/usr/bin/env python3
"""Lock the deterministic Adobe-GB1 fixture smoke behavior."""

from __future__ import annotations

import binascii
import struct
import sys
import tempfile
import unittest
import zlib
from contextlib import redirect_stderr, redirect_stdout
from io import BytesIO, StringIO, TextIOWrapper
from pathlib import Path

REPO_TOOLS = Path(__file__).resolve().parent
if str(REPO_TOOLS) not in sys.path:
    sys.path.insert(0, str(REPO_TOOLS))

import smoke_poppler_helpers as sph  # noqa: E402
from smoke_poppler_helpers import HELPERS, run_smoke  # noqa: E402


class FakeCompletedProcess:
    def __init__(self, returncode: int = 0, stdout: str = "", stderr: str = ""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def _png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)
    )


def _rgb_png(width: int = 240, height: int = 200, *, ink_y: int | None = 50) -> bytes:
    rows = []
    for y in range(height):
        row = bytearray([255] * (width * 3))
        if ink_y is not None and ink_y <= y < ink_y + 8:
            for x in range(30, 150):
                row[x * 3 : x * 3 + 3] = b"\x00\x00\x00"
        rows.append(b"\x00" + bytes(row))
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + _png_chunk(b"IDAT", zlib.compress(b"".join(rows)))
        + _png_chunk(b"IEND", b"")
    )


GOOD_BBOX = """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body><doc>
<page width="240" height="200"><flow><block><line>
<word>SMOKE</word><word>PAGE</word><word>ONE</word>
</line></block></flow></page>
<page width="240" height="200"><flow><block><line>
<word>钢结构</word><word>W12X30</word><word>梁</word>
</line></block></flow></page>
</doc></body></html>
"""

GOOD_FONTS = """name                                 type              encoding
------------------------------------ ----------------- ----------------
Helvetica                            Type 1            WinAnsi
Heiti                                CID TrueType      UniGB-UTF16-H
"""


class SmokePopplerHelpersTest(unittest.TestCase):
    def test_bbox_semantics_preserves_page_word_order_across_line_nodes(self):
        split_lines = GOOD_BBOX.replace(
            "<word>钢结构</word><word>W12X30</word><word>梁</word>",
            "<word>钢结构</word></line><line><word>W12X30</word>"
            "</line><line><word>梁</word>",
        )
        with tempfile.TemporaryDirectory() as tmp:
            bbox = Path(tmp) / "split.xml"
            bbox.write_text(split_lines, encoding="utf-8")
            page_count, semantics = sph._bbox_semantics(bbox)
        self.assertEqual(page_count, 2)
        self.assertIn("钢结构 W12X30 梁", semantics)

    def _make_bin_dir(self, present: set[str]) -> Path:
        tmp = Path(tempfile.mkdtemp(prefix="su_smoke_support_"))
        bin_dir = tmp / "Library" / "bin"
        bin_dir.mkdir(parents=True)
        for name in present:
            (bin_dir / name).write_bytes(b"")
        return bin_dir

    @staticmethod
    def _allow_runtime_data(**_kwargs):
        return None

    def _fake_run(
        self,
        returncodes: list[int] | None = None,
        *,
        bbox: str = GOOD_BBOX,
        fonts: str = GOOD_FONTS,
        pages: tuple[int, ...] = (1, 2),
        blank_page: int | None = None,
        stderr_by_call: tuple[str, ...] = (),
    ):
        calls = []

        def run_command(cmd, *, capture_output=True, text=True, **kwargs):
            calls.append((cmd, kwargs))
            index = len(calls) - 1
            rc = returncodes.pop(0) if returncodes else 0
            stderr = stderr_by_call[index] if index < len(stderr_by_call) else ""
            exe = Path(cmd[0]).name.lower()
            if rc == 0 and exe == "pdftotext.exe":
                Path(cmd[-1]).write_text(bbox, encoding="utf-8")
            elif rc == 0 and exe == "pdftocairo.exe":
                stem = Path(cmd[-1])
                for page in pages:
                    ink_y = None if blank_page == page else (50 if page == 1 else 100)
                    Path(f"{stem}-{page}.png").write_bytes(_rgb_png(ink_y=ink_y))
            stdout = fonts if exe == "pdffonts.exe" else ""
            return FakeCompletedProcess(returncode=rc, stdout=stdout, stderr=stderr)

        return run_command, calls

    def _capture_smoke(self, **kwargs):
        stdout = StringIO()
        stderr = StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            rc = run_smoke(**kwargs)
        return rc, stdout.getvalue(), stderr.getvalue()

    def test_optional_missing_helpers_returns_zero(self):
        bin_dir = self._make_bin_dir(set())
        rc, stdout, stderr = self._capture_smoke(
            bin_dir=bin_dir, platform_name="nt", required=False
        )
        self.assertEqual(rc, 0)
        self.assertTrue(stdout.startswith("SKIP: Poppler helpers absent"))
        self.assertEqual(stderr, "")

    def test_required_missing_helpers_returns_one(self):
        bin_dir = self._make_bin_dir(set())
        rc, stdout, stderr = self._capture_smoke(
            bin_dir=bin_dir, platform_name="nt", required=True
        )
        self.assertEqual(rc, 1)
        self.assertEqual(stdout, "")
        self.assertTrue(stderr.startswith("FAIL: Poppler helpers absent"))

    def test_optional_non_windows_returns_zero(self):
        bin_dir = self._make_bin_dir(set(HELPERS))
        rc, stdout, stderr = self._capture_smoke(
            bin_dir=bin_dir, platform_name="posix", required=False
        )
        self.assertEqual(rc, 0)
        self.assertTrue(stdout.startswith("SKIP: Poppler helper smoke requires Windows"))
        self.assertEqual(stderr, "")

    def test_required_non_windows_returns_one(self):
        bin_dir = self._make_bin_dir(set(HELPERS))
        rc, stdout, stderr = self._capture_smoke(
            bin_dir=bin_dir, platform_name="posix", required=True
        )
        self.assertEqual(rc, 1)
        self.assertEqual(stdout, "")
        self.assertTrue(stderr.startswith("FAIL: Poppler helper smoke requires Windows"))

    def test_runtime_data_gate_failure_prevents_execution(self):
        bin_dir = self._make_bin_dir(set(HELPERS))
        fake_run, calls = self._fake_run()

        def reject(**_kwargs):
            raise RuntimeError("FAIL-CLOSED synthetic data blocker")

        rc, stdout, stderr = self._capture_smoke(
            bin_dir=bin_dir,
            platform_name="nt",
            run_command=fake_run,
            runtime_data_verifier=reject,
            required=True,
        )
        self.assertEqual(rc, 1)
        self.assertEqual(calls, [])
        self.assertIn("FAIL-CLOSED synthetic data blocker", stderr)
        self.assertEqual(stdout, "")

    def test_three_helpers_require_exact_cid_semantics_pages_roi_and_fonts(self):
        bin_dir = self._make_bin_dir(set(HELPERS))
        fake_run, calls = self._fake_run()
        rc, stdout, stderr = self._capture_smoke(
            bin_dir=bin_dir,
            platform_name="nt",
            run_command=fake_run,
            runtime_data_verifier=self._allow_runtime_data,
            required=True,
        )
        self.assertEqual(rc, 0)
        self.assertEqual(stderr, "")
        self.assertIn(
            "PASS: Adobe-GB1 fixture text + 2-page PNG ROI + font inventory",
            stdout,
        )
        self.assertEqual(len(calls), 3)

        text_cmd, text_kwargs = calls[0]
        smoke_pdf = text_cmd[-2]
        self.assertEqual(Path(smoke_pdf).name, "poppler_cid_smoke.pdf")
        self.assertEqual(
            text_cmd,
            [str(bin_dir / "pdftotext.exe"), "-bbox-layout", smoke_pdf, text_cmd[-1]],
        )
        self.assertEqual(Path(text_cmd[-1]).name, "out.xml")

        cairo_cmd, cairo_kwargs = calls[1]
        self.assertEqual(
            cairo_cmd,
            [
                str(bin_dir / "pdftocairo.exe"),
                "-png",
                "-r",
                "72",
                smoke_pdf,
                cairo_cmd[-1],
            ],
        )
        self.assertEqual(Path(cairo_cmd[-1]).name, "page")
        self.assertEqual(
            calls[2][0], [str(bin_dir / "pdffonts.exe"), smoke_pdf]
        )

        for kwargs in (text_kwargs, cairo_kwargs, calls[2][1]):
            self.assertIn("cwd", kwargs)
            self.assertIn("env", kwargs)
            self.assertNotIn("POPPLER_DATADIR", kwargs["env"])
            self.assertNotIn("FONTCONFIG_FILE", kwargs["env"])
            self.assertNotIn("FONTCONFIG_PATH", kwargs["env"])
            self.assertEqual(
                kwargs["env"]["PATH"].split(sph.os.pathsep)[0], str(bin_dir)
            )

    def test_rc0_partial_cid_text_fails(self):
        bin_dir = self._make_bin_dir(set(HELPERS))
        partial = GOOD_BBOX.replace(
            "<word>钢结构</word><word>W12X30</word><word>梁</word>",
            "<word>W12X30</word>",
        )
        fake_run, calls = self._fake_run(bbox=partial)
        rc, stdout, _stderr = self._capture_smoke(
            bin_dir=bin_dir,
            platform_name="nt",
            run_command=fake_run,
            runtime_data_verifier=self._allow_runtime_data,
            required=True,
        )
        self.assertEqual(rc, 1)
        self.assertEqual(len(calls), 1)
        self.assertIn("pdftotext CID semantics incomplete", stdout)
        self.assertIn("钢结构 W12X30 梁", stdout)

    def test_partial_cid_failure_is_printable_on_cp1252_windows_console(self):
        bin_dir = self._make_bin_dir(set(HELPERS))
        partial = GOOD_BBOX.replace(
            "<word>钢结构</word><word>W12X30</word><word>梁</word>",
            "<word>W12X30</word>",
        )
        fake_run, _calls = self._fake_run(bbox=partial)
        raw = BytesIO()
        console = TextIOWrapper(raw, encoding="cp1252", errors="strict")
        with redirect_stdout(console):
            rc = run_smoke(
                bin_dir=bin_dir,
                platform_name="nt",
                run_command=fake_run,
                runtime_data_verifier=self._allow_runtime_data,
                required=True,
            )
        console.flush()
        rendered = raw.getvalue().decode("cp1252")
        self.assertEqual(rc, 1)
        self.assertIn(r"\u94a2\u7ed3\u6784 W12X30 \u6881", rendered)

    def test_rc0_combined_cid_diagnostic_cluster_fails(self):
        bin_dir = self._make_bin_dir(set(HELPERS))
        partial = GOOD_BBOX.replace(
            "<word>钢结构</word><word>W12X30</word><word>梁</word>",
            "<word>W12X30</word>",
        )
        cluster = (
            "Syntax Error: Missing language pack for 'Adobe-GB1' mapping\n"
            "Syntax Error: Unknown font tag 'china-s'\n"
            "Syntax Error (44846): No font in show/space\n"
        )
        fake_run, calls = self._fake_run(bbox=partial, stderr_by_call=(cluster,))
        rc, stdout, _stderr = self._capture_smoke(
            bin_dir=bin_dir,
            platform_name="nt",
            run_command=fake_run,
            runtime_data_verifier=self._allow_runtime_data,
            required=True,
        )
        self.assertEqual(rc, 1)
        self.assertEqual(len(calls), 1)
        self.assertIn("fatal CID diagnostic cluster", stdout)

    def test_complete_fixture_evidence_prevents_diagnostic_false_positive(self):
        bin_dir = self._make_bin_dir(set(HELPERS))
        cluster = (
            "Syntax Error: Missing language pack for 'Adobe-GB1' mapping\n"
            "Syntax Error: Unknown font tag 'china-s'\n"
            "Syntax Error (44846): No font in show/space\n"
        )
        fake_run, calls = self._fake_run(
            stderr_by_call=(cluster, cluster, cluster)
        )

        rc, stdout, stderr = self._capture_smoke(
            bin_dir=bin_dir,
            platform_name="nt",
            run_command=fake_run,
            runtime_data_verifier=self._allow_runtime_data,
            required=True,
        )

        self.assertEqual(rc, 0)
        self.assertEqual(len(calls), 3)
        self.assertEqual(stderr, "")
        self.assertIn("PASS:", stdout)

    def test_rc0_missing_second_png_fails(self):
        bin_dir = self._make_bin_dir(set(HELPERS))
        fake_run, calls = self._fake_run(pages=(1,))
        rc, stdout, _stderr = self._capture_smoke(
            bin_dir=bin_dir,
            platform_name="nt",
            run_command=fake_run,
            runtime_data_verifier=self._allow_runtime_data,
            required=True,
        )
        self.assertEqual(rc, 1)
        self.assertEqual(len(calls), 2)
        self.assertIn("multi-page PNG set incomplete", stdout)

    def test_rc0_blank_cid_roi_fails(self):
        bin_dir = self._make_bin_dir(set(HELPERS))
        fake_run, calls = self._fake_run(blank_page=2)
        rc, stdout, _stderr = self._capture_smoke(
            bin_dir=bin_dir,
            platform_name="nt",
            run_command=fake_run,
            runtime_data_verifier=self._allow_runtime_data,
            required=True,
        )
        self.assertEqual(rc, 1)
        self.assertEqual(len(calls), 2)
        self.assertIn("page 2 CID glyph ROI is blank", stdout)

    def test_rc0_incomplete_font_inventory_fails(self):
        bin_dir = self._make_bin_dir(set(HELPERS))
        fake_run, calls = self._fake_run(fonts="Helvetica Type 1 WinAnsi\n")
        rc, stdout, _stderr = self._capture_smoke(
            bin_dir=bin_dir,
            platform_name="nt",
            run_command=fake_run,
            runtime_data_verifier=self._allow_runtime_data,
            required=True,
        )
        self.assertEqual(rc, 1)
        self.assertEqual(len(calls), 3)
        self.assertIn("pdffonts CID inventory incomplete", stdout)

    def test_nonzero_helper_failure(self):
        bin_dir = self._make_bin_dir(set(HELPERS))
        fake_run, calls = self._fake_run(returncodes=[0, 1])
        rc, stdout, stderr = self._capture_smoke(
            bin_dir=bin_dir,
            platform_name="nt",
            run_command=fake_run,
            runtime_data_verifier=self._allow_runtime_data,
            required=True,
        )
        self.assertEqual(rc, 1)
        self.assertIn("FAIL: pdftocairo RC=1", stdout)
        self.assertEqual(stderr, "")
        self.assertEqual(len(calls), 2)

    def test_synthetic_pdf_has_two_pages_and_cid_encoding_without_plaintext(self):
        payload = sph._SMOKE_PDF_BYTES
        self.assertIn(b"/Count 2", payload)
        self.assertIn(b"/UniGB-UTF16-H", payload)
        self.assertIn(b"94A27ED36784", payload)
        self.assertNotIn("钢结构".encode("utf-8"), payload)

    def test_main_required_with_missing_helpers(self):
        with tempfile.TemporaryDirectory() as tmp:
            stdout = StringIO()
            stderr = StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                rc = sph.main(["--required", "--support-root", tmp])
            self.assertEqual(rc, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertTrue(
                stderr.getvalue().startswith("FAIL: Poppler helpers absent")
            )


if __name__ == "__main__":
    unittest.main()
