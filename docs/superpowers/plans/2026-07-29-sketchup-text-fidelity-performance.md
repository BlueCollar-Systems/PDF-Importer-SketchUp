# SketchUp Text Fidelity and Exact 3D Text Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make rotated Text fallback match the successful full-page 3D Text placement while constructing each exact repeated source-glyph solid only once per page/import.

**Architecture:** `Svg3DTextRenderer` will separate the complete-page semantic match inventory from the target render subset, then use an import-scoped `Svg3DTextSolidCache` to create exact component definitions and lightweight translated instances. Existing semantic span groups, representation-ladder proofs, source evidence, positive depth, and save/reopen verification remain authoritative.

**Tech Stack:** Ruby 2.2.4, SketchUp Make 2017 Ruby API, Minitest, pdftocairo SVG, Python release builder, PowerShell host automation.

## Global Constraints

- The representation ladder remains Text -> Labels -> 3D Text -> Glyphs -> Geometry -> item Raster.
- Every rung change is item-scoped and requires affirmative impossibility evidence.
- Direct 3D Text and Labels-to-3D-Text fallback use exact renderer SVG outlines; host-font substitution is prohibited.
- A source-rotated span cannot be recorded as a completed native Label unless resulting glyph rotation is independently verified.
- No source outline point, fill rule, winding, hole, placement, affine transform, paint, source identity, or extrusion depth may change.
- No lossy contour simplification or arbitrary visual-tolerance culling is permitted.
- Ruby 2.2.4 and SketchUp Make 2017 remain supported.
- Failure after entity creation must clean every owned group, instance, and unused definition.
- The reference input is a private corpus PDF supplied through `BCS_PRIVATE_REFERENCE_PDF`; record its exact SHA-256 only in out-of-tree acceptance evidence.

---

## File Structure

- Modify `extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer.rb`: authoritative match selection, cache orchestration, cached-span evidence, renderer timing.
- Create `extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_solid_cache.rb`: exact local-loop keying, component-definition ownership, instance placement, cache counters, cleanup.
- Modify `extracted/sketchup_ext/bc_pdf_vector_importer/main.rb`: pass the complete semantic page inventory into partial Text fallback and publish renderer/cache telemetry.
- Modify `extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb`: remove acceptance of unrotated native Text for a rotated source item.
- Modify `test/svg_text_3d_renderer_test.rb`: component-definition/instance fakes plus exact-cache and authoritative-match regressions.
- Modify `test/text_mode_placement_test.rb`: rotated Text must advance through Labels to 3D Text rather than complete unrotated.
- Modify `test/representation_fidelity_contract_test.rb`: Text fallback call must carry the full-page semantic match inventory and preserve transition history.
- Modify `tools/glyph_perf_probe.rb`: use the current bundled `Library/bin/pdftocairo.exe` and report placement-to-definition reuse.
- Modify `extracted/sketchup_ext/bc_pdf_vector_importer.rb` and `extracted/sketchup_ext/bc_pdf_vector_importer/metadata.rb`: release version only after verification.

---

### Task 1: Restore Exact-Contour and Rotated-Text Safety Rails

**Files:**
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer.rb:11-15,550-615`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb:840-906,1538-1656`
- Test: `test/svg_text_3d_renderer_test.rb:467-528`
- Test: `test/text_mode_placement_test.rb`
- Modify: `tools/glyph_perf_probe.rb:40-50`

**Interfaces:**
- Consumes: existing `normalized_contour(points)` and `place_annotation_label(...)`.
- Produces: exact duplicate-only contour normalization and mandatory rotated-Label impossibility proof for Text and Labels requests.

- [ ] **Step 1: Run the exact-outline regression and record the expected failure**

Run:

```powershell
ruby test\svg_text_3d_renderer_test.rb
```

Expected before the fix: two failures, including
`test_nonzero_submicron_source_edge_is_not_silently_normalized_away` with
`Expected: 5, Actual: 4`.

- [ ] **Step 2: Remove lossy contour culling**

Restore `normalized_contour` to exact duplicate handling:

