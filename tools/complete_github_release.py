#!/usr/bin/env python3
"""Complete a GitHub release without rewriting tags or replacing assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote


class ReleaseConflict(RuntimeError):
    """Existing remote state conflicts with the requested immutable release."""


class CommandFailed(RuntimeError):
    """The GitHub CLI failed."""


_POLL_DELAYS = (0, 1, 2, 4, 8)
_poll_sleep = time.sleep


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

    def _run(
        self, args, *, binary=False, allow_not_found=False, input_text=None
    ):
        if binary and input_text is not None:
            raise ValueError("binary GitHub CLI calls cannot accept text input")
        completed = subprocess.run(
            ["gh", *args],
            capture_output=True,
            text=not binary,
            check=False,
            input=input_text,
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

    def get_release_by_id(self, release_id):
        return self._json(
            f"repos/{self.repo}/releases/{release_id}", allow_not_found=True
        )

    def list_releases(self):
        # The by-tag endpoint never returns drafts (a draft has no tag ref
        # yet), so draft discovery must go through the list. One page of 100
        # is far beyond this repository's release count; the workflow's
        # release-plan step paginates independently for its own discovery.
        listing = self._json(f"repos/{self.repo}/releases?per_page=100")
        return listing if isinstance(listing, list) else []

    def create_release(self, tag, target, title, notes, assets, latest):
        args = [
            "release", "create", tag, "--repo", self.repo,
        ]
        if target is not None:
            args.extend(["--target", target])
        # Assemble every asset behind a draft boundary. Publication is a
        # separate ID-bound operation after exact verification, so an
        # interrupted upload cannot freeze an incomplete public release.
        args.extend(["--title", title, "--notes", notes, "--draft"])
        args.extend(str(asset.path) for asset in assets)
        self._run(args)

    def upload_asset(self, release_id, asset):
        encoded_name = quote(asset.name, safe="")
        self._run([
            "api", "--method", "POST",
            "--hostname", "uploads.github.com",
            "-H", "Content-Type: application/octet-stream",
            (
                f"repos/{self.repo}/releases/{release_id}/assets"
                f"?name={encoded_name}"
            ),
            "--input", str(asset.path),
        ])

    def publish_release(self, release_id, latest):
        payload = json.dumps(
            {
                "draft": False,
                "make_latest": "true" if latest else "false",
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        self._run(
            [
                "api", "--method", "PATCH",
                f"repos/{self.repo}/releases/{release_id}",
                "--input", "-",
            ],
            input_text=payload,
        )

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
    remote_assets = release_data.get("assets")
    if not isinstance(remote_assets, list):
        raise ReleaseConflict("release assets must be a JSON array")
    by_name = {}
    for remote in remote_assets:
        if not isinstance(remote, dict):
            raise ReleaseConflict("release assets must contain only JSON objects")
        name = str(remote.get("name") or "")
        if name in by_name:
            raise ReleaseConflict(f"duplicate release asset name: {name}")
        by_name[name] = remote

    expected_names = {asset.name for asset in expected_assets}
    unexpected = sorted(set(by_name) - expected_names)
    if unexpected:
        raise ReleaseConflict(
            "unexpected release assets: " + ", ".join(unexpected)
        )

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


def _release_id(value, *, label="release id"):
    if isinstance(value, bool):
        raise ReleaseConflict(f"{label} must be a positive integer")
    if isinstance(value, int):
        parsed = value
    elif isinstance(value, str):
        if not value or any(char not in "0123456789" for char in value):
            raise ReleaseConflict(f"{label} must be a positive integer")
        parsed = int(value)
    else:
        raise ReleaseConflict(f"{label} must be a positive integer")
    if parsed <= 0:
        raise ReleaseConflict(f"{label} must be a positive integer")
    return parsed


def _release_state(release_data, tag, *, expected_release_id=None):
    if not isinstance(release_data, dict):
        raise ReleaseConflict("release response must be a JSON object")
    release_id = _release_id(release_data.get("id"))
    if expected_release_id is not None and release_id != expected_release_id:
        raise ReleaseConflict(
            f"release id conflict: {release_id} != {expected_release_id}"
        )
    if release_data.get("tag_name") != tag:
        raise ReleaseConflict(
            f"release id {release_id} is bound to a different tag"
        )
    draft = release_data.get("draft")
    immutable = release_data.get("immutable")
    if not isinstance(draft, bool):
        raise ReleaseConflict("release draft state must be boolean")
    if not isinstance(immutable, bool):
        raise ReleaseConflict("release immutable state must be boolean")
    return release_id, draft, immutable


def _find_release_by_tag(github, tag):
    """Find a release for the tag, INCLUDING drafts.

    GET /releases/tags/{tag} only ever returns a published release: a draft
    has no tag ref yet. This tool now creates releases as drafts, so both the
    just-created draft and a pre-existing one must be discovered through the
    release list, or creation appears to have vanished ("not observable after
    creation") and a rerun would mint a duplicate draft.
    """
    published = github.get_release(tag)
    if published is not None:
        return published
    list_releases = getattr(github, "list_releases", None)
    if not callable(list_releases):
        return None
    matches = [
        release for release in list_releases()
        if isinstance(release, dict) and release.get("tag_name") == tag
    ]
    if len(matches) > 1:
        raise ReleaseConflict(
            f"expected at most one release for tag {tag}; found {len(matches)}"
        )
    return matches[0] if matches else None


def _get_release(github, tag, expected_release_id=None):
    if expected_release_id is None:
        return _find_release_by_tag(github, tag)
    current = github.get_release_by_id(expected_release_id)
    if current is None:
        raise ReleaseConflict(
            f"expected release id {expected_release_id} was not found"
        )
    _release_state(
        current, tag, expected_release_id=expected_release_id
    )
    return current


def _refetch_bound_release(github, tag, release_id):
    get_by_id = getattr(github, "get_release_by_id", None)
    if callable(get_by_id):
        current = get_by_id(release_id)
    else:
        current = github.get_release(tag)
    if current is None:
        raise ReleaseConflict(
            f"release id {release_id} was not observable after mutation"
        )
    _release_state(current, tag, expected_release_id=release_id)
    return current


def _poll_release_by_tag(github, tag):
    for delay in _POLL_DELAYS:
        if delay:
            _poll_sleep(delay)
        current = _find_release_by_tag(github, tag)
        if current is not None:
            return current
    raise ReleaseConflict(f"release for tag {tag} was not observable after creation")


def _poll_bound_release(
    github,
    tag,
    release_id,
    expected_assets,
    *,
    required_asset_names=(),
    require_published=False,
):
    required_names = set(required_asset_names)
    last_state = "release was not observable"
    for delay in _POLL_DELAYS:
        if delay:
            _poll_sleep(delay)
        try:
            current = _refetch_bound_release(github, tag, release_id)
            _, draft, immutable = _release_state(
                current, tag, expected_release_id=release_id
            )
            missing = _inspect_release(github, current, expected_assets)
        except ReleaseConflict as error:
            if "was not observable" not in str(error):
                raise
            last_state = str(error)
            continue
        missing_names = {asset.name for asset in missing}
        absent_required = sorted(required_names & missing_names)
        if absent_required:
            last_state = "required assets not visible: " + ", ".join(absent_required)
            continue
        if require_published and (draft or not immutable):
            if draft:
                last_state = "release remains a draft"
            else:
                last_state = "published release is not immutable"
            continue
        return current
    raise ReleaseConflict(
        f"release id {release_id} did not reach the required state: {last_state}"
    )


def complete_release(
    github,
    tag,
    target,
    title,
    notes,
    assets,
    latest=False,
    expected_release_id=None,
):
    expected_target = str(target).lower()
    if len(expected_target) != 40 or any(
        char not in "0123456789abcdef" for char in expected_target
    ):
        raise ReleaseConflict("release target must be an exact 40-hex commit SHA")
    names = [asset.name for asset in assets]
    if len(names) != len(set(names)):
        raise ReleaseConflict("duplicate local release asset name")

    bound_expected_id = None
    if expected_release_id is not None:
        bound_expected_id = _release_id(
            expected_release_id, label="expected release id"
        )

    tag_target = github.get_tag_target(tag)
    if tag_target is not None and tag_target.lower() != expected_target:
        raise ReleaseConflict(
            f"tag target conflict for {tag}: {tag_target} != {expected_target}"
        )

    current = _get_release(github, tag, bound_expected_id)
    created_here = False
    create_race = False
    if current is None:
        # An existing exact tag has already established the release target.
        # Omitting --target avoids asking the job token for an unnecessary tag
        # write; an absent tag still uses --target for atomic tag creation.
        create_target = expected_target if tag_target is None else None
        create_error = None
        try:
            github.create_release(tag, create_target, title, notes, assets, latest)
        except CommandFailed as error:
            create_error = error
        try:
            current = _poll_release_by_tag(github, tag)
        except ReleaseConflict:
            if create_error is not None:
                raise create_error
            raise
        if create_error is not None:
            create_race = True
        else:
            created_here = True

    if current is None:
        raise ReleaseConflict("release was not observable after completion")
    release_id, draft, immutable = _release_state(
        current, tag, expected_release_id=bound_expected_id
    )
    missing = _inspect_release(github, current, assets)
    changed = created_here
    published_now = created_here and not draft
    uploaded_missing = False
    publish_race = False

    if draft:
        if missing and immutable:
            raise ReleaseConflict(
                "existing release is immutable and incomplete: "
                + ", ".join(asset.name for asset in missing)
            )
        for asset in missing:
            upload_error = None
            try:
                github.upload_asset(release_id, asset)
            except CommandFailed as error:
                upload_error = error
            try:
                current = _poll_bound_release(
                    github,
                    tag,
                    release_id,
                    assets,
                    required_asset_names=(asset.name,),
                )
            except ReleaseConflict:
                if upload_error is not None:
                    raise upload_error
                raise
        if missing:
            changed = True
            uploaded_missing = True
            current = _poll_bound_release(
                github,
                tag,
                release_id,
                assets,
                required_asset_names=(asset.name for asset in assets),
            )
            release_id, draft, immutable = _release_state(
                current, tag, expected_release_id=release_id
            )
            remaining = _inspect_release(github, current, assets)
            if remaining:
                raise ReleaseConflict(
                    "release remains incomplete after upload: "
                    + ", ".join(asset.name for asset in remaining)
                )
        if draft:
            publish_error = None
            try:
                github.publish_release(release_id, latest)
            except CommandFailed as error:
                publish_error = error
            changed = True
            published_now = publish_error is None
            publish_race = publish_error is not None
            try:
                current = _poll_bound_release(
                    github,
                    tag,
                    release_id,
                    assets,
                    required_asset_names=(asset.name for asset in assets),
                    require_published=True,
                )
            except ReleaseConflict:
                if publish_error is not None:
                    raise publish_error
                raise
            release_id, draft, immutable = _release_state(
                current, tag, expected_release_id=release_id
            )
    elif missing:
        raise ReleaseConflict(
            "published release is incomplete: "
            + ", ".join(asset.name for asset in missing)
        )

    if create_race:
        action = "create_race_completed"
    elif publish_race:
        action = "publish_race_completed"
    elif created_here:
        action = "created"
    elif published_now and uploaded_missing:
        action = "completed_and_published_draft"
    elif published_now:
        action = "published_draft"
    else:
        action = "already_complete"

    if draft:
        raise ReleaseConflict("release remains a draft after completion")

    post_target = github.get_tag_target(tag)
    if post_target is None or post_target.lower() != expected_target:
        raise ReleaseConflict("release tag target failed post-verification")
    current = _poll_bound_release(
        github,
        tag,
        release_id,
        assets,
        required_asset_names=(asset.name for asset in assets),
        require_published=True,
    )
    release_id, draft, immutable = _release_state(
        current, tag, expected_release_id=release_id
    )
    if draft:
        raise ReleaseConflict("release became a draft during post-verification")
    if not immutable:
        raise ReleaseConflict("published release is not immutable")
    missing = _inspect_release(github, current, assets)
    if missing:
        raise ReleaseConflict(
            "release remains incomplete after completion: "
            + ", ".join(asset.name for asset in missing)
        )
    return {
        "completed": True,
        "changed": changed,
        "published_now": published_now,
        "action": action,
        "tag": tag,
        "target": expected_target,
        "release_id": release_id,
        "immutable": immutable,
        "assets": {
            asset.name: {"size": asset.size, "sha256": asset.sha256}
            for asset in assets
        },
    }


def _write_outputs(path, result):
    if not path:
        return
    with Path(path).open("a", encoding="utf-8", newline="\n") as handle:
        for key in (
            "completed", "changed", "published_now", "action", "tag",
            "target", "release_id", "immutable",
        ):
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
    parser.add_argument("--expected-release-id", type=int)
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
    args = parser.parse_args(argv)
    try:
        assets = [LocalAsset.from_path(path) for path in args.asset]
        notes = Path(args.notes_file).read_text(encoding="utf-8")
        result = complete_release(
            GhClient(args.repo), args.tag, args.target, args.title,
            notes, assets, args.latest, args.expected_release_id
        )
        _write_outputs(args.github_output, result)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (ReleaseConflict, CommandFailed, OSError, ValueError) as error:
        print(f"release completion failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
