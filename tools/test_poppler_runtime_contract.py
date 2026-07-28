#!/usr/bin/env python3
"""Fail-closed locks for bundled Poppler approval and publication."""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
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

    def test_checked_in_review_is_complete_and_well_formed(self):
        """The checked-in review must be either blocked, or approved with every
        required field present. It may never be approved on vague evidence."""
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        review = manifest["license_review"]

        self.assertIn(review["status"], ("blocked", "approved"))
        if review["status"] == "blocked":
            self.assertIn(
                "binary dependency license closure", review["missing"]
            )
            return

        self.assertEqual([], review["missing"])
        for field in ("reviewer", "reviewed_at", "evidence", "sources_sha256"):
            self.assertTrue(str(review.get(field, "")).strip(), field)
        for fragment in manifest_builder.FORBIDDEN_REVIEWER_FRAGMENTS:
            self.assertNotIn(fragment, review["reviewer"].lower())
        self.assertRegex(
            review["reviewed_at"], r"\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z"
        )
        # Evidence and source pins must be real checked-in files, not prose.
        for field in ("evidence", "sources_sha256"):
            self.assertTrue(
                (ROOT / review[field]).is_file(),
                "%s must reference a checked-in file: %r"
                % (field, review[field]),
            )

    def test_release_builder_rejects_a_blocked_runtime(self):
        """A blocked review must never pass the release gate. Tested against a
        synthetic review so the lock holds regardless of the repo's state."""
        with self.assertRaisesRegex(
            RuntimeError, "blocked|requires approved"
        ):
            manifest_builder.validate_license_review(
                {
                    "status": "blocked",
                    "missing": ["binary dependency license closure"],
                    "reason": "pending",
                },
                require_approved=True,
            )

    def test_fetcher_verifies_the_exact_pinned_upstream_archive(self):
        text = (
            ROOT / "tools" / "fetch_third_party_binaries.ps1"
        ).read_text(encoding="utf-8")

        self.assertIn(manifest_builder.PINNED_BINARY_ASSET, text)
        self.assertIn(manifest_builder.PINNED_BINARY_ASSET_SHA256, text)
        self.assertIn("Get-FileHash", text)
        self.assertIn("SHA256 mismatch", text)

    def test_fetcher_preserves_the_reviewed_compliance_payload(self):
        text = (
            ROOT / "tools" / "fetch_third_party_binaries.ps1"
        ).read_text(encoding="utf-8")

        self.assertNotIn("@($BinDir, $ShareDir, $LicenseDir)", text)
        self.assertNotIn(
            "Set-Content -Path (Join-Path $SupportDir "
            "'Library\\THIRD_PARTY_NOTICES.txt')",
            text,
        )
        self.assertIn("--validate-compliance-only", text)

    def test_source_offer_is_a_notice_member_not_an_unclassified_payload(self):
        self.assertEqual(
            "notice",
            manifest_builder.category_for("Library/SOURCE_OFFER.txt"),
        )

    def test_complete_compliance_payload_is_required(self):
        manifest_builder.validate_compliance_payload(
            SUPPORT,
            require_complete_offer=False,
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            with self.assertRaisesRegex(
                RuntimeError, "compliance payload is incomplete"
            ):
                manifest_builder.validate_compliance_payload(
                    Path(temp_dir),
                    require_complete_offer=False,
                )

    def test_draft_source_offer_cannot_be_approved(self):
        """A draft or placeholder source offer must never satisfy the complete
        -offer gate. Tested against a copy so the lock holds independently of
        whatever the checked-in offer currently says."""
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = Path(temp_dir) / "support"
            shutil.copytree(SUPPORT / "Library", fixture / "Library")
            offer = fixture / "Library" / "SOURCE_OFFER.txt"
            offer.write_text(
                "WRITTEN OFFER FOR SOURCE CODE\n\n"
                "DRAFT -- requires the owner to insert contact details.\n\n"
                "    <OWNER TO COMPLETE: name, postal address, e-mail>\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                RuntimeError, "source offer is incomplete"
            ):
                manifest_builder.validate_compliance_payload(
                    fixture,
                    require_complete_offer=True,
                )

    def test_completed_source_offer_passes_the_offer_gate(self):
        """The converse lock: the checked-in offer must actually satisfy the
        gate whenever the review is approved."""
        review = json.loads(MANIFEST.read_text(encoding="utf-8"))[
            "license_review"
        ]
        if review["status"] != "approved":
            self.skipTest("checked-in review is not approved")
        manifest_builder.validate_compliance_payload(
            SUPPORT,
            require_complete_offer=True,
        )

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
