#!/usr/bin/env python3

from __future__ import annotations

import copy
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import complete_github_release as release


class FakeGitHub:
    def __init__(self, tag_target="a" * 40, release_data=None):
        self.tag_target = tag_target
        self.release_data = release_data
        self.calls = []
        self.downloads = {}
        self.race_on_create = False
        self.created_release_is_draft = False
        self.created_release_is_immutable = True
        self.get_by_id_calls = []
        self.race_on_upload = False
        self.race_on_publish = False
        self.upload_visibility_lag = 0
        self.publish_visibility_lag = 0
        self.stale_release_views = []

    def get_tag_target(self, _tag):
        return self.tag_target

    def get_release(self, _tag):
        return self.release_data

    def get_release_by_id(self, release_id):
        self.get_by_id_calls.append(release_id)
        if self.stale_release_views:
            return self.stale_release_views.pop(0)
        if self.release_data is None:
            return None
        if self.release_data.get("id") != release_id:
            return None
        return self.release_data

    def create_release(self, tag, target, title, notes, assets, latest):
        self.calls.append(("create", tag, target, tuple(a.name for a in assets)))
        if target is not None:
            self.tag_target = target
        payload = release.release_payload(
            tag, self.tag_target, assets,
            immutable=self.created_release_is_immutable,
        )
        payload.update({
            "id": 101,
            "draft": self.created_release_is_draft,
        })
        self.downloads.update({a.name: a.path.read_bytes() for a in assets})
        self.release_data = payload
        if self.race_on_create:
            raise release.CommandFailed("already_exists")

    def upload_asset(self, release_id, asset):
        self.calls.append(("upload", release_id, asset.name))
        if self.release_data is None or self.release_data.get("id") != release_id:
            raise AssertionError("attempted to upload to a different release")
        stale = copy.deepcopy(self.release_data)
        self.downloads[asset.name] = asset.path.read_bytes()
        self.release_data["assets"].append(release.asset_payload(asset))
        self.stale_release_views.extend(
            copy.deepcopy(stale) for _ in range(self.upload_visibility_lag)
        )
        if self.race_on_upload:
            raise release.CommandFailed("asset already uploaded by concurrent run")

    def publish_release(self, release_id, latest):
        self.calls.append(("publish", release_id, latest))
        if self.release_data is None or self.release_data.get("id") != release_id:
            raise AssertionError("attempted to publish a different release")
        stale = copy.deepcopy(self.release_data)
        self.release_data["draft"] = False
        self.release_data["immutable"] = True
        self.stale_release_views.extend(
            copy.deepcopy(stale) for _ in range(self.publish_visibility_lag)
        )
        if self.race_on_publish:
            raise release.CommandFailed("release already published by concurrent run")

    def download_asset(self, asset):
        return self.downloads[asset["name"]]


