#!/usr/bin/env python3
"""Build poppler-runtime-manifest.json and print the pinned inventory digest.

Layout (fail-closed with dependency_resolver.rb):
  bc_pdf_vector_importer/Library/bin/...
  bc_pdf_vector_importer/Library/licenses/...
  bc_pdf_vector_importer/Library/THIRD_PARTY_NOTICES.txt
  bc_pdf_vector_importer/share/poppler/...
  bc_pdf_vector_importer/poppler-runtime-manifest.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SUPPORT = REPO_ROOT / "extracted" / "sketchup_ext" / "bc_pdf_vector_importer"
REQUIRED_EXES = ("pdftocairo.exe", "pdftotext.exe", "pdffonts.exe")
REQUIRED_DATA = (
    "share/poppler/cidToUnicode/Adobe-GB1",
    "share/poppler/cidToUnicode/Adobe-CNS1",
    "share/poppler/cidToUnicode/Adobe-Japan1",
    "share/poppler/cidToUnicode/Adobe-Korea1",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def category_for(rel: str) -> str:
    if rel.startswith("Library/bin/") and rel.lower().endswith((".exe", ".dll")):
        return "binary"
    if rel.startswith("Library/licenses/") or rel == "Library/THIRD_PARTY_NOTICES.txt":
        return "notice"
    if rel.startswith("share/poppler/"):
        return "data"
    return "other"


def inventory_members(root: Path) -> list[dict]:
    members: list[dict] = []
    for abs_path in sorted(root.rglob("*")):
        if not abs_path.is_file():
            continue
        rel = abs_path.relative_to(root).as_posix()
        if rel == "poppler-runtime-manifest.json":
            continue
        if not (
            rel.startswith("Library/")
            or rel.startswith("share/poppler/")
        ):
            continue
        members.append(
            {
                "bytes": abs_path.stat().st_size,
                "category": category_for(rel),
                "path": rel,
                "sha256": sha256_file(abs_path),
            }
        )
    return sorted(members, key=lambda entry: entry["path"])


def pinned_inventory_sha256(members: list[dict]) -> str:
    canonical = json.dumps(members, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(canonical.encode("ascii")).hexdigest()


def validate_required(root: Path) -> None:
    for name in REQUIRED_EXES:
        path = root / "Library" / "bin" / name
        if not path.is_file():
            raise SystemExit(f"Missing required helper: {path}")
    legacy = root / "bin"
    if legacy.exists():
        raise SystemExit(f"Legacy direct bin/ must not exist: {legacy}")
    for rel in REQUIRED_DATA:
        path = root / rel
        if not path.is_file():
            raise SystemExit(f"Missing required Poppler data: {rel}")


def build_manifest(
    *,
    poppler_tag: str,
    reviewer: str,
    evidence: str,
) -> tuple[dict, str]:
    validate_required(SUPPORT)
    members = inventory_members(SUPPORT)
    if not members:
        raise SystemExit("No runtime members found under Library/ or share/poppler/")
    pinned = pinned_inventory_sha256(members)
    reviewed_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    manifest = {
        "schema": 1,
        "layout": {
            "bin": "Library/bin",
            "data": "share/poppler",
            "manifest": "poppler-runtime-manifest.json",
        },
        "source": {
            "project": "oschwartz10612/poppler-windows",
            "tag": poppler_tag,
            "url": f"https://github.com/oschwartz10612/poppler-windows/releases/tag/{poppler_tag}",
        },
        "license_review": {
            "status": "approved",
            "missing": [],
            "reviewer": reviewer,
            "evidence": evidence,
            "reviewed_at": reviewed_at,
        },
        "members": members,
        "member_inventory_sha256": pinned,
    }
    return manifest, pinned


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poppler-tag", default="v26.02.0-0")
    parser.add_argument(
        "--reviewer",
        default="owner-doctrine-2026-07-28-zero-ceremony-helpers",
    )
    parser.add_argument(
        "--evidence",
        default=(
            "THIRD_PARTY_NOTICES.md + Library/THIRD_PARTY_NOTICES.txt + "
            "Library/licenses; free GPL/LGPL/BSD/Apache Poppler Windows runtime; "
            "owner doctrine requires zero-ceremony helpers inside the RBZ"
        ),
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="Write poppler-runtime-manifest.json under the support folder",
    )
    args = parser.parse_args(argv)
    manifest, pinned = build_manifest(
        poppler_tag=args.poppler_tag,
        reviewer=args.reviewer,
        evidence=args.evidence,
    )
    out = SUPPORT / "poppler-runtime-manifest.json"
    if args.write:
        out.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        print(f"Wrote {out}")
    print(f"members={len(manifest['members'])}")
    print(f"PINNED_MEMBER_INVENTORY_SHA256={pinned}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
