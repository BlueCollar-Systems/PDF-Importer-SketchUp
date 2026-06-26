# QA-2026-06-26 — Regression resolution (shipped)

## Agreements
- **R26-1:** SketchUp has no pre-import guidance modal. The `ImportGuidance` module is removed; mode guidance belongs in the import dialog, Import Health, reports, and docs.
- **R26-2:** Labels mode keeps native labels for rotated text; mesh text is fallback only when `add_text` fails.
- **R26-3:** BOM table uses column-aware QUAN detection; MARK/DESCRIPTION cells force horizontal angles.
- **R26-4:** FreeCAD shrinks oversized label/ShapeString text to PDF span bbox; raster underlay uses effective import scale.
- **R26-5:** LC/BL audited — no popup leak; pytest green.

## Shipped versions
| Host | Version | Key files |
|------|---------|-----------|
| SketchUp | 3.7.75 | `main.rb`, `geometry_builder.rb`, `pre_import_prompt_test.rb` |
| FreeCAD | 4.0.54 | `PDFImporterCore.py`, `test_pdf_importer_text_reconstruction.py` |

## Before / after — popup
- **Before:** Blocking `UI.messagebox` on every `import_pdf`, including LibreCAD sentence.
- **After:** No pre-file-picker guidance popup in normal or Safe Mode import; no LibreCAD mention; a source regression test fails if the prompt pattern returns.

## Field verify when user returns (Sun/Mon)
- Re-import 1017 BOM in SketchUp 2017 Labels — QUAN vertical centered, MARK horizontal.
- Re-import same PDF in FreeCAD 3D Text — no overlapping w1023 / p1016 cluster.
