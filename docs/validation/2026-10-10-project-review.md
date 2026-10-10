# Seven-project improvement and validation review — 2026-10-10

This review implemented local source improvements across all seven projects.
Tests use synthetic records and private PDFs read in place; private PDF names,
credentials, and shop records are excluded from this report. Existing released
packages, installed CAD extensions, app-store listings, and the hosted website
were not replaced or published by this review.

## Problems repaired

| Project | Concrete changes | Verification |
| --- | --- | --- |
| SketchUp importer | Correct nominal text size matching across crop/rotation frames; functional edge/face and loose-geometry scaling; nested editing-context anchors and measured lengths; reject invalid and overflowing scale inputs before saving preferences. | Current Ruby diagnostic sweep and settled workflow regressions; Ruby 2.2 compatibility scanners. Fresh native SketchUp acceptance remains unverified. |
| Blender importer | Validate complete page selections before changing the scene; reachable Escape/Cancel through main-thread modal phases; rollback unfinished pages; retain only verified completed-page counters when resuming. | Full suite before modal refactor, subsequent focused fidelity/operator tests, and native Blender 5.2.2 cancellation/resume and six-mode probes. |
| FreeCAD importer | Strict bounded page selection; responsive batch cancellation/progress; isolate corrupt PDFs and report actual results; extract selected pages in one cached run per PDF with deferred recomputation. | Full suite, final focused batch tests, and native FreeCAD 1.1.4 six-mode/private drawing probes. |
| LibreCAD converter | Include missing modules in installed wheels; validate scale/reference dimensions; consistent R2010 defaults; checkpoint cancellation before closing the GUI. | Full suite before shared font changes; isolated installed-wheel conversion and focused GUI/settings/package tests. |
| Steel Logic | Preserve existing hours when adding/canceling job rows; atomic corrections protect live shifts; retain exact seconds/milliseconds; fix duration parsing and shape decimal/fraction identity; enforce existing local worker-sheet roles; improve small-screen controls and setup guidance. | Final full Flutter suite: 983 passed, two skipped; analyzer clean; 41 Python preflight tests; English/Spanish key parity; Windows preview compiled. |
| Tag QC Builder | Functional camera/manual/photo scanner controls; stream ownership and cleanup; native QR fallback; bounded decoding; playback timeout and recovery. Package and verify the PGLite runtime so tag lookup works in the built app. | 177 app tests, 198 script tests, 51 Python tests/two skipped; typecheck/build; settled Edge scanner and built-database checks. Applies to the React application; the frozen shop portable implementation is unchanged. |
| Website | Copy feedback and recovery; preserve zero quantities; explain sidecar read errors; prevent stale asynchronous file reads; close mobile navigation after selection; provide a public-file-only localhost route preview. | Python/browser/control/resolver tests, privacy and release metadata checks; working local navigation and report workflows. |

### The shared font roadblock

Blender, FreeCAD, and LibreCAD share the same extraction core. Previously,
different original font programs with the same family name could invalidate
one another or lend the wrong glyph identity to a character. The repair binds
each occurrence to the actual original font-program SHA and its matching
Unicode/origin trace. Incomplete, conflicting, or missing evidence remains an
explicit failure.

Native inferred spaces are treated separately from painted glyphs. They must
have native synthetic-space flags, no matching painted occurrence, an exact
original font binding, and an original U+0020 glyph with no ink. Their original
layout remains intact and no painted glyph ID is invented. Original raw CFF
and SFNT fonts both have positive and negative proof tests. Requested text modes
and the existing item-scoped fallback gates remain intact.

The three shared core copies and manifests are synchronized. Final source
binding, source-quad, control-glyph, and positioned-fraction tests passed
**202 cases** in LibreCAD, with another **223 passed/six skipped** in related
font/fallback/environment checks; host-specific results are in the linked reports.
The new inferred-spacing fixture passed all six text modes in actual Blender
5.2.2 and FreeCAD 1.1.4. Their wider focused delivery checks passed 276 and 270
cases respectively; the last competing-paint rejection then passed all 28
source-font regressions in each host. These stages are recorded separately.
The final first-page export from a 179,562,772-byte, 259-page drawing set completed
in **195.72 seconds**, certified page 1, and reported zero degraded text items.
It delivered **339 spans as editable Glyphs and one as native Text**, whereas
the original run rasterized 289 spans because same-name fonts collided. The
input SHA-256 remained unchanged. This is bounded converter/reopen evidence,
not a full native LibreCAD/PDF visual acceptance. The reopened DXF audit found
zero errors or repairs. [Sanitized final drawing evidence](<C:/1PDF-Importer-LibreCAD/docs/validation/2026-10-10-large-page-probe.json>)
records counts without private source names.

## Try the local results

- [Steel Logic Windows preview launcher](<C:/1 Structural_Steel_Shapes_App/dist/audit-preview/2026-10-10-workflow-review/Open Audit Preview.bat>) — keep its surrounding DLLs and data folder. The app uses the usual local profile; the review did not open real user records.
- [Tag QC built preview](http://127.0.0.1:18182/scan) — camera, photo, pasted QR and typed tag entry. Uses the local development application, not the frozen shop launcher.
- [Website preview](http://127.0.0.1:18181/) — source pages and Report Doctor.
- LibreCAD development GUI: `C:\1PDF-Importer-LibreCAD\launch_lcpdf_gui.pyw`.
- CAD source improvements are in their respective checkouts. Existing installed
  extension archives continue to contain their previously packaged source.

Local preview servers run only while their processes remain active. Each
project's report includes startup instructions and verification limitations.

## What these results establish

There were specific implementation and packaging defects behind apparently
working controls and unnecessary loss of editability. Those defects can be
fixed without weakening fidelity checks. Automated tests and bounded native
probes provide evidence for the changed paths, not a promise that every PDF,
every control, every hardware configuration, or every future host is certified.

The corpus contains 5,897 top-level PDFs and was sampled, not converted in full.
One different sheet exceeded a five-minute bound during outline construction;
small file size alone does not predict conversion cost. Producing real editable
outlines can take longer than accepting raster patches.

Remaining acceptance work includes complete PDF/native side-by-side comparison,
older host runtimes and current SketchUp, physical Android/iOS devices and shop
scanners, installed release packaging, and Tag-to-Steel-Logic clock workflows.
No automatic 2D-to-3D reconstruction was added. Global shop policies, overnight
calendar-day accounting, and additional national shape catalogs need explicit
product design and validation before worldwide claims.

## Detailed evidence

- [SketchUp](2026-10-10-workflow-review.md)
- [Blender](<C:/1PDF-Importer-Blender/docs/validation/2026-10-10-workflow-review.md>)
- [FreeCAD](<C:/1PDF-Importer-FreeCAD/docs/validation/2026-10-10-workflow-review.md>)
- [LibreCAD](<C:/1PDF-Importer-LibreCAD/docs/validation/2026-10-10-workflow-review.md>)
- [Steel Logic](<C:/1 Structural_Steel_Shapes_App/docs/validation/2026-10-10-workflow-review.md>)
- [Tag QC Builder](<C:/1Tag-QC-Builder/docs/validation/2026-10-10-workflow-review.md>)
- [Website](<C:/1BlueCollar-Website/docs/validation/2026-10-10-workflow-review.md>)

Other workspace activity created commits during verification. This review did
not make commits or push; concurrent work was preserved. Later focused checks
were run against settled source, and suite results are identified by stage
rather than combined into a misleading final-suite total.
