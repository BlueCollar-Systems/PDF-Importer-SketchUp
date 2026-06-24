# Human Confirmation — PDF Vector Importer (SketchUp)

**Coordination:** see Desktop Q&A [COORDINATION-HUB](file:///C:/Users/Rowdy%20Payton/Desktop/PDFTest%20Files/Q&A/QA-2026-06-24_COORDINATION-HUB.md) or `_LLM_CONTROL_PACK/QA/QA-2026-06-24_COORDINATION-HUB.md`

**Session prep:** 2026-06-24 · Tier-1 corpus · See also `Desktop/PDFTest Files/Q&A/QA-2026-06-24_human-confirmation-script.md`

## Before you start

1. Install/build **v3.7.63+** RBZ from this repo or latest release.
2. Set corpus root (optional): `$env:BCS_CORPUS_ROOT = 'C:\1pdf-test-corpus'`
3. Run `python C:\1pdf-test-corpus\tools\list_tier1.py --host SU --resolved`
4. Open **Extensions → PDF Vector Importer → Compatibility Report** — note Poppler/MuPDF status.

## Tier-1 checklist (pass/fail)

| PDF | Labels | Glyphs/Outlines | 3D Text | Pass criteria |
|-----|--------|-----------------|---------|---------------|
| 1017 - Rev 0 | ☐ | ☐ | ☐ | Vector geometry visible; scale plausible; BOM qty readable |
| Welding-Symbol-Chart | ☐ | ☐ | n/a | Symbols import or clear raster fallback message |
| 1011 (1 OF 2) | ☐ | ☐ | ☐ | Page 1 title block; no crash |
| hello_world_rotated | ☐ | ☐ | ☐ | Text upright in model space (rotation handled) |
| helloworld | ☐ | ☐ | ☐ | Baseline smoke |
| doc_1_3_pages | ☐ | — | — | Page picker imports correct page |
| Simple PDF 2.0 | ☐ | ☐ | ☐ | Vector paths > 0 |
| text_only_fontsNotEmbedded | ☐ | ☐ | ☐ | Text items extracted |
| webCapture | ☐ | ☐ | ☐ | Hybrid: vectors + raster image entity |

## After each import

- [ ] Save `import_report.json` from import folder
- [ ] Check **Import Health…** menu for scale cross-check warnings
- [ ] Screenshot anomalies → `Desktop/PDFTest Files/PDF Importers Screenshots/`

## Automated preflight (developer)

```powershell
$env:BCS_CORPUS_ROOT = 'C:\1pdf-test-corpus'
ruby test/golden_oracle_test.rb
ruby test/qa_report_test.rb
```

## Sign-off

| Role | Name | Date | Result |
|------|------|------|--------|
| Shop tester | | | |
| Engineering | | | |

BUILT. NOT BOUGHT.
