# Third-Party Notices — SketchUp PDF Importer

**Poppler review status:** approved for the exact Poppler inventory below. This
record does not extend to the separately documented Ghostscript runtime.

Windows release RBZ files ship a free zero-ceremony Poppler runtime so clean
machines can import without a separate helper download. Publication remains
fail-closed on the approved integrity manifest for the exact staged bytes, the
complete source offer, the mapped licence texts, and the pinned source/archive
hashes. The checked-in approval is the recorded determination of owner Rowdy
Payton (BlueCollar Systems); it is **not independent legal counsel**. See
`third_party/sources/POPPLER_LICENSE_REVIEW.md` for its facts and scope.

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
- `bc_pdf_vector_importer/Library/SOURCE_OFFER.txt` — completed written source
  offer with owner contact and pinned source-publication details.

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
MuPDF is not bundled.

## Separate Ghostscript subprocess

Windows packages also include the unmodified Ghostscript 10.07.1 console
executable and DLL under `bc_pdf_vector_importer/Ghostscript/bin/`. The importer
invokes the console executable as a separate process; it does not link to the
Ghostscript API. Ghostscript is distributed upstream under GNU AGPLv3 or later,
with additional component terms in its source distribution. The repository's
own MIT license and the Poppler review above do not replace those terms or
constitute a legal approval of Ghostscript redistribution.

`Ghostscript/licenses/` contains the upstream AGPL text and 221 source notices,
including the component license files, the JPEG README license, IJS license
header, FreeType alternatives, font notices, and Adobe CMap notices.
`Ghostscript/THIRD_PARTY_NOTICES.txt` identifies their source and the separate
Microsoft Visual C++ runtime terms for the three app-local support DLLs.
`Ghostscript/runtime-manifest.json` pins every distributed file by size and
SHA-256; builds reject missing, added, or changed payload members.

The exact unmodified Windows installer is
[`gs10071w64.exe`](https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10071/gs10071w64.exe),
SHA-256 `3a4c28d0aac47aa7cccd35a5932c55110376e9dbd966898dde388b7faba444a4`.
The corresponding complete source archive is
[`ghostpdl-10.07.1.tar.gz`](https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10071/ghostpdl-10.07.1.tar.gz),
SHA-256 `5c580ed888ce42ce4d76b8afac302e8b507e08d05e52e05b3649e0732559bfe4`.
The shipped `Ghostscript/SOURCE.txt` repeats these immutable retrieval locations,
verification hashes, and upstream build instructions. The reproducible staging
tool is `tools/bundle_ghostscript_runtime.py`; it accepts only those pinned
downloads and copies the unmodified binaries and notices into the package.