```ruby
def self.normalized_contour(points)
  clean = []
  Array(points).each do |point|
    next unless point && point.respond_to?(:x) && point.respond_to?(:y)
    clean << point if clean.empty? || !same_point?(clean[-1], point)
  end
  clean.pop if clean.length > 1 && same_point?(clean[0], clean[-1])
  return nil if clean.length < 3
  area = signed_area(clean)
  raise 'source contour area is nonfinite' unless area.finite?
  return nil if area == 0.0
  clean
end
```

Delete `CONTOUR_CULL_TOLERANCE_INCHES`, `cull_contour_points`,
`near_point?`, and `redundant_midpoint?`.

- [ ] **Step 3: Write the rotated-Text failing test**

Add a test that requests `:text` for a nonzero-angle source item and asserts:

```ruby
delivered = builder.send(
  :place_annotation_label, entities, rotated_item, 0.0, 0.0,
  'TextLayer', :text, attempt
)

refute delivered
failure = builder.text_failures.last
proof = failure[:transition_proof]
assert_equal :labels, proof[:from_mode]
assert_equal :text3d, proof[:to_mode]
assert_equal :host_representation_unsupported, proof[:reason_code]
assert_empty entities.to_a
```

Run:

```powershell
ruby test\text_mode_placement_test.rb
```

Expected before the fix: failure because the rotated item is accepted as an
unrotated native Text entity.

- [ ] **Step 4: Restore the certified rotation path**

In `place_annotation_label`, remove the `normalized_requested != :text`
exception. Every nonzero `display_angle` must return
`host_unsupported_label_rotation_proof`. Remove `text_accept_rotation`,
`rotation_host_limitation`, and the `:text` completion branch from
`complete_text_rung!`. Successful native entities remain delivered as
`:labels`.

- [ ] **Step 5: Run focused safety tests**

Run:

```powershell
ruby test\svg_text_3d_renderer_test.rb
ruby test\text_label_placement_test.rb
ruby test\text_mode_placement_test.rb
ruby test\text_representation_distinction_test.rb
```

Expected: all pass.

- [ ] **Step 6: Commit only the safety-rail files**

```powershell
git add -- extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer.rb extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb test/svg_text_3d_renderer_test.rb test/text_mode_placement_test.rb tools/glyph_perf_probe.rb
git commit -m "fix(su): preserve exact contours and rotated Text fallback"
```

---

### Task 2: Authoritative Full-Page Matching for Partial Text Fallback

**Files:**
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer.rb:20-175`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/main.rb:845-897`
- Test: `test/svg_text_3d_renderer_test.rb`
- Test: `test/representation_fidelity_contract_test.rb`

**Interfaces:**
- Consumes: `CairoGlyphSource.match_spans(pens, text_items, media_box)`.
- Produces: `Svg3DTextRenderer.render_svg(..., :match_text_items => Array)` and result fields `:authoritative_match_span_count`, `:render_target_span_count`, and `:match_scope_verified`.

- [ ] **Step 1: Write a failing authoritative-match renderer test**

Create two overlapping semantic spans whose subset-only allocation differs from
the complete-page allocation. Render only the rotated target while supplying
both spans through `match_text_items`:

```ruby
result = RENDERER.render_svg(
  entities, two_placement_svg, MEDIA_BOX, [rotated],
  :match_text_items => [horizontal, rotated],
  :preserve_unmatched_source_placements => false,
  :depth => 0.05
)

full = RENDERER.render_svg(
  Svg3DEntities.new, two_placement_svg, MEDIA_BOX,
  [horizontal, rotated], :depth => 0.05
)

assert result[:ok], result[:failures].inspect
assert_equal(
  full[:span_results].find { |row| row[:source_span_id] == rotated.source_span_id }[:placement_indices],
  result[:span_results][0][:placement_indices]
)
assert_equal 2, result[:authoritative_match_span_count]
assert_equal 1, result[:render_target_span_count]
assert result[:match_scope_verified]
```

Run:

```powershell
ruby test\svg_text_3d_renderer_test.rb --name /authoritative_match/
```

Expected: failure because `match_text_items` is ignored.

- [ ] **Step 2: Implement separate match and render inventories**

At the start of `render_svg`, use:

