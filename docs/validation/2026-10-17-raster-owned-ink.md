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
verified all eight original-page crops. Full report-suite execution is tracked
separately from these source/rendering checks.

These source measurements are a regression diagnosis, not native acceptance.
Ordinary import/save/one Undo/fresh reopen and actual TextureWriter decoded
pixels remain required against the final packaged source. The foundation first
Undo failure and newer SketchUp versions remain separate outstanding checks.
No public release has been published.
