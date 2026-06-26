# QA-2026-06-26 — Regression: popup, BOM alignment, FreeCAD text overlap

## Anonymous questions

1. **Reviewer A (SketchUp UX):** Should the pre-import guidance appear on every PDF pick, or only until the user has seen it once? Is a LibreCAD-specific sentence ever appropriate inside the SketchUp extension?

2. **Reviewer B (Labels contract):** When Labels mode encounters rotated BOM table text or vertical QUAN cells, must the importer keep native SketchUp labels instead of routing through 3D Text/mesh placement?

3. **Reviewer C (FreeCAD scale/fit):** Can overlapping ShapeString labels on dense shop drawings be explained by host font metrics exceeding PDF span bboxes while geometry scale remains correct?

4. **Reviewer D (Cross-host):** Do LibreCAD and Blender need code changes for this regression, or is auditing their test suites sufficient when shared pdfcadcore behavior is unchanged?

5. **Reviewer E (Validation):** What automated checks prove the 1017 BOM table and connection-detail text anchors without requiring the user to remain online during the fix window?
