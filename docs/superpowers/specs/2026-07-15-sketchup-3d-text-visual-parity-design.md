# SketchUp 3D Text Visual-Parity Design

Date: 2026-07-15

Status: Approved direction; implementation remains gated on test-first verification.

## Objective

When the user requests **3D Text**, the importer must create native SketchUp
3D Text geometry and preserve the PDF's visible size, run length, baseline,
rotation, and placement as closely as SketchUp permits. It must not change the
requested representation to hide alignment, rotation, or scaling defects.

This design corrects the live SketchUp 2017 failure reproduced with
`1015 - Rev 0.pdf`: all 289 spans were delivered as native 3D Text with no
fallback, but representative runs were 17–42% too wide and 29–46% too tall,
causing BOM, dimension-chain, and title-block collisions.

## Evidence and Root Cause

The existing implementation passes the canonical PDF em size directly to
`Sketchup::Entities#add_3d_text` as `letter_height`. Those values are not
the same metric.

For the Arial family used by 409 of 410 internally parsed runs, SketchUp 2017
normalizes the generated outlines to the font's typographic ascender:

```text
1491 / 2048 = 0.72802734375
```

Live entity measurements match that normalization across flat capitals,
curved capitals, descenders, and punctuation. Passing one full PDF em therefore
inflates matching Arial ink by approximately:

```text
1 / 0.72802734375 - 1 = 37.36%
```

That prediction falls directly within the registered source-versus-SketchUp
height error. The older regression guard correctly stopped bbox-derived
microscopic text, but incorrectly equated a PDF em with SketchUp letter height.

Two additional losses compound the defect:

- generated text is hardcoded to Arial, while the source contains Arial,
  Arial Bold, Arial Narrow, and RomanT;
- the internal parser computes the text matrix's horizontal axis but discards
  its ratio to the vertical axis, losing legitimate PDF horizontal scaling such
  as the 1.436458× Arial Narrow title run.

The existing PDF bbox is useful as a final overflow ceiling, but it is not a
safe source for vertical sizing or unbounded growth.

Primary API references:

- https://ruby.sketchup.com/Sketchup/Entities.html#add_3d_text-instance_method
- https://ruby.sketchup.com/Geom/Transformation.html#method-c-scaling
- https://developer.adobe.com/document-services/docs/assets/35e4369068f86065372c18787171a17e/PDF_ISO_32000-1.pdf

## Considered Approaches

### Selected: font-metric conversion, source X scale, residual shrink

Preserve PDF em size as canonical metadata, convert it once into SketchUp's
letter-height domain, preserve trusted source-font and horizontal-matrix
metadata, then apply only a residual bbox overflow shrink in local X.

This corrects both dimensions while preserving native 3D Text, baseline,
rotation, faces, and Ruby 2.2 compatibility.

### Rejected: width-only bbox shrink

This would improve table containment but leave text 29–46% too tall. Section
labels would become unnaturally tall and condensed, and vertical crowding would
remain.

### Rejected: uniform bbox fitting or representation fallback

Uniform fitting couples width to height and recreates the v3.7.81–v3.7.89
microscopic-text failure. Falling back to Labels, Geometry, or Raster when
native 3D Text is available violates the requested representation contract.

## Behavioral Contract

### Canonical PDF size and SketchUp letter height

```text
pdf_em_height =
  font_size_points / 72 × import_scale

sketchup_letter_height =
  pdf_em_height × font_to_sketchup_letter_ratio
```

The initial supported ratios are:

- Arial, Arial Bold, and Arial Narrow: `1491 / 2048`
  (`0.72802734375`);
- RomanT: `1538 / 2048` (`0.7509765625`) when RomanT is genuinely used;
- unknown or untrusted font metadata: conservative Arial-family default
  `1491 / 2048`, explicitly reported as a default.

The PDF's `/CapHeight 500` in the test document is demonstrably inconsistent
with its embedded outlines and must be rejected. A normalized FontDescriptor
ascent is accepted only in the inclusive range `0.60..0.95`. Per-string bbox
height, digit height, punctuation height, and glyph bounds must never select
the ratio.

The existing hard minimum, hard maximum, Ruby 2.2-safe comparisons, loud
fallback counter, tolerance `0.0`, filled faces, and material behavior remain.

### Source font and text-matrix metadata

Text items gain separate optional metadata for:

- normalized source font family and style;
- trusted horizontal-to-vertical text-matrix scale;
- font-to-SketchUp letter-height ratio and its provenance.

The external extractor marker `font_name == "pdftotext"` remains intact so
existing placement heuristics do not change accidentally. Internal angle/font
hints copy the new source metadata into the external bbox item rather than
overloading `font_name`.

Subset prefixes are removed from source font names. Bold and italic style are
passed through separately. Known no-cost installed fonts are preferred.
Unavailable source fonts use the closest installed substitute and must be
reported; the representation remains native 3D Text.

