# QA-2026-06-23 — Text & Leader Alignment Root Cause

**Date:** 2026-06-23  
**Scope:** SketchUp Labels + 3D Text modes  
**Repos affected:** `C:\1PDF-Importer-SketchUp` only (Python hosts use different text APIs)

---

## Summary

Two independent SketchUp-specific bugs caused visible text/leader misalignment when importing PDF annotations as **Labels** or **3D Text**.

---

## Root cause 1 — SketchUp `add_text` vector is a leader arrow, not rotation

| Field | Detail |
|-------|--------|
| **Symptom** | Rotated dimension/part-mark text appeared offset from PDF geometry; arrow leaders pointed away from the text bbox instead of aligning with the drawing. |
| **Cause** | `Entities#add_text(text, point, vector)` treats the third argument as an **arrow leader direction**, not text rotation. Passing `label_direction_vector(angle)` for ~90° vertical labels created visible leader lines and did not rotate the annotation to match PDF orientation. |
| **Affected mode** | Labels (native `add_text`) for spans with \|angle\| > 8–12° |
| **Not affected** | Geometry/Glyphs (SVG outlines), 3D Text (`add_3d_text` + explicit rotation transform) |

---

## Root cause 2 — Double half-width shift in 3D Text anchor

| Field | Detail |
|-------|--------|
| **Symptom** | Centered BOM headers, horizontal dimensions, and slope-triangle numerals drifted left of PDF position in **3D Text** mode while **Labels** looked correct. Vertical rotated labels also shifted horizontally. |
| **Cause** | `label_insertion_pdf` already returns the **left/baseline** anchor (including bbox centering heuristics). `mesh_label_anchor_pdf` subtracted an extra `run_w * 0.5` from X whenever the anchor was not at `bbox_x0`, assuming the insertion point was still centered. |
| **Affected mode** | 3D Text only |
| **Not affected** | Labels (uses `label_insertion_pdf` directly), Python hosts (Blender/FreeCAD use font alignment flags, not this Ruby path) |

---

## Root cause 3 — Default leader visibility on horizontal Labels

| Field | Detail |
|-------|--------|
| **Symptom** | Some horizontal labels showed SketchUp leader stubs even when PDF had no leader. |
| **Cause** | Non-zero or default leader state on native text entities after placement. |
| **Fix direction** | Pass zero vector + set `display_leader = false` when API available. |

---

## Page rotation / pdfcadcore

- **Page `/Rotate` handling** for Labels/3D Text was already correct via `PageTransform.transform_point` + `display_text_angle` in `geometry_builder.rb`.
- **pdfcadcore** span extraction was **not** the root cause; no embedded-core change required for this fix.

---

## Evidence

- Regression corpus: `1017 - Rev 0.pdf` (342 external text spans, golden coordinate assertions)
- Failing pattern before fix: centered QUAN/dimension labels shifted in 3D Text; vertical `4'-0` / `10 3/8` labels showed arrow leaders in Labels mode
- Tests updated: `text_mode_placement_test.rb`, `text_label_placement_test.rb`, `text_category_placement_test.rb`
