# White-area refinement and final-annotation height, October 18, 2026

## Completed v3.7.178 host checks

The r27 archive was built from commit `434f2039328d83c85b8a31f73795c04141a91d30`,
SHA-256 `1882e6f83a393bc9d8b34b56053e962df51529ec0a11fa0946002e5f03e085a1`.
The foundation PDF SHA-256 remained
`563ed39b60518ffe34844cd142063678d51e8f675396f6b968d478e81483d6cd`.
All tests used installed SketchUp Make 2017, version 17.2.2555 / Ruby 2.2.4.

- **Glyphs failed:** the import did not return before the existing 1,800-second
  guided-stage deadline. Only the test's owned process tree was cleaned up.
  There was no completed import, saved model, Undo or fresh-open acceptance.
  This failure is retained and r27 was not promoted to the test launcher.
- **3D Text lifecycle passed:** ordinary-menu import completed in 164.7 seconds,
  followed by Save As, exactly one Edit Undo, normal close, fresh ordinary Open,
  separate Save As and normal close. No repair prompt appeared. Both owners
  completed naturally with exit zero. The single-Undo observation interval was
  220.121 seconds, including read-only observers and UI/tool round trips; it is
  not a precise operation benchmark.
- All 291 source spans were accounted for: 286 physical source-outline text
  owners and five independently verified blank spans. No text step-down was
  reported. Complete graph captures contained 111,825 unique entities and 7,832
  collections, within the unchanged limits; both same-process Save comparisons
  retained the exposed geometry and definition census.
- Independent native-loop checks found positive 1/64-inch depth, top and bottom
  caps, side walls and two-Face incidence on each expanded text Edge for all
  286 source-bound owners. These are finite topology observations, not a general
  manifold/closed-volume or original-glyph-outline certificate.
- All 16 final annotations retained original-PDF XY, paint, opacity and order
  across imported, saved, reopened and resaved captures. Their measured heights
  ranged from 0.016625 to 0.031625 inches, above the measured 0.015625-inch text top.

Strict cross-process numeric equality did **not** pass. The raw differences and
original rejection remain. A separate classification found only session identity
changes and selected recomputed native Face measurements: 359 areas differed by
at most four ULPs; 698 normal and 1,062 plane components differed by at most two
ULPs. Sixty-six signed-zero changes also remain in the raw 16-value transforms.
Other selected loop coordinates, topology, bounds, paint and attributes compared
exactly as parsed values. This scoped result must not become an omnibus strict
persistence or whole-PDF/image-pixel acceptance claim.

## v3.7.179 repair

The preceding continuation candidate exceeded the bounded foundation test; its
buffered log did not establish the exact stalled phase. The new candidate removes
measured repeated classification and temporary construction work while retaining
the existing limits and failure reporting:

1. Sweeping complete original contours with exact Rational vertical crossings
   once per slab, preserving holes, union semantics, source owner, coincident
   crossings and the existing predicate charges. Half-open source intervals also
   handle original vertices outside the clipped arrangement.
2. Constructing only the nonempty retained white subset. The complete exact
   partition still enters clearance and frame checks. Every emitted native Face
   retains its boundary check and must match the exact recursive Face roster,
   white classification and retained area. Original-ink coverage, source
   ownership, style, cancellation and rollback checks remain. Fully ink-covered
   masks retain the previous full native construction route.
3. Labelling removed-area telemetry as `exact_source_partition`, rather than
   implying that omitted temporary ink Faces were measured in the host.
4. Flushing sparse attempt/outcome and sampled checkpoint diagnostics. Logging
   changes neither controller arguments, return values nor terminal exceptions.
   A blocked native call cannot emit progress until it returns.

The bounded historical 18-Face source-kernel probe produced literally identical
ordered Rational cells, classes and areas in both partition directions. The
original direction retained 1,064 cells (550 white, 514 ink); the quarter-turn
retained 1,023 (505 white, 518 ink). Four fixed Ruby 2.2 runs measured source CPU
2.875 to 2.000 seconds and 12.578 to 6.157 seconds respectively. These are
source-kernel measurements, not native-import speed ratios.

The separately reviewed disjoint shortcut was excluded: only four of 260 old
geometric bounding-box candidates were proven disjoint in its bounded probe,
which did not establish a remedy for the dense overlapping workload.

All 34 required actual-repository runs passed: 17 suites on actual Ruby 2.2.4
with official Minitest 5.4.3 and actual Ruby 3.4.4 with Minitest 5.25.4. No run
skipped or timed out; the source, tests and README remained unchanged through the
matrix. The result receipt SHA-256 is
`0259cf2a9026588cbac540ad80dc69d9309d37271cc3103eaff7f2222fcd50d9`.

