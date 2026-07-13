#!/usr/bin/env python3
"""test_smoke_poppler_helpers.py — lock smoke_poppler_helpers.py behavior."""

from __future__ import annotations

import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path

REPO_TOOLS = Path(__file__).resolve().parent
if str(REPO_TOOLS) not in sys.path:
    sys.path.insert(0, str(REPO_TOOLS))

from smoke_poppler_helpers import HELPERS, run_smoke  # noqa: E402


class FakeCompletedProcess:
    def __init__(self, returncode: int = 0, stdout: str = "", stderr: str = ""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class SmokePopplerHelpersTest(unittest.TestCase):
    def _make_bin_dir(self, present: set[str]) -> Path:
        tmp = Path(tempfile.mkdtemp(prefix="su_smoke_bin_"))
        for name in present:
            (tmp / name).write_bytes(b"")
        return tmp

    def _fake_run(self, returncodes: list[int] | None = None):
        calls = []

        def run_command(cmd, *, capture_output=True, text=True, **kwargs):
            calls.append(cmd)
            if returncodes is None:
                return FakeCompletedProcess(returncode=0)
            # If the caller provides fewer returncodes than commands, default to 0.
            rc = returncodes.pop(0) if returncodes else 0
            return FakeCompletedProcess(returncode=rc)

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

    def test_three_command_success(self):
        bin_dir = self._make_bin_dir(set(HELPERS))
        fake_run, calls = self._fake_run()
        rc, stdout, stderr = self._capture_smoke(
            bin_dir=bin_dir,
            platform_name="nt",
            run_command=fake_run,
            required=True,
        )
        self.assertEqual(rc, 0)
        self.assertEqual(stderr, "")
        self.assertIn("PASS: pdftotext / pdftocairo / pdffonts RC=0", stdout)
        self.assertEqual(len(calls), 3)
        smoke_pdf = calls[0][2]
        self.assertEqual(Path(smoke_pdf).name, "poppler_helper_smoke.pdf")
        self.assertEqual(
            calls[0],
            [str(bin_dir / "pdftotext.exe"), "-bbox", smoke_pdf, calls[0][3]],
        )
        self.assertEqual(Path(calls[0][3]).name, "out.xml")
        self.assertEqual(
            calls[1],
            [
                str(bin_dir / "pdftocairo.exe"),
                "-png",
                "-singlefile",
                smoke_pdf,
                calls[1][4],
            ],
        )
        self.assertEqual(Path(calls[1][4]).name, "page")
        self.assertEqual(calls[2], [str(bin_dir / "pdffonts.exe"), smoke_pdf])

    def test_nonzero_helper_failure(self):
        bin_dir = self._make_bin_dir(set(HELPERS))
        fake_run, calls = self._fake_run(returncodes=[0, 1])
        rc, stdout, stderr = self._capture_smoke(
            bin_dir=bin_dir,
            platform_name="nt",
            run_command=fake_run,
            required=True,
        )
        self.assertEqual(rc, 1)
        self.assertIn("FAIL: pdftocairo RC=1", stdout)
        self.assertEqual(stderr, "")
        self.assertEqual(len(calls), 2)
        self.assertIn("pdftocairo.exe", calls[1][0])

    def test_main_required_with_missing_helpers(self):
        from smoke_poppler_helpers import main

        # Force a missing-helpers path via a temp bin dir by monkeypatching BIN_DIR
        # is hard; main() only has --required flag. We can test the flag path by
        # asserting it returns 1 when the helpers are absent. To make it
        # deterministic, supply a tiny bin_dir path with no files.
        import smoke_poppler_helpers as sph

        original_bin_dir = sph.BIN_DIR
        try:
            with tempfile.TemporaryDirectory() as tmp:
                sph.BIN_DIR = Path(tmp)
                stdout = StringIO()
                stderr = StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    rc = main(["--required"])
                self.assertEqual(rc, 1)
                self.assertEqual(stdout.getvalue(), "")
                self.assertTrue(
                    stderr.getvalue().startswith("FAIL: Poppler helpers absent")
                )
        finally:
            sph.BIN_DIR = original_bin_dir


if __name__ == "__main__":
    unittest.main()
