#!/usr/bin/env python3
"""Static locks for helper-bearing release publication."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class WorkflowPopplerContractTest(unittest.TestCase):
    def test_ci_validates_but_does_not_build_a_blocked_runtime(self):
        text = (
            ROOT / ".github" / "workflows" / "su-pdfimporter-ci.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("tools/check_release_publication.py", text)
        self.assertNotIn(
            "Build zero-ceremony release in temporary output",
            text,
        )

    def test_auto_release_skips_publication_until_gate_is_ready(self):
        text = (
            ROOT / ".github" / "workflows" / "auto-release.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("id: publication", text)
        self.assertIn("publication_ready", text)
        self.assertIn(
            "needs.source-only-build-windows.outputs.publication_ready "
            "== 'true'",
            text,
        )

    def test_release_publishes_the_windows_built_rbz_without_rebuilding(self):
        text = (
            ROOT / ".github" / "workflows" / "auto-release.yml"
        ).read_text(encoding="utf-8")
        windows_job = text[
            text.index("  source-only-build-windows:"):
            text.index("\n  release:")
        ]
        release_job = text[text.index("\n  release:"):]

        self.assertIn("python build_release.py", windows_job)
        self.assertIn("actions/upload-artifact@", windows_job)
        self.assertIn("rbz_sha256", windows_job)
        self.assertIn("actions/download-artifact@", release_job)
        self.assertIn(
            "needs.source-only-build-windows.outputs.rbz_sha256",
            release_job,
        )
        self.assertNotIn("run: python build_release.py", release_job)

    def test_release_publishes_the_checked_source_inventory_with_the_rbz(self):
        text = (
            ROOT / ".github" / "workflows" / "auto-release.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("third_party/sources/SHA256SUMS.txt", text)
        self.assertIn('"$SOURCE_CHECKSUMS"', text)
        self.assertLess(
            text.index("python build_release.py"),
            text.index("gh release create"),
        )


if __name__ == "__main__":
    unittest.main()
