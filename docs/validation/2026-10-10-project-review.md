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

## Local packaging and compatibility follow-up

The later packaging request produced usable dated Windows test packages for
all seven projects, a debug-signed Steel Logic Android TEST APK, and the
desktop shortcut `BlueCollar Test Tools - 2026-10-10`. The consolidated guide
and current archive hashes are in `C:\BlueCollar-Test-Builds\2026-10-10`.
The earlier remaining-work list describes the first pass; several of those
items have now been resolved by the follow-up below.

- SketchUp's actual Ruby 2.2.4-p230 language suite passed 176 test files after
  fixing legacy Integer numeric validation. Extracted helpers passed. Native
  Make 2017 import/save/reopen and current Pro acceptance remain pending
  because window activation failed after one recovery.
- Blender's final r5 extracted importer accepted all six modes and selected
  fixtures in native 3.1.2 and 5.2.2. Temporary TextCurve ownership and empty
  mesh material handling were corrected; 131 targeted regressions passed.
- FreeCAD's final r4 extracted importer accepted all six modes and selected
  fixtures in native 0.21.2 and 1.1.4. The legacy bounding API defect now uses
  an owned analytic copy, and content-bound checkpoint validation rejects
  code changes while preserving completed geometry.
- LibreCAD's frozen package/source/plugin gates passed. A large-file page
  converted without degraded text, reopened with no DXF audit errors, and
  its menu plugin loaded against the installed Qt5.15.2 runtime with the
  expected interface/menu entries. Native GUI interaction remains pending.
- Steel Logic's isolated Windows TEST app passed packaged offline workflow
  checks with the exact Tag QC register/CSV identities and two part timers.
  Calendar-day corrections now preserve adjacent days and overnight hours;
  23/25-hour daylight-saving regressions passed. Android package metadata,
  three ABI runtimes, integrity and debug signature were verified. Physical
  mobile installation/camera/OS dispatch and iOS signing remain pending.
- Extracted Tag QC/website packages passed scanner recovery, namespace and
  atomic per-piece accounting checks plus restart/move/ownership controls.
  The existing portable document implementation remains a separately tested
  workflow; it passed 299 self-checks and retains independent job backups.

The final consolidated `VALIDATION.html` records suite completion and precise
platform limits. Native CAD probes exercised actual package code and callback
controls on selected fixtures, with no universal GUI pixel/fidelity claim.
No automatic 2D-to-3D reconstruction, worldwide shop-policy certification,
public deployment, store publication, or user extension replacement was
performed. Private inputs and credentials are excluded from distributable
archives. Detailed SketchUp/LibreCAD packaging evidence is in
[the packaging record](2026-10-10-test-packaging.md); the other projects have
their own dated package validation records.


## Final r4 follow-up — 2026-10-10

This later record supersedes earlier pending r3 statements for the listed neutral checks only. The r4 RBZ SHA-256 is `f372b69840f02c28fb7a7abf09a5cc2d276a2a74a1ae0e12a052cdc57c7edfa9` (27,623,794 bytes), with tree `fbf8e332fd1f9af8ddbe82979c48f175acce0ac6a86a55520a03192bc3264b9b`. Full exact Ruby 2.2.4-p230 suite on the owned frozen r4 source clone: **179 files, 2,345 tests, 21,027 assertions, zero failures/errors, 8 skips**; captured clone source/tests/tools remained unchanged. A prior mutable-repository suite had zero failures/errors but failed its unchanged-source gate because an unrelated actor added Extrude UI/menu code. That working-repository change is preserved and excluded from r4; the final suite is bound to the exact frozen package instead. Original native harness tools retain their native-proof byte bindings. All eleven actual Make 2017 native matrix rows and independent external checks passed, including three native cancellation cases. Fresh source/cache-unavailable scopes: **text page(s) 1, 2 Images; raster page(s) 1, 5 Images; raster page(s) 2, 1 Images**. Every scoped Image has physical TextureWriter pixel proof and all fixture files/preferences were restored. Native render PNGs support inspection; no rendered pixel equality is claimed.

Editable bounded source-width footprints, source-point lineweight groups/tags, protected original centerlines, honest approximation warnings and flat-color display are included. Requested text modes and finite item-scoped fallback contracts remain intact. The corrected fictional sample PDF SHA-256 is `3dcb8e4ab9e91bfc456e33157111bc1486fcba3f335bf061a14ab56b2defce7e`. Neutral original proof JSON, SKPs, available render PNGs and an original/copied-byte ledger are under `C:\BlueCollar-Test-Builds\2026-10-10\SketchUp\Validation-r4`. Earlier r3 records/trees remain historical evidence; the exact r3 installer is archived under Superseded. Other project validation stages are unchanged.

- Physical Escape-key presses and GUI button interaction are not certified by injected cancellation probes.
- Current SketchUp Pro, other SketchUp versions/platforms and broader PDF/hardware coverage remain pending.
- Requested Labels uses the certified item-bound source-outline 3D visual equivalent on Make 2017; it is not an editable screen annotation.
- Bounded editable source-width footprints cover proven solid opaque undashed eligible paths; unsupported cases retain editable approximate native centerlines and report review warnings.
- Curve footprints use explicitly bounded polygonal sampling; no analytic-curve or universal page fidelity claim is made.
- Native Image boundaries and viewport rendering can differ from the PDF. Genuine Images are preserved; no rendered pixel equality is claimed.
- Fresh source-unavailable proof covers only the listed neutral modes/pages, not every PDF or mode.
- This unsigned local test snapshot does not install itself, change production extensions, deploy a website or publish a store release.


## Manual extrusion and r6 native follow-up — 2026-10-11

The manual selection command now uses finite full-dimension parsing, world +Z depth through composed transforms, unique selected/nested copies and physical cap/side/peer checks before one confirmed commit. Protected PDF stroke/text/hidden/locked content is skipped with reasons. Any unconfirmed result aborts the owned operation; rollback failure is explicit. It remains a bounded isolated-profile edit, separate from the PDF import pipeline.

Exact r6 RBZ SHA-256 `17a05c83cd11ce61dbf7bbc8cb5d0c5475b62a877998dde14cdfb5567b144faf` (27,630,968 bytes), 648 members/92 Ruby files; tree `4d749cb5bf2ec37ea9cdfdfe82cb16ddd673d9205b87ddb03c793cbb41c0b635`. Frozen full legacy suite: **181 files, 2,405 tests, 21,391 assertions, zero failures/errors, 8 skips**; focused actual product module/action tests also pass Ruby 3.4.4. Actual SketchUp 2017 17.2.2555 passed **14 extrusion checks plus 1 native dimension check**, native Undo including restored shared definitions, save/reopen and a fresh-process physical geometry/material check. All 11 import/image/lineweight/cancellation matrix rows and all three distinct fresh Image portability scopes (Text: 2 Images; itemRaster: 5; zero-text Raster: 1) were repeated on this exact r6 package. Injected failure probes do not certify physical UI/Escape presses.

Byte-bound neutral receipts/models are preserved under `C:\BlueCollar-Test-Builds\2026-10-10\SketchUp\Validation-r6`. r4 evidence remains historical. GUI interaction/open editing-context entry, current SketchUp Pro, other versions/platforms and broader PDFs/hardware remain pending.
