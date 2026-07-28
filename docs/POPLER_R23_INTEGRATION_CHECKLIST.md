# Poppler / R23 semantic integration checklist

Apply these changes semantically onto `origin/main` at or after `83f4cb7`.
Do not replace the target's representation-fidelity work with this older branch
snapshot.

## Preserve target behavior

- Keep `CairoGlyphSource` required and called by the target import path.
- Keep one source decision per import. Never mix native labels, 3D text, Cairo
  glyphs, or another representation inside a single fallback result.
- Keep `SvgTextRenderer`'s `placements_pdf` output and its PDF-point,
  media-origin, y-up meaning used for extractor span matching.
- Keep `missing_language_packs` and `missing_fonts` reporting.
- Keep `failure_info` from renderer through the caller and import report.
- Keep the target's existing `UserUnit` work, then gate physical scale so
  `/UserUnit` is applied exactly once across vector, text, and raster paths.
  Add cross-mode tests for inherited and page-local `/UserUnit`.

## Merge this branch's validation behavior

- Require `poppler_result_validator.rb` at every Poppler boundary.
- Treat the known Adobe-GB1 diagnostic cluster as fixture-scoped evidence,
  never as a universal CID oracle. A complete attempt-local semantic result
  overrides that diagnostic; stdout and stderr from separate attempts must
  never be combined.
- Preserve the two-phase gate: process/artifact validation may defer only this
  exact diagnostic while SVG evidence is parsed, then a final validation must
  reject unless the production caller proves the whole current source-span
  set. Never infer completeness from nonempty/some glyphs or placements and
  never pass literal `true` from the import route.
- On the target, build that proof from `CairoGlyphSource.match_spans` and
  `placements_pdf`: zero unmatched source runs, zero unmatched placements,
  zero missing language packs, zero skipped placements, and zero placement
  failures. The older branch's `PopplerSemanticProof` is a fail-closed
  reference certificate limited to the exact public fixture PDF/page/output;
  it must not replace the target's general matcher.
- Preserve zero-output fail-closed behavior:
  - no glyph placements -> `failure_info[:reason] = 'svg_zero_placements'`
  - placements with no nonempty glyph definitions ->
    `failure_info[:reason] = 'svg_zero_glyph_defs'`
  - return `nil`; never report `{edges: 0, glyphs: 0}` as success.
- Route validator rejection into `failure_info` without discarding the target's
  existing timeout, renderer, language-pack, and exception detail.
- Same-representation retries may use a system-installed `mutool` SVG route.
  MuPDF is optional, not bundled, and never a package or release gate.

## Geometry and page diagnostics

- Keep `svg_geometry_renderer.rb` deleted and absent from production requires,
  routing, docs, and tests. Its content-extents scaling and regex parser do not
  handle the required transforms, `<use>`, relative paths, S/Q/T/A commands,
  subpaths, or `/UserUnit`; it must not become a CID/geometry retry.
- Do not add a permanent canonical-filename blacklist. Test the absence of a
  production call path, leaving room for a future reviewed design.
- A bundled `pdfinfo -box` may be considered later as a read-only diagnostic
  oracle for page count, MediaBox, CropBox, Rotate, and physical dimensions.
  It must not choose or override import mode. It is not in the current 22-file
  runtime allowlist.

## Packaging contract to retain

- One layout only: `Library/bin`, `share/poppler`, and the root
  `poppler-runtime-manifest.json`.
- One shared contract for fetch, prune, smoke, build, archive, and CI.
- Exact member allowlist, sizes, hashes, no extras, and no legacy direct `bin`.
  Keep the independent canonical member-inventory digest; a manifest rebuilt
  from the current tree must not be able to redefine the pinned asset.
- Keep runtime resolver verification of that canonical digest, exact member
  and directory sets, all sizes/hashes, and no extras/symlinks before bundled
  helper selection.
- Semantic claim: `Adobe-GB1 deterministic fixture only`; other packaged
  standard collections remain unproven.
- `license_review.status = blocked` until qualified approval with no missing
  obligations and explicit reviewer, UTC timestamp, and evidence metadata. The
  release failure is intentional until then.
- The builder itself must reject helper-bearing builds off Windows and require
  the semantic smoke. Windows CI then builds, extracts, and smokes the RBZ;
  publication must download that exact artifact rather than rebuild it on
  Ubuntu.

## Integration gates

- Ruby 2.2 parse gate over every shipped `.rb` file.
- `test/poppler_result_validator_test.rb`
- `test/poppler_semantic_proof_test.rb`
- `test/poppler_boundary_validation_test.rb`
- `test/dependency_resolver_test.rb`
- `test/svg_text_collapse_test.rb`
- target `CairoGlyphSource`, source-provenance, placement, and `/UserUnit` tests
- `tools/test_poppler_runtime_contract.py`
- `tools/test_smoke_poppler_helpers.py`
- `tools/test_prune_poppler_bundle.py`
- `tools/test_build_release.py`
- `tools/test_workflow_poppler_contract.py`
- exact manifest verification and Windows Adobe-GB1 helper smoke
