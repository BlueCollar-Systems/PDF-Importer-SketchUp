#!/usr/bin/env python3
"""Acquire the public local-only PDF stress corpus.

The manifest is committed; downloaded PDFs are not. Every enabled download is
bound to an expected SHA-256 before publication, keeping the local test set
repeatable without redistributing third-party PDFs from this repository.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_MANIFEST = SCRIPT_DIR / "public_pdf_corpus_manifest.json"
LOCK_NAME = "PUBLIC_PDF_CORPUS.lock.json"
USER_AGENT = "BlueCollarSystems-PDFImporter-TestCorpus/1.1"
SHA256_RE = re.compile(r"\A[0-9a-f]{64}\Z")
RAW_GITHUB_PIN_RE = re.compile(
    r"\Ahttps://raw\.githubusercontent\.com/[^/]+/[^/]+/"
    r"[0-9a-f]{40}/.+\Z"
)


class CorpusDownloadError(RuntimeError):
    """Closed, path-free failure from verified corpus acquisition."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if data.get("schema") != "bcs.public_pdf_corpus/1.1":
        raise SystemExit(f"Unsupported manifest schema in {path}")
    entries = data.get("entries")
    if not isinstance(entries, list):
        raise SystemExit("Invalid manifest: entries must be an array")

    seen_ids = set()
    seen_paths = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise SystemExit("Invalid manifest: every entry must be an object")
        entry_id = entry.get("id")
        if not isinstance(entry_id, str) or not entry_id:
            raise SystemExit("Invalid manifest: entry id must be a nonempty string")
        if entry_id in seen_ids:
            raise SystemExit("Invalid manifest: duplicate entry id")
        seen_ids.add(entry_id)

        enabled = entry.get("enabled")
        if type(enabled) is not bool:
            raise SystemExit("Invalid manifest: enabled must be a boolean")
        url = entry.get("url")
        rel = entry.get("local_path")
        if not isinstance(url, str) or not isinstance(rel, str) or not rel:
            raise SystemExit("Invalid manifest: url/local_path must be strings")
        normalized_rel = rel.replace("\\", "/")
        parts = normalized_rel.split("/")
        if rel.startswith(("/", "\\")) or ":" in parts[0] or ".." in parts:
            raise SystemExit("Invalid manifest: local_path must stay relative")
        folded_rel = normalized_rel.casefold()
        if folded_rel in seen_paths:
            raise SystemExit("Invalid manifest: duplicate local_path")
        seen_paths.add(folded_rel)

        if enabled and url:
            expected = entry.get("expected_sha256")
            if not isinstance(expected, str) or not SHA256_RE.fullmatch(expected):
                raise SystemExit(
                    "Invalid manifest: enabled download requires lowercase expected_sha256"
                )
            if (
                url.startswith("https://raw.githubusercontent.com/")
                and not RAW_GITHUB_PIN_RE.fullmatch(url)
            ):
                raise SystemExit(
                    "Invalid manifest: raw GitHub URL must pin a full 40-character commit"
                )
    return data


def resolve_root(manifest: dict, explicit_root: str | None) -> Path:
    candidates = (
        explicit_root,
        os.environ.get("BCS_PRIVATE_VALIDATION_ROOT"),
        os.environ.get("PDF_PRIVATE_VALIDATION_ROOT"),
        manifest.get("default_root"),
    )
    root = next(
        (
            value.strip()
            for value in candidates
            if isinstance(value, str) and value.strip()
        ),
        None,
    )
    if root is None or root == "__private_validation_assets_not_configured__":
        raise SystemExit("Corpus root is not configured; pass an explicit --root")
    return Path(root).expanduser().resolve()


def download_verified(url: str, target: Path, timeout: int, expected_sha256: str) -> str:
    """Acquire one expected byte sequence and publish it without replacement."""
    if not isinstance(expected_sha256, str) or not SHA256_RE.fullmatch(expected_sha256):
        raise CorpusDownloadError("invalid_expected_sha256")

    if target.exists():
        if target.is_file() and sha256_file(target) == expected_sha256:
            return expected_sha256
        raise CorpusDownloadError("existing_digest_mismatch")

    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = None
    digest = hashlib.sha256()
    try:
        with tempfile.NamedTemporaryFile(
            mode="xb",
            dir=str(target.parent),
            prefix=f".{target.name}.",
            suffix=".part",
            delete=False,
        ) as handle:
            tmp_path = Path(handle.name)
            with urllib.request.urlopen(request, timeout=timeout) as response:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    handle.write(chunk)
                    digest.update(chunk)
            handle.flush()
            os.fsync(handle.fileno())

        actual = digest.hexdigest()
        if actual != expected_sha256:
            raise CorpusDownloadError("download_digest_mismatch")

        try:
            os.link(tmp_path, target)
        except FileExistsError:
            if target.is_file() and sha256_file(target) == expected_sha256:
                return expected_sha256
            raise CorpusDownloadError("publish_conflict")
        except OSError as exc:
            raise CorpusDownloadError("publish_io_error") from exc

        if sha256_file(target) != expected_sha256:
            raise CorpusDownloadError("published_digest_mismatch")
        return expected_sha256
    finally:
        if tmp_path is not None:
            try:
                tmp_path.unlink()
            except FileNotFoundError:
                pass
            except OSError:
                # The verified target, if any, is never removed by cleanup.
                pass


