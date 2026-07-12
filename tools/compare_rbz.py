#!/usr/bin/env python3
"""compare_rbz.py — R17-1 byte-verify helper for SketchUp RBZ assets.

Compares two .rbz (zip) archives by per-entry SHA-256 content hashes.
Use after `gh release download` to confirm a released asset matches a
local build (or HEAD tree built via build_release.py).

This is a verification aid, not a CI hard-gate and not a freeze on content
changes: a DIFF means "released bytes ≠ local bytes" (investigate or rebuild),
not "never change the extension." CRLF working-tree artifacts have caused
false alarms — prefer comparing two built .rbz files, not raw source trees.

Usage:
  python tools/compare_rbz.py local.rbz downloaded.rbz
  python tools/compare_rbz.py a.rbz b.rbz --quiet
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import zipfile
from pathlib import Path


def inspect(zp: Path) -> dict[str, tuple[str, int]]:
    entries: dict[str, tuple[str, int]] = {}
    with zipfile.ZipFile(zp) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            data = zf.read(info.filename)
            entries[info.filename] = (hashlib.sha256(data).hexdigest(), len(data))
    return entries


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare two SketchUp .rbz archives by content hash")
    parser.add_argument("left", type=Path, help="Local / reference RBZ")
    parser.add_argument("right", type=Path, help="Downloaded / candidate RBZ")
    parser.add_argument("--quiet", action="store_true", help="Only print summary + exit code")
    args = parser.parse_args()

    if not args.left.is_file():
        raise SystemExit(f"Missing left RBZ: {args.left}")
    if not args.right.is_file():
        raise SystemExit(f"Missing right RBZ: {args.right}")

    left = inspect(args.left)
    right = inspect(args.right)
    all_names = sorted(set(left) | set(right))
    content_diff = 0
    missing_left = 0
    missing_right = 0

    for name in all_names:
        if name not in left:
            missing_left += 1
            if not args.quiet:
                print(f"MISSING_LEFT:  {name}  right={right[name]}")
        elif name not in right:
            missing_right += 1
            if not args.quiet:
                print(f"MISSING_RIGHT: {name}  left={left[name]}")
        else:
            lsha, llen = left[name]
            rsha, rlen = right[name]
            if lsha != rsha:
                content_diff += 1
                if not args.quiet:
                    print(f"CONTENT_DIFF:  {name}  left_bytes={llen} right_bytes={rlen}")

    print(f"Total files: {len(all_names)}")
    print(f"Content diffs: {content_diff}")
    print(f"Missing left: {missing_left}")
    print(f"Missing right: {missing_right}")
    if content_diff or missing_left or missing_right:
        print("RESULT: DIFF")
        return 1
    print("RESULT: MATCH")
    return 0


if __name__ == "__main__":
    sys.exit(main())
