# v3.7.181 source improvements — native acceptance pending

This test candidate follows v3.7.180. Its native lifecycle and selected geometry
results remain historical results for that version; they do not certify181.
No release is authorized by this document.

## Exact partition work

The partitioner now charges its existing operation budget for the scans,
comparisons, interval classifications and cell construction it actually does.
The old estimate charged every source edge for each slab gap even after the
event sweep had already classified those intervals. Maximal vertical runs now
construct one exact rational cell, retaining the independent exact-area check.
The existing input, atom, slab and held-cell limits, checkpoint exception
behavior, source selection and construction-clearance checks remain.

Both real Ruby2.2.4 and3.4.4 passed28tests/3273assertions. A separate26-fixture
differential probe retained literal ordered exact-cell equality with the old
partitioner, including tiny slivers, counters, crossings and paint owners.
One authored nested fixture reduced exact-cell construction calls from97to5
while retaining all51interval classifications. This is evidence of removed
repeated work, not a native import timing or proof that the two remaining fills
can pass the unchanged clearance checks.

## Picture source query

An unrelated nonrectangular clip prevented qualification of a picture elsewhere
on the page. The traversal can now skip that clip only when bounded exact path
control-point bounds prove strict disjointness in its supported source frame.
Unknown/reference/nested frames and touching or overlapping clips retain the
existing qualification checks.

Two later round-capped single-segment lines also had overly broad miter bounds.
Such a line has no join. For a fully known style and supported diagonal affine
matrix, exact endpoint bounds plus the transformed round-cap radius prove its
support box. That tighter box is used only to prove strict query disjointness;
the old conservative bounds are retained in evidence. Unsupported path syntax,
style, frame, cap, transform and overlap cases retain the old checks.

Both runtimes passed65tests/281assertions. Replaying the exact retained source
SVG in Ruby2.2.4 qualifies the picture query with36057paint events and two exact
disjoint-line witnesses. Its decoded source image remains401x251 with the
same canonical RGBA digest. No later overlapping source paint was found.
This replay does not read a current native SketchUp image or apply a display
plan. Native placement, display ordering, TextureWriter pixels and persistence
must be tested independently.

## Combined repository checks

The actual applied repository passed23suite files on each runtime:46successful
runs, with no reported failure, error, skip or timeout. These include the four
contributor-required suites, white-mask coverage/control/progress, exact
partition/performance, paint binding/order, image clipping/placement/affine,
decorative/item-raster display, report and version checks. Parent and nested
Ruby selection and the expected Minitest versions were verified. Each ordinary
suite retained its60-second deadline; the report suite retained180seconds.
Source/test snapshots and application pins remained unchanged during the run.

The local result receipt is retained outside the repository with SHA-256
`f125dc70a7e9f60a6369bdedfcca0031f09f9fcb77d7eaeda18a0a39a96cabbc`.
Private PDFs, saved models and generated native evidence are not committed.

## Remaining host checks

The private read-only inspection of the retained180model never passed Welcome.
The Computer plugin's normal click and supported window recovery both returned
`failed to activate captured window`. Its unchanged1800-second guided stage
expired; owned process cleanup was verified with exit124, not a natural pass.
No model was opened or captured. Source, installed payload, original/private
inputs and the180archive were unchanged, and the owned leases were released.

Still required on the exact181package:

- Capture the two actual Glyphs fill inputs; verify complete source coverage,
  native boundaries and unchanged clearance/rollback behavior.
- Export the real Image through TextureWriter, decode its pixels, bind the
  correct source occurrence and verify full native placement transforms.
- Ordinary import, Save As, one Undo, fresh Open and resave in SketchUp2017,
  with source-bound annotation height and picture display checks in both modes.
- Keep previous full-Glyphs diagnostic-cap and strict3Dreopen numeric failures
  visible. An authored source pass cannot replace either failed result.

The181archive is a private test candidate. Keep the180package, original PDFs
and existing saved models; test saves use new names. Public release remains held.
