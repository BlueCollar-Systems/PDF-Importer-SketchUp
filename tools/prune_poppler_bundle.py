#!/usr/bin/env python3
"""prune_poppler_bundle.py — keep only PE-reachable Poppler binaries.

Walks the PE import tables (and delay-load import tables) of
pdftocairo/pdftotext/pdffonts (and their transitive local DLL deps) and
removes unused sibling DLLs from
extracted/sketchup_ext/bc_pdf_vector_importer/bin.

Note: libcurl → libssh2 → libcrypto-3-x64 are REQUIRED by this
oschwartz10612 poppler.dll build (hard IAT imports). They are not pruned
even though local file conversion never uses HTTP/SSH.

Usage:
  python tools/prune_poppler_bundle.py
  python tools/prune_poppler_bundle.py --dry-run
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BIN_DIR = (
    REPO_ROOT
    / "extracted"
    / "sketchup_ext"
    / "bc_pdf_vector_importer"
    / "Library"
    / "bin"
)
ROOT_EXES = ("pdftocairo.exe", "pdftotext.exe", "pdffonts.exe")

# IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT = 13
_DELAY_DIR_INDEX = 13
# dlattrRva flag: when set, delay-descriptor fields are RVAs (PE32+ norm).
_DLATTR_RVA = 0x1


def _rva_to_offset(sections: list[tuple[int, int, int]], rva: int) -> int | None:
    for va, size, ptr in sections:
        if va <= rva < va + size:
            return ptr + (rva - va)
    return None


def _pe_sections(data: bytes) -> tuple[int, list[tuple[int, int, int]]] | None:
    if data[:2] != b"MZ":
        return None
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if data[e_lfanew : e_lfanew + 4] != b"PE\0\0":
        return None
    magic = struct.unpack_from("<H", data, e_lfanew + 24)[0]
    if magic == 0x20B:  # PE32+
        data_dir_off = e_lfanew + 24 + 112
    elif magic == 0x10B:  # PE32
        data_dir_off = e_lfanew + 24 + 96
    else:
        return None
    num_sections = struct.unpack_from("<H", data, e_lfanew + 6)[0]
    size_opt = struct.unpack_from("<H", data, e_lfanew + 20)[0]
    sec_off = e_lfanew + 24 + size_opt
    sections: list[tuple[int, int, int]] = []
    for i in range(num_sections):
        off = sec_off + i * 40
        vsize = struct.unpack_from("<I", data, off + 8)[0]
        va = struct.unpack_from("<I", data, off + 12)[0]
        raw_size = struct.unpack_from("<I", data, off + 16)[0]
        raw_ptr = struct.unpack_from("<I", data, off + 20)[0]
        sections.append((va, max(vsize, raw_size), raw_ptr))
    return data_dir_off, sections


def _read_cstring(data: bytes, sections: list[tuple[int, int, int]], rva: int) -> str | None:
    noff = _rva_to_offset(sections, rva)
    if noff is None:
        return None
    end = data.find(b"\0", noff)
    if end < 0:
        return None
    return data[noff:end].decode("ascii", "ignore")


def pe_imports(path: Path) -> list[str]:
    """Return DLL names from the standard import table + delay-load table."""
    data = path.read_bytes()
    parsed = _pe_sections(data)
    if parsed is None:
        return []
    data_dir_off, sections = parsed

    imports: list[str] = []

    # Standard IMAGE_DIRECTORY_ENTRY_IMPORT (index 1) — 8 bytes after export.
    import_rva, _import_size = struct.unpack_from("<II", data, data_dir_off + 8)
    if import_rva:
        idx = 0
        while True:
            off = _rva_to_offset(sections, import_rva + idx * 20)
            if off is None:
                break
            name_rva = struct.unpack_from("<I", data, off + 12)[0]
            oft_rva = struct.unpack_from("<I", data, off + 0)[0]
            if name_rva == 0 and oft_rva == 0:
                break
            name = _read_cstring(data, sections, name_rva)
            if name:
                imports.append(name)
            idx += 1

    # Delay-load IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT (index 13) — R21-7.
    delay_rva, _delay_size = struct.unpack_from(
        "<II", data, data_dir_off + _DELAY_DIR_INDEX * 8
    )
    if delay_rva:
        idx = 0
        while True:
            off = _rva_to_offset(sections, delay_rva + idx * 32)
            if off is None:
                break
            attrs = struct.unpack_from("<I", data, off + 0)[0]
            name_field = struct.unpack_from("<I", data, off + 4)[0]
            # Null terminator descriptor.
            if attrs == 0 and name_field == 0:
                break
            # Prefer RVA form (dlattrRva). Absolute VA form is rare in modern
            # MSVC delay-load; if attrs lacks the flag, treat name_field as RVA
            # only when it resolves inside a section (best-effort).
            name_rva = name_field
            if attrs & _DLATTR_RVA == 0:
                # Absolute VA: subtract preferred image base when possible.
                magic = struct.unpack_from("<H", data, struct.unpack_from("<I", data, 0x3C)[0] + 24)[0]
                e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
                if magic == 0x20B:
                    image_base = struct.unpack_from("<Q", data, e_lfanew + 24 + 24)[0]
                else:
                    image_base = struct.unpack_from("<I", data, e_lfanew + 24 + 28)[0]
                if name_field >= image_base:
                    name_rva = int(name_field - image_base)
            name = _read_cstring(data, sections, name_rva)
            if name:
                imports.append(name)
            idx += 1

    return imports


def resolve_local(bin_dir: Path, name: str) -> Path | None:
    direct = bin_dir / name
    if direct.is_file():
        return direct
    matches = [p for p in bin_dir.iterdir() if p.is_file() and p.name.lower() == name.lower()]
    return matches[0] if matches else None


def reachable_files(bin_dir: Path) -> set[str]:
    needed: set[str] = set()
    queue: list[str] = list(ROOT_EXES)
    while queue:
        name = queue.pop(0)
        path = resolve_local(bin_dir, name)
        if path is None:
            continue
        key = path.name.lower()
        if key in needed:
            continue
        needed.add(key)
        for dep in pe_imports(path):
            local = resolve_local(bin_dir, dep)
            if local is not None and local.name.lower() not in needed:
                queue.append(local.name)
    return needed


def prune(bin_dir: Path, *, dry_run: bool = False) -> tuple[list[tuple[str, int]], int]:
    if not bin_dir.is_dir():
        raise SystemExit(f"Bin directory missing: {bin_dir}")
    for exe in ROOT_EXES:
        if resolve_local(bin_dir, exe) is None:
            raise SystemExit(f"Required Poppler tool missing: {exe}")

    needed = reachable_files(bin_dir)
    removed: list[tuple[str, int]] = []
    total = 0
    # Only DLLs are prune candidates (helpers/notices stay).
    for path in sorted(bin_dir.glob("*.dll")):
        if path.name.lower() in needed:
            continue
        size = path.stat().st_size
        removed.append((path.name, size))
        total += size
        if not dry_run:
            path.unlink()
    return removed, total


def main() -> int:
    parser = argparse.ArgumentParser(description="Prune unused Poppler DLLs via PE import walk")
    parser.add_argument("--bin-dir", default=str(BIN_DIR), help="Poppler bin directory")
    parser.add_argument("--dry-run", action="store_true", help="Report only; do not delete")
    args = parser.parse_args()
    bin_dir = Path(args.bin_dir).resolve()

    needed = sorted(reachable_files(bin_dir))
    print(f"PE-reachable from {', '.join(ROOT_EXES)} ({len(needed)} files):")
    for name in needed:
        print(f"  keep  {name}")

    removed, total = prune(bin_dir, dry_run=args.dry_run)
    action = "Would remove" if args.dry_run else "Removed"
    if not removed:
        print("No unused local DLLs.")
        return 0
    print(f"{action} {len(removed)} unused DLL(s), {total} bytes ({total / 1024 / 1024:.2f} MiB):")
    for name, size in removed:
        print(f"  drop  {name}\t{size}")
    # Explicit note for the historically suspected ~8 MiB chain.
    curl_chain = ("libcurl.dll", "libssh2.dll", "libcrypto-3-x64.dll")
    present = [n for n in curl_chain if resolve_local(bin_dir, n) is not None]
    if present:
        print(
            "Retained curl/OpenSSL chain (hard IAT deps of poppler.dll): "
            + ", ".join(present)
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
