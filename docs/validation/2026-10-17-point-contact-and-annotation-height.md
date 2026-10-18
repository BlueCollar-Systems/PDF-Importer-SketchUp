# SketchUp 2017 point-contact paint and annotation height: v3.7.176

The exact r25 candidate completed ordinary foundation-sheet Glyphs import,
Save As, one Undo to the empty baseline, fresh-process Open/resave and normal
closure. The former point-contact source-binding and final-annotation height
warnings are absent. One different white-area construction-scale warning remains;
whole-page white-mask composition is therefore **not accepted**. No release or
delivery-guide promotion follows from this scoped result.

## Candidate and source checks

| Identity/check | Value |
|---|---|
| Source commit | `f03ff46de0522608df3f07a4e74843be1ca65dc2` |
| Source tree | `a3df47a7cf24b086350cf4000d98b5db5a5b5dd8` |
| RBZ SHA256 | `72cec90fbcc4656cc4ef32c1a4cdde6a63eef03e5ae17910112509ddbbac5c47` |
| Bytes / members | 27,709,610 / 651 |
| Actual Ruby 2.2.4 parses / bundled runtime files | 95 / 31 unchanged |
| Independent archive/install comparison | Exact 651-member source/archive/install match; 313 unrelated plugin files preserved |

All 24 actual-repository test runs passed: twelve suites on each of Ruby
2.2.4/official Minitest 5.4.3 and Ruby 3.4.4/default Minitest 5.25.4. These include
boundary 15 tests/42 assertions, paint binding 30/70, composition control 12/185,
late overlays 10/71, keep-page behavior 19/162, SVG paint order 24/146, planar
composition 66/4,321 and covered clipping 13/67, alongside smoke, compatibility,
Import Health and mode invariants. Source/test bytes stayed unchanged during the
matrix. The exact commit's 11 GitHub checks also succeeded, as read by the root
reviewer from [PR 111 checks](https://github.com/BlueCollar-Systems/PDF-Importer-SketchUp/pull/111/checks).
This is the tested r25 head, not acceptance for a subsequent repair.

## Point-contact binding repair

The old warning at original paint order `[0,2413620]` involved a black opaque
clipped fill in the shared white-area stage. Original parser, exact Cairo SVG and
retained native geometry all retain one ten-vertex contour and six small
triangles. Adjacent triangles meet exactly at vertices. The former conservative
cycle tracer rejected their multiple incoming/outgoing edges.

Only `SvgPaintBinding` now opts into bounded exact point-contact tracing after
ordinary tracing fails. Existing Rational atomic-edge and filled-side predicates
remain. Alternating angular incidence must yield unique cycles; proper crossings,
interior segment contacts, coincident rays, open/repeated cycles and unresolved
pairing remain unqualified. Other callers keep the strict default. Component
count, whole directed-boundary coverage, source style, opacity, occurrence/order
guards and the existing binding tolerance are unchanged. No source/native
coordinates, geometry or requested representation are changed by this repair.

The retained target replay passed on both Ruby versions: strict tracing still
rejects; the opt-in produces seven uniquely corresponding native/source cycles
and selects the actual SVG occurrence at offset 7,747,706. Wrong color, an extra
same-shape occurrence, and a missing middle triangle with unchanged overall
bounds remain unbound. The private PDF, SVG and geometry are not included here.

## Independent annotation context

The importer now collects valid native source roots and finite text height
independently of white-mask source matching. Reused context must belong to the
same page group and valid roots. Normal composition reuses its verified crops;
when mask composition fails, a cancellable read-only scan recovers verified crop
footprints without discarding the independently measured text height. Missing or
invalid height/roots/crops still produce an explicit step-down. No mode routing
or source-geometry deletion is introduced.

## Completed r25 native observations

Both native roots exited normally: menu PID 14752 and fresh PID 28896. Import took
295.7 seconds in this guided run, not a general hardware benchmark. The report
accounts for all 291 spans: 286 direct Glyphs deliveries and five verified blank
spans, with no text fallback or lost text. Actual page fallback remains true with
one reported page step-down:

> exact white-mask construction scale budget exceeded;
> white_bbox=[4.1716667,32.33,6.3783333,32.525]; ink_faces=18;
> spans=text_span:1:23

Ordinary Save/one-Undo/fresh Open/resave succeeded without a repair prompt. The
lightweight saved/fresh inventories preserve 28 literal session-ID differences;
fresh loaded/resaved inventory and transaction observations are literally equal.
The targeted selected geometry, styling and world loops persist across the pair;
raw capture/identity differences remain in the receipts.

**Full Save-graph comparison is unavailable.** Both stages exceeded the unchanged
8,192-unique-collection diagnostic limit. Watchers were not armed, and neither a
zero-change full Save graph nor an unused-definition cause is claimed. These were
subsecond collection-limit failures, not 60-second native timeouts.

Independent comparison of all four completed composition captures proves the
following finite source facts:

- The original target's seven Faces/28 Edges remain visible, black, opaque and
  texture-free, with world loops literally equal to the previously source-bound
  native target. It has zero filled-region intersection with the only later
  bbox-overlapping glyph, placement 789, in both Cairo source and native geometry.
  Subtraction leaves this particular target unchanged. The capture contains zero
  composed-target regions. Source review establishes that earlier successful
  mask changes remain while a failing mask stops later processing; the zero
  target count alone does not establish why that target was unprocessed or prove
  whole-page composition.
- Cairo's target coordinates are quantized relative to original/native paths:
  measured boundary distance is `3.529641349429487e-5` inches and symmetric area
  difference is `1.0479832871710397e-5` square inches in every capture. Literal
  Cairo/native region equality is false. The boundary distance is within the
  existing `1/(72*128)`-inch binding tolerance; no new tolerance or geometry repair
  is used. A new, overly strict literal-coordinate diagnostic failed and is
  preserved rather than represented as successful source equality.
- All 16 final rectangles independently match the original PDF operators' XY,
  fill/stroke colors, opacity and paint rank. Their maximum measured boundary
  difference is `7.944109290391274e-15` inches. Actual native Face heights run from
  `.001` through `.016` inches above the 286 flat Glyphs roots at Z=0, and persist
  through save/reopen. This establishes final-mark height for this Glyphs case.

Positive-height 3D Text annotation testing on the next candidate remains pending.
Older r24 warnings and r23 3D findings retain their original candidate identities.
Whole-page pixels, native image pixels, complete deep-mesh continuity, other
PDFs/modes/hosts and exact source-outline equality remain outside these results.

## Bound private receipts

All paths below are local validation evidence; original reports and failed
diagnostics remain unchanged.

| Receipt | SHA256 |
|---|---|
| `Checks/su176-actualrepo-mask-annotation-required-20261017-r2/RESULTS.json` | `93b368f48d97b2a9eff9cca131416bc993fa14d015ba0bc842d4ded59e5a4409` |
| `Checks/su176-r25-independent-postbuild-20261017-r1/INDEPENDENT-POSTBUILD.json` | `9f78c1da53509b43d9a5c8a75729af86458062c0a12c87790c36ca7c30b27457` |
| `2026-10-17/white-mask-foundation-diagnosis-r1/ACTUAL-REPLAY-RUBY224.json` | `fe9214c96323ec9f1c73ce10dad74f62611ec49235cbc1830c04a49779fe5463` |
| Same directory, `ACTUAL-REPLAY-RUBY344.json` | `bf20586fa0f69f52b5997f69cacd4da3b8b1bde037526ced2113cb2d52ae1102` |
| `2026-10-17/foundation176-r25-glyphs-r1/Evidence/offline-review-r2/PAIR-REVIEW.json` | `3dc67532a54fca6f2e6ef182bcb6252f20ca2e82b52f8562f62fb5dfc9ced8f6` |
| Same case, `Evidence/independent-source-footprints-r1/SOURCE-PHYSICAL-PAIR-REVIEW-r2.json` | `0bcbf8be16bb630887800661f5377a79e8b4797832890315ab8f1110ed701971` |

Receipt paths are relative to `C:/BlueCollar-Validation/`. The completed build's
original PENDING native-acceptance metadata remains historical; these dated
observations do not rewrite it. The remaining scale-budget failure is retained
for the next focused repair, and no release was published.
