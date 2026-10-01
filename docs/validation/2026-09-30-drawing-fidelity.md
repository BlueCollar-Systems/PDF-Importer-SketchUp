# Drawing fidelity and saved-view validation

The importer clips source glyph contours to the visible page before creating their requested vector representation. Visible glyph placements without a reliable semantic-text match retain their source glyph and placement identity; the importer does not invent characters for them. Glyphs, Geometry, and 3D Text keep their requested representation.

Source-ordered opaque masks retain their original editable geometry, color, and stroke. Separately owned visible fill regions preserve later glyph ink instead of covering its interiors. Exact Rational partitioning and native boundary checks reject altered geometry; bounded binary construction frames avoid small-feature rounding loss. Exact loop-bound rejection reduces unnecessary winding calculations without changing partition results.

The final top orthographic view covers every retained page, including a fully resumed import, without including unrelated model geometry. Updating the existing native camera also preserves that frame when SketchUp 2017 saves and reopens the model.

## Automated and corpus validation

- The original focused validation completed 725 test runs and 10,851 assertions with no failures or errors. One pre-existing test was skipped because its optional `condensed_span.pdf` fixture is absent.
- After correcting an obsolete direct-child face assumption in the stroke-color test, all 92 distinct Ruby test files referenced by the CI, release, and exact-source gate lists passed on Windows Ruby 3.4.4 with normal filesystem access: 1,402 test runs, 15,258 assertions, no failures or errors, and two existing skips. Those skips are the absent optional `condensed_span.pdf` fixture and the intentionally pending non-ASCII helper-output-path test; the existing SafeTemp guard tests passed. The test correction verifies both retained fill boundaries and colors, hidden unstyled support edges, and the exact visible source stroke without changing product code.
- A subsequent Ruby 2.2 compatibility repair checks integer and Rational RGB channels with exact range comparisons and checks finiteness only for Float channels. This rejects non-real, non-finite, and out-of-range values without rounding them into the accepted range; geometry calculations are unchanged. Regressions exercise the legacy numeric API and require the precise construction-frame error class expected by the bundled older Minitest. All 92 referenced files then passed with 1,404 test runs, 15,280 assertions, no failures or errors, and the same two existing skips.
- The complete local sweep covers the referenced Ruby test files on Windows Ruby 3.4.4. An additional focused run emulated the older numeric API and used the original Ruby 2.2 bundled Minitest assertion implementation; that is not execution of the complete suite in Ruby 2.2. The hosted CI runtime matrix for the corrected commit is still pending.
- The Ruby 2.2 compatibility scan and whitespace checks passed. Native acceptance ran in SketchUp 2017's Ruby 2.2.4 host.
- A private corpus of 39 distinct PDFs and 106 pages passed final source conversion and glyph binding: 45,216 physical glyph placements, no binding failures, and no unmatched semantic text runs. Fourteen physical-only placements remain explicitly source-bound without invented semantic identity. Input digests were checked before and after processing each document.
- All 14 exact partition benchmark cases retained identical ordered Rational output after the loop-bound optimization.

## Native acceptance

| Case | Verified result |
| --- | --- |
| Glyphs | Import, save, healing, and final reopen passed with 70 unique source placements, 14 physical claim roots, and the requested flat glyph representation. |
| Geometry | The same 70 placements and 14 roots passed in the requested Geometry representation through both reopens. |
| 3D Text | The same 70 placements and 14 roots passed as native solid text with positive depth through both reopens. |
| Mixed-size two-page import and full resume | Both pages resumed without creating new page geometry or changing imported persistent IDs. All eight page corners remained inside the top orthographic frame, including after both reopens. A distant unrelated group did not widen the frame. |
| Image-only page | Source inspection positively established zero canonical text. A native image retained verified pixels and dimensions through healing and final reopen after deletion of the source PNG, without fabricated text entities. |

For each vector-mode case, all 14 editable source masks retained their physical geometry, styles, source colors, and persistent identities through both reopens. Physical evidence checked every source placement exactly once, including visible placements without semantic text. Each stage retained the top orthographic frame with all page corners visible. Within each mode, images captured after import and both reopens were byte-identical; visual inspection confirmed filled glyph interiors and source annotations.

After the RGB compatibility repair, a fresh 3D Text acceptance run on the exact corrected source again passed import, save, healing, and both reopens in SketchUp 2017's Ruby 2.2.4 host. All 70 placements and 14 source masks retained their physical geometry, styles, and identities. All three view images were byte-identical to the previously accepted 3D Text image. The other geometry and partition code remained unchanged; all 126 prior mask-stage RGB records used finite Float channels with identical decisions under the old and new predicates.

For the image-only case, actual `TextureWriter` exports from the native image matched the expected canonical visual-pixel digest and dimensions at all three physical snapshots. This validates saved image content independently of importer attributes or the continued presence of its original PNG.

The vector checks combine physical geometry and style verification, persistent identity checks, camera projection, and visual inspection. They do not claim complete pixel equality between a PDF renderer and SketchUp.

## Measured acceptance cost

The original three-mode acceptance measured:

| Representative vector mode | Product import | Complete private acceptance job |
| --- | ---: | ---: |
| Glyphs | 104.2 seconds | 294.6 seconds |
| Geometry | 100.5 seconds | 288.0 seconds |
| 3D Text | 5.8 seconds | 44.8 seconds |

The later corrected-source 3D Text run took 5.6 seconds for product import and 46.6 seconds for the complete acceptance job, within its unchanged 300-second limit.

Complete acceptance includes startup, saving, recursive physical snapshots, healing, and reopening. The private harness used a bounded allowance for that verification work; product timeouts and proof requirements were unchanged. These are measurements of one validation drawing, not general performance guarantees.

This evidence validates source changes in SketchUp 2017. It does not establish acceptance in a newer SketchUp host or installation of a new release package. Customer PDFs, drawing identifiers, native models, screenshots, and local evidence paths are excluded from public source changes.
