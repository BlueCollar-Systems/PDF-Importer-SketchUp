# Third-Party Notices — SketchUp PDF Importer

This extension bundles third-party software so it runs on any PC without
separate installs. Full license texts ship inside the extension itself.

## Bundled components

| Component | Role | License |
|-----------|------|---------|
| Poppler (`poppler.dll`, `pdftocairo.exe`, `pdftotext.exe`, `pdffonts.exe`) | PDF parsing / rendering helpers | GPL |
| Cairo | 2D rendering used by pdftocairo | LGPL/MPL dual |
| FreeType | Font rasterization | FTL/GPL dual |
| OpenJPEG | JPEG 2000 decoding | BSD-2-Clause |
| OpenSSL (`libcrypto`) / libcurl / libssh2 | Transitive Poppler dependencies | Apache-2.0 / curl / BSD-3-Clause |

The bundled binaries (~29 files) live under
`bc_pdf_vector_importer/bin/` in the installed extension and in release RBZs.

## Where the license texts are

- `bc_pdf_vector_importer/bin/licenses/` — full license text per component.
- `bc_pdf_vector_importer/bin/THIRD_PARTY_NOTICES.txt` — per-binary notice list.

## Authoritative manifest

The machine-readable inventory of every shipped binary (path, version,
license, SHA-256) is produced by the private dependency-audit tooling used
for release validation.

## Source availability

Poppler and the other GPL/LGPL components are unmodified upstream builds.
Sources are available from the respective upstream projects; see
`bin/licenses/` for project URLs. For corresponding-source requests, contact
support@bluecollar-systems.com.
