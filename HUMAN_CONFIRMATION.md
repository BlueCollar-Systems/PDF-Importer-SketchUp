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
| **Labels** — editable annotations preserve exact content/anchor and never claim rotated glyphs when the host cannot express them | ☐ |
| **3D Text** (first-run default) — BOM, dimensions, notes, rotation, and scale visually match Adobe Reader at the same zoom | ☐ |
| **Glyphs** — per-glyph grouped outlines, placement, rotation, and scale are faithful when selected | ☐ |
| **Geometry** — source/page path edges remain distinct from Glyph groups and are faithful when selected | ☐ |
| **Raster** — requested item crops or zero-canonical-text page image are source-bound and visually faithful; a verification failure stops truthfully | ☐ |
| Scale plausible vs the source drawing | ☐ |
| Multi-page import behaves as expected | ☐ |

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
