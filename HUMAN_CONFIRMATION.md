# Human Verification — PDF Vector Importer (SketchUp)

Use **your own shop PDFs** for sign-off. There is no fixed public test matrix, and internal validation files are not published in this repo.

## Before you start

1. Install the latest release from this repo or GitHub Releases.
2. Open **Extensions → PDF Vector Importer → Compatibility Report** — note Poppler/MuPDF status.

## Checklist

For each representative shop drawing you import:

| Check | Pass |
|-------|------|
| **Text** — when selected, the result is distinct flat editable model text, or the report contains the exact item-bound host capability proof before any Label attempt | ☐ |
| **Labels** — on SketchUp 2017, each finite-bbox item has its size/run-width or rotation proof and exactly one source-outline 3D visual-equivalent delivery with the same semantic span/provenance; it is not a native editable annotation and never silently uses Raster | ☐ |
| **3D Text** (first-run default) — BOM, dimensions, notes, rotation, and scale visually match Adobe Reader at the same zoom | ☐ |
| **Glyphs** — per-glyph grouped outlines, placement, rotation, and scale are faithful when selected | ☐ |
| **Geometry** — source/page path edges remain distinct from Glyph groups and are faithful when selected | ☐ |
| **Raster** — requested item crops or zero-canonical-text page image are source-bound and visually faithful; a verification failure stops truthfully | ☐ |
| Scale plausible vs the source drawing | ☐ |
| Multi-page import behaves as expected | ☐ |

For the canonical 1011 SketchUp 2017 Labels acceptance, use the opt-in
`"labels_visual_equivalent_acceptance": true` host job. Its saved/reopened census
must report 0 `Sketchup::Text`, 0 Raster, and exactly 791 unique source-glyph 3D
deliveries; persistent ID, source span ID, and provenance ID are one-to-one. It
must account for 653 size transitions and 138 rotation transitions, and physical
readback must show filled visible faces with material plus persisted hidden
contour edges. The import-within-30-seconds and governed fixed-frame side-by-side
no-visible-difference checks are external live gates. Host-free fixtures test the
schema only and do not prove live-host or visual acceptance.

## After each import

- Save `import_report.json` from the import folder
- Check **Import Health…** for scale cross-check warnings
- If something looks wrong: use [Report Doctor](https://bluecollarsystems.com/report-doctor) or **Send Feedback** with screenshots and your report JSON

## Sign-off

| Role | Name | Date | Result |
|------|------|------|--------|
| Shop tester | | | |
| Engineering | | | |

BUILT. NOT BOUGHT.
