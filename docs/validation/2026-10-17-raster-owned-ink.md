# Source-owned item Raster crop bounds: v3.7.172

The interrupted r19 native import still showed white cutouts in slanted Raster
text. A new authored PDF reproduced the same missing letter portions by combining
the original Ghostscript crops outside SketchUp. This isolates an incomplete
crop-coverage defect; it does not establish a host depth or transparency defect.

The eight canonical spans include horizontal, vertical, and slanted text. The
existing Cairo source matcher uniquely assigned all 23 glyph placements to those
spans. Poppler's estimated boxes missed real slanted glyph ink. Combining each
span's extractor box with only its matched source-outline ink bounds, followed
by the existing 1.5-point padding and device-pixel grid, covered all visible ink.

A separately authored fixed pixel region contains 6,188 visible source pixels.
The original v3.7.171 crop union omitted 795; the proposed source-owned union
omitted zero. Every copied crop pixel matched the shared original page render.
The source PDF SHA-256 is
`269b98c863b22c246a0234418bbd4fa8fe113d46b01b332eacaa6bbbef5a228b`.
Private diagnostics are in
`C:/BlueCollar-Validation/2026-10-17/Overlap-Probe/`.

The implementation retains canonical extractor bounds and semantic/source IDs;
only Raster crop geometry uses the added source-owned enclosure. Its per-page
plan and SVG digest are cached once. Missing, ambiguous, stroked or unsupported
outline evidence retains bounded extractor-box delivery and reports that ink
coverage is unqualified. It never changes the requested mode or image depth.

Actual renderer tests also exposed automatic page rotation during Ghostscript
font embedding. Embedding now explicitly disables that automatic rotation while
preserving the PDF's displayed intrinsic orientation. SVG viewport dimensions
must resolve to one source MediaBox or CropBox; ambiguous origins remain
unqualified. Command-option metadata alone cannot establish the actual viewport,
because the bundled SVG renderer can reject its CropBox flag while still using
the PDF CropBox by default.

The final source suite passed on actual Ruby 2.2.4 and 3.4: 11 tests/152
assertions, including real bundled rendering at rotations 0/90/180/270 with a
nonzero MediaBox and CropBox. The independent repeat passed 11/150 on each
runtime; its invocation omits two helper-availability assertions. Representation
contracts passed 110/1,134, item display 13/96, page rendering 10/140, and font
embedding 18/77. The separate Cairo and multi-page suites retain their existing
private-fixture skips. An independent Pillow comparison of the changed product
source again found zero missing pixels in the fixed 6,188-pixel ink region and
verified all eight original-page crops. The full report suite also passed
48 tests/306 assertions on each runtime. All 11 GitHub checks passed at the exact
product commit below.

## Local r20 package and installation

| Field | Bound value |
|---|---|
| Version / candidate | 3.7.172 / r20 |
| Product commit | `7413634a8f8095c46f7d28e3de42b3377924045d` |
| Source tree | `49a7f7a3b7678207c745bc0e6fa71e313a0653d8` |
| Package | `SketchUp-PDF-Importer-TEST_v3.7.172_2026-10-17-r20.rbz` |
| SHA-256 | `8488c6aa76347540ba2a5b9a4acfc5e2e562f808fb7d495aff480960c0aa0c10` |
| Files / bytes | 651 / 27,698,210 |

Every archive, extracted and installed member was independently compared with
its exact committed Git blob, using the builder's Ruby newline convention.
Actual Ruby 2.2.4 parsed all 95 shipped Ruby files. All 31 runtime binaries match
r19, and bundled Poppler and relocated Ghostscript smokes passed. The previous
650-file installation was backed up. All 338 currently unrelated plugin files
were preserved byte for byte; this is the actual current inventory, rather than
the earlier historical count of 340. Preferences and original PDFs were unchanged.

The package guide and master package list point to r20; the other host sections
of the master list remain byte-identical. Earlier candidate binaries and build
identities remain available. Original build identities are immutable; native
status is recorded in a separate supplement.

## Native status: import has not run

The first r20 controller stopped at Welcome after Windows denied an atomic
lease-file replacement. Its historical failure remains intact. A bounded sharing
error retry passed independent tests with a real Windows delete-sharing conflict.
A subsequent cancellation exposed a separate process-termination timing race:
zero active Job members did not imply that every retained process handle had
signaled. The private controller now waits for those actual handles. Its real
SketchUp cancellation verified all three retained exits after an additional
15 milliseconds; the earlier incomplete proof was not relabeled as successful.

With the controller stable, Welcome capture worked but click and refreshed Raise
activation failed with `failed to activate captured window`. Opening a fresh,
byte-identical installed stock template through the command line still showed
Welcome. A direct launch through the supported Computer plugin also showed the
same activation failure after its refreshed retry. No session or elevation
mismatch was proven. No Windows security or privacy setting was changed.

