# QA-2026-06-23 — Text & Leader Alignment Fix

**Date:** 2026-06-23  
**Version:** SketchUp **v3.7.57**  
**Repo:** `C:\1PDF-Importer-SketchUp`

---

## What changed

### `geometry_builder.rb`

1. **Labels — horizontal text**
   - Use zero leader vector for native `add_text`.
   - Hide leaders via `display_leader = false` when supported.
   - Keeps screen-space labels at PDF baseline without arrow stubs.

2. **Labels — rotated text (\|angle\| > 8–12°)**
   - Route to `place_mesh_text` (same mesh path as 3D Text) so text rotates in model space instead of drawing a leader arrow.

3. **3D Text — anchor parity**
   - `mesh_label_anchor_pdf` now delegates to `text_insertion_pdf` (single left/baseline anchor).
   - Removes erroneous second `run_w / 2` X shift that misaligned centered and vertical labels.

4. **Architecture doc**
   - `BCS-ARCH-001.md` updated to document leader-vs-rotation behavior and shared anchor model.

### Tests

- `test/text_mode_placement_test.rb` — label vs 3D Text SketchUp point parity; rotated label routes to mesh; zero leader vector
- `test/text_label_placement_test.rb` — counts mesh + native labels for 1017 corpus
- `test/text_category_placement_test.rb` — mesh anchor equals label insertion (no double shift)

---

## How to verify (manual)

### Tier-1 PDFs

| PDF | Modes | What to check |
|-----|-------|---------------|
| `1017 - Rev 0.pdf` | Labels, 3D Text | BOM headers (QUAN/MARK), section titles, connection marks (`w1023`, `p1052`), vertical dims (`4'-0`, `10 3/8`), leader callouts (`8-15/16"Ø`) |
| Rotated landscape sheet (e.g. sealed drawings / `BCS_ROTATED_PDF`) | Labels, 3D Text | Text stays aligned with geometry after `/Rotate 270`; vertical dims remain readable |

### Pass criteria

- No visible arrow leaders on horizontal annotation text unless the PDF actually has leaders.
- Vertical/rotated dimension and part-mark text sits on the member/dimension line, not offset by a leader stub.
- **3D Text** and **Labels** share the same insertion point for the same span (toggle modes on identical import settings).
- Page-rotated sheets: text and vectors remain co-registered.

---

## Automated verification

```powershell
cd C:\1PDF-Importer-SketchUp
ruby test/text_label_placement_test.rb
ruby test/text_mode_placement_test.rb
ruby test/text_category_placement_test.rb
ruby test/page_rotation_test.rb
ruby test/text_mode_routing_test.rb
ruby test/qa_report_test.rb
```

All should exit 0. Golden 1017 assertions require `1017 - Rev 0.pdf` on Desktop corpus path.

---

## Hosts not changed

| Host | Reason |
|------|--------|
| FreeCAD | ShapeString/Draft text uses font alignment, not SketchUp leader API |
| LibreCAD | DXF TEXT placement path differs |
| Blender | `align_x` CENTER/LEFT already handles anchors |
| pdfcadcore | No shared bug; extraction/bbox data was correct |

---

## Release

- Version bumped: **3.7.56 → 3.7.57**
- Commit + push to `origin/main` on SketchUp repo
