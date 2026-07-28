#!/usr/bin/env python3
"""test_build_release.py — lock build_release.py release-gate behavior."""

from __future__ import annotations

import json
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
    def test_fetch_script_uses_shared_pins_and_transactional_stage(self):
        script = (br.REPO_ROOT / "tools" / "fetch_third_party_binaries.ps1").read_text(
            encoding="utf-8-sig"
        )
        self.assertIn("poppler_runtime_contract.py", script)
        self.assertIn("describe", script)
        self.assertIn("Get-FileHash", script)
        self.assertNotIn("Select-Object -First 1", script)
        self.assertNotIn("$PopplerReleaseTag =", script)
        self.assertNotIn(br.POPLER_PINNED_ASSET_SHA256, script.lower())
        self.assertIn("--support-root $StageSupport", script)
        self.assertIn("--stage-support $StageSupport", script)
        self.assertLess(
            script.index("--support-root $StageSupport"),
            script.index("--stage-support $StageSupport"),
        )

    def test_runtime_data_blocker_is_checked_in_and_factual(self):
        blocker = br.REPO_ROOT / "POPLER_RUNTIME_DATA_BLOCKER.md"
        self.assertTrue(blocker.is_file(), "runtime-data blocker must be explicit")
        if not blocker.is_file():
            return
        text = blocker.read_text(encoding="utf-8")
        self.assertIn("v26.02.0-0", text)
        self.assertIn("Library/bin", text)
        self.assertIn("share/poppler", text)
        self.assertIn("COPYING.gpl3", text)
        self.assertIn("qualified licensing review", text.lower())

    def test_runtime_contract_requires_full_pinned_data_and_honest_scope(self):
        contract = br.poppler_contract
        self.assertEqual(contract.PINNED_DATA_FILE_COUNT, 271)
        self.assertEqual(contract.PINNED_DATA_TOTAL_BYTES, 12_968_872)
        self.assertEqual(contract.GB1_FIXTURE_SCOPE,
                         "Adobe-GB1 deterministic fixture only")
        self.assertEqual(contract.BIN_REL, Path("Library/bin"))

    def test_release_gate_fails_closed_without_verified_runtime_data(self):
        gate = getattr(br, "_verify_poppler_runtime_data", None)
        self.assertIsNotNone(gate, "release builder needs a Poppler runtime-data gate")
        if gate is None:
            return

        with tempfile.TemporaryDirectory() as tmp:
            support = Path(tmp) / "bc_pdf_vector_importer"
            bin_dir = support / "bin"
            bin_dir.mkdir(parents=True)
            for name in br.BUNDLED_HELPERS:
                path = bin_dir / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"present")

            with self.assertRaises(RuntimeError) as ctx:
                gate(support_dir=support, required=True)

        message = str(ctx.exception)
        self.assertIn("runtime manifest", message)
        self.assertIn("poppler-runtime-manifest.json", message)

    def test_helper_bearing_build_requires_windows_host(self):
        with mock.patch.object(br.sys, "platform", "linux"):
            with self.assertRaisesRegex(RuntimeError, "Windows host"):
                br._require_windows_helper_build()
        with mock.patch.object(br.sys, "platform", "win32"):
            br._require_windows_helper_build()

    def test_source_only_payload_excludes_poppler_bin_and_data(self):
        predicate = getattr(br, "_is_poppler_payload", None)
        self.assertIsNotNone(predicate, "source-only builds need a payload exclusion oracle")
        if predicate is None:
            return

        self.assertTrue(predicate(Path("bc_pdf_vector_importer/bin/pdftotext.exe")))
        self.assertTrue(
            predicate(
                Path(
                    "bc_pdf_vector_importer/share/poppler/"
                    "cMap/Adobe-GB1/UniGB-UTF16-H"
                )
            )
        )
        self.assertFalse(predicate(Path("bc_pdf_vector_importer/main.rb")))

    def test_archive_oracle_delegates_to_shared_exact_contract(self):
        oracle = getattr(br, "_verify_poppler_data_archive", None)
        self.assertIsNotNone(oracle, "release builder needs a data archive oracle")
        if oracle is None:
            return

        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "missing-data.rbz"
            with zipfile.ZipFile(archive, "w"):
                pass
            with self.assertRaises(RuntimeError) as ctx:
                oracle(archive)
        self.assertIn("poppler-runtime-manifest.json", str(ctx.exception))

    def test_archive_oracle_requires_shared_manifest_not_legacy_data_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "empty-manifest.rbz"
            with zipfile.ZipFile(archive, "w") as zf:
                zf.writestr(
                    "bc_pdf_vector_importer/share/poppler/"
                    "poppler-data-manifest.json",
                    json.dumps({"schema": 1, "files": []}),
                )
            with self.assertRaises(RuntimeError) as ctx:
                br._verify_poppler_data_archive(archive)
        self.assertIn("poppler-runtime-manifest.json", str(ctx.exception))

    def test_source_only_build_never_packages_existing_poppler_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ext_root = root / "extracted" / "sketchup_ext"
            support = ext_root / "bc_pdf_vector_importer"
            (support / "bin").mkdir(parents=True)
            (support / "Library" / "bin").mkdir(parents=True)
            (support / "Library" / "licenses").mkdir(parents=True)
            (support / "share" / "poppler").mkdir(parents=True)
            (support / "main.rb").write_text("# source\n", encoding="utf-8")
            (support / "bin" / "pdftotext.exe").write_bytes(b"unsafe")
            (support / "Library" / "bin" / "pdftocairo.exe").write_bytes(b"unsafe")
            (support / "Library" / "licenses" / "COPYING").write_bytes(b"unsafe")
            (support / "Library" / "THIRD_PARTY_NOTICES.txt").write_bytes(b"unsafe")
            (support / "share" / "poppler" / "data").write_bytes(b"unsafe")
            (support / "poppler-runtime-manifest.json").write_bytes(b"unsafe")
            loader = ext_root / "bc_pdf_vector_importer.rb"
            loader.write_text("PLUGIN_VERSION = '0.0.0'\n", encoding="utf-8")
            out_dir = root / "out"

            with (
                mock.patch.object(br, "REPO_ROOT", root),
                mock.patch.object(br, "EXT_ROOT", ext_root),
                mock.patch.object(br, "SUPPORT_DIR", support),
                mock.patch.object(br, "LOADER_FILE", loader),
                mock.patch.object(br, "SMOKE_SCRIPT", root / "missing-smoke.py"),
                mock.patch.object(br.subprocess, "run"),
            ):
                archive = br.build(
                    out_dir, require_helpers=False, require_poppler_smoke=False
                )

            with zipfile.ZipFile(archive, "r") as zf:
                names = set(zf.namelist())
        self.assertIn("bc_pdf_vector_importer/main.rb", names)
        self.assertFalse(any("/bin/" in name for name in names))
        self.assertFalse(any("/Library/" in name for name in names))
        self.assertFalse(any("/share/poppler/" in name for name in names))
        self.assertNotIn("bc_pdf_vector_importer/poppler-runtime-manifest.json", names)

    def test_dormant_svg_geometry_renderer_is_absent_from_source_and_docs(self):
        renderer = br.SUPPORT_DIR / "svg_geometry_renderer.rb"
        main_text = (br.SUPPORT_DIR / "main.rb").read_text(encoding="utf-8")
        readme_text = (br.REPO_ROOT / "README.md").read_text(encoding="utf-8")

        self.assertFalse(renderer.exists())
        self.assertNotIn("svg_geometry_renderer", main_text)
        self.assertNotIn("svg_geometry_renderer", readme_text)
        self.assertNotIn("SvgGeometryRenderer", readme_text)

    def test_no_permanent_filename_blacklist_for_future_renderer_designs(self):
        self.assertFalse(hasattr(br, "FORBIDDEN_SUPPORT_PATHS"))
        self.assertFalse(hasattr(br, "_verify_forbidden_support_paths"))
        self.assertFalse(hasattr(br, "_verify_forbidden_archive_paths"))

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
