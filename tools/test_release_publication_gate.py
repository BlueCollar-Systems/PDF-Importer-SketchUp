#!/usr/bin/env python3
"""Tests for the release workflow's publish-or-skip decision."""

from __future__ import annotations

import sys
import subprocess
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
for path in (ROOT, TOOLS):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

import check_release_publication  # noqa: E402


class ReleasePublicationGateTest(unittest.TestCase):
    def test_current_checked_in_runtime_is_publishable_when_approved(self):
        ready, reason = check_release_publication.publication_state()

        self.assertTrue(ready)
        self.assertEqual(
            "approved compliance evidence and complete source offer",
            reason,
        )

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
            "publication_reason=approved compliance evidence "
            "and complete source offer",
            result.stdout,
        )


if __name__ == "__main__":
    unittest.main()