```ruby
render_items = Array(text_items)
match_items = opts.key?(:match_text_items) ?
  Array(opts[:match_text_items]) : render_items
match = CairoGlyphSource.match_spans(pens, match_items, media_box)
```

Validate that render source IDs are unique and are all present in the
authoritative inventory. Validate that each placement index appears in at most
one `placement_matches` record. Build `matched_by_span` from the authoritative
match, but iterate only `render_items` when creating semantic groups.

Set:

```ruby
result[:authoritative_match_span_count] = match_items.length
result[:render_target_span_count] = render_items.length
result[:match_scope_verified] = true
```

Any duplicate placement assignment or target absent from the authoritative
inventory is a generic hard failure and creates no fallback proof.

- [ ] **Step 3: Write the integration call-contract test**

Stub `Svg3DTextRenderer.render_svg`, call
`complete_label_item_fallbacks!`, and capture options:

```ruby
assert_equal failed_items, captured[:text_items]
assert_equal all_page_text_items, captured[:options][:match_text_items]
assert_equal false,
  captured[:options][:preserve_unmatched_source_placements]
```

Run:

```powershell
ruby test\representation_fidelity_contract_test.rb --name /label.*full_page_match/
```

Expected: failure because `main.rb` does not pass `match_text_items`.

- [ ] **Step 4: Pass the complete page inventory from Text fallback**

In `complete_label_item_fallbacks!`, add:

```ruby
:match_text_items => Array(all_page_text_items || text_items),
```

The direct 3D Text call omits this option because its target set is already the
complete page.

- [ ] **Step 5: Run focused matching and ladder tests**

Run:

```powershell
ruby test\cairo_glyph_source_test.rb
ruby test\svg_text_3d_renderer_test.rb
ruby test\representation_fidelity_contract_test.rb
ruby test\text_mode_routing_test.rb
```

Expected: all pass.

- [ ] **Step 6: Commit authoritative matching**

```powershell
git add -- extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer.rb extracted/sketchup_ext/bc_pdf_vector_importer/main.rb test/svg_text_3d_renderer_test.rb test/representation_fidelity_contract_test.rb
git commit -m "fix(su): bind rotated Text to full-page glyph matching"
```

---

### Task 3: Import-Scoped Exact Source-Solid Cache

**Files:**
- Create: `extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_solid_cache.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer.rb:1-10,20-181,269-401`
- Modify: `test/svg_text_3d_renderer_test.rb:9-286`

**Interfaces:**
- Consumes: exact model-space entry hashes with `:glyph_id`, `:loops`, `:fill_rgb`, `:fill_opacity`, `:svg_matrix`, and `:placement_index`.
- Produces:
  - `Svg3DTextSolidCache.new(model, depth)`
  - `cache.supported_for?(target_entities) -> true|false`
  - `cache.key_for(entry) -> String`
  - `cache.fetch(entry) { |definition_entities, local_entry| metrics_hash } -> record`
  - `cache.add_instance(target_entities, record) -> Sketchup::ComponentInstance`
  - `cache.cleanup_all! -> true`
  - `cache.metrics -> Hash`

- [ ] **Step 1: Extend the host fakes and write the repeated-solid failing test**

Add fake `Svg3DDefinitions`, `Svg3DDefinition`, and `Svg3DInstance` classes.
`Svg3DDefinition#entities` stores one physical face/extrusion set;
`Svg3DInstance#bounds` returns definition bounds translated by its
`Geom::Transformation`. Extend `Geom::Transformation` with:

```ruby
def self.translation(values)
  transform = new(1.0)
  transform.instance_variable_set(:@translation, Array(values).map(&:to_f))
  transform
end

attr_reader :translation
```

Add a two-placement SVG using the same glyph definition and assert:

```ruby
model = Svg3DModel.new(:with_definitions => true)
entities = Svg3DEntities.new(:model => model)
result = RENDERER.render_svg(
  entities, repeated_square_svg, MEDIA_BOX,
  [wide_span], :depth => 0.05
)

assert result[:ok], result[:failures].inspect
assert_equal 1, result[:solid_cache][:definition_builds]
assert_equal 1, result[:solid_cache][:cache_misses]
assert_equal 1, result[:solid_cache][:cache_hits]
assert_equal 2, result[:solid_cache][:instance_placements]
assert_equal 1, model.definitions.to_a.length
```

