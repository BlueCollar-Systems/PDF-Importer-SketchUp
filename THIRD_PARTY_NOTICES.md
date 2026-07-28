# Third-Party Notices — SketchUp PDF Importer

Windows release RBZ files ship a free zero-ceremony Poppler runtime so clean
machines can import without a separate helper download. Publication requires an
approved integrity manifest for the exact staged bytes. The currently staged
runtime is **blocked from stable publication** pending the independent review
described in `POPLER_RUNTIME_PUBLICATION_BLOCKER.md`.

## Bundled components

| Component | Role | License |
|-----------|------|---------|
| Poppler (`poppler.dll`, `pdftocairo.exe`, `pdftotext.exe`, `pdffonts.exe`) | PDF parsing / rendering helpers | GPL |
| Cairo | 2D rendering used by pdftocairo | LGPL/MPL dual |
| FreeType | Font rasterization | FTL/GPL dual |
| OpenJPEG | JPEG 2000 decoding | BSD-2-Clause |
| OpenSSL (`libcrypto`) / libcurl / libssh2 | Transitive Poppler dependencies | Apache-2.0 / curl / BSD-3-Clause |
| Poppler `share/poppler` language data | CID/CMap completeness for helper rendering | Poppler upstream |

The canonical binaries live under `bc_pdf_vector_importer/Library/bin/`, and
Poppler character-map/data files live under
`bc_pdf_vector_importer/share/poppler/`. A legacy direct `bin/` tree is rejected.

## Where the license texts are

- `bc_pdf_vector_importer/Library/licenses/` — preserved runtime license texts.
- `bc_pdf_vector_importer/Library/THIRD_PARTY_NOTICES.txt` — runtime provenance.

## Authoritative manifest

`bc_pdf_vector_importer/poppler-runtime-manifest.json` is the machine-readable
inventory of binaries, Poppler data, notices, licenses, sizes, SHA-256 values,
source pins, and license-review state.

## Source availability

`third_party/sources/SHA256SUMS.txt` pins the upstream Windows binary archive
and the official Poppler data archive. These checksums prove source identity;
they do not by themselves approve the dependency/license closure. MuPDF and
Ghostscript are not bundled.