def download(url: str, target: Path, timeout: int, expected_sha256: str) -> str:
    """Verified public entry point; the expected hash is mandatory."""
    return download_verified(url, target, timeout, expected_sha256)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    parser.add_argument("--root", help="Corpus root. Defaults to BCS_PRIVATE_VALIDATION_ROOT or __private_validation_assets_not_configured__.")
    parser.add_argument("--id", action="append", dest="ids", help="Download only the named manifest id. Repeatable.")
    parser.add_argument("--include-disabled", action="store_true", help="Attempt entries marked enabled=false when they have a URL.")
    parser.add_argument("--timeout", type=int, default=120, help="Per-file HTTP timeout in seconds.")
    args = parser.parse_args(argv)

    manifest_path = Path(args.manifest).resolve()
    manifest = load_manifest(manifest_path)
    root = resolve_root(manifest, args.root)
    root.mkdir(parents=True, exist_ok=True)

    selected_ids = set(args.ids or [])
    entries = []
    for entry in manifest.get("entries", []):
        entry_id = entry.get("id", "")
        if selected_ids and entry_id not in selected_ids:
            continue
        if not entry.get("enabled", False) and not args.include_disabled:
            continue
        entries.append(entry)

    if selected_ids:
        found = {entry.get("id") for entry in entries}
        missing = sorted(selected_ids - found)
        if missing:
            print(f"Warning: no enabled manifest entries matched: {', '.join(missing)}", file=sys.stderr)

    lock_entries = []
    failures = []

    print(f"Manifest: {manifest_path}")
    print(f"Corpus root: {root}")
    print(f"Entries: {len(entries)}")

    for entry in entries:
        entry_id = entry.get("id", "")
        url = entry.get("url", "")
        rel = entry.get("local_path", "")
        expected = entry.get("expected_sha256", "")
        if not url or not rel or rel.endswith("/"):
            print(f"SKIP {entry_id}: no direct download URL")
            lock_entries.append({"id": entry_id, "status": "skipped", "reason": "no_direct_url"})
            continue

        target = (root / rel).resolve()
        try:
            target.relative_to(root)
        except ValueError:
            failures.append((entry_id, "target_outside_root"))
            print(f"FAIL {entry_id}: target_outside_root", file=sys.stderr)
            lock_entries.append(
                {"id": entry_id, "status": "failed", "reason": "target_outside_root"}
            )
            continue
        try:
            if target.exists():
                digest = download_verified(url, target, args.timeout, expected)
                print(f"OK   {entry_id}: exists {target} sha256={digest[:12]}")
            else:
                print(f"GET  {entry_id}: {url}")
                start = time.time()
                digest = download_verified(url, target, args.timeout, expected)
                elapsed = time.time() - start
                print(f"OK   {entry_id}: {target.stat().st_size} bytes in {elapsed:.1f}s sha256={digest[:12]}")

            lock_entries.append(
                {
                    "id": entry_id,
                    "title": entry.get("title", ""),
                    "source_org": entry.get("source_org", ""),
                    "source_page": entry.get("source_page", ""),
                    "url": url,
                    "local_path": str(target),
                    "size_bytes": target.stat().st_size,
                    "expected_sha256": expected,
                    "sha256": digest,
                    "features": entry.get("features", []),
                    "test_intent": entry.get("test_intent", ""),
                    "license_note": entry.get("license_note", ""),
                    "status": "ok",
                }
            )
        except (
            CorpusDownloadError,
            OSError,
            urllib.error.URLError,
            urllib.error.HTTPError,
            TimeoutError,
        ) as exc:
            failures.append((entry_id, str(exc)))
            print(f"FAIL {entry_id}: {exc}", file=sys.stderr)
            lock_entries.append({"id": entry_id, "status": "failed", "reason": str(exc)})

    lock = {
        "schema": "bcs.public_pdf_corpus.lock/1.1",
        "manifest": str(manifest_path),
        "root": str(root),
        "updated_unix": int(time.time()),
        "entries": lock_entries,
    }
    lock_path = root / "web-acquired" / LOCK_NAME
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("w", encoding="utf-8") as handle:
        json.dump(lock, handle, indent=2)
        handle.write("\n")
    print(f"Lock file: {lock_path}")

    if failures:
        print("Failures:", file=sys.stderr)
        for entry_id, reason in failures:
            print(f"  {entry_id}: {reason}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
