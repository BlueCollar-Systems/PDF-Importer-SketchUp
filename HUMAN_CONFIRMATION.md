# Human Verification — PDF Vector Importer (SketchUp)

Use **your own shop PDFs** for sign-off. There is no fixed public test matrix, and internal validation files are not published in this repo.

## Before you start

1. Install the latest release from this repo or GitHub Releases.
2. Open **Extensions → PDF Vector Importer → Compatibility Report** — note Poppler/MuPDF status.

## Checklist

For each representative shop drawing you import:

| Check | Pass |
|-------|------|
| **3D Text default** — BOM, dimensions, notes, rotation, and scale visually match Adobe Reader at the same zoom | ☐ |
| **Outlines/Glyphs** — linework and symbols are faithful to the PDF when selected | ☐ |
| **Labels** — editable text remains readable when selected, with expected SketchUp screen-space/horizontal behavior | ☐ |
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