Run:

```powershell
ruby test\svg_text_3d_renderer_test.rb --name /repeated_solid/
```

Expected: failure because `:solid_cache` is absent and faces are built twice.

- [ ] **Step 2: Implement exact keying and local-loop normalization**

In `Svg3DTextSolidCache`, compute each entry extent and subtract only
`min_x/min_y` from copied points. Build the key with SHA-256 over:

```ruby
[
  entry[:glyph_id].to_s,
  canonical_local_loop_coordinates(local_entry[:loops]),
  'nonzero',
  canonical_number(@depth),
  Array(entry[:fill_rgb]).map { |v| canonical_number(v) },
  canonical_number(entry[:fill_opacity].nil? ? 1.0 : entry[:fill_opacity])
]
```

Do not round coordinates. `canonical_number` must use `format('%.17g',
value.to_f)` and reject nonfinite values. Translation must not enter the key.
Different affine transforms naturally produce different local coordinates and
therefore different keys.

- [ ] **Step 3: Implement definition ownership and exact instance placement**

`fetch` must create a definition named with
`"BC_PDF_GLYPH_#{key[0, 24]}"`, yield its entities and the localized entry,
and cache it only after the builder block succeeds.

`add_instance` must use:

```ruby
transform = Geom::Transformation.translation(record[:origin])
instance = target_entities.add_instance(record[:definition], transform)
raise 'host rejected exact glyph component instance' unless instance
```

On builder failure, remove the just-created definition. `cleanup_all!` removes
all definitions created by this cache after caller-owned instances/groups have
been erased.

- [ ] **Step 4: Integrate the cache with semantic span construction**

Create one cache per `render_svg` call when the model exposes component
definitions and the target entities expose `add_instance`. Pass it into
`build_span_group`.

For every entry, call `cache.fetch` with a block that invokes the existing exact
`build_filled_glyph`, construction-scale, positive-depth extrusion, and
definition-local bounds verification. Add the returned instance to the
source-span group.

Preserve existing row fields and add:

```ruby
:component_instance_entity_ids => instance_ids,
:component_definition_keys => definition_keys.uniq.sort,
:definition_reuse_verified => true
```

`face_count` and `extruded_face_count` remain physical occurrence counts.
Definition build counts are reported separately through cache metrics.

If the host does not expose component definitions, retain the current exact
per-occurrence renderer. Do not fall back on any cache construction exception;
that exception is a hard generic failure with atomic cleanup.

- [ ] **Step 5: Add key-separation, exactness, and cleanup tests**

Add tests asserting:

```ruby
refute_equal cache.key_for(base_entry),
             cache.key_for(base_entry.merge(:loops => sheared_loops))
refute_equal cache.key_for(base_entry),
             Svg3DTextSolidCache.new(model, 0.10).key_for(base_entry)
```

Also assert:

- submicron nonzero edges retain the exact vertex count inside definitions;
- opposite-winding holes remain holes;
- colored spans retain the source material;
- two translated instances produce expected combined bounds;
- a synthetic second-definition build failure erases the semantic groups and
  every definition created by the render call.

Run:

```powershell
ruby test\svg_text_3d_renderer_test.rb
```

Expected: all pass.

- [ ] **Step 6: Run Ruby 2.2 compatibility gates**

Run:

```powershell
ruby test\ruby22_compat_test.rb
ruby test\ruby22_real_parse_gate_contract_test.rb
ruby -c extracted\sketchup_ext\bc_pdf_vector_importer\svg_3d_text_solid_cache.rb
ruby -c extracted\sketchup_ext\bc_pdf_vector_importer\svg_3d_text_renderer.rb
```

Expected: all pass and every syntax check prints `Syntax OK`.

- [ ] **Step 7: Commit the exact-solid cache**

```powershell
git add -- extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_solid_cache.rb extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer.rb test/svg_text_3d_renderer_test.rb
git commit -m "perf(su): reuse exact source-glyph solids"
```

---

### Task 4: Performance Evidence and Complete Regression Gates

