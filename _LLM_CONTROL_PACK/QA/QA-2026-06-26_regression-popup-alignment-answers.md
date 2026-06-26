# QA-2026-06-26 — Regression answers

## Q1 — SketchUp pre-import popup
**Reviewer A:** Do not show a pre-import guidance popup in SketchUp at all. The field report proved that even a well-meant prompt can become friction or stale cross-host copy. Remove `ImportGuidance`, keep SketchUp mode guidance in the import dialog / Import Health / documentation surfaces, and fail CI if `Before you import`, `ImportGuidance`, or LibreCAD-specific copy returns to the SketchUp import path.

## Q2 — Labels vs mesh for rotated BOM text
**Reviewer B:** Yes. Labels mode must stay on `add_text` with `label_direction_vector` for rotated native labels. The regression came from routing |angle|>12° labels to `place_mesh_text` inside Labels mode. QUAN-column digits need BOM-table column context so they are not misclassified as vertical dimensions.

## Q3 — FreeCAD overlap root cause
**Reviewer C:** Primary issue is host text wider than PDF span bbox at the same scale — not a title-block scale regression. Fix by `_fit_font_size_to_span_bbox` for Draft labels and ShapeString, plus baseline offset on all exact-label spans. Hybrid raster backgrounds must use the same effective import scale as vectors.

## Q4 — LC/BL scope
**Reviewer D:** No popup pattern exists in LibreCAD/Blender. Run their pytest suites for regression safety; no host-specific code required for this ticket.

## Q5 — Automated proof
**Reviewer E:** SketchUp: `text_label_placement_test.rb` (1017 golden anchors + BOM column cases), `text_mode_placement_test.rb`, `pre_import_prompt_test.rb`, `ruby22_compat_test.rb`. FreeCAD: `test_pdf_importer_text_reconstruction.py` bbox-fit cases. Interactive SU 2017 + FreeCAD 0.21 confirmation remains for the user on return.
