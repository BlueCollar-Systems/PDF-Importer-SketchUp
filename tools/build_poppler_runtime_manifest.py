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
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SUPPORT = REPO_ROOT / "extracted" / "sketchup_ext" / "bc_pdf_vector_importer"
PINNED_POPPLER_TAG = "v26.02.0-0"
PINNED_BINARY_ASSET = "Release-26.02.0-0.zip"
PINNED_BINARY_ASSET_SHA256 = (
    "993e4a94376ed712fafc7058d724ea0b943d118bbd2305cd9ed55174eb85cda5"
)
PINNED_DATA_ARCHIVE = "poppler-data-0.4.12.tar.gz"
PINNED_DATA_ARCHIVE_SHA256 = (
    "c835b640a40ce357e1b83666aabd95edffa24ddddd49b8daff63adb851cdab74"
)
FORBIDDEN_REVIEWER_FRAGMENTS = (
    "owner" + "-doctrine",
    "codex",
    "automation",
    "unknown",
)
UTC_REVIEWED_AT = re.compile(
    r"\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z"
)
REQUIRED_EXES = ("pdftocairo.exe", "pdftotext.exe", "pdffonts.exe")
REQUIRED_DATA = (
    "share/poppler/cidToUnicode/Adobe-GB1",
    "share/poppler/cidToUnicode/Adobe-CNS1",
    "share/poppler/cidToUnicode/Adobe-Japan1",
    "share/poppler/cidToUnicode/Adobe-Korea1",
)
REQUIRED_LICENSE_FILES = (
    "Library/licenses/LGPL-2.1.txt",
    "Library/licenses/MPL-1.1.txt",
    "Library/licenses/cairo-COPYING",
    "Library/licenses/curl-COPYING",
    "Library/licenses/expat-COPYING",
    "Library/licenses/fontconfig-COPYING",
    "Library/licenses/freetype-FTL.TXT",
    "Library/licenses/freetype-GPLv2.TXT",
    "Library/licenses/freetype-LICENSE.TXT",
    "Library/licenses/lcms2-COPYING",
    "Library/licenses/lerc-LICENSE",
    "Library/licenses/libdeflate-COPYING",
    "Library/licenses/libjpeg-turbo-LICENSE.md",
    "Library/licenses/libpng-LICENSE",
    "Library/licenses/libssh2-COPYING",
    "Library/licenses/libtiff-LICENSE.md",
    "Library/licenses/openjpeg-LICENSE",
    "Library/licenses/openssl-LICENSE.txt",
    "Library/licenses/pixman-COPYING",
    "Library/licenses/poppler-COPYING",
    "Library/licenses/xz-COPYING.0BSD",
    "Library/licenses/zlib-LICENSE",
    "Library/licenses/zstd-LICENSE",
)
REQUIRED_COMPLIANCE_FILES = (
    "Library/THIRD_PARTY_NOTICES.txt",
    "Library/SOURCE_OFFER.txt",
) + REQUIRED_LICENSE_FILES
SOURCE_OFFER_REQUIRED_LABELS = (
    "name:",
    "postal address:",
    "e-mail:",
    "source publication url:",
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
    if rel.startswith("Library/licenses/") or rel in (
        "Library/THIRD_PARTY_NOTICES.txt",
        "Library/SOURCE_OFFER.txt",
    ):
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


def validate_compliance_payload(
    support: Path,
    *,
    require_complete_offer: bool,
) -> None:
    missing = [
        rel for rel in REQUIRED_COMPLIANCE_FILES if not (support / rel).is_file()
    ]
    if missing:
        raise RuntimeError(
            "Poppler compliance payload is incomplete; missing: "
            + ", ".join(missing)
        )

    notices = (support / "Library" / "THIRD_PARTY_NOTICES.txt").read_text(
        encoding="utf-8",
        errors="replace",
    )
    unreferenced = [
        rel for rel in REQUIRED_LICENSE_FILES if rel not in notices
    ]
    if unreferenced:
        raise RuntimeError(
            "Poppler third-party notice omits required license references: "
            + ", ".join(unreferenced)
        )

    if not require_complete_offer:
        return
    offer = (support / "Library" / "SOURCE_OFFER.txt").read_text(
        encoding="utf-8",
        errors="replace",
    )
    lowered = offer.lower()
    placeholders = (
        "draft",
        "<owner to complete",
        "<insert",
        "<to be completed",
    )
    missing_labels = [
        label for label in SOURCE_OFFER_REQUIRED_LABELS if label not in lowered
    ]
    if (
        any(placeholder in lowered for placeholder in placeholders)
        or re.search(r"<[^>]+>", offer)
        or missing_labels
    ):
        raise RuntimeError(
            "Poppler source offer is incomplete; replace every draft "
            "placeholder and provide name, postal address, e-mail, and "
            "source publication URL before approval"
        )


def require_checked_in_file(reference: str | None, label: str) -> str:
    value = str(reference or "").strip()
    if not value:
        raise SystemExit(f"Approved review requires --{label}")
    candidate = (REPO_ROOT / value).resolve()
    try:
        relative = candidate.relative_to(REPO_ROOT).as_posix()
    except ValueError as exc:
        raise SystemExit(f"{label} must stay inside the repository") from exc
    if not candidate.is_file():
        raise SystemExit(f"{label} is not a checked-in file: {relative}")
    tracked = subprocess.run(
        [
            "git",
            "-c",
            f"safe.directory={REPO_ROOT}",
            "-C",
            str(REPO_ROOT),
            "ls-files",
            "--error-unmatch",
            relative,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if tracked.returncode != 0:
        raise SystemExit(f"{label} is not tracked by git: {relative}")
    return relative


def build_license_review(
    *,
    status: str,
    reviewer: str | None,
    reviewed_at: str | None,
    evidence: str | None,
    sources_sha256: str | None,
) -> dict:
    if status == "blocked":
        return {
            "status": "blocked",
            "missing": ["binary dependency license closure"],
            "reason": (
                "Qualified review of the exact 22-binary dependency/license "
                "closure and source-availability obligations is pending"
            ),
        }
    if status != "approved":
        raise SystemExit(f"Unsupported license review status: {status}")

    reviewer_value = str(reviewer or "").strip()
    if not reviewer_value:
        raise SystemExit("Approved review requires --reviewer")
    lowered = reviewer_value.lower()
    if any(fragment in lowered for fragment in FORBIDDEN_REVIEWER_FRAGMENTS):
        raise SystemExit("Approved review requires an independent review authority")
    reviewed_value = str(reviewed_at or "").strip()
    if not UTC_REVIEWED_AT.fullmatch(reviewed_value):
        raise SystemExit(
            "Approved review requires --reviewed-at in UTC "
            "YYYY-MM-DDTHH:MM:SSZ format"
        )
    evidence_path = require_checked_in_file(evidence, "evidence")
    sources_path = require_checked_in_file(sources_sha256, "sources-sha256")
    source_text = (REPO_ROOT / sources_path).read_text(
        encoding="utf-8", errors="replace"
    )
    for digest in (
        PINNED_BINARY_ASSET_SHA256,
        PINNED_DATA_ARCHIVE_SHA256,
    ):
        if digest not in source_text:
            raise SystemExit(
                f"sources-sha256 does not contain required source pin {digest}"
            )
    return {
        "status": "approved",
        "missing": [],
        "reviewer": reviewer_value,
        "reviewed_at": reviewed_value,
        "evidence": evidence_path,
        "sources_sha256": sources_path,
    }


def validate_license_review(review: object, *, require_approved: bool) -> dict:
    if not isinstance(review, dict):
        raise RuntimeError("Poppler runtime license review is missing")
    status = review.get("status")
    if status == "blocked":
        if require_approved:
            raise RuntimeError(
                "Poppler runtime license review is blocked; "
                "release requires approved external evidence"
            )
        return review
    if status != "approved":
        raise RuntimeError("Poppler runtime license review state is invalid")
    try:
        expected = build_license_review(
            status="approved",
            reviewer=review.get("reviewer"),
            reviewed_at=review.get("reviewed_at"),
            evidence=review.get("evidence"),
            sources_sha256=review.get("sources_sha256"),
        )
    except SystemExit as exc:
        raise RuntimeError(str(exc)) from exc
    if review.get("missing"):
        raise RuntimeError(
            "Approved Poppler runtime license review still lists missing items"
        )
    return expected


def expected_source(poppler_tag: str) -> dict:
    return {
        "project": "oschwartz10612/poppler-windows",
        "tag": poppler_tag,
        "url": (
            "https://github.com/oschwartz10612/poppler-windows/releases/tag/"
            + poppler_tag
        ),
        "binary_asset": PINNED_BINARY_ASSET,
        "binary_asset_sha256": PINNED_BINARY_ASSET_SHA256,
        "data_archive": PINNED_DATA_ARCHIVE,
        "data_archive_sha256": PINNED_DATA_ARCHIVE_SHA256,
    }


def build_manifest(
    *,
    poppler_tag: str,
    license_status: str,
    reviewer: str | None,
    reviewed_at: str | None,
    evidence: str | None,
    sources_sha256: str | None,
) -> tuple[dict, str]:
    validate_required(SUPPORT)
    validate_compliance_payload(
        SUPPORT,
        require_complete_offer=license_status == "approved",
    )
    members = inventory_members(SUPPORT)
    if not members:
        raise SystemExit("No runtime members found under Library/ or share/poppler/")
    pinned = pinned_inventory_sha256(members)
    manifest = {
        "schema": 1,
        "layout": {
            "bin": "Library/bin",
            "data": "share/poppler",
            "manifest": "poppler-runtime-manifest.json",
        },
        "source": expected_source(poppler_tag),
        "license_review": build_license_review(
            status=license_status,
            reviewer=reviewer,
            reviewed_at=reviewed_at,
            evidence=evidence,
            sources_sha256=sources_sha256,
        ),
        "members": members,
        "member_inventory_sha256": pinned,
    }
    return manifest, pinned


def validate_existing_manifest(
    support: Path = SUPPORT,
    *,
    require_approved: bool,
) -> dict:
    validate_required(support)
    validate_compliance_payload(
        support,
        require_complete_offer=require_approved,
    )
    manifest_path = support / "poppler-runtime-manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise RuntimeError(f"Invalid Poppler runtime manifest: {exc}") from exc
    if not isinstance(manifest, dict) or manifest.get("schema") != 1:
        raise RuntimeError("Poppler runtime manifest schema must be exactly 1")
    if manifest.get("source") != expected_source(PINNED_POPPLER_TAG):
        raise RuntimeError("Poppler runtime manifest source pins are incomplete")
    validate_license_review(
        manifest.get("license_review"),
        require_approved=require_approved,
    )

    declared = manifest.get("members")
    if not isinstance(declared, list):
        raise RuntimeError("Poppler runtime manifest members must be a list")
    actual = inventory_members(support)
    if declared != actual:
        raise RuntimeError(
            "Poppler runtime files do not exactly match the manifest inventory"
        )
    actual_pinned = pinned_inventory_sha256(actual)
    if manifest.get("member_inventory_sha256") != actual_pinned:
        raise RuntimeError(
            "Poppler runtime member inventory digest does not match"
        )
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poppler-tag", default=PINNED_POPPLER_TAG)
    parser.add_argument(
        "--license-status",
        choices=("blocked", "approved"),
        default="blocked",
    )
    parser.add_argument("--reviewer")
    parser.add_argument("--reviewed-at")
    parser.add_argument("--evidence")
    parser.add_argument("--sources-sha256")
    parser.add_argument(
        "--write",
        action="store_true",
        help="Write poppler-runtime-manifest.json under the support folder",
    )
    parser.add_argument(
        "--validate-compliance-only",
        action="store_true",
        help=(
            "Verify checked-in notices, source offer, and license texts "
            "without rebuilding the runtime manifest"
        ),
    )
    args = parser.parse_args(argv)
    if args.validate_compliance_only:
        validate_compliance_payload(
            SUPPORT,
            require_complete_offer=False,
        )
        print(
            "Poppler compliance payload present: "
            f"{len(REQUIRED_COMPLIANCE_FILES)} required files"
        )
        return 0
    manifest, pinned = build_manifest(
        poppler_tag=args.poppler_tag,
        license_status=args.license_status,
        reviewer=args.reviewer,
        reviewed_at=args.reviewed_at,
        evidence=args.evidence,
        sources_sha256=args.sources_sha256,
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
