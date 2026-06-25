#!/usr/bin/env python3
"""Acquire the public local-only PDF stress corpus.

The manifest is committed; downloaded PDFs are not. This keeps the test set
repeatable without redistributing third-party PDFs from this repository.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import urllib.error
import urllib.request


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_MANIFEST = SCRIPT_DIR / "public_pdf_corpus_manifest.json"
LOCK_NAME = "PUBLIC_PDF_CORPUS.lock.json"
USER_AGENT = "BlueCollarSystems-PDFImporter-TestCorpus/1.0"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if data.get("schema") != "bcs.public_pdf_corpus/1.0":
        raise SystemExit(f"Unsupported manifest schema in {path}")
    return data


def resolve_root(manifest: dict, explicit_root: str | None) -> Path:
    root = (
        explicit_root
        or os.environ.get("BCS_CORPUS_ROOT")
        or os.environ.get("PDF_TEST_CORPUS")
        or manifest.get("default_root")
        or "C:/1pdf-test-corpus"
    )
    return Path(root).expanduser().resolve()


def download(url: str, target: Path, timeout: int) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    tmp = target.with_suffix(target.suffix + ".part")
    target.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        with tmp.open("wb") as handle:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                handle.write(chunk)
    tmp.replace(target)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    parser.add_argument("--root", help="Corpus root. Defaults to BCS_CORPUS_ROOT or C:/1pdf-test-corpus.")
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
        if not url or not rel or rel.endswith("/"):
            print(f"SKIP {entry_id}: no direct download URL")
            lock_entries.append({"id": entry_id, "status": "skipped", "reason": "no_direct_url"})
            continue

        target = root / rel
        try:
            if target.exists() and target.stat().st_size > 0:
                digest = sha256_file(target)
                print(f"OK   {entry_id}: exists {target} sha256={digest[:12]}")
            else:
                print(f"GET  {entry_id}: {url}")
                start = time.time()
                download(url, target, args.timeout)
                elapsed = time.time() - start
                digest = sha256_file(target)
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
                    "sha256": digest,
                    "features": entry.get("features", []),
                    "test_intent": entry.get("test_intent", ""),
                    "license_note": entry.get("license_note", ""),
                    "status": "ok",
                }
            )
        except (OSError, urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
            failures.append((entry_id, str(exc)))
            print(f"FAIL {entry_id}: {exc}", file=sys.stderr)
            lock_entries.append({"id": entry_id, "status": "failed", "reason": str(exc)})

    lock = {
        "schema": "bcs.public_pdf_corpus.lock/1.0",
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