### Horizontal scaling

Horizontal scaling has two distinct stages:

```text
matrix_x = trusted PDF horizontal-axis / vertical-axis ratio, otherwise 1.0
residual = min(target_bbox_run / width_after_matrix_x, 1.0)
total_x = matrix_x × residual
```

Trusted matrix scaling may grow or shrink because it is explicit source
geometry. The bbox residual may only shrink; it must never manufacture
untrusted growth.

Residual bbox shrink is allowed only when:

- all bbox coordinates are finite and non-degenerate;
- the display angle is near 0° or ±90°, so the along-run bbox axis is known;
- generated width and target width are positive;
- the residual factor is in the inclusive range `0.50..1.00`; smaller
  factors are rejected and reported as outliers rather than clamped.

Arbitrary diagonal spans retain trusted matrix scaling but do not receive
axis-aligned bbox reconciliation until oriented source-run geometry is carried.

### Transform and placement order

The required order is:

```text
generate at corrected letter height
→ apply local-X scaling about ORIGIN
→ translate to the existing insertion point
→ rotate about that insertion point
```

Y and Z scale must remain exactly `1.0`. No uniform post-scale, bbox-derived
Y scale, post-rotation nudge, or speculative baseline translation is allowed.

The existing rotated mesh anchor remains based on the canonical source em
placement policy. It is not multiplied by the letter-height conversion in this
change. Live probes must confirm baseline-relative bounds for flat capitals,
descenders, parentheses, fractions, and ±90° runs before release.

### Failure handling and reporting

If native mesh generation returns false, creates no entities, or throws, the
existing item-level fallback ladder applies and reports the exact reason.

If any scale, translation, or rotation transform fails after native entities
were created, those partial entities must be erased before the fallback rung.
The importer must never leave both a partial mesh and a fallback Label.

The report distinguishes:

- canonical PDF em height;
- requested SketchUp letter height;
- letter-height ratio and provenance;
- trusted matrix-X factor;
- residual bbox shrink;
- fitted, skipped, rejected-outlier, and failed-transform counts;
- requested and delivered representation;
- font substitution and fallback reasons.

## Test-First Implementation

The first production edit is prohibited until the corresponding regression test
has been observed failing for the expected reason.

Focused tests must prove:

1. Arial-family ratio is exactly `1491.0 / 2048.0`.
2. RomanT ratio is exactly `1538.0 / 2048.0`.
3. A 12pt Arial PDF em requests `0.121337890625` inches at scale 1.
4. Bogus `CapHeight 500` is rejected.
5. Digits, punctuation, lowercase, and descenders use font-level metrics, never
   their span bbox height.
6. Trusted matrix X may grow, including the 1.436458× Arial Narrow case.
7. Untrusted bbox width may shrink overflow but may not grow a run.
8. The scale transformation is `[total_x, 1.0, 1.0]`.
9. Transform order is local-X scale, translation, rotation.
10. Horizontal and rotated insertion anchors are unchanged.
11. Faces/material survive the transform.
12. Transform failure erases partial meshes before fallback.
13. Ruby 2.2 compatibility, loud height fallback, and tiny-text protections
    remain green.
14. The old whole-file ban on every `Transformation.scaling` is replaced by
    semantic assertions that forbid uniform or Y scaling.

## Live SketchUp 2017 Acceptance

Release remains blocked until a fresh installed-byte probe verifies:

- requested mode and reported mode are both `text3d`;
- all 289 expected spans are delivered with zero silent fallback;
- PDF em and SketchUp letter-height telemetry are present and plausible;
- SECTION A/B visible width is within 5% and height within 2 registered pixels
  of the PDF source;
- BILL OF MATERIAL, BOM rows, E–E/F–F dimensions, GALVANIZED subtitle, and the
  title block no longer cross their neighboring rules;
- rotated and diagonal spans preserve source angle and baseline;
- no microscopic text, erased faces, duplicate partial mesh, or raster
  substitution appears;
- the installed loader and plugin bytes match the committed release artifact.

The screenshot camera must be registered to the source linework or explicitly
framed to the same sheet bounds so viewport cropping cannot be mistaken for an
import defect.

## Follow-On Work

The host-mode runner and adjacent false-green paths are a separate implementation
unit. After this correction passes live visual acceptance, the next design will
repair the broken `ImportConfig.auto` call, explicit mode selection, result
JSON, model saving, page-failure detection, Raster multi-page/report behavior,
SVG zero/partial delivery reporting, and the full Geometry/Glyphs/Labels/3D
Text/Raster host matrix.

Q&A authority and archival are updated only after both the native 3D Text
acceptance and host-mode verification are complete. Historical evidence is
retained, while superseded instructions that could restore uniform bbox fitting
or representation switching are removed from current guidance.
