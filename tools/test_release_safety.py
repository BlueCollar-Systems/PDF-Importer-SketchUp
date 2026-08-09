#!/usr/bin/env python3
"""test_release_safety.py — lock release_safety.py contract."""

from __future__ import annotations

import datetime
import hashlib
import json
import sys
import tempfile
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path

REPO_TOOLS = Path(__file__).resolve().parent
REPO_ROOT = REPO_TOOLS.parent
if str(REPO_TOOLS) not in sys.path:
    sys.path.insert(0, str(REPO_TOOLS))

import release_safety as rs  # noqa: E402


class FakeCompleted:
    def __init__(self, returncode: int = 0, stdout: str = "", stderr: str = ""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def fake_git_factory(
    files: list[str] = None,
    commits: list[tuple[str, str]] = None,
    commit_files_map: dict[str, list[str]] = None,
):
    files = files or []
    commits = commits or []
    commit_files_map = commit_files_map or {}

    def git_command(cmd, *, capture_output=True, text=True, cwd=None, check=True):
        # cmd is like ['git', 'diff', '--name-only', 'tag..HEAD', '--', '.']
        args = cmd[1:]
        if args[:2] == ["diff", "--name-only"]:
            return FakeCompleted(stdout="\n".join(files))
        if args and args[0] == "log":
            return FakeCompleted(stdout="\n".join(f"{sha} {subj}" for sha, subj in commits))
        if args and args[0] == "diff-tree":
            sha = args[-1]
            return FakeCompleted(stdout="\n".join(commit_files_map.get(sha, [])))
        raise AssertionError(f"unexpected git command: {cmd}")

    return git_command


class ReleaseSafetyTest:
    def test_packaging_tools_are_product(self):
        assert rs.is_product_path("build_release.py")
        assert rs.is_product_path("tools/build_release.py")
        assert rs.is_product_path("tools/prune_poppler_bundle.py")
        assert rs.is_product_path("scripts/smoke_release_zip.py")

    def test_docs_and_tests_are_excluded(self):
        assert not rs.is_product_path("README.md")
        assert not rs.is_product_path("docs/usage.md")
        assert not rs.is_product_path("tests/test_foo.py")
        assert not rs.is_product_path("test/smoke_test.rb")
        assert not rs.is_product_path(".github/workflows/ci.yml")
        assert not rs.is_product_path("tools/test_release_safety.py")
        assert not rs.is_product_path(".gitignore")
        assert not rs.is_product_path(".cursor/rules/text-mode-fidelity.mdc")

    # --- positive product scope (packaged tree + byte-affecting build tools) ---

    ROOTS = ["extracted/sketchup_ext/"]
    TOOLS = [
        "build_release.py",
        "tools/build_release.py",
        "tools/build_poppler_runtime_manifest.py",
        "tools/prune_poppler_bundle.py",
        "tools/build_steel_shapes_release.py",
    ]

    def test_scope_packaged_tree_is_product(self):
        assert rs.is_product_path(
            "extracted/sketchup_ext/bc_pdf_vector_importer/main.rb",
            product_roots=self.ROOTS, build_tools=self.TOOLS,
        )
        assert rs.is_product_path(
            "extracted/sketchup_ext/bc_pdf_vector_importer/Library/bin/pdftocairo.exe",
            product_roots=self.ROOTS, build_tools=self.TOOLS,
        )

    def test_scope_keeps_byte_affecting_build_tools_product(self):
        # THE FOOTGUN GUARD: these change shipped bytes and must still strand.
        for tool in self.TOOLS:
            assert rs.is_product_path(
                tool, product_roots=self.ROOTS, build_tools=self.TOOLS
            ), f"{tool} must remain product under positive scope"

    def test_scope_harness_and_publisher_do_not_strand(self):
        # The exact files that caused the false stranding, plus their families.
        for harness in (
            "tools/sketchup_host_launcher.rb",
            "tools/sketchup_batch_import.rb",
            "tools/sketchup_full_corpus_sweep.rb",
            "tools/complete_github_release.py",
            "tools/check_release_publication.py",
            "tools/glyph_perf_probe.rb",
            "tools/su_batch_cli.rb",
        ):
            assert not rs.is_product_path(
                harness, product_roots=self.ROOTS, build_tools=self.TOOLS
            ), f"{harness} does not enter the RBZ and must not strand a release"

    def test_scope_still_honours_excludes_first(self):
        # An excluded path is non-product even if it sits under a product root.
        assert not rs.is_product_path(
            "extracted/sketchup_ext/whatever_test.rb",
            product_roots=self.ROOTS, build_tools=self.TOOLS,
        )

    def test_default_mode_unchanged_without_scope(self):
        # No scope -> denylist behaviour identical to before (other repos).
        assert rs.is_product_path("tools/sketchup_host_launcher.rb")
        assert rs.is_product_path("tools/complete_github_release.py")

    def test_load_product_scope_reads_repo_config(self):
        import tempfile as _tf
        with _tf.TemporaryDirectory() as d:
            root = Path(d)
            (root / ".release-safety").mkdir()
            (root / ".release-safety" / "product-scope.json").write_text(
                json.dumps({"product_roots": ["x/"], "build_tools": ["b.py"]}),
                encoding="utf-8",
            )
            roots, tools = rs.load_product_scope(root)
            assert roots == ["x/"] and tools == ["b.py"]

    def test_load_product_scope_absent_is_none(self):
        import tempfile as _tf
        with _tf.TemporaryDirectory() as d:
            roots, tools = rs.load_product_scope(Path(d))
            assert roots is None and tools is None

    def test_collect_delta_filters_commits_by_files(self):
        git = fake_git_factory(
            files=["build_release.py", "README.md", "tests/test_foo.py"],
            commits=[("abc123", "fix package"), ("def456", "docs update")],
            commit_files_map={
                "abc123": ["build_release.py"],
                "def456": ["README.md"],
            },
        )
        files, commits = rs.collect_delta("v1.0.0", git_command=git, repo_root=Path("."))
        assert files == ["build_release.py"]
        assert len(commits) == 1
        assert commits[0].startswith("abc123")

    def test_load_record_creates_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "warnings.json"
            record = rs.load_warning_record(path)
            assert record == {"schema_version": 1, "warnings": []}

    def test_load_record_rejects_malformed_deadline(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "warnings.json"
            path.write_text(
                '{"schema_version":1,"warnings":[{"repo":"r","tag":"t","first_seen":"2026-07-12T00:00:00+00:00","first_seen_sha":"abc","deadline":"2026-07-13T01:00:00+00:00","responsible_session":"sess"}]}',
                encoding="utf-8",
            )
            try:
                rs.load_warning_record(path)
            except ValueError as e:
                assert "more than 24h" in str(e)

    def test_evaluate_first_warning_exits_zero_and_writes_record(self):
        record = {"schema_version": 1, "warnings": []}
        now = datetime.datetime(2026, 7, 12, 12, 0, 0, tzinfo=datetime.timezone.utc)
        code, summary, out = rs.evaluate_warning(
            record, "owner/repo", "v1.0.0", ["build_release.py"], ["abc fix"], now, "sess-1"
        )
        assert code == 0
        assert "First stranded-release warning" in summary
        assert len(out["warnings"]) == 1
        assert out["warnings"][0]["repo"] == "owner/repo"
        assert out["warnings"][0]["tag"] == "v1.0.0"

    def test_evaluate_second_warning_past_deadline_exits_two_in_release_mode(self):
        first_seen = datetime.datetime(2026, 7, 12, 0, 0, 0, tzinfo=datetime.timezone.utc)
        record = {
            "schema_version": 1,
            "warnings": [
                {
                    "repo": "owner/repo",
                    "tag": "v1.0.0",
                    "first_seen": first_seen.isoformat(),
                    "deadline": (first_seen + datetime.timedelta(hours=24)).isoformat(),
                    "responsible_session": "sess-1",
                }
            ],
        }
        now = first_seen + datetime.timedelta(hours=25)
        code, summary, out = rs.evaluate_warning(
            record, "owner/repo", "v1.0.0", ["build_release.py"], ["abc fix"], now, "sess-2", release_mode=True
        )
        assert code == 2
        assert "not acknowledged before deadline" in summary

    def test_evaluate_second_warning_non_release_exits_zero(self):
        first_seen = datetime.datetime(2026, 7, 12, 0, 0, 0, tzinfo=datetime.timezone.utc)
        record = {
            "schema_version": 1,
            "warnings": [
                {
                    "repo": "owner/repo",
                    "tag": "v1.0.0",
                    "first_seen": first_seen.isoformat(),
                    "deadline": (first_seen + datetime.timedelta(hours=24)).isoformat(),
                    "responsible_session": "sess-1",
                }
            ],
        }
        now = first_seen + datetime.timedelta(hours=25)
        code, summary, out = rs.evaluate_warning(
            record, "owner/repo", "v1.0.0", ["build_release.py"], ["abc fix"], now, "sess-2", release_mode=False
        )
        assert code == 0
        assert "past deadline (non-release run)" in summary

    def test_evaluate_version_bump_plan_accepted_within_deadline(self):
        first_seen = datetime.datetime(2026, 7, 12, 0, 0, 0, tzinfo=datetime.timezone.utc)
        record = {
            "schema_version": 1,
            "warnings": [
                {
                    "repo": "owner/repo",
                    "tag": "v1.0.0",
                    "first_seen": first_seen.isoformat(),
                    "deadline": (first_seen + datetime.timedelta(hours=24)).isoformat(),
                    "responsible_session": "sess-1",
                    "version_bump_plan": "1.0.1",
                }
            ],
        }
        now = first_seen + datetime.timedelta(hours=12)
        code, summary, out = rs.evaluate_warning(
            record, "owner/repo", "v1.0.0", ["build_release.py"], ["abc fix"], now, "sess-2"
        )
        assert code == 0
        assert "Version bump plan" in summary

    def test_evaluate_version_bump_plan_expires(self):
        first_seen = datetime.datetime(2026, 7, 12, 0, 0, 0, tzinfo=datetime.timezone.utc)
        record = {
            "schema_version": 1,
            "warnings": [
                {
                    "repo": "owner/repo",
                    "tag": "v1.0.0",
                    "first_seen": first_seen.isoformat(),
                    "deadline": (first_seen + datetime.timedelta(hours=24)).isoformat(),
                    "responsible_session": "sess-1",
                    "version_bump_plan": "1.0.1",
                }
            ],
        }
        now = first_seen + datetime.timedelta(hours=25)
        code, summary, out = rs.evaluate_warning(
            record, "owner/repo", "v1.0.0", ["build_release.py"], ["abc fix"], now, "sess-2", release_mode=True
        )
        assert code == 2
        assert "exceeded deadline" in summary

    def test_evaluate_release_deferred_until_accepted_future(self):
        first_seen = datetime.datetime(2026, 7, 12, 0, 0, 0, tzinfo=datetime.timezone.utc)
        defer = datetime.datetime(2026, 7, 15, 0, 0, 0, tzinfo=datetime.timezone.utc)
        record = {
            "schema_version": 1,
            "warnings": [
                {
                    "repo": "owner/repo",
                    "tag": "v1.0.0",
                    "first_seen": first_seen.isoformat(),
                    "deadline": (first_seen + datetime.timedelta(hours=24)).isoformat(),
                    "responsible_session": "sess-1",
                    "release_deferred_until": defer.isoformat(),
                }
            ],
        }
        now = first_seen + datetime.timedelta(hours=25)
        code, summary, out = rs.evaluate_warning(
            record, "owner/repo", "v1.0.0", ["build_release.py"], ["abc fix"], now, "sess-2", release_mode=True
        )
        assert code == 0
        assert "Release deferred" in summary

    def test_evaluate_release_deferred_until_expired(self):
        first_seen = datetime.datetime(2026, 7, 12, 0, 0, 0, tzinfo=datetime.timezone.utc)
        defer = datetime.datetime(2026, 7, 12, 12, 0, 0, tzinfo=datetime.timezone.utc)
        record = {
            "schema_version": 1,
            "warnings": [
                {
                    "repo": "owner/repo",
                    "tag": "v1.0.0",
                    "first_seen": first_seen.isoformat(),
                    "deadline": (first_seen + datetime.timedelta(hours=24)).isoformat(),
                    "responsible_session": "sess-1",
                    "release_deferred_until": defer.isoformat(),
                }
            ],
        }
        now = first_seen + datetime.timedelta(hours=25)
        code, summary, out = rs.evaluate_warning(
            record, "owner/repo", "v1.0.0", ["build_release.py"], ["abc fix"], now, "sess-2", release_mode=True
        )
        assert code == 2
        assert "Deferred release date expired" in summary

    def test_main_audit_creates_warning(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo_root = Path(tmp)
            warnings_path = repo_root / ".release-safety" / "warnings.json"
            # No real git repo, so monkeypatch collect_delta for argument wiring.
            original = rs.collect_delta
            try:
                rs.collect_delta = lambda *args, **kwargs: (["build_release.py"], ["abc fix"])
                code = rs.main(
                    [
                        "audit-existing-tag",
                        "--repo", "owner/repo",
                        "--tag", "v1.0.0",
                        "--session-id", "sess-1",
                        "--warnings-file", str(warnings_path),
                    ]
                )
                assert code == 0
                assert warnings_path.exists()
                record = json.loads(warnings_path.read_text(encoding="utf-8"))
                assert len(record["warnings"]) == 1
            finally:
                rs.collect_delta = original

    def test_main_acknowledge(self):
        with tempfile.TemporaryDirectory() as tmp:
            warnings_path = Path(tmp) / "warnings.json"
            first_seen = datetime.datetime(2026, 7, 12, 0, 0, 0, tzinfo=datetime.timezone.utc)
            warnings_path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "warnings": [
                            {
                                "repo": "owner/repo",
                                "tag": "v1.0.0",
                                "first_seen": first_seen.isoformat(),
                                "first_seen_sha": "abc",
                                "deadline": (first_seen + datetime.timedelta(hours=24)).isoformat(),
                                "responsible_session": "sess-1",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            original_now = rs._now
            try:
                rs._now = lambda: first_seen + datetime.timedelta(hours=12)
                code = rs.main(
                    [
                        "acknowledge",
                        "--repo", "owner/repo",
                        "--tag", "v1.0.0",
                        "--version-bump-plan", "1.0.1",
                        "--warnings-file", str(warnings_path),
                    ]
                )
            finally:
                rs._now = original_now
            assert code == 0
            record = json.loads(warnings_path.read_text(encoding="utf-8"))
            assert record["warnings"][0]["version_bump_plan"] == "1.0.1"

    def test_later_product_push_without_persisted_state_blocks_release(self):
        record = {"schema_version": 1, "warnings": []}
        first_seen = datetime.datetime(
            2026, 7, 12, 0, 0, 0, tzinfo=datetime.timezone.utc
        )
        code, summary, out = rs.evaluate_warning(
            record,
            "owner/repo",
            "v1.0.0",
            ["build_release.py"],
            ["abc first product", "def later product"],
            first_seen + datetime.timedelta(hours=1),
            "sess-2",
            release_mode=True,
            later_product_push=True,
            first_seen_sha="abc",
            first_seen_at=first_seen,
        )
        assert code == 2
        assert "later product push" in summary.lower()
        assert out["warnings"][0]["first_seen_sha"] == "abc"
        assert out["warnings"][0]["responsible_session"] == "derived:abc"

    def test_expired_deferral_report_mode_stays_green(self):
        first_seen = datetime.datetime(
            2026, 7, 12, 0, 0, 0, tzinfo=datetime.timezone.utc
        )
        record = {
            "schema_version": 1,
            "warnings": [
                {
                    "repo": "owner/repo",
                    "tag": "v1.0.0",
                    "first_seen": first_seen.isoformat(),
                    "first_seen_sha": "abc",
                    "deadline": (first_seen + datetime.timedelta(hours=24)).isoformat(),
                    "responsible_session": "sess-1",
                    "release_deferred_until": (
                        first_seen + datetime.timedelta(hours=12)
                    ).isoformat(),
                }
            ],
        }
        code, summary, _ = rs.evaluate_warning(
            record,
            "owner/repo",
            "v1.0.0",
            ["build_release.py"],
            ["abc fix"],
            first_seen + datetime.timedelta(hours=25),
            "sess-2",
            release_mode=False,
        )
        assert code == 0
        assert "expired" in summary.lower()

    def test_load_record_rejects_naive_timestamp_and_wrong_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "warnings.json"
            path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "warnings": [
                            {
                                "repo": "wrong/repo",
                                "tag": "v1.0.0",
                                "first_seen": "2026-07-12T00:00:00",
                                "first_seen_sha": "abc",
                                "deadline": "2026-07-13T00:00:00",
                                "responsible_session": "sess-1",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            try:
                rs.load_warning_record(
                    path, expected_repo="owner/repo", expected_tag="v1.0.0"
                )
            except ValueError:
                pass
            else:
                raise AssertionError("naive/wrong-repository state was accepted")

    def test_release_safety_helper_is_not_a_product_path(self):
        assert not rs.is_product_path("tools/release_safety.py")
        assert not rs.is_product_path("scripts/release_safety.py")

    def test_existing_tag_without_release_builds_and_mints_from_tag(self):
        plan = rs.plan_release_completion(
            version="1.0.76",
            head_sha="b" * 40,
            tag_sha="a" * 40,
            release_exists=False,
        )
        assert plan == {
            "action": "complete_existing_tag",
            "tag": "v1.0.76",
            "build_ref": "a" * 40,
            "release_target": "a" * 40,
        }

    def test_existing_release_is_verify_only_and_never_uploads(self):
        plan = rs.plan_release_completion(
            version="1.0.76",
            head_sha="b" * 40,
            tag_sha="a" * 40,
            release_exists=True,
        )
        assert plan["action"] == "verify_existing_release"
        assert plan["build_ref"] == "a" * 40

    def test_new_tag_builds_and_mints_from_head(self):
        plan = rs.plan_release_completion(
            version="1.0.76",
            head_sha="b" * 40,
            tag_sha=None,
            release_exists=False,
        )
        assert plan["action"] == "mint_new_tag"
        assert plan["build_ref"] == "b" * 40

    def test_draft_release_is_resumed_from_existing_tag(self):
        plan = rs.plan_release_completion(
            version="1.0.76",
            head_sha="b" * 40,
            tag_sha="a" * 40,
            release_exists=True,
            release_is_draft=True,
        )
        assert plan["action"] == "complete_draft_release"
        assert plan["build_ref"] == "a" * 40

    def test_tagless_draft_plans_completion_from_its_own_target(self):
        # Releases are created draft-first, and a draft has NO tag ref until
        # it is published -- an interrupted run leaves exactly this state.
        # The old precondition ("an existing release must have a resolvable
        # immutable tag") crashed the planner on it, stranding the draft.
        plan = rs.plan_release_completion(
            version="1.0.76",
            head_sha="b" * 40,
            tag_sha="",
            release_exists=True,
            release_is_draft=True,
            draft_target_sha="c" * 40,
        )
        assert plan["action"] == "complete_draft_release"
        assert plan["build_ref"] == "c" * 40
        assert plan["release_target"] == "c" * 40

    def test_tagless_draft_with_branch_name_target_fails_closed(self):
        # target_commitish may legally be a branch name on GitHub; ours is
        # always an exact SHA because creation passes --target <sha>. A branch
        # name is NOT an immutable source, so refuse it.
        try:
            rs.plan_release_completion(
                version="1.0.76",
                head_sha="b" * 40,
                tag_sha="",
                release_exists=True,
                release_is_draft=True,
                draft_target_sha="main",
            )
        except ValueError as exc:
            assert "immutable source" in str(exc)
        else:
            raise AssertionError("a branch-name draft target was accepted")

    def test_published_release_without_a_tag_still_fails_closed(self):
        # Only DRAFTS may lack a tag ref; a published release without one is
        # an inconsistency the planner must keep refusing.
        try:
            rs.plan_release_completion(
                version="1.0.76",
                head_sha="b" * 40,
                tag_sha="",
                release_exists=True,
                release_is_draft=False,
            )
        except ValueError as exc:
            assert "resolvable immutable tag" in str(exc)
        else:
            raise AssertionError("a tagless published release was accepted")

    def test_release_discovery_includes_drafts_and_binds_numeric_id(self):
        release = rs.discover_release_by_tag(
            [
                {"id": 12, "tag_name": "v1.0.75", "draft": False},
                {"id": 34, "tag_name": "v1.0.76", "draft": True},
            ],
            "v1.0.76",
        )
        assert release == {
            "release_state": "draft",
            "release_id": "34",
        }

        try:
            rs.discover_release_by_tag(
                [
                    {"id": 34, "tag_name": "v1.0.76", "draft": True},
                    {"id": 35, "tag_name": "v1.0.76", "draft": False},
                ],
                "v1.0.76",
            )
        except ValueError as exc:
            assert "exactly one" in str(exc)
        else:
            raise AssertionError("duplicate tag-bound releases were accepted")

    def test_release_discovery_cli_emits_machine_readable_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            releases_path = Path(tmp) / "releases.json"
            releases_path.write_text(
                json.dumps(
                    [
                        {"id": 34, "tag_name": "v1.0.76", "draft": True},
                    ]
                ),
                encoding="utf-8",
            )
            stdout = StringIO()
            with redirect_stdout(stdout):
                code = rs.main(
                    [
                        "discover-release",
                        "--releases-json",
                        str(releases_path),
                        "--tag",
                        "v1.0.76",
                    ]
                )
            assert code == 0
            assert json.loads(stdout.getvalue()) == {
                "release_state": "draft",
                "release_id": "34",
            }

    def test_release_asset_verification_is_idempotent_and_digest_bound(self):
        with tempfile.TemporaryDirectory() as tmp:
            asset = Path(tmp) / "package.zip"
            asset.write_bytes(b"immutable package")
            digest = hashlib.sha256(asset.read_bytes()).hexdigest()
            verified = rs.verify_release_assets(
                [asset],
                [{"name": asset.name, "size": asset.stat().st_size, "digest": f"sha256:{digest}"}],
            )
            assert verified == [{"name": asset.name, "size": 17, "sha256": digest}]

            try:
                rs.verify_release_assets(
                    [asset],
                    [{"name": asset.name, "size": asset.stat().st_size, "digest": "sha256:" + "0" * 64}],
                )
            except ValueError as exc:
                assert "digest" in str(exc).lower()
            else:
                raise AssertionError("a mismatched immutable release asset was accepted")

    def test_release_asset_verification_requires_exact_unique_name_closure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            asset = root / "package.zip"
            asset.write_bytes(b"immutable package")
            digest = hashlib.sha256(b"immutable package").hexdigest()
            expected = {
                "name": "package.zip",
                "size": 17,
                "digest": f"sha256:{digest}",
            }

            bad_remote_sets = (
                ([expected, {
                    "name": "unexpected.zip",
                    "size": 0,
                    "digest": "sha256:" + "0" * 64,
                }], "asset name closure"),
                ([], "asset name closure"),
                ([expected, dict(expected)], "duplicate remote release asset name"),
            )
            for remote_assets, expected_error in bad_remote_sets:
                try:
                    rs.verify_release_assets([asset], remote_assets)
                except ValueError as exc:
                    assert expected_error in str(exc).lower()
                else:
                    raise AssertionError(
                        f"non-exact remote asset closure was accepted: {remote_assets!r}"
                    )

            other = root / "other"
            other.mkdir()
            duplicate_local = other / "package.zip"
            duplicate_local.write_bytes(b"immutable package")
            try:
                rs.verify_release_assets([asset, duplicate_local], [expected])
            except ValueError as exc:
                assert "duplicate local release asset name" in str(exc).lower()
            else:
                raise AssertionError("duplicate local release asset names were accepted")

    def test_release_asset_verification_rejects_malformed_remote_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            asset = Path(tmp) / "package.zip"
            asset.write_bytes(b"immutable package")
            digest = hashlib.sha256(b"immutable package").hexdigest()
            valid = {
                "name": "package.zip",
                "size": 17,
                "digest": f"sha256:{digest}",
            }
            malformed = (
                None,
                dict(valid, name=None),
                dict(valid, name=7),
                dict(valid, size="17"),
                dict(valid, size=True),
                dict(valid, size=-1),
                dict(valid, digest=None),
                dict(valid, digest=b"sha256:" + digest.encode("ascii")),
                dict(valid, digest="SHA256:" + digest.upper()),
                dict(valid, digest="sha256:" + "0" * 63),
                dict(valid, digest="sha512:" + "0" * 64),
            )
            for remote in malformed:
                try:
                    rs.verify_release_assets([asset], [remote])
                except ValueError as exc:
                    assert "remote release asset" in str(exc).lower()
                else:
                    raise AssertionError(
                        f"malformed remote release asset was accepted: {remote!r}"
                    )

    def test_release_asset_verification_fails_closed_without_authenticated_digest(self):
        with tempfile.TemporaryDirectory() as tmp:
            asset = Path(tmp) / "package.zip"
            asset.write_bytes(b"immutable package")
            try:
                rs.verify_release_assets(
                    [asset],
                    [{"name": "package.zip", "size": 17}],
                )
            except ValueError as exc:
                message = str(exc).lower()
                assert "digest" in message
                assert "authenticated" in message
            else:
                raise AssertionError("an asset with no authenticated digest was accepted")

    def test_release_asset_verification_streams_local_sha256(self):
        with tempfile.TemporaryDirectory() as tmp:
            asset = Path(tmp) / "package.zip"
            asset.write_bytes(b"immutable package")
            digest = hashlib.sha256(b"immutable package").hexdigest()
            original_read_bytes = Path.read_bytes
            try:
                def forbid_whole_file_read(_path):
                    raise AssertionError("release verification must stream local assets")

                Path.read_bytes = forbid_whole_file_read
                verified = rs.verify_release_assets(
                    [asset],
                    [{
                        "name": "package.zip",
                        "size": 17,
                        "digest": f"sha256:{digest}",
                    }],
                )
            finally:
                Path.read_bytes = original_read_bytes

            assert verified == [{
                "name": "package.zip",
                "size": 17,
                "sha256": digest,
            }]

    def test_plan_release_cli_writes_stable_github_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "github-output.txt"
            code = rs.main([
                "plan-release",
                "--version", "1.0.76",
                "--head-sha", "b" * 40,
                "--tag-sha", "a" * 40,
                "--release-state", "missing",
                "--github-output", str(output),
            ])
            assert code == 0
            assert output.read_text(encoding="utf-8").splitlines() == [
                "action=complete_existing_tag",
                "tag=v1.0.76",
                "build_ref=" + "a" * 40,
                "release_target=" + "a" * 40,
            ]

    def test_verify_release_assets_cli_writes_machine_readable_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            asset = root / "package.zip"
            release_json = root / "release.json"
            output = root / "verified.json"
            asset.write_bytes(b"immutable package")
            digest = hashlib.sha256(asset.read_bytes()).hexdigest()
            release_json.write_text(
                json.dumps({
                    "assets": [{
                        "name": asset.name,
                        "size": asset.stat().st_size,
                        "digest": f"sha256:{digest}",
                    }]
                }),
                encoding="utf-8",
            )

            code = rs.main([
                "verify-release-assets",
                "--release-json", str(release_json),
                "--asset", str(asset),
                "--output", str(output),
            ])

            assert code == 0
            assert json.loads(output.read_text(encoding="utf-8")) == {
                "verified_assets": [{
                    "name": asset.name,
                    "size": asset.stat().st_size,
                    "sha256": digest,
                }]
            }

    def test_collect_delta_accepts_explicit_head(self):
        git = fake_git_factory(
            files=["build_release.py"],
            commits=[("abc123", "fix package")],
            commit_files_map={"abc123": ["build_release.py"]},
        )
        files, commits = rs.collect_delta(
            "v1.0.0", head="push-head", git_command=git, repo_root=Path(".")
        )
        assert files == ["build_release.py"]
        assert commits == ["abc123 fix package"]

    def test_multi_commit_first_push_warns_once_and_lists_every_sha(self):
        record = {"schema_version": 1, "warnings": []}
        now = datetime.datetime(
            2026, 7, 12, 0, 0, 0, tzinfo=datetime.timezone.utc
        )
        commits = ["abc root product", "def merge product"]
        code, summary, out = rs.evaluate_warning(
            record,
            "owner/repo",
            "v1.0.0",
            ["build_release.py", "installer/setup.py"],
            commits,
            now,
            "sess-1",
            release_mode=True,
            later_product_push=False,
            first_seen_sha="abc",
            first_seen_at=now,
        )
        assert code == 0
        assert "First stranded-release warning" in summary
        assert "abc root product" in summary
        assert "def merge product" in summary
        assert out["warnings"][0]["first_seen_sha"] == "abc"
        assert out["warnings"][0]["responsible_session"] == "sess-1"

    def test_main_uses_prior_and_current_push_ranges_without_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state = root / "warnings.json"
            original_collect = rs.collect_delta
            original_before = rs._effective_before
            original_time = rs._git_commit_time
            try:
                def fake_collect(base, *, head="HEAD", **_kwargs):
                    ranges = {
                        ("v1.0.0", "headsha"): (
                            ["build_release.py", "installer/setup.py"],
                            ["abc first", "def later"],
                        ),
                        ("beforesha", "headsha"): (
                            ["installer/setup.py"],
                            ["def later"],
                        ),
                        ("v1.0.0", "beforesha"): (
                            ["build_release.py"],
                            ["abc first"],
                        ),
                    }
                    return ranges[(base, head)]

                rs.collect_delta = fake_collect
                rs._effective_before = lambda *_args: "beforesha"
                rs._git_commit_time = lambda *_args: datetime.datetime(
                    2026, 7, 12, tzinfo=datetime.timezone.utc
                )
                code = rs.main(
                    [
                        "audit-existing-tag",
                        "--repo", "owner/repo",
                        "--tag", "v1.0.0",
                        "--before", "beforesha",
                        "--head", "headsha",
                        "--mode", "release",
                        "--session-id", "sess-2",
                        "--warnings-file", str(state),
                        "--repo-root", str(root),
                    ]
                )
                assert code == 2
            finally:
                rs.collect_delta = original_collect
                rs._effective_before = original_before
                rs._git_commit_time = original_time

    def test_main_docs_only_followup_never_escalates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state = root / "warnings.json"
            original_collect = rs.collect_delta
            original_before = rs._effective_before
            try:
                def fake_collect(base, *, head="HEAD", **_kwargs):
                    if (base, head) == ("v1.0.0", "headsha"):
                        return ["build_release.py"], ["abc first"]
                    if (base, head) == ("beforesha", "headsha"):
                        return [], []
                    raise AssertionError((base, head))

                rs.collect_delta = fake_collect
                rs._effective_before = lambda *_args: "beforesha"
                code = rs.main(
                    [
                        "audit-existing-tag",
                        "--repo", "owner/repo",
                        "--tag", "v1.0.0",
                        "--before", "beforesha",
                        "--head", "headsha",
                        "--mode", "release",
                        "--warnings-file", str(state),
                        "--repo-root", str(root),
                    ]
                )
                assert code == 0
                assert not state.exists()
            finally:
                rs.collect_delta = original_collect
                rs._effective_before = original_before

    def test_all_zero_before_falls_back_to_tag(self):
        with tempfile.TemporaryDirectory() as tmp:
            assert rs._effective_before("0" * 40, "v1.0.0", Path(tmp)) == "v1.0.0"

    def test_unresolvable_before_falls_back_to_tag(self):
        with tempfile.TemporaryDirectory() as tmp:
            assert rs._effective_before("deadbeef", "v1.0.0", Path(tmp)) == "v1.0.0"

    def test_load_record_rejects_duplicate_and_wrong_tag(self):
        warning = {
            "repo": "owner/repo",
            "tag": "v0.9.0",
            "first_seen": "2026-07-12T00:00:00+00:00",
            "first_seen_sha": "abc",
            "deadline": "2026-07-13T00:00:00+00:00",
            "responsible_session": "sess-1",
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "warnings.json"
            path.write_text(
                json.dumps({"schema_version": 1, "warnings": [warning, warning]}),
                encoding="utf-8",
            )
            try:
                rs.load_warning_record(
                    path, expected_repo="owner/repo", expected_tag="v1.0.0"
                )
            except ValueError:
                pass
            else:
                raise AssertionError("duplicate/wrong-tag state was accepted")

    def test_expired_version_plan_report_mode_stays_green(self):
        first_seen = datetime.datetime(
            2026, 7, 12, tzinfo=datetime.timezone.utc
        )
        record = {
            "schema_version": 1,
            "warnings": [
                {
                    "repo": "owner/repo",
                    "tag": "v1.0.0",
                    "first_seen": first_seen.isoformat(),
                    "first_seen_sha": "abc",
                    "deadline": (first_seen + datetime.timedelta(hours=24)).isoformat(),
                    "responsible_session": "sess-1",
                    "version_bump_plan": "1.0.1",
                }
            ],
        }
        code, _, _ = rs.evaluate_warning(
            record,
            "owner/repo",
            "v1.0.0",
            ["build_release.py"],
            ["abc fix"],
            first_seen + datetime.timedelta(hours=25),
            "sess-2",
            release_mode=False,
        )
        assert code == 0

    def test_steel_shapes_release_never_overwrites_existing_assets(self):
        # The invariant is unchanged -- publishing must never clobber an asset
        # that already exists -- but the mechanism was replaced in ce2b0d6. The
        # workflow no longer uses softprops/action-gh-release with
        # overwrite_files: false; it now calls tools/complete_github_release.py,
        # which refuses on size or digest conflict. That commit carried
        # [skip release], so this gate never ran against it and the stale
        # assertion sat green until the next release-bearing push tripped it on
        # `ValueError: substring not found`. Assert the mechanism actually in use.
        workflow = (
            REPO_ROOT / ".github" / "workflows" / "steel-shapes-release.yml"
        ).read_text(encoding="utf-8")
        publish_at = workflow.index(
            "- name: Publish exact non-product-latest release"
        )
        publish_block = workflow[publish_at:]
        assert "python tools/complete_github_release.py" in publish_block
        assert "--clobber" not in publish_block
        assert "softprops/action-gh-release" not in publish_block

        completer = (
            REPO_ROOT / "tools" / "complete_github_release.py"
        ).read_text(encoding="utf-8")
        assert "refusing overwrite" in completer, (
            "complete_github_release.py must refuse to replace an existing "
            "asset; it is the only thing standing between a re-run and a "
            "silently rewritten published release"
        )

    def test_acknowledge_rejects_past_deferral(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "warnings.json"
            first_seen = datetime.datetime(
                2026, 7, 12, tzinfo=datetime.timezone.utc
            )
            path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "warnings": [
                            {
                                "repo": "owner/repo",
                                "tag": "v1.0.0",
                                "first_seen": first_seen.isoformat(),
                                "first_seen_sha": "abc",
                                "deadline": (
                                    first_seen + datetime.timedelta(hours=24)
                                ).isoformat(),
                                "responsible_session": "sess-1",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            stderr = StringIO()
            with redirect_stderr(stderr):
                code = rs.main(
                    [
                        "acknowledge",
                        "--repo", "owner/repo",
                        "--tag", "v1.0.0",
                        "--release-deferred-until", "2000-01-01T00:00:00+00:00",
                        "--warnings-file", str(path),
                    ]
                )
            assert code == 1
            assert "must be in the future" in stderr.getvalue()

    def test_load_rejects_invalid_version_plan_values(self):
        first_seen = "2026-07-12T00:00:00+00:00"
        base = {
            "repo": "owner/repo",
            "tag": "v1.0.0",
            "first_seen": first_seen,
            "first_seen_sha": "abc",
            "deadline": "2026-07-13T00:00:00+00:00",
            "responsible_session": "sess-1",
            "acknowledged_at": "2026-07-12T01:00:00+00:00",
        }
        for bad in (
            None,
            "",
            {},
            [],
            True,
            "next someday",
            "01.2.3",
            "1.2.3-.",
            "1.2.3-a..b",
            "1.2.3-01",
        ):
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "warnings.json"
                warning = dict(base, version_bump_plan=bad)
                path.write_text(
                    json.dumps({"schema_version": 1, "warnings": [warning]}),
                    encoding="utf-8",
                )
                try:
                    rs.load_warning_record(
                        path, expected_repo="owner/repo", expected_tag="v1.0.0"
                    )
                except ValueError:
                    pass
                else:
                    raise AssertionError(f"invalid plan was accepted: {bad!r}")

    def test_load_rejects_unicode_digits_in_version_plan(self):
        warning = {
            "repo": "owner/repo",
            "tag": "v1.0.0",
            "first_seen": "2026-07-12T00:00:00+00:00",
            "first_seen_sha": "abc",
            "deadline": "2026-07-13T00:00:00+00:00",
            "responsible_session": "sess-1",
            "acknowledged_at": "2026-07-12T01:00:00+00:00",
            "version_bump_plan": "1١.2.3",
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "warnings.json"
            path.write_text(
                json.dumps({"schema_version": 1, "warnings": [warning]}),
                encoding="utf-8",
            )
            try:
                rs.load_warning_record(
                    path, expected_repo="owner/repo", expected_tag="v1.0.0"
                )
            except ValueError:
                pass
            else:
                raise AssertionError("Unicode digits were accepted in a version plan")

    def test_load_rejects_trailing_newline_in_version_plan(self):
        warning = {
            "repo": "owner/repo",
            "tag": "v1.0.0",
            "first_seen": "2026-07-12T00:00:00+00:00",
            "first_seen_sha": "abc",
            "deadline": "2026-07-13T00:00:00+00:00",
            "responsible_session": "sess-1",
            "acknowledged_at": "2026-07-12T01:00:00+00:00",
            "version_bump_plan": "1.2.3\n",
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "warnings.json"
            path.write_text(
                json.dumps({"schema_version": 1, "warnings": [warning]}),
                encoding="utf-8",
            )
            try:
                rs.load_warning_record(
                    path, expected_repo="owner/repo", expected_tag="v1.0.0"
                )
            except ValueError:
                pass
            else:
                raise AssertionError("a trailing newline was accepted in a version plan")

    def test_load_accepts_full_semver_version_plan(self):
        warning = {
            "repo": "owner/repo",
            "tag": "v1.0.0",
            "first_seen": "2026-07-12T00:00:00+00:00",
            "first_seen_sha": "abc",
            "deadline": "2026-07-13T00:00:00+00:00",
            "responsible_session": "sess-1",
            "acknowledged_at": "2026-07-12T01:00:00+00:00",
            "version_bump_plan": "1.2.3-rc.1+build.5",
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "warnings.json"
            path.write_text(
                json.dumps({"schema_version": 1, "warnings": [warning]}),
                encoding="utf-8",
            )
            record = rs.load_warning_record(path, expected_repo="owner/repo")
            assert record["warnings"][0]["version_bump_plan"] == warning["version_bump_plan"]

    def test_historical_tag_for_same_repo_is_allowed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "warnings.json"
            path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "warnings": [
                            {
                                "repo": "owner/repo",
                                "tag": "v0.9.0",
                                "first_seen": "2026-07-12T00:00:00+00:00",
                                "first_seen_sha": "abc",
                                "deadline": "2026-07-13T00:00:00+00:00",
                                "responsible_session": "sess-1",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            record = rs.load_warning_record(
                path, expected_repo="owner/repo", expected_tag="v1.0.0"
            )
            assert record["warnings"][0]["tag"] == "v0.9.0"

    def test_deferral_must_be_future_when_acknowledged_but_may_expire_later(self):
        warning = {
            "repo": "owner/repo",
            "tag": "v1.0.0",
            "first_seen": "2026-07-12T00:00:00+00:00",
            "first_seen_sha": "abc",
            "deadline": "2026-07-13T00:00:00+00:00",
            "responsible_session": "sess-1",
            "acknowledged_at": "2026-07-12T01:00:00+00:00",
            "release_deferred_until": "2026-07-12T12:00:00+00:00",
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "warnings.json"
            path.write_text(
                json.dumps({"schema_version": 1, "warnings": [warning]}),
                encoding="utf-8",
            )
            rs.load_warning_record(
                path, expected_repo="owner/repo", expected_tag="v1.0.0"
            )
            warning["acknowledged_at"] = "2026-07-12T13:00:00+00:00"
            path.write_text(
                json.dumps({"schema_version": 1, "warnings": [warning]}),
                encoding="utf-8",
            )
            try:
                rs.load_warning_record(
                    path, expected_repo="owner/repo", expected_tag="v1.0.0"
                )
            except ValueError:
                pass
            else:
                raise AssertionError("deferral already past at acknowledgement was accepted")

    def test_load_rejects_non_string_identity_fields(self):
        for key, bad in (("repo", None), ("tag", []), ("first_seen_sha", True), ("responsible_session", {})):
            warning = {
                "repo": "owner/repo",
                "tag": "v1.0.0",
                "first_seen": "2026-07-12T00:00:00+00:00",
                "first_seen_sha": "abc",
                "deadline": "2026-07-13T00:00:00+00:00",
                "responsible_session": "sess-1",
            }
            warning[key] = bad
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "warnings.json"
                path.write_text(
                    json.dumps({"schema_version": 1, "warnings": [warning]}),
                    encoding="utf-8",
                )
                try:
                    rs.load_warning_record(path, expected_repo="owner/repo")
                except ValueError:
                    pass
                else:
                    raise AssertionError(f"non-string {key} was accepted")


if __name__ == "__main__":
    # Minimal runner; run with pytest or unittest as well.
    t = ReleaseSafetyTest()
    for name in dir(t):
        if name.startswith("test_"):
            print(f"RUN {name}")
            getattr(t, name)()
    print("OK")
