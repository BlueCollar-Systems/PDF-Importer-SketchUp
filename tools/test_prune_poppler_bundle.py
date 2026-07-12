#!/usr/bin/env python3
"""test_prune_poppler_bundle.py — lock PE-reachable Poppler prune policy."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

REPO_TOOLS = Path(__file__).resolve().parent
if str(REPO_TOOLS) not in sys.path:
    sys.path.insert(0, str(REPO_TOOLS))

from prune_poppler_bundle import (  # noqa: E402
    BIN_DIR,
    ROOT_EXES,
    pe_imports,
    prune,
    reachable_files,
    resolve_local,
)


class PrunePopplerBundleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BIN_DIR.is_dir():
            raise unittest.SkipTest(f"bin dir absent: {BIN_DIR}")
        for exe in ROOT_EXES:
            if resolve_local(BIN_DIR, exe) is None:
                raise unittest.SkipTest(f"missing {exe}")

    def test_helpers_import_poppler(self):
        for exe in ROOT_EXES:
            path = resolve_local(BIN_DIR, exe)
            deps = {d.lower() for d in pe_imports(path)}
            self.assertIn("poppler.dll", deps, f"{exe} must import poppler.dll")

    def test_curl_chain_required_by_poppler(self):
        poppler = resolve_local(BIN_DIR, "poppler.dll")
        self.assertIsNotNone(poppler)
        deps = {d.lower() for d in pe_imports(poppler)}
        self.assertIn("libcurl.dll", deps)

    def test_no_unused_dlls_remain(self):
        removed, _total = prune(BIN_DIR, dry_run=True)
        self.assertEqual(
            removed,
            [],
            "unused DLLs present — run: python tools/prune_poppler_bundle.py",
        )

    def test_known_unused_names_absent(self):
        needed = reachable_files(BIN_DIR)
        banned = {
            "charset.dll",
            "expat.dll",
            "iconv.dll",
            "libtiff.dll",
            "libzstd.dll",
            "poppler-cpp.dll",
            "poppler-glib.dll",
        }
        present = sorted(n for n in banned if resolve_local(BIN_DIR, n) is not None)
        self.assertEqual(present, [], f"banned unused DLLs still present: {present}")
        for name in ("libcurl.dll", "libssh2.dll", "libcrypto-3-x64.dll"):
            self.assertIn(name, needed)


if __name__ == "__main__":
    unittest.main()
