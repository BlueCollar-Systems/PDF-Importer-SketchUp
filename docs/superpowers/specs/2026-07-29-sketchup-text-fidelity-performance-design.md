# SketchUp Text Fidelity and Exact 3D Text Performance Design

**Status:** Approved for implementation
**Approved:** 2026-07-29
**Scope:** `C:\1PDF-Importer-SketchUp`
**Reference PDF:** `C:\Users\Rowdy Payton\Desktop\PDFTest Files\1011 (1 OF 2) - Rev 0.pdf`
**Reference PDF SHA-256:** `e84a16bd2243277a523320aa276ce1207c2b80722e964b73e801200846eb4d94`

## 1. Outcome

SketchUp must preserve the PDF renderer's exact source glyph outlines, placement,
rotation, scale, color, and positive 3D depth while avoiding repeated construction
of identical glyph solids. Text mode must keep horizontal text as native SketchUp
Labels and must deliver source-rotated text through the certified
Labels-to-3D-Text fallback with the same authoritative full-page glyph matching
used by direct 3D Text.

The foreground remains unchanged: the user selects Text or 3D Text and imports.
All matching, reuse, verification, fallback evidence, and performance telemetry
remain automatic.

## 2. Measured Problem

The reference PDF establishes two baselines on SketchUp Make 2017:

- Direct 3D Text delivered 813 semantic text spans from 4,280 physical SVG glyph
  placements in 400.5 seconds. Visual fidelity was excellent.
- Text delivered 813 semantic spans in 131.3 seconds: 657 native Labels and 156
  exact source-glyph 3D Text fallbacks. The rotated fallback fragments showed
  visible alignment and composition defects.
- The SVG contains 413 unique glyph definitions for 4,280 placements, a reuse
  ratio of approximately 10.4 placements per definition on this page.

### 2.1 Direct 3D Text root cause

`Svg3DTextRenderer` parses reusable SVG definitions, but currently constructs
SketchUp faces and performs extrusion again for every placed occurrence. It also
performs construction-safety work for each occurrence. The resulting cost scales
with physical placements and contour complexity instead of unique source solids.

The existing bucketed duplicate-point check is a useful complementary
optimization, but it does not eliminate repeated `add_face` and `pushpull`
operations.

### 2.2 Text rotation/alignment root cause

SketchUp has no distinct flat editable model Text entity, so Text correctly
advances item-by-item to Labels. Native `Sketchup::Text` Labels cannot rotate
their glyphs. A nonzero source rotation is therefore affirmative host
impossibility for the Labels rung and must advance that item to exact 3D Text.

The direct 3D Text path matches all 813 semantic spans against the complete SVG
placement inventory. The Text fallback path renders only the 156 rotated target
spans and currently recomputes matching against that subset while retaining the
complete SVG inventory. Fragmented engineering notation, stacked fractions, and
nearby dimension strings can consequently receive a different placement
partition than they receive in the successful full-page direct 3D Text import.

Rendering a rotated source item as an unrotated native Label is not an acceptable
fix. It changes the source representation without advancing the certified
fallback ladder and preserves the visual defect.

## 3. Non-Negotiable Contracts

1. The representation ladder remains:
   Text -> Labels -> 3D Text -> Glyphs -> Geometry -> item Raster.
2. Every rung change is item-scoped and requires affirmative impossibility
   evidence. Generic failure cannot authorize a fallback.
3. Direct 3D Text and Labels-to-3D-Text fallback use exact renderer SVG outlines.
   Host-font substitution is prohibited.
4. A source-rotated span cannot be recorded as a completed native Label unless
   the resulting glyph rotation is independently verified.
5. Horizontal Text items remain native Labels when their placement is verified.
6. Reuse cannot alter source outline points, fill rule, winding, holes, placement,
   affine transform, paint, source identity, or extrusion depth.
7. No lossy contour simplification or arbitrary visual-tolerance culling is part
   of this design.
8. Failure after entity creation is atomic: all owned groups, instances, and
   newly created unused definitions are removed or the model operation is
   aborted.
9. Ruby 2.2.4 and SketchUp Make 2017 remain supported.

## 4. Selected Design

### 4.1 One authoritative full-page match

Extend `Svg3DTextRenderer.render_svg` so matching input and rendering input are
separate:

- `text_items` is the target set to render.
- `match_text_items` is the authoritative semantic inventory used by
  `CairoGlyphSource.match_spans`.
- When `match_text_items` is omitted, it defaults to `text_items`, preserving the
  direct 3D Text call contract.

The renderer matches the complete page once, validates that a placement is not
assigned to multiple semantic spans, then filters the authoritative match to the
requested target source IDs. Text mode passes all page text items as
`match_text_items` and only rotation-failed Label items as `text_items`.

Unmatched source placements are not materialized during a partial fallback
render. Match evidence records both the authoritative inventory and the rendered
subset so that a partial result cannot masquerade as a full-page match.

### 4.2 Exact source-solid definition cache

Introduce an import-scoped exact-solid cache owned by the 3D Text renderer. A
cache key contains every value that can change physical geometry:

