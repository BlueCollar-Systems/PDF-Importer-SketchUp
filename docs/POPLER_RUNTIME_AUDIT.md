# Poppler runtime audit record

Date: 2026-07-16

## Inputs

- Windows asset: `v26.02.0-0 / Release-26.02.0-0.zip`
- Windows asset SHA-256:
  `993e4a94376ed712fafc7058d724ea0b943d118bbd2305cd9ed55174eb85cda5`
- Official data archive: `poppler-data-0.4.12.tar.gz`
- Data archive SHA-256:
  `c835b640a40ce357e1b83666aabd95edffa24ddddd49b8daff63adb851cdab74`
- Official GNU GPLv3 text SHA-256:
  `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`
- Public comparison fixture:
  `C:\1pdf-test-corpus\tier2\pdf-type-matrix\cid_identity_h.pdf`
- Public fixture SHA-256:
  `988a2b0bd07f63eb6871ffaa5871d7b203614173d431cdfb9da23ed47ce7bde1`

The official data archive contains 271 files totaling 12,968,872 bytes. A
path-by-path SHA-256 comparison found zero differences against the Windows
asset's `share/poppler` tree. All 22 staged binary hashes matched the pinned
Windows archive.

## Route evidence

| Route | Shipped by product? | Fixture text | Placement / visual evidence | Result |
|---|---|---|---|---|
| Internal `PDFParser` + `TextParser` | Yes | `~g W12X30 h` | all item boxes absent | incomplete |
| Pinned Poppler + full data | Candidate, license-blocked | `钢结构 W12X30 梁` | exact bbox text; two nonblank PNG glyph ROIs; expected font row | proven for Adobe-GB1 fixture |
| System MuPDF `mutool` | No | `钢结构 W12X30 梁` | 44 SVG uses; 31 nonempty recognized defs; visual raster line present | optional route only |
| Codex-only PDFium runtime | No | exact | clean-room visual proof | diagnostic evidence only |

The synthetic release smoke PDF has SHA-256
`44a05eaf29903e517b5b3e7431d46141c5b807facab1eacfd746b9c1e73ccd51`
and requires exact text, two pages, nonblank expected ROIs, and the expected
Heiti CID / `UniGB-UTF16-H` font inventory.

## Verified result

- Layout: `Library/bin` + `share/poppler`
- Binaries: 22 exact files
- Data: 271 exact files / 12,968,872 bytes
- Legacy direct `bin`: absent
- Manifest: exact structural verification passes
- Independent canonical 300-member inventory digest:
  `a2c5d125fee4f3af1893556501efd50455a953ed7eb77c8a0d094819db2f5654`.
  Regenerating the manifest after changing a packaged byte cannot self-bless
  the mutation.
- Runtime selection: SketchUp verifies the canonical manifest digest, exact
  file/directory set, every member size and SHA-256, and absence of legacy
  `bin`, extras, and symlinks before using bundled helpers (successful result
  cached once for the session).
- Qualified-diagnostic override: two-phase SVG validation defers only the
  proven cluster, then `main.rb` supplies the exact public-fixture page
  certificate (PDF hash plus all 36 glyph definitions and 44 placements).
  Partial/unmatched/failed evidence remains rejected.
- Adobe-GB1 staged smoke: passes
- Adobe-GB1 post-transaction live smoke: passes
- Full fetch -> hash -> prune -> stage -> smoke -> transactional install path:
  passes
- Ruby 2.2 full shipped/test syntax sweep and targeted Poppler gates: passes
- License review: blocked
- Helper-bearing release build: intentionally fail-closed until qualified
  approval

The five obsolete experimental layout directories were retained until this
record and the exact runtime manifest were written. Their final deletion is a
cleanup action only; none is a release input.

| Obsolete directory | Files | Bytes before deletion |
|---|---:|---:|
| `tmp_poppler_minimal_layout` | 78 | 24,860,591 |
| `tmp_poppler_relocated` | 31 | 22,237,959 |
| `tmp_poppler_three_file_layout` | 34 | 22,616,515 |
| `tmp_poppler_two_file_layout` | 37 | 23,158,815 |
| `tmp_poppler_upstream` | 458 | 73,191,490 |
