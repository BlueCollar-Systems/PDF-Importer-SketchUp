#!/usr/bin/env python3
"""test_build_release.py — lock build_release.py release-gate behavior."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

REPO_TOOLS = Path(__file__).resolve().parent
if str(REPO_TOOLS) not in sys.path:
    sys.path.insert(0, str(REPO_TOOLS))

REPO_ROOT = REPO_TOOLS.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import build_release as br  # noqa: E402


class BuildReleaseTest(unittest.TestCase):
    def test_source_only_build_excludes_current_and_legacy_runtime_payloads(self):
        original_ext_root = br.EXT_ROOT
        original_loader = br.LOADER_FILE
        original_support = br.SUPPORT_DIR
        try:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                ext_root = root / "extracted" / "sketchup_ext"
                support = ext_root / "bc_pdf_vector_importer"
                support.mkdir(parents=True)
                loader = ext_root / "bc_pdf_vector_importer.rb"
                loader.write_text("PLUGIN_VERSION = 'test'\n", encoding="utf-8")
                (support / "safe_source.rb").write_text("# source\n", encoding="utf-8")

                payloads = [
                    support / "bin" / "pdftocairo.exe",
                    support / "Library" / "bin" / "pdftocairo.exe",
                    support / "share" / "poppler" / "cidToUnicode" / "Adobe-GB1",
                    support / "poppler-runtime-manifest.json",
                ]
                for payload in payloads:
                    payload.parent.mkdir(parents=True, exist_ok=True)
                    payload.write_bytes(b"runtime payload")

                br.EXT_ROOT = ext_root
                br.LOADER_FILE = loader
                br.SUPPORT_DIR = support
                with mock.patch.object(br.subprocess, "run"), mock.patch.object(
                    br, "_run_poppler_smoke"
                ):
                    archive = br.build(root / "out")

                with zipfile.ZipFile(archive) as built:
                    names = set(built.namelist())

                self.assertIn("bc_pdf_vector_importer.rb", names)
                self.assertIn("bc_pdf_vector_importer/safe_source.rb", names)
                for payload in payloads:
                    relative = payload.relative_to(ext_root).as_posix()
                    self.assertNotIn(relative, names)
        finally:
            br.EXT_ROOT = original_ext_root
            br.LOADER_FILE = original_loader
            br.SUPPORT_DIR = original_support

    def test_auto_release_rejects_runtime_payload_members(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "auto-release.yml").read_text(
            encoding="utf-8"
        )

        self.assertNotIn(
            '"bc_pdf_vector_importer/bin/pdftocairo.exe"', workflow
        )
        self.assertIn("forbidden_runtime", workflow)
        self.assertIn("Source-only RBZ contains forbidden runtime payload", workflow)
        self.assertIn("source-only-build-windows", workflow)
        self.assertIn("test_build_release.py", workflow)
        self.assertNotIn("poppler-smoke-windows", workflow)
        self.assertNotIn("--require-poppler-smoke", workflow)
        self.assertNotIn("Build release with required Poppler smoke", workflow)

    def test_release_docs_match_source_only_archive_contract(self):
        readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
        compatibility = (REPO_ROOT / "COMPATIBILITY.md").read_text(
            encoding="utf-8"
        )

        for name, document in (
            ("README.md", readme),
            ("COMPATIBILITY.md", compatibility),
        ):
            normalized = document.lower()
            self.assertIn("source-only", normalized, name)
            self.assertNotIn("poppler helpers are bundled", normalized, name)
            self.assertNotIn("poppler bundled", normalized, name)
            self.assertNotIn("release rbz files also bundle poppler", normalized, name)
            self.assertNotIn("release rbz files include poppler", normalized, name)
            self.assertNotIn("release build fails if bundled poppler", normalized, name)

    def test_shipped_ruby_guidance_does_not_claim_poppler_is_bundled(self):
        support = REPO_ROOT / "extracted" / "sketchup_ext" / "bc_pdf_vector_importer"
        sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(support.glob("*.rb"))
        ).lower()

        self.assertNotIn("bundled poppler", sources)

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
