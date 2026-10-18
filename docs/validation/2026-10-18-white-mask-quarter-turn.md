# SketchUp 2017 exact white-area repair: v3.7.177

The r26 foundation Glyphs candidate completed ordinary import, Save As, one
Undo, fresh-process Open and a separate resave. The selected white area now
matches the source ink subtraction and all 16 final annotations retain their
height through saving and reopening. A later mask reaches the unchanged cell
budget, so whole-page white-area composition is not accepted by these results.

## Tested candidate

| Identity | Value |
|---|---|
| Source commit | `2cebfb3b03fc62818fa4ac1040c474bc1e1b80e1` |
| Source tree | `14a9aca1c63b1841fe9aa5c116422940614502c4` |
| RBZ SHA256 | `43be0d75fd53bda4a6988e97e92c642ac7b6e55121a2c13f96e6724f17edc250` |
| Archive bytes / members | 27,710,024 / 651 |
| Ruby 2.2.4 source parses / unchanged bundled runtime files | 95 / 31 |
| Menu / fresh native process | 26020 / 26136, both natural exit 0 |

All 28 source test runs passed on actual Ruby 2.2.4 with official Minitest 5.4.3
and Ruby 3.4.4 with default Minitest 5.25.4. The planar suite passed 72 tests and
4,376 assertions on each runtime. Both parent and nested Ruby/dependency paths
were verified, and source/test bytes were unchanged during testing. All 11
GitHub checks passed for the tested commit. These checks apply to r26, not the
subsequent local continuation repair.

## Exact alternate partition

The former failing white mask's ordinary partition contained artificial cells
only one floating-point step wide. The repair permits one exact quarter-turn
partition when the original uniform construction scale exceeds its existing
limit. It inversely maps every Rational cell to the original coordinates and
checks exact signed and classified areas before the existing native geometry,
coverage, style and rollback checks. Source contours, construction limits,
tolerances and text representation are unchanged.

The source replay produced 1,023 cells: 505 retained white cells and 518 ink cells.
The actual saved model contains 505 visible white Faces and 2,003 hidden Edges.
The original editable white Face remains hidden with literally unchanged loops.
Independent comparison with the original source region measured boundary
difference `1.4238583e-14` inches. Shapely/GEOS measured zero symmetric-difference
area and zero white-over-bound-ink area; these are numerical measurements, not
an assertion of exact mathematical set equality. All 18 source glyph Faces
remain literally unchanged.
The separate black target correctly remains unchanged because its filled region
has zero intersection with the later bbox-overlapping glyph.

These results repeat across imported, saved, fresh-loaded and fresh-resaved
captures. Cairo quantization is retained explicitly; literal equality with
quantized Cairo coordinates is not substituted for the source/native proof.

## Lifecycle, height and remaining limits

Import took 512.3 seconds in this guided run. The report accounts for 291 source
spans: 286 direct Glyphs deliveries and five verified blank spans, with no text
fallback or lost text. One ordinary Edit Undo returned to the empty baseline.
Fresh Open required no repair prompt. All 16 final marks retain source XY,
opacity and order, with actual native heights `.001` through `.016` inches above
the flat Glyphs roots at Z=0. The measured source boundary difference is at most
`7.9441e-15` inches. Positive-depth 3D Text on the next candidate is pending.

The later warning is `exact planar partition cell budget exceeded`. Earlier
successful mask changes remain in this model; the current implementation cleans
up the failing mask locally and stops later masks. A missing composition result
in report telemetry is not evidence that earlier successful geometry was undone.
The independent census finds 25 reachable composed groups, so a page-wide
rollback explanation is incorrect.

Full graph diagnostics exceeded the unchanged 8,192-collection limit. The
separate count-only census finds 16,426 definitions: 16,425 reachable through
Groups/ComponentInstances and one native Image whose reachability is outside
that census. No definitions are empty or have zero declared instances; the
roster is literally equal within each Save. This does not prove unused-definition
leakage or a zero-change full graph. Selected physical geometry does persist;
raw session-ID differences remain separately recorded.

Whole-page pixels, embedded image pixels, complete deep-mesh continuity, other
PDFs/modes/hosts and the later masks remain outside acceptance. An existing
embedded-image paint-order warning also remains. No release was published.

## Private evidence bindings

Paths are relative to `C:/BlueCollar-Validation/`. Original PDFs and failed
diagnostics are preserved outside Git.

| Receipt | SHA256 |
|---|---|
| `Checks/su177-actualrepo-mask-annotation-required-20261017-r1/RESULTS.json` | `53a3167bf88222e22a3614c20755212f63b2904a5b0c6a8064437759d73a5fb7` |
| `Checks/su177-r26-independent-postbuild-20261017-r1/INDEPENDENT-POSTBUILD.json` | `9b1282d79992dbd02ebb6463f1d16df36ee0661780e8e9ad014cdbd0f7f33499` |
| `2026-10-17/foundation177-r26-glyphs-r1/Evidence/offline-review-r1/PAIR-REVIEW.json` | `8756ec4b16b74c4a7d9d29bc045f84e433069cd346eb506ea7001e77847d334c` |
| Same case, `Evidence/independent-source-footprints-r1/SOURCE-PHYSICAL-PAIR-REVIEW.json` | `ac5a559a6218513935fdad2e61701620e2c943d354571d3aebc2205213ea76a2` |

The build's original PENDING metadata remains immutable. These dated r26 results
do not certify a later candidate or rewrite earlier evidence.