**Files:**
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer.rb:20-181`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/main.rb:1337-1535`
- Modify: `test/svg_text_3d_renderer_test.rb`
- Modify: `test/qa_report_test.rb`
- Modify: `tools/glyph_perf_probe.rb`

**Interfaces:**
- Consumes: `render_result[:solid_cache]` and authoritative-match fields from Tasks 2-3.
- Produces: `render_result[:performance]` and report `extra.text_renderers[].solid_cache/performance`.

- [ ] **Step 1: Write telemetry contract tests**

Assert renderer results include:

```ruby
assert_equal(
  [:definition_build_ms, :instance_placement_ms, :match_ms,
   :parse_ms, :verification_ms],
  result[:performance].keys.sort
)
assert_equal result[:source_placements],
             result[:solid_cache][:instance_placements]
assert_operator result[:solid_cache][:definition_builds], :<,
                result[:solid_cache][:instance_placements]
```

In `qa_report_test.rb`, assert the renderer record preserves the nested
`solid_cache` and `performance` hashes.

- [ ] **Step 2: Add Ruby-2.2-safe timing**

Use:

```ruby
def self.monotonic_ms
  if Process.respond_to?(:clock_gettime) &&
     defined?(Process::CLOCK_MONOTONIC)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
  else
    Time.now.to_f * 1000.0
  end
end
```

Measure parse, match, definition build, instance placement, and final
verification phases. Round only report values, never geometry values.

- [ ] **Step 3: Publish cache and timing evidence**

In `record_svg_3d_text_delivery!`, add:

```ruby
:solid_cache => render_result[:solid_cache],
:performance => render_result[:performance],
:authoritative_match_span_count =>
  render_result[:authoritative_match_span_count],
:render_target_span_count => render_result[:render_target_span_count],
:match_scope_verified => render_result[:match_scope_verified]
```

The QA report must serialize these fields without renaming or flattening them.

- [ ] **Step 4: Make the offline probe report reuse potential**

Use the current `Library/bin/pdftocairo.exe`. Print with measured values
interpolated:

```text
physical_glyph_placements=4280
unique_glyph_definitions=413
placement_to_definition_ratio=10.3632
```

Run:

```powershell
ruby tools\glyph_perf_probe.rb "$env:BCS_PRIVATE_REFERENCE_PDF"
```

Expected reference values: 4,280 physical placements, 413 unique definitions,
and approximately 10.4 placements per definition.

- [ ] **Step 5: Run every Ruby test**

Run:

```powershell
Get-ChildItem -Path test -Filter '*_test.rb' | ForEach-Object { ruby $_.FullName; if ($LASTEXITCODE -ne 0) { throw "Failed: $($_.Name)" } }
```

Expected: every test exits zero.

- [ ] **Step 6: Run source and packaging syntax checks**

Run:

```powershell
Get-ChildItem -Path extracted\sketchup_ext -Recurse -Filter '*.rb' | ForEach-Object { ruby -c $_.FullName; if ($LASTEXITCODE -ne 0) { throw "Syntax failed: $($_.FullName)" } }
python build_release.py --require-poppler-smoke --out dist
```

Expected: all Ruby files print `Syntax OK`; release builder completes with
bundled Poppler smoke verification.

- [ ] **Step 7: Commit telemetry and gates**

```powershell
git add -- extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer.rb extracted/sketchup_ext/bc_pdf_vector_importer/main.rb test/svg_text_3d_renderer_test.rb test/qa_report_test.rb tools/glyph_perf_probe.rb
git commit -m "test(su): gate exact 3D Text reuse and timing"
```

---

### Task 5: Real SketchUp 2017 Acceptance and Release

