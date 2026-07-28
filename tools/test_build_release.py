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


def _write_runtime(support: Path) -> None:
    bin_dir = support / "Library" / "bin"
    data = support / "share" / "poppler" / "cidToUnicode"
    licenses = support / "Library" / "licenses"
    for path in (bin_dir, data, licenses):
        path.mkdir(parents=True, exist_ok=True)
    for name in ("pdftocairo.exe", "pdftotext.exe", "pdffonts.exe"):
        (bin_dir / name).write_bytes(b"MZ helper")
    for name in ("Adobe-GB1", "Adobe-CNS1", "Adobe-Japan1", "Adobe-Korea1"):
        (data / name).write_bytes(b"cmap")
    (support / "Library" / "THIRD_PARTY_NOTICES.txt").write_text(
        "notices\n", encoding="utf-8"
    )
    (licenses / "COPYING").write_text("gpl\n", encoding="utf-8")
    (support / "poppler-runtime-manifest.json").write_text(
        json.dumps(
            {
                "schema": 1,
                "layout": {
                    "bin": "Library/bin",
                    "data": "share/poppler",
                    "manifest": "poppler-runtime-manifest.json",
                },
                "license_review": {
                    "status": "approved",
                    "missing": [],
                    "reviewer": "test",
                    "evidence": "unit-test",
                    "reviewed_at": "2026-07-28T00:00:00Z",
                },
                "members": [],
            }
        )
        + "\n",
        encoding="utf-8",
    )


class BuildReleaseTest(unittest.TestCase):
    def test_release_build_includes_library_runtime_and_rejects_legacy_bin(self):
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
                _write_runtime(support)

                br.EXT_ROOT = ext_root
                br.LOADER_FILE = loader
                br.SUPPORT_DIR = support
                with mock.patch.object(br.subprocess, "run"), mock.patch.object(
                    br, "_run_poppler_smoke"
                ):
                    archive = br.build(
                        root / "out",
                        require_helpers=True,
                        require_poppler_smoke=True,
                    )

                with zipfile.ZipFile(archive) as built:
                    names = set(built.namelist())

                self.assertIn("bc_pdf_vector_importer.rb", names)
                self.assertIn("bc_pdf_vector_importer/safe_source.rb", names)
                self.assertIn(
                    "bc_pdf_vector_importer/Library/bin/pdftocairo.exe", names
                )
                self.assertIn(
                    "bc_pdf_vector_importer/share/poppler/cidToUnicode/Adobe-GB1",
                    names,
                )
                self.assertIn(
                    "bc_pdf_vector_importer/poppler-runtime-manifest.json", names
                )

                legacy = support / "bin" / "pdftocairo.exe"
                legacy.parent.mkdir(parents=True, exist_ok=True)
                legacy.write_bytes(b"MZ bad")
                with mock.patch.object(br.subprocess, "run"), mock.patch.object(
                    br, "_run_poppler_smoke"
                ):
                    with self.assertRaises(RuntimeError):
                        br.build(
                            root / "out2",
                            require_helpers=True,
                            require_poppler_smoke=False,
                        )
        finally:
            br.EXT_ROOT = original_ext_root
            br.LOADER_FILE = original_loader
            br.SUPPORT_DIR = original_support

    def test_auto_release_requires_zero_ceremony_runtime(self):
        workflow = (REPO_ROOT / ".github" / "workflows" / "auto-release.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("required_runtime", workflow)
        self.assertIn(
            "RBZ missing required zero-ceremony Poppler runtime", workflow
        )
        self.assertIn("forbidden legacy bin/ payload", workflow)
        self.assertIn(
            "bc_pdf_vector_importer/Library/bin/pdftocairo.exe", workflow
        )
        self.assertNotIn(
            "Source-only RBZ contains forbidden runtime payload", workflow
        )

    def test_release_docs_describe_bundled_helpers(self):
        readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
        compatibility = (REPO_ROOT / "COMPATIBILITY.md").read_text(
            encoding="utf-8"
        )

        for name, document in (
            ("README.md", readme),
            ("COMPATIBILITY.md", compatibility),
        ):
            normalized = document.lower()
            self.assertIn("zero-ceremony", normalized, name)
            self.assertIn("bundled", normalized, name)
            self.assertNotIn(
                "every release rbz is source-only", normalized, name
            )

    def test_shipped_ruby_guidance_prefers_bundled_runtime(self):
        sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (
                REPO_ROOT
                / "extracted"
                / "sketchup_ext"
                / "bc_pdf_vector_importer"
                / "dependency_resolver.rb",
            )
        )
        self.assertIn("ship a free bundled poppler runtime", sources.lower())
        self.assertNotIn("never bundle this runtime", sources.lower())


if __name__ == "__main__":
    unittest.main()
