#!/usr/bin/env python3
"""Report whether the checked-in Poppler runtime may be published.

A valid blocked manifest is an intentional, successful gate result: CI stays
green, while the auto-release job receives ``publication_ready=false`` and
skips release creation. Invalid or inconsistent runtime state still fails.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools import build_poppler_runtime_manifest as runtime_manifest


def publication_state() -> tuple[bool, str]:
    manifest = runtime_manifest.validate_existing_manifest(
        require_approved=False,
    )
    review = manifest["license_review"]
    if review["status"] == "approved":
        runtime_manifest.validate_existing_manifest(require_approved=True)
        return True, "approved compliance evidence and complete source offer"

    if review["status"] != "blocked":
        raise RuntimeError("Unexpected Poppler publication state")
    try:
        runtime_manifest.validate_existing_manifest(require_approved=True)
    except RuntimeError as exc:
        return False, str(exc)
    raise RuntimeError(
        "Blocked Poppler review unexpectedly passed the publication gate"
    )


def main() -> int:
    ready, reason = publication_state()
    value = "true" if ready else "false"
    print(f"publication_ready={value}")
    print(f"publication_reason={reason}")

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        sanitized = " ".join(reason.splitlines())
        with Path(github_output).open("a", encoding="utf-8") as handle:
            handle.write(f"publication_ready={value}\n")
            handle.write(f"publication_reason={sanitized}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
