#!/usr/bin/env python3
"""Host-free contract for immutable-source SketchUp release completion."""

from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

try:
    from tools import release_safety as rs
except ModuleNotFoundError:  # Direct execution places tools/ on sys.path.
    import release_safety as rs


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "auto-release.yml"


def _workflow_text() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def _job(text: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(name)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        text,
    )
    if not match:
        raise AssertionError(f"workflow job is missing: {name}")
    return match.group(0)


def _step(job: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^      - name: {re.escape(name)}\n(?P<body>.*?)(?=^      - (?:name:|uses:)|\Z)",
        job,
    )
    if not match:
        raise AssertionError(f"workflow step is missing: {name}")
    return match.group(0)


class WorkflowReleaseIdentityContractTest(unittest.TestCase):
    def test_same_version_tag_draft_and_published_states_select_old_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)

            def git(*args: str) -> str:
                completed = subprocess.run(
                    ["git", *args],
                    cwd=repo,
                    check=True,
                    capture_output=True,
                    text=True,
                )
                return completed.stdout.strip()

            git("init", "--quiet")
            git("config", "user.name", "Release Contract")
            git("config", "user.email", "release-contract@example.invalid")
            payload = repo / "payload.txt"
            payload.write_text("tagged bytes\n", encoding="utf-8")
            git("add", "payload.txt")
            git("commit", "--quiet", "-m", "tagged source")
            tagged_sha = git("rev-parse", "HEAD")
            payload.write_text("newer HEAD bytes\n", encoding="utf-8")
            git("commit", "--quiet", "-am", "same version newer source")
            head_sha = git("rev-parse", "HEAD")
            self.assertNotEqual(tagged_sha, head_sha)

            for release_exists, release_is_draft in (
                (False, False),
                (True, True),
                (True, False),
            ):
                plan = rs.plan_release_completion(
                    version="3.7.128",
                    head_sha=head_sha,
                    tag_sha=tagged_sha,
                    release_exists=release_exists,
                    release_is_draft=release_is_draft,
                )
                self.assertEqual(tagged_sha, plan["build_ref"])
                self.assertEqual("tagged bytes", git("show", f'{plan["build_ref"]}:payload.txt'))
            self.assertEqual("newer HEAD bytes", git("show", f"{head_sha}:payload.txt"))

    def test_release_plan_is_an_upstream_closed_identity_job(self):
        text = _workflow_text()
        plan = _job(text, "release-plan")
        self.assertLess(text.index("  release-plan:\n"), text.index("  source-only-build-windows:\n"))
        for output in (
            "version",
            "action",
            "tag",
            "build_ref",
            "release_target",
            "release_state",
            "release_id",
        ):
            self.assertRegex(plan, rf"(?m)^      {output}: ")
        self.assertIn("fetch-depth: 0", plan)
        self.assertIn("fetch-tags: true", plan)
        self.assertIn("--paginate", plan)
        self.assertIn("discover-release", plan)
        self.assertIn("plan-release", plan)
        self.assertIn("release_id=", plan)

    def test_selected_source_is_checked_out_before_every_product_gate_and_build(self):
        text = _workflow_text()
        for job_name in ("ruby22-exact-parse", "source-only-build-windows"):
            job = _job(text, job_name)
            self.assertIn("release-plan", job.split("steps:", 1)[0])
            self.assertIn("ref: ${{ needs.release-plan.outputs.build_ref }}", job)
            self.assertIn("git rev-parse HEAD", job)
            self.assertIn("needs.release-plan.outputs.build_ref", job)

        build_job = _job(text, "source-only-build-windows")
        assertion = _step(build_job, "Assert immutable release source")
        build = _step(build_job, "Build approved Windows release bytes")
        self.assertLess(build_job.index(assertion), build_job.index(build))

        release_job = _job(text, "release")
        preserve = _step(release_job, "Preserve current release control plane")
        detach = _step(release_job, "Checkout immutable release source")
        gates = _step(release_job, "Run release gate tests")
        self.assertLess(release_job.index(preserve), release_job.index(detach))
        self.assertLess(release_job.index(detach), release_job.index(gates))
        self.assertIn("needs.release-plan.outputs.build_ref", detach)
        self.assertIn("git rev-parse HEAD", detach)

    def test_completion_is_id_bound_exact_and_fail_closed(self):
        release = _job(_workflow_text(), "release")
        completion = _step(release, "Complete or verify immutable release")
        for required in (
            "needs.release-plan.outputs.action",
            "needs.release-plan.outputs.release_id",
            "needs.release-plan.outputs.release_target",
            "verify-release-assets",
            "--expected-release-id",
            '"$RBZ"',
            '"$RELEASE_CHECKSUMS"',
            '"$SOURCE_CHECKSUMS"',
            ".draft == false",
            ".immutable == true",
            "published_now=false",
        ):
            self.assertIn(required, completion)
        self.assertNotIn("--clobber", completion)

    def test_website_dispatch_only_follows_this_run_publishing(self):
        release = _job(_workflow_text(), "release")
        for name in (
            "Check website dispatch token secret",
            "Dispatch website release update",
            "Warn when website dispatch token is missing",
        ):
            step = _step(release, name)
            self.assertIn("steps.mint.outputs.published_now == 'true'", step)
            self.assertNotIn("steps.mint.outputs.changed == 'true'", step)


if __name__ == "__main__":
    unittest.main()
