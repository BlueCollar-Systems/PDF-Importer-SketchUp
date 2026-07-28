# Third-Party Notices — SketchUp PDF Importer

The candidate Windows helper payload uses an extension-local Poppler runtime.
It is present for verification but remains fail-closed for publication until a
qualified licensing review approves the exact manifest.

## Bundled components

| Component | Role | License |
|-----------|------|---------|
| Poppler (`poppler.dll`, `pdftocairo.exe`, `pdftotext.exe`, `pdffonts.exe`) | PDF parsing / rendering helpers | GPL |
| Cairo | 2D rendering used by pdftocairo | LGPL/MPL dual |
| FreeType | Font rasterization | FTL/GPL dual |
| OpenJPEG | JPEG 2000 decoding | BSD-2-Clause |
| OpenSSL (`libcrypto`) / libcurl / libssh2 | Transitive Poppler dependencies | Apache-2.0 / curl / BSD-3-Clause |

The 22 allowlisted binaries live under
`bc_pdf_vector_importer/Library/bin/`. The complete 271-file poppler-data
0.4.12 tree lives under `bc_pdf_vector_importer/share/poppler/`.

## Where the license texts are

- `bc_pdf_vector_importer/Library/licenses/` — currently preserved Poppler data
  license texts plus a separately pinned official GPLv3 text.
- `bc_pdf_vector_importer/Library/THIRD_PARTY_NOTICES.txt` — runtime provenance
  and the publication blocker.

## Authoritative manifest

`bc_pdf_vector_importer/poppler-runtime-manifest.json` is the checked-in exact
inventory of binaries, data, notices, licenses, sizes, SHA-256 values, source
pins, semantic scope, and license-review state. Source-only builds exclude the
entire runtime payload.

## Source availability

The manifest pins unmodified upstream binary and data archives. This notice is
not a source-offer or publication-approval claim. Publication remains blocked
until qualified review closes the exact dependency-specific obligations and
sets `license_review.status` to `approved` with no missing items.
