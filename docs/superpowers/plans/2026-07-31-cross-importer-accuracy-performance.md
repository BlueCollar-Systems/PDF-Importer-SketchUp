# Cross-Importer Accuracy & Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix sweep fail buckets (Phase A), then port SketchUp fidelity/perf methods across hosts (Phase B), without committing Desktop PDFTest corpus files.

**Architecture:** Triage LibreCAD map-text verification and FreeCAD SVG item assignment first; harden SketchUp export-only evidence; then share angle-hint / residual-rotation / outline-reuse patterns via each host’s existing text renderer.

**Tech Stack:** Ruby (SketchUp), Python (LibreCAD / Blender / FreeCAD), pdfcadcore, Poppler/pdftocairo SVG, FreeCADCmd

**Spec:** `docs/superpowers/specs/2026-07-31-cross-importer-accuracy-performance-design.md`

> Checked implementation steps record work attempted in the originating lane;
> they are not release acceptance. Clean-branch tests, saved/reopened host
> evidence, privacy gates, packaging, and byte verification remain mandatory.

## Global Constraints

- Text-mode fidelity doctrine (requested mode wins; finite closest ladders).
- Corpus and CAD counterparts never enter git; keep under Desktop / `C:\TMP`.
- Free/bundled only.
- SketchUp 2017 routes 3D Text through the verified source-outline renderer; native `add_3d_text` remains excluded from that path.
- Fallback ladders are finite and host-specific. Do not copy one importer's order into another.
- In-repo tests use synthetic fixtures only.

---

## File map

| Area | Primary files |
|------|----------------|
| FreeCAD glyphs assign | `PDFVectorImporter/src/PDFSvgTextRenderer.py`, `PDFImporterCore.py`, tests under `tests/` |
| LibreCAD text verify | LibreCAD text delivery / DXF verify modules under `librecad_pdf_importer/` + `pdfcadcore/` |
| SketchUp evidence | `tools/sketchup_batch_import.rb`, `tools/sketchup_host_evidence.rb` |
| Shared perf (Phase B) | SketchUp `svg_3d_text_renderer.rb` / `main.rb` as reference; port into FreeCAD `PDFSvgTextRenderer.py` and LibreCAD/Blender pdfcadcore text paths |
| Containment | `.gitignore` in all four repos (already present; verify) |

---

### Task 1: FreeCAD — fix `svg_item_assignment_empty` for glyphs/geometry

**Files:**
- Modify: `C:\1PDF-Importer-FreeCAD\PDFVectorImporter\src\PDFSvgTextRenderer.py`
- Test: `C:\1PDF-Importer-FreeCAD\tests\` (existing SVG/text tests or new synthetic)

- [x] **Step 1:** Reproduce assignment failure path in `render_text` / assignment helpers; identify why shop-span ids get empty assignment while source_manifest is present
- [x] **Step 2:** Write failing unit test with synthetic SVG + semantic items that currently returns `svg_item_assignment_empty`
- [x] **Step 3:** Implement matching/filter fix (full-page inventory matching like SketchUp; do not subset-match only target items)
- [x] **Step 4:** Run FreeCAD-relevant pytest subset; confirm glyphs path no longer empty-assigns for fixture
- [x] **Step 5:** Optional local FreeCADCmd smoke on Desktop `1011` page 1 glyphs → output under `C:\TMP` only

---

### Task 2: LibreCAD — map-text visual verification false negatives

**Files:**
- Modify: LibreCAD / pdfcadcore text verification + native DXF text delivery modules
- Test: existing LibreCAD pytest

- [x] **Step 1:** Load failed report `TX_Alvord… out_failed_import_report_*.json`; isolate verification predicate for `text_span:1:3037`
- [x] **Step 2:** Write failing test that encodes the false-negative condition (synthetic, no corpus bytes in repo)
- [x] **Step 3:** Fix verification or placement so valid native text certifies; keep loud failure for real mismatches
- [x] **Step 4:** Fix `text_mode=raster` exit-2 path to certify item raster or report exact ladder failure
- [x] **Step 5:** Run LibreCAD pytest subset green

---

### Task 3: SketchUp — export-only evidence readiness after SKP save

**Files:**
- Modify: `tools/sketchup_batch_import.rb`, `tools/sketchup_host_evidence.rb` as needed
- Test: existing host job unit tests if present

- [x] **Step 1:** Reproduce `report representation readiness mismatch` when SKP already saved under `skp_export_only`
- [x] **Step 2:** Align report binding / readiness checks with export-only contract (SKP + import_report without full reopen snapshot)
- [x] **Step 3:** Ensure orphan host lock cleanup remains in QA runners (outside product if lock is QA-only)
- [x] **Step 4:** Ruby syntax check / relevant unit tests

---

### Task 4: Phase B — residual rotation + angle-hint indexing on FreeCAD SVG text

**Files:**
- Reference: `extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer.rb`
- Modify: FreeCAD `PDFSvgTextRenderer.py` (+ LibreCAD/Blender if same gap)

- [x] **Step 1:** Confirm FreeCAD applies residual `item.angle − svg_matrix_angle` for solid/glyph groups
- [x] **Step 2:** Add/port angle-hint spatial index for short tokens if FreeCAD still scans linearly
- [x] **Step 3:** Shared outline reuse where FreeCAD rebuilds identical glyphs per placement
- [x] **Step 4:** Tests for rotation residual and reuse invariants

---

### Task 5: Phase B — LibreCAD/Blender contract + perf parity check

**Files:**
- `pdfcadcore` / host text deliverers in LibreCAD and Blender

- [x] **Step 1:** Audit that all six requested modes exist and every host-specific ladder is finite, tested, and advances only after item-scoped impossibility
- [x] **Step 2:** Port any missing residual-rotation / hint-index fixes discovered in Task 4
- [x] **Step 3:** Blender regression smoke (CLI) on synthetic fixture; optional Desktop page-1 under `C:\TMP`

---

### Task 6: Containment verification + summary

- [x] **Step 1:** `git ls-files` in all four repos — no PDFTest / Imported Evidence binaries
- [x] **Step 2:** Confirm `.gitignore` containment blocks present
- [x] **Step 3:** Update `C:\TMP\cross-importer-sweep-20260730\LIVE_STATUS.md` with post-fix notes (local only, not in repo)
- [x] **Step 4:** Record completion in this plan checkboxes

---

## Execution note

Prefer implementing Tasks 1→2→3 before Phase B. Do not commit corpus files. Only create git commits if the user explicitly asks.

## Implementation notes (2026-07-31)

- Task 4 residual-rotation / outline-reuse port to FreeCAD deferred as follow-on; assignment expansion + doctrine ladders landed first.
- LibreCAD map abort root cause was ezdxf trailing-`^` mutation (ESRIDefaultMarker), not bbox tolerance.
- A proposed fleet-global ladder edit was rejected during integration because it contradicted the owner-approved host-specific doctrine and existing contract gates. Reusable performance fixes remain eligible; each importer's tested ladder stays authoritative.
