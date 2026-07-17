# Third-Party Notices — SketchUp PDF Importer

The candidate Windows helper payload uses an extension-local Poppler runtime.
Helper-bearing publication is fail-closed until a qualified licensing review
approves the exact runtime manifest; source-only builds omit the payload.

## Bundled components

| Component | Role | License |
|-----------|------|---------|
| Poppler (`poppler.dll`, `pdftocairo.exe`, `pdftotext.exe`, `pdffonts.exe`) | PDF parsing / rendering helpers | GPL |
| Cairo | 2D rendering used by pdftocairo | LGPL/MPL dual |
| FreeType | Font rasterization | FTL/GPL dual |
| OpenJPEG | JPEG 2000 decoding | BSD-2-Clause |
| OpenSSL (`libcrypto`) / libcurl / libssh2 | Transitive Poppler dependencies | Apache-2.0 / curl / BSD-3-Clause |

The canonical binaries live under `bc_pdf_vector_importer/Library/bin/`, and
Poppler character-map/data files live under
`bc_pdf_vector_importer/share/poppler/`. A legacy direct `bin/` tree is rejected.

## Where the license texts are

- `bc_pdf_vector_importer/Library/licenses/` — preserved runtime license texts.
- `bc_pdf_vector_importer/Library/THIRD_PARTY_NOTICES.txt` — runtime provenance and publication status.

## Authoritative manifest

`bc_pdf_vector_importer/poppler-runtime-manifest.json` is the machine-readable
inventory of binaries, Poppler data, notices, licenses, sizes, SHA-256 values,
source pins, semantic scope, and license-review state.

## Source availability

The manifest pins unmodified upstream binary and data archives. This notice is
not by itself a source-offer or publication-approval claim. Publication remains
blocked unless the exact dependency obligations are closed and the manifest's
license review is approved with no missing items.
