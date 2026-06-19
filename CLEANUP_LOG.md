# Cleanup Log — 2026-06-18

Combined log for the multi-repo cleanup pass and steel-shapes merge prep.
Paths use canonical `C:\1PDF-Importer-*` naming.

## Summary

| Repo | Items removed | Notes |
|------|---------------|-------|
| PDF-Importer-SketchUp | 12 | caches, 5 superseded RBZ, dist duplicate, dev_logs |
| PDF-Importer-FreeCAD | 10 | caches, 2 superseded ZIPs, `_archived` |
| PDF-Importer-LibreCAD | 11 | caches, `--out` stale build |
| PDF-Importer-Blender | 14 | caches, egg-info, 2 superseded dist ZIPs |
| pdfcadcore | 4 | caches |
| BlueCollar-Website | 2 | `__pycache__` only (conservative) |
| pdf-test-corpus | 1 | obsolete venv under `New folder (2)` |
| Steel-Shapes-SU | 1 | superseded release ZIP (pre-merge) |
| Steel-Shapes-DXF-DWG | 2 | `__pycache__`, superseded release ZIP |

**Total top-level removals:** 56 paths (many were directories with nested cache files)

## PDF-Importer-SketchUp

- `__pycache__/`
- `SketchUp-PDF-Importer_v3.7.24.rbz` … `v3.7.28.rbz` (kept `v3.7.29.rbz`)
- `dist/SketchUp-PDF-Importer_v3.7.24.rbz`
- `dev_logs/` (LLM context scratch + archived_packages)

## PDF-Importer-FreeCAD

- `__pycache__/`, `.pytest_cache/`, `.ruff_cache/` (repo + PDFVectorImporter subtrees)
- `FreeCAD-PDF-Importer_v4.0.22.zip`, `v4.0.23.zip` (kept `v4.0.24.zip`)
- `PDFVectorImporter/_archived/` (legacy mirror)

## PDF-Importer-LibreCAD

- Python/pytest/ruff caches across repo
- `--out/` (stale `LibreCAD-PDF-Importer_v1.0.20.zip`)

## PDF-Importer-Blender

- Python/pytest/ruff caches across repo
- `pdf_vector_importer.egg-info/`
- `dist/Blender-PDF-Importer_v1.0.20.zip`, `v1.0.21.zip` (kept `v1.0.22.zip`)

## pdfcadcore

- `.ruff_cache/`, `__pycache__/` under pdfcadcore, tests, tools
- `tests/.pytest_cache/`

## BlueCollar-Website

- `__pycache__/`, `tools/__pycache__/`

## pdf-test-corpus

- `New folder (2)/Structural_Steel_SVG_Blueprints_v43_FIXED/venv_project/` (~5k files)
- **Not removed:** corpus PDFs, Q&A folder, scripts, `PDFTest Files/`

## Steel repos (before merge)

- `C:\1Steel-Shapes-SU\Structural-Steel-SU-Shapes-v1.0.0.zip`
- `C:\1Steel-Shapes-DXF-DWG\Structural-Steel-DXF-DWG-Shapes-v1.0.0.zip`
- `C:\1Steel-Shapes-DXF-DWG\__pycache__/`

## Intentionally kept

- Source code, tests, CI workflows, LICENSE, README, golden baselines
- `_LLM_CONTROL_PACK/` (one per importer — not duplicated across repos)
- Latest release artifacts per repo
- `extracted/` SketchUp extension source (tracked)
- Corpus PDFs and Desktop Q&A (not touched)

## Steel shapes merge (Task B)

See importer READMEs for layout:

- `PDF-Importer-SketchUp/steel_shapes/` ← from `1Steel-Shapes-SU`
- `PDF-Importer-FreeCAD/steel_shapes/` ← from `1Steel-Shapes-DXF-DWG`

Provenance recorded in each `steel_shapes/ATTRIBUTION.md`.

## Duplicate partial-merge cleanup

Removed redundant trees created by an earlier partial import attempt:

- `PDF-Importer-SketchUp/resources/`, `shape-packs/`
- `PDF-Importer-FreeCAD/resources/`, `shape-packs/`

Canonical layout is **`steel_shapes/`** at each importer repo root.
