#!/usr/bin/env python3
"""Fail-closed locks for bundled Poppler approval and publication."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
for path in (ROOT, TOOLS):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

import build_poppler_runtime_manifest as manifest_builder  # noqa: E402
import build_release  # noqa: E402


SUPPORT = (
    ROOT
    / "extracted"
    / "sketchup_ext"
    / "bc_pdf_vector_importer"
)
MANIFEST = SUPPORT / "poppler-runtime-manifest.json"


class PopplerRuntimeContractTest(unittest.TestCase):
    def test_manifest_writer_has_no_doctrine_or_automation_self_approval(self):
        text = (
            ROOT / "tools" / "build_poppler_runtime_manifest.py"
        ).read_text(encoding="utf-8").lower()

        self.assertNotIn("owner-doctrine", text)
        self.assertNotIn('default="approved"', text)
        self.assertIn("--license-status", text)
        self.assertIn("--reviewer", text)
        self.assertIn("--reviewed-at", text)
        self.assertIn("--evidence", text)
        self.assertIn("--sources-sha256", text)

    def test_checked_in_review_remains_blocked_until_evidence_is_complete(self):
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        review = manifest["license_review"]

        self.assertEqual("blocked", review["status"])
        self.assertIn("binary dependency license closure", review["missing"])

    def test_release_builder_rejects_the_blocked_checked_in_runtime(self):
        with self.assertRaisesRegex(
            RuntimeError, "license review.*blocked|requires approved"
        ):
            build_release._require_bundled_runtime()

    def test_fetcher_verifies_the_exact_pinned_upstream_archive(self):
        text = (
            ROOT / "tools" / "fetch_third_party_binaries.ps1"
        ).read_text(encoding="utf-8")

        self.assertIn(manifest_builder.PINNED_BINARY_ASSET, text)
        self.assertIn(manifest_builder.PINNED_BINARY_ASSET_SHA256, text)
        self.assertIn("Get-FileHash", text)
        self.assertIn("SHA256 mismatch", text)

    def test_approved_review_requires_external_evidence_fields(self):
        with self.assertRaisesRegex(
            SystemExit, "reviewer|reviewed-at|evidence|sources"
        ):
            manifest_builder.build_license_review(
                status="approved",
                reviewer=None,
                reviewed_at=None,
                evidence=None,
                sources_sha256=None,
            )


if __name__ == "__main__":
    unittest.main()