**Files:**
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/metadata.rb`
- Create: release RBZ under `dist/`
- Create: host evidence under a new `C:\TMP\su-acceptance-20260729\` run directory

**Interfaces:**
- Consumes: test-green source state and the reference PDF.
- Produces: installed byte-verified RBZ, Text/3D Text SKP files, import reports, timing evidence, release commit/tag/push.

- [ ] **Step 1: Run direct 3D Text acceptance**

Create `C:\TMP\su-acceptance-20260729\text3d\job.json` with:

```json
{
  "pdf_path": "<absolute private reference path>",
  "original_pdf_path": "<absolute private reference path>",
  "original_pdf_sha256": "<computed private source SHA-256>",
  "output_dir": "C:\\TMP\\su-acceptance-20260729\\text3d",
  "text_mode": "text3d",
  "import_mode": "auto",
  "pages": [1]
}
```

Run:

```powershell
$env:SKETCHUP_EXE='C:\Program Files\SketchUp\SketchUp 2017\SketchUp.exe'
$env:BC_SKETCHUP_HOST_TIMEOUT_SECONDS='3600'
ruby tools\sketchup_host_launcher.rb 'C:\TMP\su-acceptance-20260729\text3d\job.json'
```

Capture the generated SKP, import report, host log, and wall time.

Required checks:

- 813 semantic spans are terminally accounted for;
- source glyph identity and positive Z depth are verified;
- cache definition builds are materially below 4,280 placements;
- no raster fallback is used;
- elapsed time is at most 200.25 seconds, with 133.5 seconds or less as the
  target.

- [ ] **Step 2: Run Text acceptance**

Create `C:\TMP\su-acceptance-20260729\text\job.json` with the same source
identity, `output_dir` set to
`C:\TMP\su-acceptance-20260729\text`, and `text_mode` set to `text`.

Run:

```powershell
$env:SKETCHUP_EXE='C:\Program Files\SketchUp\SketchUp 2017\SketchUp.exe'
$env:BC_SKETCHUP_HOST_TIMEOUT_SECONDS='3600'
ruby tools\sketchup_host_launcher.rb 'C:\TMP\su-acceptance-20260729\text\job.json'
```

Required checks:

- horizontal spans remain native Labels;
- every rotated span records Text -> Labels -> 3D Text;
- rotated placement indices equal their direct-3D-Text placement indices;
- no rotated source item is completed as an unrotated native Label;
- full import does not exceed the measured 131.3-second baseline;
- the exact-3D fallback phase is at least 2x faster than its pre-cache phase.

- [ ] **Step 3: Visually inspect the reported defect area**

At equal zoom, compare Acrobat, direct 3D Text, and Text output around:

- `7 3/4`;
- `10 7/16`;
- `8 13/16`;
- `a1020`;
- stacked fractions and nearby leader annotations.

Reject the release if rotation, baseline, fraction composition, or alignment is
worse than the direct 3D Text reference.

- [ ] **Step 4: Save, reopen, and re-verify**

Save both SKP files, close SketchUp, reopen each file, and run the existing host
evidence verifier. Required checks:

- component definitions and instances survive;
- semantic group source IDs remain unique;
- instance transformations and bounds match stored evidence;
- faces retain positive depth and source paint.

- [ ] **Step 5: Increment the release version and rebuild**

Increment both version declarations to the next unused patch version, then run:

```powershell
python build_release.py --require-poppler-smoke --out dist
```

Hash the RBZ, extract it to a fresh temporary directory, and run `ruby -c` on
every shipped Ruby file.

- [ ] **Step 6: Install the exact verified artifact and retest**

Install the extracted bytes into:

```text
%APPDATA%\SketchUp\SketchUp 2017\SketchUp\Plugins
```

Restart SketchUp and repeat one Text and one 3D Text host import from the
installed plugin. The installed file hashes must equal the verified RBZ payload
hashes.

- [ ] **Step 7: Commit, tag, and push**

```powershell
git add -- extracted/sketchup_ext/bc_pdf_vector_importer.rb extracted/sketchup_ext/bc_pdf_vector_importer/metadata.rb dist
git commit -m "release(su): ship exact cached 3D Text"
$versionMatch = Select-String -LiteralPath 'extracted\sketchup_ext\bc_pdf_vector_importer.rb' -Pattern "PLUGIN_VERSION = '([^']+)'"
$verifiedVersion = $versionMatch.Matches[0].Groups[1].Value
git tag "v$verifiedVersion"
git push origin main
git push origin "v$verifiedVersion"
```

Before pushing, verify `git status --short` contains no unintended files and
the release commit identifies the exact tested RBZ SHA-256.
