# Third-Party Notices — SketchUp PDF Importer

Windows release RBZ files ship a free zero-ceremony Poppler runtime so clean
machines can import without a separate helper download. Publication requires an
approved integrity manifest for the exact staged bytes. The currently staged
runtime is **blocked from stable publication** pending the independent review
described in `POPLER_RUNTIME_PUBLICATION_BLOCKER.md`.

## Bundled components

The exact 19-component inventory covers Poppler, Cairo, curl, Expat,
Fontconfig, FreeType, Lerc, libdeflate, libjpeg-turbo, libpng, libssh2,
libtiff, Little CMS, OpenJPEG, OpenSSL, Pixman, XZ, zlib, and zstd. The
runtime notice maps every component and binary to its applicable license text.
Poppler `share/poppler` language data also ships with its upstream license
files.

The canonical binaries live under `bc_pdf_vector_importer/Library/bin/`, and
Poppler character-map/data files live under
`bc_pdf_vector_importer/share/poppler/`. A legacy direct `bin/` tree is rejected.

## Where the license texts are

- `bc_pdf_vector_importer/Library/licenses/` — 23 mapped upstream license
  texts plus Poppler-data notices.
- `bc_pdf_vector_importer/Library/THIRD_PARTY_NOTICES.txt` — component,
  binary, source, license, and hash mapping.
- `bc_pdf_vector_importer/Library/SOURCE_OFFER.txt` — written-source-offer
  draft; owner contact and publication details must be completed before
  approval.

## Authoritative manifest

`bc_pdf_vector_importer/poppler-runtime-manifest.json` is the machine-readable
inventory of binaries, Poppler data, notices, licenses, sizes, SHA-256 values,
source pins, and license-review state.

## Source availability

`third_party/sources/SHA256SUMS.txt` pins the upstream Windows binary archive
and the official Poppler data archive.
`third_party/sources/LICENSE_TEXT_SHA256SUMS.txt` and
`third_party/sources/license-fetch-provenance.json` pin the fetched license
texts and their authoritative upstream URLs. These records prove identity and
coverage; they do not by themselves approve the dependency/license closure.
MuPDF and Ghostscript are not bundled.
