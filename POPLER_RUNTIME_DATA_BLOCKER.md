# Poppler runtime publication blocker

Status: **FAIL-CLOSED ON LICENSING**. The runtime layout, pinned data tree, and
Adobe-GB1 fixture smoke are closed. The helper-bearing RBZ must still not be
published until a qualified reviewer approves the exact binary-license record.

The filename is retained for existing release references; runtime data is no
longer the blocker.

## Exact runtime contract

The only supported extension-local layout is:

```text
bc_pdf_vector_importer/
  Library/bin/                    22 exact helpers/DLLs
  Library/THIRD_PARTY_NOTICES.txt
  Library/licenses/               contract allowlist of seven files
  share/poppler/                  271 exact files, 12,968,872 bytes
  poppler-runtime-manifest.json   sizes and SHA-256 for every member
```

The Windows asset is pinned to `v26.02.0-0`,
`Release-26.02.0-0.zip`, SHA-256
`993e4a94376ed712fafc7058d724ea0b943d118bbd2305cd9ed55174eb85cda5`.
Every staged binary matches that archive.

The complete official `poppler-data-0.4.12.tar.gz` is pinned independently at
SHA-256
`c835b640a40ce357e1b83666aabd95edffa24ddddd49b8daff63adb851cdab74`.
Its 271 files are byte-for-byte identical to the packaged `share/poppler`
tree. It includes the standard Adobe-CNS1, Adobe-GB1, Adobe-Japan1, and
Adobe-Korea1 collections.

The data archive contains `COPYING`, `COPYING.adobe`, `COPYING.gpl2`, and
`README`; it does not contain GPLv3. The separately packaged official GNU GPLv3
text is stored as `Library/licenses/share_poppler_COPYING.gpl3` and pinned at SHA-256
`3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`.
Its separate provenance is explicit in the manifest and notices.

## What is empirically proven

On Windows, the exact packaged layout passes all three required helpers on the
deterministic Adobe-GB1 fixture:

- `pdftotext -bbox-layout` returns the exact line `钢结构 W12X30 梁` in page
  and word order.
- `pdftocairo` returns two named PNG pages with nonblank expected glyph ROIs.
- `pdffonts` returns the expected Heiti CID / `UniGB-UTF16-H` inventory row.

This is deliberately recorded as **Adobe-GB1 deterministic fixture only**.
The other standard collections are packaged but are not semantically proven.
Diagnostic strings alone never override complete fixture evidence, and a
return code of zero with incomplete semantic output fails the smoke.

The internal parser does not close this fixture: it produced the garbled line
`~g W12X30 h` with no placement boxes. A system-installed MuPDF route rendered
the line correctly, but MuPDF is not bundled and is never a package gate. A
Codex-only PDFium runtime also proved the fixture but is not a product-shipped
dependency.

## Remaining qualified licensing review blocker

`poppler-runtime-manifest.json` records each allowlisted binary's component and
license identifiers and currently has:

```json
"license_review": {
  "status": "blocked",
  "missing": ["binary dependency license closure"]
}
```

The current license files are not asserted to close every dependency-specific
notice, license-text, corresponding-source, or written-offer obligation. A
qualified reviewer must verify the exact 22-binary dependency graph and either
complete the payload or reject publication. Only that reviewer may change the
status to `approved`, and an approved record must have no missing items. The
contract also requires a nonempty reviewer, UTC review timestamp, and evidence
record before either runtime discovery or release packaging accepts approval.

`build_release.py` requires a Windows host, approved status, and a passing
semantic smoke for any helper-bearing RBZ, then verifies the same exact
manifest inside the archive. Source-only builds exclude
`Library`, `share/poppler`, the manifest, and the legacy direct `bin` layout.
Windows CI then extracts and re-smokes the built RBZ; the release job downloads
that same artifact and does not rebuild it on another platform.

Until qualified approval is recorded, the release failure is intentional.
