"""Reproduce the GS runtime from pinned official archives; never run installers."""
from __future__ import annotations
import argparse
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ghostscript_runtime as gs

def bundle(installer, sources, seven_zip, support=gs.SUPPORT):
    if gs.digest(installer) != gs.INSTALLER_SHA256 or gs.digest(sources) != gs.SOURCE_SHA256:
        raise RuntimeError("Official Ghostscript installer/source SHA256 mismatch")
    target = Path(support) / "Ghostscript"
    if target.exists():
        raise RuntimeError("Refusing to overwrite existing Ghostscript runtime")
    with tempfile.TemporaryDirectory(prefix="gs_bundle_") as temp:
        stage = Path(temp) / "Ghostscript"
        stage.mkdir()
        subprocess.run([str(seven_zip), "x", str(Path(installer).resolve()), "-o" + str(stage), "bin/gswin64c.exe", "bin/gsdll64.dll", "-y"], check=True, stdout=subprocess.DEVNULL)
        for name, expected in gs.UPSTREAM_BINARIES.items():
            if gs.digest(stage / "bin" / name) != expected:
                raise RuntimeError("Official installer binary identity mismatch: " + name)
        for name in gs.CRT:
            shutil.copyfile(Path(support) / "Library/bin" / name, stage / "bin" / name)
        copied = []
        with tarfile.open(sources, "r:gz") as archive:
            for member in archive:
                if not member.isfile():
                    continue
                parts = PurePosixPath(member.name).parts
                if parts[0] != "ghostpdl-10.07.1" or any(p in (".", "..") for p in parts):
                    raise RuntimeError("Unsafe Ghostscript source archive path")
                rel = PurePosixPath(*parts[1:])
                leaf = rel.name
                notice = bool(re.search(r"(?i)(copying|copyright|licen[cs]e|notice)", leaf))
                notice = notice and not leaf.startswith(("update-copyright", "no-copyright"))
                extra = str(rel) in ("freetype/docs/FTL.TXT", "freetype/docs/GPLv2.TXT", "jpeg/README", "ijs/ijs.h")
                cmap = parts[1:3] == ("Resource", "CMap")
                if not (notice or extra or cmap):
                    continue
                data = archive.extractfile(member).read()
                if cmap:
                    # Reproduce the upstream copyright/license header verbatim.
                    if b"%%EndComments" not in data:
                        continue
                    data = data.split(b"%%EndComments", 1)[0] + b"%%EndComments\n"
                    rel = PurePosixPath(str(rel) + ".notice.txt")
                elif str(rel) == "ijs/ijs.h":
                    data = data.split(b"**/", 1)[0] + b"**/\n"
                    rel = PurePosixPath(str(rel) + ".txt")
                destination = stage / "licenses" / Path(*rel.parts)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
                copied.append(str(rel))
        (stage / "SOURCE.txt").write_text(
            "Ghostscript/GhostPDL 10.07.1 corresponding source\n"
            "The bundled gswin64c.exe and gsdll64.dll are unmodified official Windows binaries.\n"
            "Download the complete corresponding upstream source (including component sources and build files):\n"
            + gs.UPSTREAM + gs.SOURCE + "\nSHA256: " + gs.SOURCE_SHA256 + "\n"
            "Upstream Windows binary installer:\n" + gs.UPSTREAM + gs.INSTALLER + "\nSHA256: " + gs.INSTALLER_SHA256 + "\n"
            "Verify the archive SHA256, extract it, and follow doc/Make.htm or the documentation sources under doc/src/ for build instructions.\n"
            "Upstream release: https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/tag/gs10071\n"
            "The importer invokes this program as a separate command-line process; no Ghostscript API is linked into the Ruby extension.\n",
            encoding="utf-8", newline="\n")
        existing_notice = (Path(support) / "Library/THIRD_PARTY_NOTICES.txt").read_text(encoding="utf-8")
        crt_notice = existing_notice.split("\nMICROSOFT VISUAL C++ RUNTIME\n", 1)[1].split("\nPOPPLER DATA\n", 1)[0]
        (stage / "THIRD_PARTY_NOTICES.txt").write_text(
            "Ghostscript 10.07.1 -- separate unmodified Windows subprocess\n"
            "Copyright (C) Artifex Software, Inc. and upstream contributors.\n"
            "Ghostscript is distributed under GNU AGPL version3 or later. The complete AGPL text is licenses/doc/COPYING; licenses/LICENSE describes upstream scope and font exceptions.\n"
            "This notice records upstream facts; it is not a claim of independent legal approval and does not extend the separate Poppler license review.\n"
            "All license/copyright/notice files found in the pinned complete source release are retained, together with JPEG's README license, FreeType license texts, IJS's MIT banner and every Adobe CMap license header. Some notices cover optional upstream components not enabled in these exact binaries.\n"
            "See SOURCE.txt for pinned corresponding-source retrieval and build information. Runtime resources, fonts and initialization files are compiled into the official DLL (ROM filesystem).\n"
            "Microsoft app-local CRT copies in bin/ are byte-identical to the previously shipped Library/bin DLLs; they are not part of Ghostscript or under AGPL. The existing separate notice is reproduced below (its Library/bin references identify those original copies).\n\nMICROSOFT VISUAL C++ RUNTIME\n" + crt_notice + "\n",
            encoding="utf-8", newline="\n")
        rows = gs.inventory(stage)
        if gs.inventory_digest(rows) != gs.PINNED_INVENTORY_SHA256:
            raise RuntimeError("Staged Ghostscript inventory differs from the reviewed runtime pin")
        manifest = {"schema": 1, "version": gs.VERSION,
            "upstream_installer": {"url": gs.UPSTREAM + gs.INSTALLER, "sha256": gs.INSTALLER_SHA256},
            "corresponding_source": {"url": gs.UPSTREAM + gs.SOURCE, "sha256": gs.SOURCE_SHA256},
            "separate_unmodified_subprocess": True, "resources": "compiled ROM",
            "license_notices": sorted(copied), "members": rows}
        (stage / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
        shutil.copytree(stage, target)
        print(json.dumps({"files": len(rows), "bytes": sum(r['bytes'] for r in rows), "inventory_sha256": gs.inventory_digest(rows), "notice_files": len(copied)}, indent=2))

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installer", type=Path, required=True)
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--seven-zip", type=Path, required=True)
    args = parser.parse_args()
    bundle(args.installer, args.sources, args.seven_zip)
