#!/usr/bin/env python3
"""test_build_release.py — lock build_release.py release-gate behavior."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_TOOLS = Path(__file__).resolve().parent
if str(REPO_TOOLS) not in sys.path:
    sys.path.insert(0, str(REPO_TOOLS))

REPO_ROOT = REPO_TOOLS.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import build_release as br  # noqa: E402


class BuildReleaseTest(unittest.TestCase):
    def test_run_poppler_smoke_required_missing_script(self):
        original = br.SMOKE_SCRIPT
        try:
            with tempfile.TemporaryDirectory() as tmp:
                br.SMOKE_SCRIPT = Path(tmp) / "missing_smoke.py"
                with self.assertRaises(RuntimeError) as ctx:
                    br._run_poppler_smoke(required=True)
                self.assertIn("Poppler smoke script not found", str(ctx.exception))
        finally:
            br.SMOKE_SCRIPT = original

    def test_run_poppler_smoke_optional_missing_script_silently_skips(self):
        original = br.SMOKE_SCRIPT
        try:
            with tempfile.TemporaryDirectory() as tmp:
                br.SMOKE_SCRIPT = Path(tmp) / "missing_smoke.py"
                # Should not raise when not required.
                br._run_poppler_smoke(required=False)
        finally:
            br.SMOKE_SCRIPT = original

    def test_run_poppler_smoke_required_propagates_called_process_error(self):
        original = br.SMOKE_SCRIPT
        with tempfile.TemporaryDirectory() as tmp:
            smoke_path = Path(tmp) / "failing_smoke.py"
            smoke_path.write_text("import sys\nsys.exit(1)\n", encoding="utf-8")
            try:
                br.SMOKE_SCRIPT = smoke_path
                with self.assertRaises(subprocess.CalledProcessError):
                    br._run_poppler_smoke(required=True)
            finally:
                br.SMOKE_SCRIPT = original

    def test_build_require_poppler_smoke_missing_script_raises(self):
        original = br.SMOKE_SCRIPT
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "out"
            br.SMOKE_SCRIPT = Path(tmp) / "missing_smoke.py"
            try:
                with self.assertRaises(RuntimeError) as ctx:
                    br.build(out_dir, require_helpers=False, require_poppler_smoke=True)
                self.assertIn("Poppler smoke script not found", str(ctx.exception))
            finally:
                br.SMOKE_SCRIPT = original

    def test_build_require_poppler_smoke_failing_smoke_raises(self):
        original = br.SMOKE_SCRIPT
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "out"
            smoke_path = Path(tmp) / "failing_smoke.py"
            smoke_path.write_text("import sys\nsys.exit(1)\n", encoding="utf-8")
            br.SMOKE_SCRIPT = smoke_path
            try:
                with self.assertRaises(subprocess.CalledProcessError):
                    br.build(out_dir, require_helpers=False, require_poppler_smoke=True)
            finally:
                br.SMOKE_SCRIPT = original


if __name__ == "__main__":
    unittest.main()