class CompleteGitHubReleaseTest(unittest.TestCase):
    def setUp(self):
        self._original_poll_sleep = release._poll_sleep
        release._poll_sleep = lambda _seconds: None

    def tearDown(self):
        release._poll_sleep = self._original_poll_sleep

    def make_assets(self, root):
        paths = []
        for name, data in (("product.rbz", b"package"),
                           ("SHA256SUMS.txt", b"checksums")):
            path = root / name
            path.write_bytes(data)
            paths.append(release.LocalAsset.from_path(path))
        return paths

    def make_release_data(
        self,
        tag,
        target,
        assets,
        *,
        release_id=101,
        draft=False,
        immutable=True,
    ):
        payload = release.release_payload(
            tag, target, assets, immutable=immutable
        )
        payload.update({"id": release_id, "draft": draft})
        return payload

    def test_existing_tag_without_release_creates_complete_release(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub()
            result = release.complete_release(
                github, "v1.2.3", "a" * 40, "title", "notes", assets, True
            )
            self.assertTrue(result["changed"])
            self.assertTrue(result["completed"])
            self.assertTrue(result["published_now"])
            self.assertEqual(101, result["release_id"])
            self.assertEqual("created", result["action"])
            self.assertEqual(
                ("create", "v1.2.3", None, ("product.rbz", "SHA256SUMS.txt")),
                github.calls[0],
            )

    def test_absent_tag_creation_passes_exact_atomic_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub(tag_target=None)
            result = release.complete_release(
                github, "v1.2.3", "a" * 40, "title", "notes", assets, True
            )
            self.assertTrue(result["completed"])
            self.assertEqual("a" * 40, github.calls[0][2])

    def test_gh_existing_tag_release_create_omits_target_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = release.GhClient("owner/repo")
            captured = []
            github._run = lambda args, **_kwargs: captured.append(args)
            github.create_release(
                "v1.2.3", None, "title", "notes", assets, True
            )
            self.assertEqual(1, len(captured))
            self.assertNotIn("--target", captured[0])

    def test_gh_absent_tag_release_create_includes_exact_target_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = release.GhClient("owner/repo")
            captured = []
            github._run = lambda args, **_kwargs: captured.append(args)
            github.create_release(
                "v1.2.3", "a" * 40, "title", "notes", assets, True
            )
            target_index = captured[0].index("--target")
            self.assertEqual("a" * 40, captured[0][target_index + 1])

    def test_gh_nonproduct_release_is_explicitly_not_latest(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = release.GhClient("owner/repo")
            captured = []
            github._run = lambda args, **_kwargs: captured.append(args)
            github.create_release(
                "steel-v1.0.1", "a" * 40, "title", "notes", assets, False
            )
            self.assertIn("--latest=false", captured[0])

    def test_partial_mutable_release_uploads_only_missing_asset(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub(
                release_data=self.make_release_data(
                    "v1.2.3", "a" * 40, [assets[0]],
                    draft=True, immutable=False,
                )
            )
            github.downloads[assets[0].name] = assets[0].path.read_bytes()
            result = release.complete_release(
                github, "v1.2.3", "a" * 40, "title", "notes", assets, True
            )
            self.assertEqual(
                [
                    ("upload", 101, assets[1].name),
                    ("publish", 101, True),
                ],
                github.calls,
            )
            self.assertEqual("completed_and_published_draft", result["action"])
            self.assertTrue(result["changed"])
            self.assertTrue(result["published_now"])
            self.assertFalse(github.release_data["draft"])
            self.assertTrue(github.release_data["immutable"])
            self.assertGreaterEqual(github.get_by_id_calls.count(101), 2)

    def test_complete_draft_is_explicitly_published_then_refetched(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub(
                release_data=self.make_release_data(
                    "v1.2.3", "a" * 40, assets,
                    draft=True, immutable=False,
                )
            )
            github.downloads = {a.name: a.path.read_bytes() for a in assets}

            result = release.complete_release(
                github, "v1.2.3", "a" * 40, "title", "notes", assets, True
            )

            self.assertEqual([("publish", 101, True)], github.calls)
            self.assertEqual("published_draft", result["action"])
            self.assertTrue(result["published_now"])
            self.assertTrue(result["immutable"])
            self.assertGreaterEqual(github.get_by_id_calls.count(101), 2)

    def test_upload_and_publish_command_races_reconcile_by_exact_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub(
                release_data=self.make_release_data(
                    "v1.2.3", "a" * 40, [assets[0]],
                    draft=True, immutable=False,
                )
            )
            github.downloads[assets[0].name] = assets[0].path.read_bytes()
            github.race_on_upload = True
            github.race_on_publish = True

            result = release.complete_release(
                github, "v1.2.3", "a" * 40,
                "title", "notes", assets, True,
                expected_release_id=101,
            )

            self.assertEqual("publish_race_completed", result["action"])
            self.assertFalse(result["published_now"])
            self.assertTrue(result["immutable"])
            self.assertTrue(all(value == 101 for value in github.get_by_id_calls))

    def test_eventually_consistent_release_views_are_polled_to_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub(
                release_data=self.make_release_data(
                    "v1.2.3", "a" * 40, [assets[0]],
                    draft=True, immutable=False,
                )
            )
            github.downloads[assets[0].name] = assets[0].path.read_bytes()
            github.upload_visibility_lag = 2
            github.publish_visibility_lag = 2

            result = release.complete_release(
                github, "v1.2.3", "a" * 40,
                "title", "notes", assets, True,
                expected_release_id=101,
            )

            self.assertTrue(result["published_now"])
            self.assertTrue(result["immutable"])
            self.assertGreaterEqual(github.get_by_id_calls.count(101), 7)

    def test_complete_release_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub(
                release_data=self.make_release_data(
                    "v1.2.3", "a" * 40, assets,
                    draft=False, immutable=True,
                )
            )
            github.downloads = {a.name: a.path.read_bytes() for a in assets}
            result = release.complete_release(
                github, "v1.2.3", "a" * 40, "title", "notes", assets, True
            )
            self.assertEqual([], github.calls)
            self.assertFalse(result["changed"])
            self.assertFalse(result["published_now"])
            self.assertEqual("already_complete", result["action"])

    def test_published_incomplete_release_fails_without_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub(
                release_data=self.make_release_data(
                    "v1.2.3", "a" * 40, [assets[0]],
                    draft=False, immutable=False,
                )
            )
            github.downloads[assets[0].name] = assets[0].path.read_bytes()

            with self.assertRaisesRegex(
                release.ReleaseConflict, "published release is incomplete"
            ):
                release.complete_release(
                    github, "v1.2.3", "a" * 40,
                    "title", "notes", assets, True,
                )
            self.assertEqual([], github.calls)

    def test_published_mutable_release_fails_without_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub(
                release_data=self.make_release_data(
                    "v1.2.3", "a" * 40, assets,
                    draft=False, immutable=False,
                )
            )
            github.downloads = {a.name: a.path.read_bytes() for a in assets}

            with self.assertRaisesRegex(release.ReleaseConflict, "not immutable"):
                release.complete_release(
                    github, "v1.2.3", "a" * 40,
                    "title", "notes", assets, True,
                )
            self.assertEqual([], github.calls)

    def test_wrong_existing_digest_fails_without_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            wrong = release.asset_payload(assets[0])
            wrong["digest"] = "sha256:" + "f" * 64
            github = FakeGitHub(
                release_data={
                    "id": 101, "draft": False,
                    "tag_name": "v1.2.3", "target_commitish": "a" * 40,
                    "immutable": False, "assets": [wrong]
                }
            )
            with self.assertRaisesRegex(release.ReleaseConflict, "digest"):
                release.complete_release(
                    github, "v1.2.3", "a" * 40, "title", "notes", assets, True
                )
            self.assertEqual([], github.calls)

    def test_duplicate_or_immutable_incomplete_release_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            duplicate = release.asset_payload(assets[0])
            github = FakeGitHub(
                release_data={
                    "id": 101, "draft": True,
                    "tag_name": "v1.2.3", "target_commitish": "a" * 40,
                    "immutable": False, "assets": [duplicate, dict(duplicate)]
                }
            )
            with self.assertRaisesRegex(release.ReleaseConflict, "duplicate"):
                release.complete_release(
                    github, "v1.2.3", "a" * 40, "title", "notes", assets, True
                )

            github = FakeGitHub(
                release_data=self.make_release_data(
                    "v1.2.3", "a" * 40, [assets[0]],
                    draft=True, immutable=True,
                )
            )
            github.downloads[assets[0].name] = assets[0].path.read_bytes()
            with self.assertRaisesRegex(release.ReleaseConflict, "immutable"):
                release.complete_release(
                    github, "v1.2.3", "a" * 40, "title", "notes", assets, True
                )

    def test_wrong_tag_target_fails_before_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub(tag_target="b" * 40)
            with self.assertRaisesRegex(release.ReleaseConflict, "tag target"):
                release.complete_release(
                    github, "v1.2.3", "a" * 40, "title", "notes", assets, True
                )
            self.assertEqual([], github.calls)

    def test_create_race_reinspects_and_succeeds_without_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub()
            github.race_on_create = True
            result = release.complete_release(
                github, "v1.2.3", "a" * 40, "title", "notes", assets, True
            )
            self.assertTrue(result["completed"])
            self.assertEqual("create_race_completed", result["action"])

    def test_expected_release_id_binds_existing_draft_before_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub(
                release_data=self.make_release_data(
                    "v1.2.3", "a" * 40, assets,
                    release_id=202, draft=True, immutable=False,
                )
            )
            github.downloads = {a.name: a.path.read_bytes() for a in assets}

            with self.assertRaisesRegex(release.ReleaseConflict, "release id"):
                release.complete_release(
                    github, "v1.2.3", "a" * 40,
                    "title", "notes", assets, True,
                    expected_release_id=101,
                )
            self.assertEqual([], github.calls)
            self.assertEqual([101], github.get_by_id_calls)

    def test_expected_release_id_is_preserved_through_publish(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub(
                release_data=self.make_release_data(
                    "v1.2.3", "a" * 40, assets,
                    release_id=202, draft=True, immutable=False,
                )
            )
            github.downloads = {a.name: a.path.read_bytes() for a in assets}

            result = release.complete_release(
                github, "v1.2.3", "a" * 40,
                "title", "notes", assets, True,
                expected_release_id="202",
            )

            self.assertEqual(202, result["release_id"])
            self.assertEqual([("publish", 202, True)], github.calls)
            self.assertTrue(all(value == 202 for value in github.get_by_id_calls))

    def test_unexpected_remote_asset_is_rejected_before_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            unexpected = dict(release.asset_payload(assets[0]))
            unexpected.update({"id": 999, "name": "surprise.bin"})
            data = self.make_release_data(
                "v1.2.3", "a" * 40, assets,
                draft=True, immutable=False,
            )
            data["assets"].append(unexpected)
            github = FakeGitHub(release_data=data)
            github.downloads = {a.name: a.path.read_bytes() for a in assets}

            with self.assertRaisesRegex(release.ReleaseConflict, "unexpected"):
                release.complete_release(
                    github, "v1.2.3", "a" * 40,
                    "title", "notes", assets, True,
                )
            self.assertEqual([], github.calls)

    def test_new_release_must_be_published_and_immutable(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub()
            github.created_release_is_immutable = False

            with self.assertRaisesRegex(release.ReleaseConflict, "not immutable"):
                release.complete_release(
                    github, "v1.2.3", "a" * 40,
                    "title", "notes", assets, True,
                )

    def test_gh_publish_uses_exact_release_id_and_typed_json(self):
        github = release.GhClient("owner/repo")
        captured = []
        github._run = lambda args, **kwargs: captured.append((args, kwargs))

        github.publish_release(202, False)

        self.assertEqual(1, len(captured))
        args, kwargs = captured[0]
        self.assertEqual(
            [
                "api", "--method", "PATCH",
                "repos/owner/repo/releases/202",
                "--input", "-",
            ],
            args,
        )
        self.assertEqual(
            {"draft": False, "make_latest": "false"},
            __import__("json").loads(kwargs["input_text"]),
        )

    def test_gh_upload_uses_exact_release_id_and_encoded_asset_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "product final.rbz"
            path.write_bytes(b"package")
            asset = release.LocalAsset.from_path(path)
            github = release.GhClient("owner/repo")
            captured = []
            github._run = lambda args, **kwargs: captured.append((args, kwargs))

            github.upload_asset(202, asset)

            self.assertEqual(
                [
                    "api", "--method", "POST",
                    "--hostname", "uploads.github.com",
                    "-H", "Content-Type: application/octet-stream",
                    "repos/owner/repo/releases/202/assets?name=product%20final.rbz",
                    "--input", str(asset.path),
                ],
                captured[0][0],
            )
            self.assertEqual({}, captured[0][1])

    def test_outputs_include_publication_and_release_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "github-output"
            release._write_outputs(
                output,
                {
                    "completed": True,
                    "changed": True,
                    "published_now": True,
                    "action": "published_draft",
                    "tag": "v1.2.3",
                    "target": "a" * 40,
                    "release_id": 202,
                    "immutable": True,
                },
            )
            self.assertEqual(
                [
                    "completed=true",
                    "changed=true",
                    "published_now=true",
                    "action=published_draft",
                    "tag=v1.2.3",
                    "target=" + "a" * 40,
                    "release_id=202",
                    "immutable=true",
                ],
                output.read_text(encoding="utf-8").splitlines(),
            )


if __name__ == "__main__":
    unittest.main()
