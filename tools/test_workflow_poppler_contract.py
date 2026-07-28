#!/usr/bin/env python3
"""Static locks for the Windows-built, Windows-smoked release artifact."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class WorkflowPopplerContractTest(unittest.TestCase):
    def test_ci_smokes_the_extracted_rbz_and_uploads_that_artifact(self):
        text = (ROOT / ".github/workflows/su-pdfimporter-ci.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("test_poppler_runtime_contract.py", text)
        self.assertIn("Expand-Archive", text)
        self.assertIn("--support-root $ExtractedSupport --required", text)
        self.assertIn("actions/upload-artifact@v4", text)
        self.assertLess(text.index("Expand-Archive"), text.index("actions/upload-artifact@v4"))

    def test_release_downloads_the_windows_smoked_rbz_without_rebuilding(self):
        text = (ROOT / ".github/workflows/auto-release.yml").read_text(encoding="utf-8")
        windows, release = text.split("\n  release:\n", 1)
        self.assertIn("Expand-Archive", windows)
        self.assertIn("--support-root $ExtractedSupport --required", windows)
        self.assertIn("actions/upload-artifact@v4", windows)
        self.assertIn("actions/download-artifact@v4", release)
        self.assertNotIn("python build_release.py", release)
        self.assertIn("bc_pdf_vector_importer/Library/bin/pdftocairo.exe", release)
        self.assertIn("bc_pdf_vector_importer/poppler-runtime-manifest.json", release)


if __name__ == "__main__":
    unittest.main()
