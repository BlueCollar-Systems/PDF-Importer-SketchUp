# QA-2026-06-24 — Text Mode Verification Matrix

**Date:** 2026-06-24  
**Purpose:** Define expected output per host × text mode and how to verify after field fixes.

---

## Mode definitions (BCS-ARCH-001)

| Mode | pdfcadcore `text_mode` | Expected geometry |
|------|------------------------|-------------------|
| **Geometry** | `geometry` | Text becomes linework (edges/outlines); not editable |
| **Labels** | `labels` | Native editable text annotations |
| **3D Text** | `3d_text` | Host 3D/extruded text where supported |
| **Glyphs** | `glyphs` | Per-character vector glyphs (SVG/component or curve outlines) |

`import_text=false` → no text regardless of mode.

---

## Verification matrix

| Host | Geometry | Labels | 3D Text | Glyphs | Verify with |
|------|----------|--------|---------|--------|-------------|
| **SketchUp** | SVG path edges via Poppler/MuPDF; no Text group | Native `add_text` when \|angle\| ≤ ~12°; mesh fallback when rotated | `add_3d_text` + rotation transform; shared anchor with Labels | SVG/component glyph path (`svg_text_renderer`) | `1017 - Rev 0.pdf`; `ruby test/text_mode_placement_test.rb`; inspect QUAN column + SECTION dims |
| **FreeCAD** | Draft geometry / wires | `Draft` text objects | Part/design text where enabled | Glyph curves | pytest subset; import report `text_mode` |
| **Blender** | Mesh/curve outlines | Font curve objects | Extruded text objects | Per-char curves | pytest; preferences PyMuPDF OK; import small PDF |
| **LibreCAD** | DXF polylines (outline mode) | DXF **TEXT** entities (GUI default) | N/A (mapped to TEXT in CLI) | Same as geometry outlines | GUI **Labels**; open DXF — TEXT not POLYLINE soup |

---

## SketchUp routing (reference)

```
import_dialog effective_text_mode
  :geometry / :glyphs  → main.rb SVG render path
  :labels / :text3d     → GeometryBuilder (use_3d_text flag)
  :none                 → skip text
```

**Pass criteria (SU):** Labels and 3D Text share `text_insertion_pdf` coordinates for same span; rotated BOM quantities use vertical signed angle; no visible leader stubs on horizontal labels.

---

## Regression commands

```powershell
cd C:\1PDF-Importer-SketchUp
ruby test\text_label_placement_test.rb
ruby test\text_mode_placement_test.rb
```
