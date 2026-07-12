#!/usr/bin/env python3
"""test_prune_poppler_bundle.py — lock PE-reachable Poppler prune policy."""

from __future__ import annotations

import struct
import sys
import tempfile
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


def _minimal_pe_with_delay(dll_name: bytes) -> bytes:
    """Build a tiny PE32+ with an empty import table and one delay-load DLL."""
    # DOS stub
    dos = bytearray(128)
    dos[0:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, 128)  # e_lfanew

    # PE header + optional header (PE32+)
    pe = bytearray()
    pe += b"PE\0\0"
    # COFF: Machine, NumberOfSections, ...
    pe += struct.pack("<HHIIIHH", 0x8664, 1, 0, 0, 0, 0xF0, 0x22)  # size_opt=0xF0, characteristics
    # Optional header PE32+ magic + stub fields through data directories
    opt = bytearray(0xF0)
    struct.pack_into("<H", opt, 0, 0x20B)  # PE32+
    struct.pack_into("<Q", opt, 24, 0x140000000)  # ImageBase
    # NumberOfRvaAndSizes at offset 108 for PE32+
    struct.pack_into("<I", opt, 108, 16)
    # Data directories start at opt+112. Delay import = index 13.
    delay_rva = 0x2000
    struct.pack_into("<II", opt, 112 + 13 * 8, delay_rva, 64)
    pe += opt

    # One section .rdata covering RVA 0x2000
    sec = bytearray(40)
    sec[0:6] = b".rdata"
    struct.pack_into("<I", sec, 8, 0x200)   # VirtualSize
    struct.pack_into("<I", sec, 12, 0x2000)  # VirtualAddress
    struct.pack_into("<I", sec, 16, 0x200)  # SizeOfRawData
    # Raw pointer will be set after we know header size
    header_size = 128 + len(pe) + 40
    # Align raw to 512
    raw_ptr = (header_size + 511) // 512 * 512
    struct.pack_into("<I", sec, 20, raw_ptr)
    pe += sec

    # Delay descriptor (32 bytes) + null descriptor + name string
    rdata = bytearray(0x200)
    # attrs = dlattrRva (1), name RVA = 0x2020
    struct.pack_into("<IIIIIIII", rdata, 0, 1, 0x2020, 0, 0, 0, 0, 0, 0)
    # null terminator already zero
    name_off = 0x20
    rdata[name_off : name_off + len(dll_name)] = dll_name
    rdata[name_off + len(dll_name)] = 0

    out = bytearray(raw_ptr + 0x200)
    out[0:128] = dos
    out[128 : 128 + len(pe)] = pe
    out[raw_ptr : raw_ptr + len(rdata)] = rdata
    return bytes(out)


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

    def test_delay_load_imports_are_unioned(self):
        # R21-7: synthetic PE with only a delay-load dependency must surface it.
        pe_bytes = _minimal_pe_with_delay(b"delaydep.dll")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "delay_host.exe"
            path.write_bytes(pe_bytes)
            deps = {d.lower() for d in pe_imports(path)}
            self.assertIn("delaydep.dll", deps)


if __name__ == "__main__":
    unittest.main()
