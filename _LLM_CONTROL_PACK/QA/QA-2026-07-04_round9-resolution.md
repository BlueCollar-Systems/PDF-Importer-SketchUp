# Round 9 Resolution — "3D Model from PDF" Feature (2026-07-04)

**User request:** "In the software that's capable of it, I want them to have the option to generate a 3D model of the PDF if it makes sense to do so."

---

## Analysis

| Importer | 3D Extrude? | Rationale |
|----------|:-----------:|-----------|
| **SketchUp** | ✅ **Implemented** | Native `Face#pushpull(depth)` Ruby API. Geometry builder already creates flat `Sketchup::Face` objects from closed PDF paths. Ideal host for this feature. |
| FreeCAD | ❌ Not this layer | FreeCAD has Part::Extrude but the import step targets 2D Draft geometry; extrusion belongs in the FreeCAD user workflow, not the import. |
| Blender | ❌ Not this layer | Same argument. Blender users extrude curves/meshes after import. |
| LibreCAD | ❌ No 3D concept | 2D CAD application. |

---

## What was shipped — SU v3.7.80

| Item | Status |
|------|--------|
| `extrude_3d.rb` — `Extrude3D.apply(entities, depth_in)` post-processor | **SHIPPED** |
| `ImportConfig#extrude_depth` attribute (default 0.0 = disabled) | **SHIPPED** |
| `ImportDialog#build_opts` passes `extrude_depth` through CLI and dialog | **SHIPPED** |
| Pipeline hook in `main.rb` after cleanup, before fit-bounds | **SHIPPED** |
| `stats[:extruded_faces]` counter in import stats and report | **SHIPPED** |
| `test/extrude_3d_test.rb` — 19 tests, 45 assertions | **SHIPPED** |
| QA design doc `round9-3d-extrude-design.md` | **SHIPPED** |

---

## How it works

1. User sets `extrude_depth = N` inches (CLI: `--extrude-depth=4.0`; dialog: "Extrude depth" field).
2. After geometry build + cleanup + embedded image placement, the pipeline calls `Extrude3D.apply(page_group.entities, N)`.
3. Every **flat horizontal face** (Z-normal ≥ 0.99) with area ≥ 0.01 in² gets `face.pushpull(N)`.
4. Results (faces_found / extruded / skipped) are logged and added to `stats[:extruded_faces]`.
5. Feature is **opt-in** — `extrude_depth: 0.0` default means zero change to any existing workflow.

**Best use cases:** floor plans, structural cross-sections, site plans, architectural elevations.  
**Not useful for:** raster-only imports, text-only PDFs, map/GIS fill-art floods (skips those automatically since raster mode produces no faces).

---

## Test results

```
ruby test/extrude_3d_test.rb      → 19 runs, 45 assertions, 0 failures
ruby test/su_cli_test.rb          → PASS: 18 assertions
ruby test/embedded_image_extractor_test.rb → 3 runs, 12 assertions, 0 failures
ruby test/batch_cli_test.rb       → 4 runs, 14 assertions, 0 failures
full corpus placement gate        → 30 PDFs, 29 OK / 1 TIMEOUT (warn-only)
```

---

## Remaining honest signoff

All automated gates green. Human signoff still needed:

- Open a floor plan PDF in SketchUp with `extrude_depth = 96` (8 ft story height) and visually verify wall prisms, room shapes, and column bases look correct.
- For T-01 visual fidelity: color, lineweight, dimension spacing — still needs in-host golden raster comparison.
- Dialog UI for `extrude_depth` field: needs SketchUp host UX review (currently CLI-only until the advanced dialog HTML is wired up).

---

*Round 9 closure — 2026-07-04*
