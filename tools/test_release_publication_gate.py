#!/usr/bin/env python3
"""Tests for the release workflow's publish-or-skip decision."""

from __future__ import annotations

import sys
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
for path in (ROOT, TOOLS):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

import check_release_publication  # noqa: E402


class ReleasePublicationGateTest(unittest.TestCase):
    def test_current_checked_in_runtime_is_valid_but_not_publishable(self):
        ready, reason = check_release_publication.publication_state()

        self.assertFalse(ready)
        self.assertRegex(
            reason,
            "source offer is incomplete|license review is blocked",
        )

    def test_script_runs_from_the_repository_root_like_ci(self):
        result = subprocess.run(
            [sys.executable, "tools/check_release_publication.py"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("publication_ready=false", result.stdout)


if __name__ == "__main__":
    unittest.main()