- a digest of the exact source glyph outline and fill rule;
- the placement-independent affine linear transform, including mirror or shear;
- resolved positive extrusion depth;
- any construction transform required to overcome host precision limits; and
- resolved paint when SketchUp material inheritance cannot prove that paint can
  remain instance-scoped.

Translation is excluded from the key. Geometry is constructed at a stable local
origin inside a SketchUp component definition. Each physical occurrence becomes
a lightweight component instance with the exact source translation/placement
transform.

Semantic ownership remains item-scoped. Each source-span group contains the
instances assigned to that span, retains the source-span identity attributes,
and remains the entity referenced by terminal representation evidence.

Cache lifetime is one page/import operation. It must not leak state between PDFs,
pages, models, or retries. Failed entries are never retained.

### 4.3 Evidence and verification

The optimized path must preserve the current evidence contract:

- source glyph identity;
- exact source-to-instance placement binding;
- expected and actual transformed bounds;
- source rotation;
- width and height;
- positive Z depth and extruded face existence;
- physical style and paint;
- top-level semantic group ownership; and
- save/reopen persistence.

Definition identity and instance transforms are added to evidence. Verification
must inspect physical geometry through instances rather than assuming an
instance is correct because its definition exists.

### 4.4 Performance telemetry

Record, per page:

- SVG extraction/parse time;
- semantic match time;
- unique solid-definition build time;
- instance placement time;
- evidence verification time;
- unique cache keys;
- definition builds;
- cache hits and misses;
- physical glyph placements;
- semantic spans; and
- rendered fallback subset size.

The implementation must prove that face/extrusion construction count scales with
unique cache keys, not placement count.

## 5. Rejected Alternatives

### 5.1 Optimize only the duplicate-point scan

This reduces one quadratic hotspot but leaves thousands of repeated face and
extrusion builds. It does not resolve Text alignment.

### 5.2 Keep subset-only matching and adjust angles or anchors heuristically

The direct 3D Text result proves that the full-page source matching already has
the required placement information. Angle or anchor heuristics would create a
second visual authority and would remain fragile around fractions, shaped text,
and adjacent dimension strings.

### 5.3 Keep rotated Text as unrotated native Labels

SketchUp Labels cannot represent the requested rotation. Recording them as
complete would violate the fallback contract and leave the visible defect.

### 5.4 Rasterize rotated text

Raster is terminal and requires affirmative impossibility at every preceding
rung. It would sacrifice editability and exact vector/3D output even though exact
source outlines are available.

### 5.5 Simplify source contours by visual tolerance

This can reduce geometry but changes the source outline and undermines the
exactness claim. It is outside this design unless a future contract defines and
proves a lossless host-equivalence transform.

## 6. Test-First Implementation

Before production changes, add failing tests for:

1. A repeated glyph constructs one exact solid definition and places multiple
   instances with distinct exact translations.
2. Cache keys separate different affine linear transforms, extrusion depths,
   fill rules, and geometry-affecting paint cases.
3. Source holes, winding, paint, dimensions, rotation, and positive depth survive
   definition reuse.
4. A partial target set uses the full semantic inventory for matching and
   receives the same placement indices as a full-page render.
5. Horizontal Text completes as native Labels.
6. Rotated Text records Text-to-Labels and Labels-to-3D-Text transitions and uses
   exact source-outline 3D Text.
7. Rotated Text is never accepted as an unrotated native Label.
8. Malformed source geometry, host creation failure, and evidence failure clean
   every owned entity and unused definition.
9. Save/reopen verification retains instance geometry, transforms, identity, and
   evidence.
10. Ruby 2.0/2.2 syntax and compatibility gates remain green.

The reference PDF is the real-host acceptance fixture after the focused tests
pass.

## 7. Acceptance and Release Gates

### 7.1 Fidelity

- Direct 3D Text is visually equal to or better than the accepted 3D reference.
- Text mode aligns rotated dimensions, stacked fractions, part marks, and
  annotations with the Acrobat source and the direct 3D Text result.
- No rotated item is silently flattened.
- Source glyph, placement, color, depth, entity ownership, and fallback evidence
  gates pass before and after save/reopen.
- No item Raster or page Raster is introduced when exact SVG geometry succeeds.

### 7.2 Performance

For the reference PDF on the current machine:

- Direct 3D Text must be at least 2x faster than the 400.5-second baseline; 3x or
  better is the target.
- The exact 3D fallback phase in Text mode must be at least 2x faster for the
  same rotated target set.
- Full Text mode must not regress from the 131.3-second measured baseline.
- Definition builds must be no greater than unique geometry cache keys and must
  be materially lower than physical glyph placements on repeated-glyph pages.

The algorithmic construction-count gate is mandatory because it protects older
hardware even when wall-clock measurements vary with CPU, memory, and host state.

### 7.3 Delivery

After all focused and repository-wide tests pass:

1. Build the RBZ through the normal release pipeline.
2. Verify the shipped archive bytes and syntax.
3. Install the exact verified artifact into SketchUp Make 2017.
4. Restart the host and repeat Text and 3D Text acceptance imports.
5. Save/reopen the resulting SKP files and verify evidence.
6. Commit, tag, and push only the tested source and artifact state.