Native v3.7.179 import/save/Undo/reopen and source-footprint acceptance remain
pending. Prior failures, packages, original PDFs and saved models are preserved.

## Completed v3.7.179 host checks

The r28 candidate was built from `57b011f3a03782c39f4c5e51e28d9c4282a05ee3`;
its RBZ SHA-256 is
`8a355e0d12d7c08841e67119bc7601f465cef049dfbdd31448b37037a7b550c4`.
The ordinary foundation Glyphs import again exceeded the unchanged 1,800-second
stage limit. The log recorded 260 eligible attempts: 254 composed, four exact
no-ink outcomes and two restored failures. Composition alone took 1,474.389
seconds. There was no completed import, Save, Undo or fresh-open acceptance.
The last picture-clip warning does not establish the cause of the remaining delay.

The separate 3D Text import completed in 160.5 seconds, with ordinary Save As,
one Undo to an empty root, fresh Open without repair and a separate Save As.
Both test processes exited naturally with zero. All 291 spans were accounted for
(286 positive-depth owners and five verified blanks), and all 16 final
annotations retained their source placement, paint, order and height above the
measured 1/64-inch text depth across the four captures.

The strict cross-process numeric comparison still failed. The original rejection
and raw differences remain: 2,119 host-derived area/normal/plane scalar changes,
at most four ULPs, and 66 signed-zero raw transform changes. A separate scoped
classification found no other selected primary geometry/style differences. This
is not strict raw identity, whole-PDF appearance, native-image pixel, independently
exact glyph-outline, manifold or volume acceptance. The r28 package was not
promoted; its added dated guide and acceptance supplement preserve these limits.

Its report also showed zero warnings despite retaining a source-picture clipping
qualification failure in `extra.embedded_image_paint_order`. This reporting gap
is addressed below; the picture's clipping itself is not declared fixed.

## v3.7.180 bulk construction and warning repair

For a single source-white owner with retained cells, the importer may construct
those cells with PolygonMesh in one empty child of the verified construction
frame. Exact source partition, all-cell clearance, frame, source class/area,
coverage and style checks remain. Each native Face must match one exact cell;
actual native Edges must match its Face-loop boundaries and adjacency. Merged,
split, missing or changed cells are rejected, including tiny cells below the
aggregate area tolerance. Unsupported APIs and other source-owner cases retain
the isolated construction path.

A rejected mesh can retry isolated construction only after its owned child is
removed and the original roster, visibility and empty frame are read back
unchanged. Cancellation, changed resume data and uncertain cleanup never retry.
Original editable fills are hidden only after the shared final checks pass.

A private SketchUp 2017 sample built all 505 retained white cells with 1,568 Edges
and 1,067 Vertices, including 435 Edges shared by two Faces. Ordinary Save As,
one Undo to an empty root, fresh Open without repair and resave passed. Four
read-only captures matched the source cell/world loops, native adjacency and
styles. Cross-process persistent geometry matched; 7,212 session/reference ID
changes remain in the strict raw comparison, with no derived scalar changes.
The independent pair receipt SHA-256 is
`1721b311bc97faf0d300d26a9e4b0857859868333400f9aaf88a04c5b2db3088`.
This finite historical-coordinate sample is not a fresh PDF import or full
product acceptance. The actual importer adds an identity staging child, so the
new package still requires its own ordinary foundation lifecycle checks.

QA now counts deduplicated picture-display qualification warnings and presents a
plain-language clipping/overlap caution in its summary and Import Health. Exact
image identities and reasons stay in the detailed report. This does not alter
text modes, delivery status or image geometry. The white-area warning's doubled
period is also corrected.

All 34 actual-repository required/affected runs passed: 17 suites on verified
Ruby 2.2.4 with official Minitest 5.4.3 and Ruby 3.4.4 with Minitest 5.25.4.
There were no failures, errors, skips or timeouts, and all snapshotted source,
tests and README bytes stayed unchanged. QA had 60 tests / 431 assertions on each
runtime; the white-area suite had 113 tests / 5,177 assertions. The result receipt
SHA-256 is
`04f76104be742646c175b8fc3bd0db04b0ac28c8a4ad7087a81b178a52dca031`.

Native v3.7.180 package acceptance is recorded separately after the exact build.
Original PDFs, saved models, older packages and negative evidence are retained.
