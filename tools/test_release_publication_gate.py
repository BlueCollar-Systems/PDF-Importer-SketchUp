#!/usr/bin/env python3
"""Tests for the release workflow's publish-or-skip decision."""

from __future__ import annotations

import json
import sys
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
MANIFEST = (
    ROOT
    / "extracted"
    / "sketchup_ext"
    / "bc_pdf_vector_importer"
    / "poppler-runtime-manifest.json"
)
for path in (ROOT, TOOLS):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

import check_release_publication  # noqa: E402


class ReleasePublicationGateTest(unittest.TestCase):
    def test_current_checked_in_runtime_is_publishable_when_approved(self):
        ready, reason = check_release_publication.publication_state()

        self.assertTrue(ready)
        self.assertEqual(
            "owner-approved compliance record and complete source offer; "
            "not independent legal counsel",
            reason,
        )

    def test_gate_rejects_notice_state_that_disagrees_with_manifest(self):
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        manifest["license_review"]["evidence"] = "review.md"

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            notice = root / "THIRD_PARTY_NOTICES.md"
            notice.write_text("**Status:** blocked\n", encoding="utf-8")
            (root / "review.md").write_text(
                "**Status:** approved\n",
                encoding="utf-8",
            )

            with mock.patch.object(check_release_publication, "REPO_ROOT", root), mock.patch.object(
                check_release_publication,
                "ROOT_NOTICE",
                notice,
                create=True,
            ), mock.patch.object(
                check_release_publication.runtime_manifest,
                "validate_existing_manifest",
                return_value=manifest,
            ):
                with self.assertRaisesRegex(
                    RuntimeError,
                    "publication state disagreement.*notice=blocked",
                ):
                    check_release_publication.publication_state()

    def test_gate_rejects_review_state_that_disagrees_with_manifest(self):
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        manifest["license_review"]["evidence"] = "review.md"

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            notice = root / "THIRD_PARTY_NOTICES.md"
            notice.write_text("**Status:** approved\n", encoding="utf-8")
            (root / "review.md").write_text(
                "**Status:** blocked\n",
                encoding="utf-8",
            )

            with mock.patch.object(check_release_publication, "REPO_ROOT", root), mock.patch.object(
                check_release_publication,
                "ROOT_NOTICE",
                notice,
                create=True,
            ), mock.patch.object(
                check_release_publication.runtime_manifest,
                "validate_existing_manifest",
                return_value=manifest,
            ):
                with self.assertRaisesRegex(
                    RuntimeError,
                    "publication state disagreement.*review=blocked",
                ):
                    check_release_publication.publication_state()

    def test_blocked_runtime_is_valid_but_not_publishable(self):
        blocked = {"license_review": {"status": "blocked"}}

        def validate(require_approved):
            if require_approved:
                raise RuntimeError("license review is blocked")
            return blocked

        with mock.patch.object(
            check_release_publication.runtime_manifest,
            "validate_existing_manifest",
            side_effect=validate,
        ):
            ready, reason = check_release_publication.publication_state()

        self.assertFalse(ready)
        self.assertEqual("license review is blocked", reason)

    def test_script_runs_from_the_repository_root_like_ci(self):
        result = subprocess.run(
            [sys.executable, "tools/check_release_publication.py"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("publication_ready=true", result.stdout)
        self.assertIn(
            "publication_reason=owner-approved compliance record "
            "and complete source offer; not independent legal counsel",
            result.stdout,
        )


if __name__ == "__main__":
    unittest.main()
