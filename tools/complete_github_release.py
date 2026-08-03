#!/usr/bin/env python3
"""Complete a GitHub release without rewriting tags or replacing assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote


class ReleaseConflict(RuntimeError):
    """Existing remote state conflicts with the requested immutable release."""


class CommandFailed(RuntimeError):
    """The GitHub CLI failed."""


@dataclass(frozen=True)
class LocalAsset:
    path: Path
    name: str
    size: int
    sha256: str

    @classmethod
    def from_path(cls, value):
        path = Path(value).resolve()
        if not path.is_file():
            raise ReleaseConflict(f"release asset is missing: {path}")
        return cls(
            path=path,
            name=path.name,
            size=path.stat().st_size,
            sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
        )


def asset_payload(asset):
    return {
        "id": asset.name,
        "name": asset.name,
        "size": asset.size,
        "digest": f"sha256:{asset.sha256}",
    }


def release_payload(tag, target, assets, immutable=False):
    return {
        "tag_name": tag,
        "target_commitish": target,
        "immutable": immutable,
        "assets": [asset_payload(asset) for asset in assets],
    }


class GhClient:
    def __init__(self, repo):
        self.repo = repo

    def _run(self, args, *, binary=False, allow_not_found=False):
        completed = subprocess.run(
            ["gh", *args], capture_output=True, text=not binary, check=False
        )
        if completed.returncode == 0:
            return completed.stdout
        stderr = completed.stderr
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
        if allow_not_found and ("404" in stderr or "Not Found" in stderr):
            return None
        raise CommandFailed(
            f"gh {' '.join(args)} failed ({completed.returncode}): {stderr.strip()}"
        )

    def _json(self, endpoint, *, allow_not_found=False):
        output = self._run(
            ["api", endpoint], allow_not_found=allow_not_found
        )
        return None if output is None else json.loads(output)

    def get_tag_target(self, tag):
        encoded = quote(tag, safe="")
        ref = self._json(
            f"repos/{self.repo}/git/ref/tags/{encoded}", allow_not_found=True
        )
        if ref is None:
            return None
        obj = ref.get("object") or {}
        seen = set()
        while obj.get("type") == "tag":
            sha = str(obj.get("sha", "")).lower()
            if not sha or sha in seen:
                raise ReleaseConflict(f"tag {tag} has an invalid tag-object chain")
            seen.add(sha)
            annotated = self._json(f"repos/{self.repo}/git/tags/{sha}")
            obj = annotated.get("object") or {}
        if obj.get("type") != "commit":
            raise ReleaseConflict(f"tag {tag} does not resolve to a commit")
        return str(obj.get("sha", "")).lower()

    def get_release(self, tag):
        encoded = quote(tag, safe="")
        return self._json(
            f"repos/{self.repo}/releases/tags/{encoded}", allow_not_found=True
        )

    def create_release(self, tag, target, title, notes, assets, latest):
        args = [
            "release", "create", tag, "--repo", self.repo,
        ]
        if target is not None:
            args.extend(["--target", target])
        args.extend(["--title", title, "--notes", notes])
        if latest:
            args.append("--latest")
        else:
            args.append("--latest=false")
        args.extend(str(asset.path) for asset in assets)
        self._run(args)

    def upload_asset(self, tag, asset):
        self._run([
            "release", "upload", tag, str(asset.path), "--repo", self.repo
        ])

    def download_asset(self, asset):
        return self._run([
            "api", "-H", "Accept: application/octet-stream",
            f"repos/{self.repo}/releases/assets/{asset['id']}",
        ], binary=True)


def _remote_digest(github, remote):
    digest = str(remote.get("digest") or "").lower()
    if digest.startswith("sha256:") and len(digest) == 71:
        return digest[7:]
    return hashlib.sha256(github.download_asset(remote)).hexdigest()


def _inspect_release(github, release_data, expected_assets):
    remote_assets = list(release_data.get("assets") or [])
    by_name = {}
    for remote in remote_assets:
        name = str(remote.get("name") or "")
        if name in by_name:
            raise ReleaseConflict(f"duplicate release asset name: {name}")
        by_name[name] = remote

    missing = []
    for expected in expected_assets:
        remote = by_name.get(expected.name)
        if remote is None:
            missing.append(expected)
            continue
        if int(remote.get("size") or -1) != expected.size:
            raise ReleaseConflict(
                f"asset size conflict for {expected.name}; refusing overwrite"
            )
        if _remote_digest(github, remote) != expected.sha256:
            raise ReleaseConflict(
                f"asset digest conflict for {expected.name}; refusing overwrite"
            )
    return missing


def complete_release(github, tag, target, title, notes, assets, latest=False):
    expected_target = str(target).lower()
    if len(expected_target) != 40 or any(
        char not in "0123456789abcdef" for char in expected_target
    ):
        raise ReleaseConflict("release target must be an exact 40-hex commit SHA")
    names = [asset.name for asset in assets]
    if len(names) != len(set(names)):
        raise ReleaseConflict("duplicate local release asset name")

    tag_target = github.get_tag_target(tag)
    if tag_target is not None and tag_target.lower() != expected_target:
        raise ReleaseConflict(
            f"tag target conflict for {tag}: {tag_target} != {expected_target}"
        )

    current = github.get_release(tag)
    if current is None:
        action = "created"
        # An existing exact tag has already established the release target.
        # Omitting --target avoids asking the job token for an unnecessary tag
        # write; an absent tag still uses --target for atomic tag creation.
        create_target = expected_target if tag_target is None else None
        try:
            github.create_release(tag, create_target, title, notes, assets, latest)
        except CommandFailed:
            current = github.get_release(tag)
            if current is None:
                raise
            action = "create_race_completed"
        else:
            current = github.get_release(tag)
        changed = True
    else:
        missing = _inspect_release(github, current, assets)
        if missing and current.get("immutable") is True:
            raise ReleaseConflict(
                "existing release is immutable and incomplete: "
                + ", ".join(asset.name for asset in missing)
            )
        for asset in missing:
            github.upload_asset(tag, asset)
        changed = bool(missing)
        action = "completed_partial" if missing else "already_complete"
        current = github.get_release(tag)

    if current is None:
        raise ReleaseConflict("release was not observable after completion")
    post_target = github.get_tag_target(tag)
    if post_target is None or post_target.lower() != expected_target:
        raise ReleaseConflict("release tag target failed post-verification")
    missing = _inspect_release(github, current, assets)
    if missing:
        raise ReleaseConflict(
            "release remains incomplete after completion: "
            + ", ".join(asset.name for asset in missing)
        )
    return {
        "completed": True,
        "changed": changed,
        "action": action,
        "tag": tag,
        "target": expected_target,
        "immutable": current.get("immutable") is True,
        "assets": {
            asset.name: {"size": asset.size, "sha256": asset.sha256}
            for asset in assets
        },
    }


def _write_outputs(path, result):
    if not path:
        return
    with Path(path).open("a", encoding="utf-8", newline="\n") as handle:
        for key in ("completed", "changed", "action", "tag", "target", "immutable"):
            value = result[key]
            if isinstance(value, bool):
                value = str(value).lower()
            handle.write(f"{key}={value}\n")


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--notes-file", required=True)
    parser.add_argument("--asset", action="append", required=True)
    parser.add_argument("--latest", action="store_true")
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
    args = parser.parse_args(argv)
    try:
        assets = [LocalAsset.from_path(path) for path in args.asset]
        notes = Path(args.notes_file).read_text(encoding="utf-8")
        result = complete_release(
            GhClient(args.repo), args.tag, args.target, args.title,
            notes, assets, args.latest
        )
        _write_outputs(args.github_output, result)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (ReleaseConflict, CommandFailed, OSError, ValueError) as error:
        print(f"release completion failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
