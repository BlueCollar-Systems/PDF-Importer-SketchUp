#!/usr/bin/env python3

from __future__ import annotations

import hashlib
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

    def get_tag_target(self, _tag):
        return self.tag_target

    def get_release(self, _tag):
        return self.release_data

    def create_release(self, tag, target, title, notes, assets, latest):
        self.calls.append(("create", tag, target, tuple(a.name for a in assets)))
        payload = release.release_payload(tag, target, assets, immutable=False)
        self.downloads.update({a.name: a.path.read_bytes() for a in assets})
        self.release_data = payload
        if self.race_on_create:
            raise release.CommandFailed("already_exists")

    def upload_asset(self, tag, asset):
        self.calls.append(("upload", tag, asset.name))
        self.downloads[asset.name] = asset.path.read_bytes()
        self.release_data["assets"].append(release.asset_payload(asset))

    def download_asset(self, asset):
        return self.downloads[asset["name"]]


class CompleteGitHubReleaseTest(unittest.TestCase):
    def make_assets(self, root):
        paths = []
        for name, data in (("product.rbz", b"package"),
                           ("SHA256SUMS.txt", b"checksums")):
            path = root / name
            path.write_bytes(data)
            paths.append(release.LocalAsset.from_path(path))
        return paths

    def test_existing_tag_without_release_creates_complete_release(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub()
            result = release.complete_release(
                github, "v1.2.3", "a" * 40, "title", "notes", assets, True
            )
            self.assertTrue(result["changed"])
            self.assertTrue(result["completed"])
            self.assertEqual("created", result["action"])
            self.assertEqual("create", github.calls[0][0])

    def test_partial_mutable_release_uploads_only_missing_asset(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            present = release.asset_payload(assets[0])
            github = FakeGitHub(
                release_data=release.release_payload(
                    "v1.2.3", "a" * 40, [assets[0]], immutable=False
                )
            )
            github.downloads[assets[0].name] = assets[0].path.read_bytes()
            result = release.complete_release(
                github, "v1.2.3", "a" * 40, "title", "notes", assets, True
            )
            self.assertEqual([("upload", "v1.2.3", assets[1].name)], github.calls)
            self.assertEqual("completed_partial", result["action"])
            self.assertTrue(result["changed"])

    def test_complete_release_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            github = FakeGitHub(
                release_data=release.release_payload(
                    "v1.2.3", "a" * 40, assets, immutable=True
                )
            )
            github.downloads = {a.name: a.path.read_bytes() for a in assets}
            result = release.complete_release(
                github, "v1.2.3", "a" * 40, "title", "notes", assets, True
            )
            self.assertEqual([], github.calls)
            self.assertFalse(result["changed"])
            self.assertEqual("already_complete", result["action"])

    def test_wrong_existing_digest_fails_without_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            assets = self.make_assets(Path(tmp))
            wrong = release.asset_payload(assets[0])
            wrong["digest"] = "sha256:" + "f" * 64
            github = FakeGitHub(
                release_data={
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
                    "tag_name": "v1.2.3", "target_commitish": "a" * 40,
                    "immutable": False, "assets": [duplicate, dict(duplicate)]
                }
            )
            with self.assertRaisesRegex(release.ReleaseConflict, "duplicate"):
                release.complete_release(
                    github, "v1.2.3", "a" * 40, "title", "notes", assets, True
                )

            github = FakeGitHub(
                release_data=release.release_payload(
                    "v1.2.3", "a" * 40, [assets[0]], immutable=True
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


if __name__ == "__main__":
    unittest.main()
