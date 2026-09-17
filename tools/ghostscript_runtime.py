"""Integrity and dependency closure for the separate, unmodified GS subprocess."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
from tools.prune_poppler_bundle import pe_imports

VERSION = "10.07.1"
UPSTREAM = "https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10071/"
INSTALLER = "gs10071w64.exe"
INSTALLER_SHA256 = "3a4c28d0aac47aa7cccd35a5932c55110376e9dbd966898dde388b7faba444a4"
SOURCE = "ghostpdl-10.07.1.tar.gz"
SOURCE_SHA256 = "5c580ed888ce42ce4d76b8afac302e8b507e08d05e52e05b3649e0732559bfe4"
PINNED_INVENTORY_SHA256 = "0eed39d13b9e56e6c48f5b0b86e95bd5ff90cf51ec0172bfe41e93b1a6cd4924"
UPSTREAM_BINARIES = {
    "gswin64c.exe": "de3bce7c03dfce0dfd78af8bf1d464c6a21fbcb7237f127ec5c027179d2c2741",
    "gsdll64.dll": "af9bcd9313956aea105fd38da35413d50e446548ba21b6e85b87da3f24e8c546",
}
CRT = ("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")
OS_DLLS = set("kernel32.dll user32.dll gdi32.dll advapi32.dll shell32.dll ole32.dll oleaut32.dll comdlg32.dll winspool.drv ucrtbase.dll ntdll.dll".split())
ROOT = Path(__file__).resolve().parents[1]
SUPPORT = ROOT / "extracted/sketchup_ext/bc_pdf_vector_importer"

def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

def inventory(root):
    rows = []
    for path in sorted(Path(root).rglob("*")):
        if path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction()):
            raise RuntimeError("Ghostscript runtime contains a link")
        if path.is_file() and path != Path(root) / "runtime-manifest.json":
            rows.append({"bytes": path.stat().st_size, "path": path.relative_to(root).as_posix(), "sha256": digest(path)})
    return sorted(rows, key=lambda row: row["path"])

def inventory_digest(rows):
    return hashlib.sha256(json.dumps(rows, separators=(",", ":"), sort_keys=True, ensure_ascii=True).encode("ascii")).hexdigest()

def validate(support=SUPPORT):
    root = Path(support) / "Ghostscript"
    for path in (root, *root.parents):
        if path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction()):
            raise RuntimeError("Ghostscript runtime trust path contains a link")
    manifest_path = root / "runtime-manifest.json"
    if manifest_path.is_symlink():
        raise RuntimeError("Ghostscript runtime manifest is linked")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or manifest.get("version") != VERSION:
        raise RuntimeError("Ghostscript manifest schema/version mismatch")
    if manifest.get("upstream_installer") != {"url": UPSTREAM + INSTALLER, "sha256": INSTALLER_SHA256}:
        raise RuntimeError("Ghostscript installer provenance mismatch")
    if manifest.get("corresponding_source") != {"url": UPSTREAM + SOURCE, "sha256": SOURCE_SHA256}:
        raise RuntimeError("Ghostscript corresponding source mismatch")
    rows = inventory(root)
    if rows != manifest.get("members") or inventory_digest(rows) != PINNED_INVENTORY_SHA256:
        raise RuntimeError("Ghostscript runtime inventory/hash mismatch")
    for name, expected in UPSTREAM_BINARIES.items():
        if digest(root / "bin" / name) != expected:
            raise RuntimeError("Ghostscript upstream executable bytes changed")
    for name in CRT:
        if not (root / "bin" / name).is_file():
            raise RuntimeError("Ghostscript app-local CRT missing: " + name)
    for path in (root / "bin").iterdir():
        for dependency in pe_imports(path):
            lower = dependency.lower()
            if lower not in OS_DLLS and not lower.startswith(("api-ms-win-", "ext-ms-win-")) and not (root / "bin" / lower).is_file():
                raise RuntimeError("Ghostscript non-OS DLL is unbundled: " + dependency)
    for name in ("licenses/doc/COPYING", "licenses/LICENSE", "licenses/jpeg/README", "licenses/ijs/ijs.h.txt", "SOURCE.txt", "THIRD_PARTY_NOTICES.txt"):
        if not (root / name).is_file():
            raise RuntimeError("Ghostscript notice is missing: " + name)
    return manifest