No r20 ordinary-menu import, save, Undo, fresh reopen or actual TextureWriter
pixel acceptance has therefore occurred. A manual Start using SketchUp click
and main-window focus are pending. The earlier prepared cases and failure
evidence are distinct, retained under `C:/BlueCollar-Validation/2026-10-17/`.

These source measurements are a regression diagnosis, not native acceptance.
Ordinary import/save/one Undo/fresh reopen and actual TextureWriter decoded
pixels remain required against the final packaged source. The foundation first
Undo failure and newer SketchUp versions remain separate outstanding checks.
No public release has been published.


## Native acceptance update: 2026-10-17, after r5 and foundation r2

The earlier "Native status: import has not run" section records the Oct17 r1-r3
activation/controller attempts. Its NOT_RUN status is historical. Fresh window
selection through the supported Computer controls subsequently recovered
Welcome and ordinary-menu input. No security settings changed; a permanent
Windows connection cause or repair was not established. Earlier failures remain.

The unchanged r20 RBZ was tested at HEAD
`1d2cafdffc1e4d7e3cf964f02e0e28df45bd9814` in SketchUp Make 17.2.2555 /
Ruby 2.2.4. The authored Raster fixture passed ordinary import (4.6 seconds),
Save As, exactly one Edit-menu Undo to the exact empty baseline, normal close
without saving that Undo, and opening/resaving in a separate native process.
All 16 real TextureWriter PNG exports (eight saved, eight reopened) independently
matched original crop pixels, dimensions, persistent image ancestry and
transformed placement. Horizontal, vertical and slanted reference regions
retained all 15,273 visible reference pixels, with zero missing in either stage.

Raw imported/saved and baseline/single-Undo inventories are exactly equal.
Raw saved/fresh-open inventory equality is **false**: exactly 10 session
`entity_id` fields changed; the raw differences remain in the independent
receipt. Persistent IDs, placement and image pixels match. Fresh-open/resaved
inventory is exactly equal. The native roots (PIDs 18196 and 13828) both exited
naturally with code 0; retained handles were signaled and closed.

The foundation drawing was explicitly tested in **3D Text** mode. Import took
147.9 seconds and ordinary Save succeeded. Before Save, Undo named Import PDF
Vectors; after Save, it named Check Validity. Exactly one Undo left the sheet in
place: **single-Undo-to-baseline failed**, and no second Undo was issued. The
exact save graph delta removed 16 loose Edges under PDF Geometry Batch groups
200, 201, 204 and 281 (111,841 to 111,825 entities), added none and changed no
retained entity rows. Each removed Edge had no faces and a bitwise-identical,
same-style surviving duplicate. Six definition GUID fields also changed. This
is a bounded geometric diagnosis, not a complete internal-validity or creation
call-stack proof; the r20 product has no fix for this Save/Undo interaction.

A fresh foundation process opened the retained saved model and saved a new
copy without a repair prompt; it exited normally. The initial forward-slash
filename was rejected by Windows Open, then accepted after correction to a
backslash path; that was a filename-format error, not model repair. Raw
saved/fresh inventory equality remains false; fresh-open/resaved equality is
true. Menu/fresh PIDs 4464 and 14420 both exited naturally with code 0 and
retained handles closed. Import/save and fresh open/resave pass; first Undo
remains a defect requiring a successor candidate and repeat checks.

Evidence: [curated Raster summary](C:/BlueCollar-Test-Builds/2026-10-12/SketchUp-r20-candidate/Evidence/native-raster-2026-10-17-r5/SUMMARY.json),
[paired independent audit](C:/BlueCollar-Validation/Checks/su172-r5-native-paired-audit-20261017-r1/INDEPENDENT-PAIRED-AUDIT.json),
[foundation menu owner](C:/BlueCollar-Validation/2026-10-17/foundation172-ordinary-r2/Evidence/menu-owner.json),
[fresh owner](C:/BlueCollar-Validation/2026-10-17/foundation172-ordinary-r2/Evidence/fresh-owner.json),
and [exact raw graph delta](C:/BlueCollar-Validation/2026-10-17/foundation172-ordinary-r2/Evidence/Offline-save-analysis-r1/EXACT-GRAPH-DELTA.json).
The separate package supplement is
`SketchUp-r20-candidate/NATIVE_ACCEPTANCE_2026-10-17_r5.json`; original build
identities and the earlier native-status file remain unchanged.

These results do not certify other PDFs/modes, general glyph editability,
full-page clipping/paint order or newer SketchUp versions. Foundation first
Undo and the remaining compatibility checks stay open. No public release was
published; r21 is expected to address the demonstrated defect.
