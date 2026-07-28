# Poppler bundled-runtime licence review

**Status:** approved
**Reviewer:** Rowdy Payton (BlueCollar Systems)
**Reviewed at:** 2026-07-28T22:38:51Z

**This is an owner determination, not an opinion of independent counsel.** It is
recorded as such deliberately. If the review is later corroborated by a
qualified third party, this record and the manifest `reviewer` field should be
updated to name them.

---

## What was reviewed

Redistribution of an unmodified, pre-built Poppler runtime and its supporting
libraries inside the MIT-licensed PDF Vector Importer extension for SketchUp.

| Item | Value |
|---|---|
| Binaries | 22 (`Library/bin/`) |
| Distinct components | 19 |
| Licence texts shipped | `Library/licenses/` |
| Data payload | `share/poppler/` (poppler-data 0.4.12) |
| Product licence | MIT, (c) 2024-2026 BlueCollar Systems |
| Price to end users | free |
| Distribution | GitHub Releases (`.rbz`), SketchUp Extension Warehouse, manual install |

## Upstream provenance

Pinned and hash-verified in `third_party/sources/SHA256SUMS.txt`:

- `Release-26.02.0-0.zip` — `993e4a94376ed712fafc7058d724ea0b943d118bbd2305cd9ed55174eb85cda5`
- `poppler-data-0.4.12.tar.gz` — `c835b640a40ce357e1b83666aabd95edffa24ddddd49b8daff63adb851cdab74`

The upstream binary archive was downloaded and confirmed byte-identical to its
pinned digest. Of its 462 entries, only three are licence files, and all three
belong to poppler-data itself. It ships **no** licence texts for its own binary
dependencies. That absence is why this review was required, and closing it is
what this record documents.

## Licence texts

Every bundled component's licence text was obtained from that component's own
upstream project and is shipped under `Library/licenses/`. Retrieval URLs, byte
counts and SHA-256 digests are recorded in
`third_party/sources/license-fetch-provenance.json` and
`third_party/sources/LICENSE_TEXT_SHA256SUMS.txt`, so provenance is
independently verifiable.

Generic licence templates were **not** used. MIT and BSD licences carry
project-specific copyright lines; boilerplate would have been inaccurate.

Copyleft components present:

| Component | Licence |
|---|---|
| poppler | GPL-2.0-or-later |
| freetype | FTL **or** GPL-2.0-only (dual) |
| cairo | LGPL-2.1-or-later / MPL-1.1 (dual) |

All remaining components are permissive: MIT, BSD-2-Clause, BSD-3-Clause,
Apache-2.0, Zlib, curl, Libpng-2.0, 0BSD, libtiff.

## Facts relied on

1. **Invocation model.** The bundled helpers run as separate processes
   (`pdftocairo.exe`, `pdftotext.exe`, `pdffonts.exe`). They are not statically
   linked into the extension and do not share an address space with its Ruby
   code.
2. **No modification.** The binaries are unmodified upstream redistributions.
   No patches were applied and nothing was rebuilt. A subset of unused DLLs was
   removed by a PE import-table prune; no binary was altered.
3. **Source availability.** Complete corresponding source is publicly
   obtainable from the pinned upstream URLs above. `Library/SOURCE_OFFER.txt`
   records the publication URL and a contact route valid for at least three
   years.
4. **Prior distribution.** Releases v3.7.79 through v3.7.91 already
   redistributed these binaries publicly (approximately 8.8 MB of runtime
   files, legacy `bin/` layout) before this gate existed. This review therefore
   also regularises that earlier distribution.

## Determination

Redistribution as configured is approved, on the basis that the full licence
text for every bundled component ships with the product, attribution is
complete and inventoried, and corresponding source is both publicly published
and offered on request.

## Supporting material

- `Library/THIRD_PARTY_NOTICES.txt` — per-component inventory with provenance
- `Library/licenses/**` — full licence texts
- `Library/SOURCE_OFFER.txt` — written offer for source
- `third_party/sources/SHA256SUMS.txt` — upstream archive pins
- `third_party/sources/LICENSE_TEXT_SHA256SUMS.txt` — licence text digests
- `third_party/sources/license-fetch-provenance.json` — retrieval audit trail
