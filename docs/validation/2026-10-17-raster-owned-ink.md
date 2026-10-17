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
