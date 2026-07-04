# QA 2026-07-04 Round 9 — "3D Model from PDF" Feature Design

**Requested by user:** "I want the software that's capable of it to have the option to generate a 3D model of the PDF if it makes sense to do so."

---

## Which software is capable of it?

| Importer | Verdict | Reason |
|----------|---------|--------|
| **SketchUp** | ✅ **Yes — implement** | SketchUp has a native `Face#pushpull(distance)` Ruby API. The geometry builder already creates flat `Sketchup::Face` objects (Z=0) from closed PDF paths when `import_fills` is on. Push/pull turns each face into a solid prism — this is idiomatic SketchUp 3D modeling. |
| FreeCAD | ⚠️ Possible but wrong layer | FreeCAD has Part::Extrude but the Python importer targets 2D Draft geometry. Extrusion belongs in the FreeCAD workflow, not the import step. |
| Blender | ⚠️ Possible but wrong layer | Blender has `bpy.ops.mesh.extrude_region_move`. Same argument — the import step should land clean 2D curves; extrusion is a user modeling step. |
| LibreCAD | ❌ No | LibreCAD is a 2D CAD application with no 3D concept. |

**Decision: SketchUp only.** The native `pushpull` API makes this a first-class SketchUp feature, not a hack. It is explicitly **not** added to the other importers because they target different workflows.

---

## When does it make sense?

"Generate a 3D model" is meaningful for:
- **Floor plans / site plans** — walls, columns, pads extruded to story height.
- **Structural fabrication drawings** — cross-sections extruded to member length.
- **Architectural elevations** — profile extrusions for mass modeling.

It is **not** meaningful for:
- **Raster-only imports** — no faces, nothing to push/pull.
- **Text-only PDFs** — no closed geometry.
- **Maps / GIS** — fill-art floods of decorative polygons; 3D would be noise.

The feature is **opt-in only** with a default depth of 0 (off). No existing behavior changes.

---

## Design

### New option: `extrude_depth`

- Type: float, in **inches** (the importer's native unit).
- Default: `0.0` (feature disabled).
- Range: any positive value; 0 or negative = skip.
- Exposed in:
  1. `ImportConfig` as `@extrude_depth` attribute.
  2. `ImportDialog` as an optional "Extrude depth" field (shown only when import_mode ≠ raster).
  3. CLI flags: `--extrude-depth=4.0` (in inches).

### New file: `extrude_3d.rb`

Module `BlueCollarSystems::PDFVectorImporter::Extrude3D` with one public method:

```ruby
Extrude3D.apply(entities, depth_inches, opts = {})
# → { faces_found: N, faces_extruded: N, faces_skipped: N }
```

Logic:
1. Collect all `Sketchup::Face` instances from `entities` (recursive into groups/components).
2. Skip faces where `face.normal.z.abs < 0.99` (not horizontal — already 3D or angled).
3. Skip faces with area below `opts[:min_area_sqin]` (default 0.01 in² = ~8mm² — filters hairline artifacts).
4. Call `face.pushpull(depth_inches)` — positive = extrude upward (Z+).
5. Return stats hash.

### Pipeline hook in `main.rb`

After cleanup and embedded image placement, before `add_page_fit_bounds`:

```ruby
if opts[:extrude_depth].to_f > 0.0 && builder.page_group && opts[:import_mode].to_s != 'raster'
  ex = Extrude3D.apply(builder.page_group.entities, opts[:extrude_depth].to_f)
  stats[:extruded_faces] = (stats[:extruded_faces] || 0) + ex[:faces_extruded]
end
```

### ImportConfig changes

```ruby
attr_accessor :extrude_depth   # float inches, 0.0 = disabled
# In initialize:
@extrude_depth = attrs[:extrude_depth] || 0.0
# In to_raw:
extrude_depth: @extrude_depth
```

### ImportDialog changes

Add an optional "Extrude depth (in)" text field in the HTML dialog, hidden/disabled when import_mode = raster. Passes through `build_opts`. Default blank = 0.

### import_report.json additions

```json
"extra": {
  "extruded_faces": 42,
  "extrude_depth_in": 4.0
}
```

---

## What it does NOT do

- No heuristic "guess which faces are walls" — all faces get the same depth.
- No layer-based selective extrusion (P2 if requested).
- No parametric heights from dimension text parsing (P2).
- No support for PDF pages with only raster or only text content.
- No changes to FreeCAD, Blender, or LibreCAD importers.

---

## Regression test contract

`test/extrude_3d_test.rb`:
- Unit test: build a minimal flat face in a mock entities container, call `Extrude3D.apply`, assert `faces_extruded = 1` and depth was applied.
- Skip test: zero depth → `faces_extruded = 0`.
- Skip test: face with non-horizontal normal → skipped.
- Skip test: tiny face below min_area threshold → skipped.
- Stats test: return hash has correct keys.

Since tests run outside SketchUp, `Extrude3D` must be testable with a lightweight mock that stubs `face.pushpull` — the module is written to accept injected face objects.

---

## Implementation plan

1. Create `extracted/sketchup_ext/bc_pdf_vector_importer/extrude_3d.rb`
2. Add `extrude_depth` to `ImportConfig`
3. Add `extrude_depth` to `ImportDialog#build_opts` passthrough
4. Wire hook in `main.rb` after cleanup
5. Add `extruded_faces` to stats and QA report
6. Write `test/extrude_3d_test.rb`
7. Run full test suite (must stay green)
8. Commit

---

*Design approved — Round 9 — 2026-07-04*
