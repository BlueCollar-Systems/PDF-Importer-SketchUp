# SketchUp 3D Text Visual Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver native SketchUp 3D Text at the PDF's visible height, run length, baseline, rotation, and placement without representation switching or silent partial geometry.

**Architecture:** Preserve trusted font and text-matrix metadata from the internal PDF parser while keeping external `pdftotext` bboxes and identity. GeometryBuilder converts canonical PDF em height into SketchUp letter-height units, applies trusted and shrink-only local-X correction before placement, cleans failed partial meshes, and emits structured telemetry. Existing placement anchors remain unchanged; live SketchUp 2017 evidence is the release gate.

**Tech Stack:** Ruby 2.2-compatible SketchUp extension code, Minitest and repository script tests, pure-Ruby PDF parsing, SketchUp Make 2017, Python release tooling, PowerShell host orchestration.

## Global Constraints

- The first production edit for each behavior is prohibited until its regression test has failed for the expected reason.
- SketchUp Make 2017 and Ruby 2.2.4 remain the minimum host/runtime; do not use `Numeric#clamp`, safe navigation, keyword-initialized Structs, or newer Ruby syntax.
- A requested `text3d` representation remains native 3D Text unless native creation is genuinely impossible; alignment, rotation, height, or width defects never justify a mode switch.
- Canonical PDF size is `font_size_points / 72.0 * import_scale`; per-span bbox height never selects vertical size.
- Arial, Arial Bold, and Arial Narrow use exactly `1491.0 / 2048.0`; RomanT uses exactly `1538.0 / 2048.0` only when RomanT is genuinely selected.
- A FontDescriptor `/Ascent` ratio is trusted only in the inclusive range `0.60..0.95`; `/CapHeight` is never used.
- Trusted matrix-X may grow or shrink. Bbox residual-X may only shrink, is used only near 0 or plus/minus 90 degrees, and is rejected below `0.50` rather than clamped.
- Transform order is local-X scale about `ORIGIN`, translation to the existing insertion point, then rotation about that insertion point. Y and Z scale remain exactly `1.0`.
- Existing rotated and horizontal insertion anchors, tolerance `0.0`, filled faces, materials, hard height limits, and loud height-fallback counting remain.
- A failed transformed mesh is erased before fallback; when cleanup cannot be confirmed, do not overlay a Label and route the item to the existing page-level terminal rung.
- No release or version claim occurs until fresh installed-byte SketchUp 2017 visual acceptance passes. Q&A authority and archival remain unchanged until the separate five-mode host verification also passes.

---

## File Map

- `extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser.rb`: extract source font family/style and validated font-level ratio alongside ToUnicode data.
- `extracted/sketchup_ext/bc_pdf_vector_importer/text_parser.rb`: append render metadata, compute trusted matrix-X including `Tz`, and preserve metadata through internal rebuilds.
- `extracted/sketchup_ext/bc_pdf_vector_importer/external_text_extractor.rb`: preserve appended metadata and span identity through external rebuilds.
- `extracted/sketchup_ext/bc_pdf_vector_importer/main.rb`: merge internal render hints into external bbox items and aggregate 3D Text telemetry.
- `extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb`: select native font/style, convert em to letter height, fit local X, order transforms, clean partial meshes, and record telemetry.
- `extracted/sketchup_ext/bc_pdf_vector_importer/qa_report.rb`: expose canonical em, letter height, metric provenance, width fit, failures, and substitutions.
- `test/pdf_font_metadata_test.rb`: unit contract for font normalization and descriptor validation.
- `test/text_item_metadata_propagation_test.rb`: unit contract for append-only metadata through rebuild paths.
- `test/mesh_text_visual_parity_test.rb`: unit contract for font metrics, local-X fitting, transform order, faces, and cleanup.
- Existing focused tests listed below: replace obsolete full-em and blanket scaling/erase prohibitions without weakening tiny-text, anchor, or Ruby 2.2 guards.

### Task 1: Extract trusted source-font metadata

**Files:**
- Create: `test/pdf_font_metadata_test.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser.rb:228-261`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser.rb:922-951`

**Interfaces:**
- Consumes: PDF font resource dictionaries, descendant dictionaries, FontDescriptor dictionaries, and optional ToUnicode CMaps.
- Produces: `PDFParser#page_font_maps(page_num) -> Hash<String, Hash>` where each value contains `:map`, `:code_lengths`, `:source_font_family`, `:source_font_bold`, `:source_font_italic`, `:font_to_sketchup_letter_ratio`, and `:font_to_sketchup_letter_ratio_source`.

- [ ] **Step 1: Write the failing font metadata tests**

Create `test/pdf_font_metadata_test.rb` with synthetic dictionaries so it does not depend on the private test PDF:

```ruby
#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'

class PdfFontMetadataTest < Minitest::Test
  Parser = BlueCollarSystems::PDFVectorImporter::PDFParser

  def parser_for(objects, cmap = nil)
    parser = Parser.new(__FILE__)
    parser.define_singleton_method(:resolve_object) { |ref| objects.fetch(ref, ref) }
    parser.define_singleton_method(:extract_font_to_unicode_map) { |_ref| cmap }
    parser
  end

  def info_for(font, objects = {}, cmap = nil)
    parser_for(objects, cmap).send(:extract_font_resource_info, font)
  end

  def test_subset_arial_variants_and_romant_have_exact_known_metrics
    cases = {
      '/FPAVJU+Arial' => ['Arial', false, false, 1491.0 / 2048.0, :known_arial_family],
      '/FPFAQD+Arial,Bold' => ['Arial', true, false, 1491.0 / 2048.0, :known_arial_family],
      '/FPWADG+ArialNarrow' => ['Arial Narrow', false, false, 1491.0 / 2048.0, :known_arial_family],
      '/FPMZBW+RomanT' => ['RomanT', false, false, 1538.0 / 2048.0, :known_romant]
    }
    cases.each do |name, expected|
      info = info_for('/BaseFont' => name)
      actual = [info[:source_font_family], info[:source_font_bold],
                info[:source_font_italic], info[:font_to_sketchup_letter_ratio],
                info[:font_to_sketchup_letter_ratio_source]]
      assert_equal expected, actual
    end
  end

  def test_descriptor_ascent_is_bounded_and_capheight_is_ignored
    valid = info_for({'/BaseFont' => '/UnknownCAD', '/FontDescriptor' => 'd'},
                     {'d' => {'/Ascent' => 600, '/CapHeight' => 500}})
    assert_in_delta 0.60, valid[:font_to_sketchup_letter_ratio], 1.0e-12
    assert_equal :font_descriptor_ascent, valid[:font_to_sketchup_letter_ratio_source]

    invalid = info_for({'/BaseFont' => '/UnknownCAD', '/FontDescriptor' => 'd'},
                       {'d' => {'/Ascent' => 500, '/CapHeight' => 900}})
    assert_in_delta 1491.0 / 2048.0, invalid[:font_to_sketchup_letter_ratio], 1.0e-12
    assert_equal :default_arial_family, invalid[:font_to_sketchup_letter_ratio_source]
  end

  def test_font_resource_is_retained_without_tounicode
    info = info_for({'/BaseFont' => '/Arial'}, {}, nil)
    assert_equal({}, info[:map])
    assert_equal [1], info[:code_lengths]
    assert_equal 'Arial', info[:source_font_family]
  end

  def test_descriptor_italic_angle_sets_style
    info = info_for({'/BaseFont' => '/Custom', '/FontDescriptor' => 'd'},
                    {'d' => {'/Ascent' => 728, '/ItalicAngle' => -12}})
    assert_equal true, info[:source_font_italic]
  end
end
```

- [ ] **Step 2: Run the new test and record the expected RED result**

Run: `ruby test/pdf_font_metadata_test.rb`

Expected: FAIL/ERROR because `extract_font_resource_info` does not exist and fonts without ToUnicode are currently omitted.

- [ ] **Step 3: Implement font-resource extraction without using CapHeight**

Change `page_font_maps` to call `extract_font_resource_info(font_ref)` and retain every resolved font resource. Add these private helpers:

```ruby
def extract_font_resource_info(font_ref)
  top = to_dict(resolve_object(font_ref))
  return nil unless top.is_a?(Hash)
  descendant = nil
  if top['/DescendantFonts'].is_a?(Array) && !top['/DescendantFonts'].empty?
    descendant = to_dict(resolve_object(top['/DescendantFonts'].first))
  end
  descriptor = font_descriptor_for(descendant) || font_descriptor_for(top)
  raw_name = top['/BaseFont']
  raw_name = descendant['/BaseFont'] if (!raw_name || raw_name.to_s.empty?) && descendant
  raw_name = descriptor['/FontName'] if (!raw_name || raw_name.to_s.empty?) && descriptor
  family, bold, italic = normalize_source_font(raw_name, descriptor)
  ratio, source = font_to_sketchup_letter_ratio(family, descriptor)
  cmap = extract_font_to_unicode_map(font_ref) || { map: {}, code_lengths: [1] }
  {
    map: cmap[:map].is_a?(Hash) ? cmap[:map] : {},
    code_lengths: Array(cmap[:code_lengths]).empty? ? [1] : Array(cmap[:code_lengths]),
    source_font_family: family,
    source_font_bold: bold,
    source_font_italic: italic,
    font_to_sketchup_letter_ratio: ratio,
    font_to_sketchup_letter_ratio_source: source
  }
end

def font_descriptor_for(font_dict)
  return nil unless font_dict.is_a?(Hash)
  to_dict(resolve_object(font_dict['/FontDescriptor']))
rescue StandardError
  nil
end

def normalize_source_font(raw_name, descriptor = nil)
  name = raw_name.to_s.sub(/\A\//, '').sub(/\A[A-Z]{6}\+/, '')
  compact = name.downcase.gsub(/[^a-z0-9]/, '')
  family = if compact.include?('arialnarrow')
             'Arial Narrow'
           elsif compact.include?('arial')
             'Arial'
           elsif compact.include?('romant')
             'RomanT'
           else
             name.gsub(/[,_-]?(bolditalic|boldoblique|bold|italic|oblique|bd|it)\z/i, '')
           end
  bold = !!(name =~ /(bold|\bbd\b)/i)
  italic_angle = descriptor.is_a?(Hash) ? descriptor['/ItalicAngle'].to_f : 0.0
  italic = !!(name =~ /(italic|oblique|\bit\b)/i) || italic_angle.abs > 0.001
  [family.to_s.empty? ? 'Arial' : family, bold, italic]
end

def font_to_sketchup_letter_ratio(family, descriptor)
  key = family.to_s.downcase
  return [1491.0 / 2048.0, :known_arial_family] if key == 'arial' || key == 'arial narrow'
  return [1538.0 / 2048.0, :known_romant] if key == 'romant'
  ascent = descriptor.is_a?(Hash) ? descriptor['/Ascent'].to_f : 0.0
  ascent /= 1000.0 if ascent.abs > 10.0
  return [ascent, :font_descriptor_ascent] if ascent >= 0.60 && ascent <= 0.95
  [1491.0 / 2048.0, :default_arial_family]
end
```

The `page_font_maps` loop becomes:

```ruby
font_dict.each do |font_name, font_ref|
  info = extract_font_resource_info(font_ref)
  next unless info
  key = font_name.to_s
  maps[key] = info
  maps[key.sub(/\A\//, '')] = info
end
```

- [ ] **Step 4: Run the focused parser tests**

Run: `ruby test/pdf_font_metadata_test.rb`

Expected: PASS, including exact ratios and proof that `/CapHeight 500` cannot select a ratio.

- [ ] **Step 5: Commit the parser contract**

```powershell
git add test/pdf_font_metadata_test.rb extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser.rb
git commit -m "fix: preserve PDF font render metadata"
```

### Task 2: Carry font and matrix-X metadata through every text rebuild

**Files:**
- Create: `test/text_item_metadata_propagation_test.rb`
- Modify: `test/text_parser_transform_test.rb`
- Modify: `test/text_angle_hint_test.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/text_parser.rb:12-30,86-249,592-930`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/external_text_extractor.rb:285-300,431-457,503-516`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/main.rb:412-450`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb:760-800`

**Interfaces:**
- Consumes: Task 1 font-map fields.
- Produces: append-only `TextItem` fields `source_font_family`, `source_font_bold`, `source_font_italic`, `font_to_sketchup_letter_ratio`, `font_to_sketchup_letter_ratio_source`, and `trusted_text_matrix_x_scale`; class methods `TextParser.copy_text_item_metadata!(target, source)` and `TextParser.copy_text_item_final_fields!(target, source)`.

- [ ] **Step 1: Write failing matrix and propagation tests**

Extend `test/text_parser_transform_test.rb` with:

```ruby
def test_font_metadata_and_trusted_matrix_x_reach_item
  maps = {'F1' => {
    map: {}, code_lengths: [1], source_font_family: 'Arial Narrow',
    source_font_bold: false, source_font_italic: false,
    font_to_sketchup_letter_ratio: 1491.0 / 2048.0,
    font_to_sketchup_letter_ratio_source: :known_arial_family
  }}
  item = TP.new(['BT /F1 12 Tf 1.436458 0 0 1 10 20 Tm (ONE FRAME) Tj ET'],
                maps, strict_text_fidelity: true).parse.first
  assert_equal 'Arial Narrow', item.source_font_family
  assert_in_delta 1.436458, item.trusted_text_matrix_x_scale, 1.0e-6
end

def test_tz_multiplies_trusted_x_without_changing_vertical_size
  item = TP.new(['BT /F1 12 Tf 80 Tz 1 0 0 2 0 0 Tm (A) Tj ET'], {},
                strict_text_fidelity: true).parse.first
  assert_in_delta 24.0, item.font_size, 1.0e-9
  assert_in_delta 0.4, item.trusted_text_matrix_x_scale, 1.0e-9
end
```

Create `test/text_item_metadata_propagation_test.rb` with one metadata canary and direct calls through each existing clone helper:

```ruby
#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class TextItemMetadataPropagationTest < Minitest::Test
  TP = BlueCollarSystems::PDFVectorImporter::TextParser
  TI = TP::TextItem

  def canary(text = 'A')
    item = TI.new(text, 10, 20, 12, 0, 'F1', 12, 10, 20, 30, 32, nil, 'span:1')
    item.source_font_family = 'Arial Narrow'
    item.source_font_bold = true
    item.source_font_italic = false
    item.font_to_sketchup_letter_ratio = 1491.0 / 2048.0
    item.font_to_sketchup_letter_ratio_source = :known_arial_family
    item.trusted_text_matrix_x_scale = 1.436458
    item
  end

  def assert_canary(item)
    assert_equal 'span:1', item.source_span_id
    assert_equal 'Arial Narrow', item.source_font_family
    assert_equal true, item.source_font_bold
    assert_in_delta 1.436458, item.trusted_text_matrix_x_scale, 1.0e-6
  end

  def test_copy_helpers_preserve_identity_and_all_render_metadata
    source = canary
    target = TI.new('B', 0, 0, 8, 0, 'pdftotext')
    TP.copy_text_item_final_fields!(target, source)
    assert_canary(target)
  end

  def test_external_bbox_identity_survives_internal_hint_overlay
    external = canary
    external.font_name = 'pdftotext'
    internal = canary
    internal.source_span_id = 'internal-span'
    merged = BlueCollarSystems::PDFVectorImporter.clone_text_item_with_hints(external, internal)
    assert_equal 'pdftotext', merged.font_name
    assert_equal external.bbox_x0, merged.bbox_x0
    assert_canary(merged)
  end
end
```

Extend `test/text_angle_hint_test.rb` so its internal hint carries the six fields and assert the merged external item keeps `font_name == 'pdftotext'`, its bbox, its external `source_span_id`, and the internal render metadata.

- [ ] **Step 2: Run the focused tests and record the expected RED result**

Run:

```powershell
ruby test/text_parser_transform_test.rb
ruby test/text_item_metadata_propagation_test.rb
ruby test/text_angle_hint_test.rb
```

Expected: errors for missing Struct readers/writers or copy helpers; the Tz/matrix-X assertions also fail because horizontal scale is currently discarded.

- [ ] **Step 3: Append metadata and add centralized copy helpers**

Append these members after `source_span_id` without reordering any legacy member:

```ruby
:source_font_family,
:source_font_bold,
:source_font_italic,
:font_to_sketchup_letter_ratio,
:font_to_sketchup_letter_ratio_source,
:trusted_text_matrix_x_scale
```

Add to `TextParser`:

```ruby
TEXT_ITEM_METADATA_FIELDS = [
  :source_font_family, :source_font_bold, :source_font_italic,
  :font_to_sketchup_letter_ratio, :font_to_sketchup_letter_ratio_source,
  :trusted_text_matrix_x_scale
].freeze

def self.copy_text_item_metadata!(target, source)
  TEXT_ITEM_METADATA_FIELDS.each do |field|
    writer = "#{field}="
    target.send(writer, source.send(field)) if target.respond_to?(writer) && source.respond_to?(field)
  end
  target
end

def self.copy_text_item_final_fields!(target, source)
  copy_text_item_metadata!(target, source)
  if target.respond_to?(:source_span_id=) && source.respond_to?(:source_span_id)
    target.source_span_id = source.source_span_id
  end
  target
end
```

Call `copy_text_item_final_fields!` immediately after every rebuilt TextItem in `text_parser.rb`, `external_text_extractor.rb`, and the stacked-label split in `geometry_builder.rb`. Include `trusted_text_matrix_x_scale` in the internal merge bucket key rounded to six decimals so runs with different X scales cannot merge.

- [ ] **Step 4: Compute trusted matrix-X and support PDF Tz**

Initialize `horizontal_scale = 1.0` for each content stream, handle `Tz`, and pass it to every `emit_text` call:

```ruby
when 'Tz'
  horizontal_scale = nums.last.to_f / 100.0 if nums.last
```

Replace `emit_text` with the same vertical-size behavior plus metadata assignment:

```ruby
def emit_text(text, tm, font_size, font_name, horizontal_scale = 1.0)
  text_matrix = multiply_matrix(tm, @ctm)
  x = text_matrix[4]
  y = text_matrix[5]
  vertical = Math.hypot(text_matrix[2].to_f, text_matrix[3].to_f)
  horizontal = Math.hypot(text_matrix[0].to_f, text_matrix[1].to_f)
  effective_size = vertical.abs < 0.001 ? font_size : font_size * vertical
  angle = -Math.atan2(text_matrix[1], text_matrix[0]) * 180.0 / Math::PI
  item = TextItem.new(text, x, y, effective_size, angle, font_name, font_size,
                      nil, nil, nil, nil, @current_ocg_layer)
  ratio = vertical > 1.0e-9 ? (horizontal / vertical) * horizontal_scale.to_f : nil
  ratio = nil unless ratio && ratio.finite? && ratio > 0.0
  item.trusted_text_matrix_x_scale = ratio
  info = @font_maps[font_name.to_s] || @font_maps[font_name.to_s.sub(/\A\//, '')]
  if info.is_a?(Hash)
    TEXT_ITEM_METADATA_FIELDS.each do |field|
      next if field == :trusted_text_matrix_x_scale
      item.send("#{field}=", info[field]) if info.key?(field)
    end
  end
  @text_items << item
end
```

- [ ] **Step 5: Preserve external identity while overlaying internal render hints**

In `clone_text_item_with_hints`, create the positional clone exactly as today, then apply:

```ruby
clone = TextParser::TextItem.new(
  item.text,
  hint.x,
  hint.y,
  nominal_size,
  hint.angle.to_f,
  item.font_name,
  hint.respond_to?(:raw_font_size) ? hint.raw_font_size : item.raw_font_size,
  item.respond_to?(:bbox_x0) ? item.bbox_x0 : nil,
  item.respond_to?(:bbox_y0) ? item.bbox_y0 : nil,
  item.respond_to?(:bbox_x1) ? item.bbox_x1 : nil,
  item.respond_to?(:bbox_y1) ? item.bbox_y1 : nil,
  item.respond_to?(:layer_name) ? item.layer_name : nil,
  item.respond_to?(:source_span_id) ? item.source_span_id : nil
)
TextParser.copy_text_item_final_fields!(clone, item)
TextParser.copy_text_item_metadata!(clone, hint)
clone.source_span_id = item.source_span_id if clone.respond_to?(:source_span_id=)
clone
```

Do not change `clone.font_name`; it must remain `pdftotext`. Implement `clone_text_item_with_angle` as:

```ruby
hint = item.dup
hint.angle = angle
clone_text_item_with_hints(item, hint)
```

Add this inventory guard to `test/text_item_metadata_propagation_test.rb` so none of the existing rebuild paths silently drops append-only fields:

```ruby
def test_every_rebuild_file_uses_the_central_final_field_copy
  root = File.expand_path('..', __dir__)
  expected_minimums = {
    'extracted/sketchup_ext/bc_pdf_vector_importer/text_parser.rb' => 4,
    'extracted/sketchup_ext/bc_pdf_vector_importer/external_text_extractor.rb' => 3,
    'extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb' => 1,
    'extracted/sketchup_ext/bc_pdf_vector_importer/main.rb' => 1
  }
  expected_minimums.each do |relative, minimum|
    source = File.read(File.join(root, relative))
    assert_operator source.scan('copy_text_item_final_fields!').length, :>=, minimum, relative
  end
end
```

Include all six metadata fields, not only matrix-X, in the internal merge bucket key; round only the numeric ratio and matrix-X fields to six decimals.

- [ ] **Step 6: Run propagation, placement, and Ruby compatibility tests**

Run:

```powershell
ruby test/text_parser_transform_test.rb
ruby test/text_item_metadata_propagation_test.rb
ruby test/text_angle_hint_test.rb
ruby test/bootstrap_provenance_join_test.rb
ruby test/text_mode_placement_test.rb
ruby test/ruby22_compat_test.rb
python tools/check_su2017_ruby_compat.py extracted/sketchup_ext
```

Expected: all PASS; the external marker and existing anchors remain unchanged.

- [ ] **Step 7: Commit metadata propagation**

```powershell
git add test/text_parser_transform_test.rb test/text_item_metadata_propagation_test.rb test/text_angle_hint_test.rb test/bootstrap_provenance_join_test.rb extracted/sketchup_ext/bc_pdf_vector_importer/text_parser.rb extracted/sketchup_ext/bc_pdf_vector_importer/external_text_extractor.rb extracted/sketchup_ext/bc_pdf_vector_importer/main.rb extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb
git commit -m "fix: carry native text render metadata"
```

### Task 3: Convert PDF em height to the selected SketchUp font metric

**Files:**
- Create: `test/mesh_text_visual_parity_test.rb`
- Modify: `test/mesh_text_scaling_test.rb`
- Modify: `test/mesh_text_height_faithful_test.rb`
- Modify: `test/text_scale_regression_test.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb:30-62,548-624`

**Interfaces:**
- Consumes: Task 2 TextItem font family/style/ratio fields and optional GeometryBuilder option `installed_font_families: Array<String>` for deterministic tests.
- Produces: `mesh_text_font_profile(item) -> Hash`, `mesh_text_pdf_em_height_inches(item) -> Float`, and corrected `mesh_text_height_inches(item, angle, page_height, profile = nil) -> Float`.

- [ ] **Step 1: Replace obsolete full-em expectations with failing metric tests**

Create the focused test file by reusing the established SketchUp stubs:

```ruby
#!/usr/bin/env ruby
require_relative 'mesh_text_scaling_test'

class MeshTextVisualParityTest < Minitest::Test
  def builder_with_fonts(fonts)
    GB.new(Object.new, [], [], LETTER, scale_factor: 1.0,
           import_text: true, use_3d_text: true,
           installed_font_families: fonts)
  end

  def render_item(text, family, ratio, bbox_height = 2.0)
    item = TI.new(text, 50.0, 100.0, 12.0, 0.0, 'pdftotext', nil,
                  50.0, 100.0, 150.0, 100.0 + bbox_height)
    item.source_font_family = family
    item.source_font_bold = family == 'Arial'
    item.source_font_italic = false
    item.font_to_sketchup_letter_ratio = ratio
    item.font_to_sketchup_letter_ratio_source = :known_font
    item
  end

  def test_exact_known_ratios_and_12pt_arial_canary
    builder = builder_with_fonts(['Arial', 'Arial Narrow', 'RomanT'])
    arial = render_item('SECTION A', 'Arial', 1491.0 / 2048.0)
    romant = render_item('R', 'RomanT', 1538.0 / 2048.0)
    assert_in_delta 0.121337890625,
                    builder.send(:mesh_text_height_inches, arial, 0.0, 792.0), 1.0e-12
    assert_in_delta (12.0 / 72.0) * (1538.0 / 2048.0),
                    builder.send(:mesh_text_height_inches, romant, 0.0, 792.0), 1.0e-12
  end

  def test_span_bbox_content_never_changes_vertical_metric
    builder = builder_with_fonts(['Arial'])
    %w[1234 () gypq SECTION].each do |text|
      tiny = render_item(text, 'Arial', 1491.0 / 2048.0, 0.5)
      tall = render_item(text, 'Arial', 1491.0 / 2048.0, 50.0)
      assert_in_delta builder.send(:mesh_text_height_inches, tiny, 0.0, 792.0),
                      builder.send(:mesh_text_height_inches, tall, 0.0, 792.0), 1.0e-12
    end
  end

  def test_unavailable_romant_substitutes_arial_and_uses_arial_metric
    builder = builder_with_fonts(['Arial'])
    item = render_item('R', 'RomanT', 1538.0 / 2048.0)
    profile = builder.send(:mesh_text_font_profile, item)
    assert_equal 'Arial', profile[:family]
    assert_match(/RomanT.*Arial/, profile[:substitution_reason])
    assert_in_delta 1491.0 / 2048.0, profile[:letter_height_ratio], 1.0e-12
  end

  def test_selected_family_and_style_are_passed_to_add_3d_text
    builder = builder_with_fonts(['Arial Narrow'])
    item = render_item('TITLE', 'Arial Narrow', 1491.0 / 2048.0)
    item.source_font_bold = true
    item.source_font_italic = true
    entities = DummyTransformEntities.new
    builder.send(:place_mesh_text, entities, item, 0.0, 0.0, nil)
    assert_equal ['Arial Narrow', true, true], entities.font_style_args.last
  end
end
```

Extend `DummyTransformEntities` with `attr_reader :font_style_args`, initialize it to `[]`, and append `[_font, _bold, _italic]` inside `add_3d_text` so this assertion exercises the actual API call rather than only the profile helper.

Update every full-em assertion in `test/mesh_text_scaling_test.rb` and `test/text_scale_regression_test.rb` to multiply by `1491.0 / 2048.0`. In `test/mesh_text_height_faithful_test.rb`, keep the bbox-height prohibition but scope it to vertical-size and ratio selection; remove the obsolete blanket prohibition on every scaling or erase call because Task 4 adds safe local-X scaling and failure cleanup.

- [ ] **Step 2: Run the metric tests and record the expected RED result**

Run:

```powershell
ruby test/mesh_text_visual_parity_test.rb
ruby test/mesh_text_height_faithful_test.rb
```

Expected: the 12pt canary reports `0.166666...` instead of `0.121337890625`, and `mesh_text_font_profile` is missing.

- [ ] **Step 3: Add deterministic font availability and profile selection**

Store the optional constructor override:

```ruby
@installed_font_families_override = opts[:installed_font_families]
```

Add Ruby 2.2-compatible font helpers:

```ruby
ARIAL_SKETCHUP_LETTER_RATIO = 1491.0 / 2048.0
ROMANT_SKETCHUP_LETTER_RATIO = 1538.0 / 2048.0

def installed_text_font_families
  return @installed_text_font_families if @installed_text_font_families
  names = {}
  supplied = @installed_font_families_override
  if supplied.respond_to?(:each)
    supplied.each { |name| names[name.to_s.downcase] = true }
  else
    begin
      require 'win32/registry'
      key = 'SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts'
      Win32::Registry::HKEY_LOCAL_MACHINE.open(key) do |reg|
        reg.each_value do |name, _type, _data|
          family = name.to_s.sub(/\s+\([^)]*\)\z/, '')
          family = family.sub(/\s+(Bold|Italic|Oblique|Regular).*/i, '')
          names[family.downcase] = true unless family.empty?
        end
      end
    rescue StandardError => e
      Logger.warn('GeometryBuilder', "installed font query failed: #{e.message}; using Arial")
    end
  end
  names['arial'] = true
  @installed_text_font_families = names
end

def trusted_letter_ratio(value)
  ratio = value.to_f
  ratio.finite? && ratio >= 0.60 && ratio <= 0.95 ? ratio : nil
rescue StandardError
  nil
end

def mesh_text_font_profile(item)
  requested = item.respond_to?(:source_font_family) ? item.source_font_family.to_s.strip : ''
  requested = 'Arial' if requested.empty?
  installed = installed_text_font_families
  selected = installed[requested.downcase] ? requested : 'Arial'
  substitution = selected == requested ? nil : "#{requested} unavailable; using #{selected}"
  source_ratio = item.respond_to?(:font_to_sketchup_letter_ratio) ?
                   trusted_letter_ratio(item.font_to_sketchup_letter_ratio) : nil
  ratio = if selected.downcase == 'romant'
            source_ratio || ROMANT_SKETCHUP_LETTER_RATIO
          elsif selected.downcase == 'arial' || selected.downcase == 'arial narrow'
            source_ratio && selected == requested ? source_ratio : ARIAL_SKETCHUP_LETTER_RATIO
          else
            source_ratio || ARIAL_SKETCHUP_LETTER_RATIO
          end
  metric_source = if substitution
                    :font_substitution_arial_family
                  elsif item.respond_to?(:font_to_sketchup_letter_ratio_source) &&
                        item.font_to_sketchup_letter_ratio_source
                    item.font_to_sketchup_letter_ratio_source
                  else
                    :default_arial_family
                  end
  {
    family: selected,
    bold: item.respond_to?(:source_font_bold) && !!item.source_font_bold,
    italic: item.respond_to?(:source_font_italic) && !!item.source_font_italic,
    letter_height_ratio: ratio,
    metric_source: metric_source,
    substitution_reason: substitution
  }
end
```

- [ ] **Step 4: Convert canonical em height exactly once**

Replace the full-em height calculation with:

```ruby
def mesh_text_pdf_em_height_inches(item)
  effective_font_size_pts(item) * PDF_POINT_TO_INCH * @scale
end

def mesh_text_height_inches(item, _angle_deg, _page_h, profile = nil)
  profile ||= mesh_text_font_profile(item)
  height = mesh_text_pdf_em_height_inches(item) * profile[:letter_height_ratio].to_f
  height = MESH_TEXT_HEIGHT_MIN_IN if height < MESH_TEXT_HEIGHT_MIN_IN
  height = MESH_TEXT_HEIGHT_MAX_IN if height > MESH_TEXT_HEIGHT_MAX_IN
  height
rescue StandardError => e
  @text_height_fallback_count = @text_height_fallback_count.to_i + 1
  if @text_height_fallback_count <= 3
    Logger.warn('GeometryBuilder',
                "mesh_text_height_inches failed (#{e.class}: #{e.message}); " \
                "using #{MESH_TEXT_HEIGHT_MIN_IN}\" minimum " \
                "(occurrence #{@text_height_fallback_count})")
  end
  MESH_TEXT_HEIGHT_MIN_IN
end
```

In `place_mesh_text`, compute one profile and pass its family/bold/italic and corrected height to `add_3d_text`; keep tolerance `0.0`, extrusion `0.0`, fill `true`, and z `0.0`.

- [ ] **Step 5: Run height, style, tiny-text, and Ruby 2.2 gates**

Run:

```powershell
ruby test/mesh_text_visual_parity_test.rb
ruby test/mesh_text_scaling_test.rb
ruby test/mesh_text_height_faithful_test.rb
ruby test/text_scale_regression_test.rb
ruby test/ruby22_compat_test.rb
python tools/check_su2017_ruby_compat.py extracted/sketchup_ext
```

Expected: PASS; the 12pt value is exactly `0.121337890625`, bbox height has no vertical effect, and the loud 0.01-inch safety fallback remains counted.

- [ ] **Step 6: Commit metric conversion**

```powershell
git add test/mesh_text_visual_parity_test.rb test/mesh_text_scaling_test.rb test/mesh_text_height_faithful_test.rb test/text_scale_regression_test.rb extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb
git commit -m "fix: convert PDF em size for SketchUp 3D text"
```

### Task 4: Apply shrink-only local-X fitting and clean partial meshes

**Files:**
- Modify: `test/mesh_text_visual_parity_test.rb`
- Modify: `test/mesh_text_scaling_test.rb`
- Modify: `test/geometry_builder_text_fallback_test.rb`
- Modify: `test/text_mode_placement_test.rb`
- Modify: `test/shop_bom_visual_parity_regression_test.rb`
- Modify: `test/text_label_placement_test.rb`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb:591-669`

**Interfaces:**
- Consumes: `TextItem#trusted_text_matrix_x_scale`, external bbox coordinates, selected font profile, unchanged insertion anchor.
- Produces: `mesh_text_matrix_x_scale(item) -> Float`, `mesh_text_residual_x_scale(item, entities, display_angle, matrix_x) -> [Float, Symbol, String]`, phase-specific ordered transforms inside `place_mesh_text`, and `erase_partial_mesh_entities(entities, created) -> Boolean`.

- [ ] **Step 1: Add failing local-X and order tests**

Extend `test/mesh_text_visual_parity_test.rb` with a deterministic entity collection whose generated width is `1.0` inch, then add:

```ruby
def test_trusted_matrix_x_can_grow_and_bbox_residual_cannot_grow
  builder = builder_with_fonts(['Arial Narrow'])
  item = render_item('ONE FRAME', 'Arial Narrow', 1491.0 / 2048.0)
  item.trusted_text_matrix_x_scale = 1.436458
  item.bbox_x0, item.bbox_x1 = 0.0, 200.0
  generated = [DummyRenderedTextEntity.new(1.0, 0.1)]
  residual, status, reason = builder.send(:mesh_text_residual_x_scale,
                                           item, generated, 0.0, 1.436458)
  assert_equal 1.0, residual
  assert_equal :skipped, status
  assert_equal 'no_overflow', reason
  assert_in_delta 1.436458,
                  builder.send(:mesh_text_matrix_x_scale, item) * residual, 1.0e-6
end

def test_bbox_only_shrinks_and_rejects_extreme_outlier
  builder = builder_with_fonts(['Arial'])
  item = render_item('BOM', 'Arial', 1491.0 / 2048.0)
  generated = [DummyRenderedTextEntity.new(1.0, 0.1)]
  item.bbox_x0, item.bbox_x1 = 0.0, 54.0
  residual, status, = builder.send(:mesh_text_residual_x_scale, item, generated, 0.0, 1.0)
  assert_in_delta 0.75, residual, 1.0e-9
  assert_equal :fitted, status
  item.bbox_x1 = 20.0
  residual, status, = builder.send(:mesh_text_residual_x_scale, item, generated, 0.0, 1.0)
  assert_equal 1.0, residual
  assert_equal :rejected_outlier, status
end

def test_diagonal_span_keeps_matrix_x_without_bbox_reconciliation
  builder = builder_with_fonts(['Arial'])
  item = render_item('DIAGONAL', 'Arial', 1491.0 / 2048.0)
  item.trusted_text_matrix_x_scale = 0.8
  residual, status, reason = builder.send(:mesh_text_residual_x_scale,
                                           item, [DummyRenderedTextEntity.new(1, 0.1)], 41.0, 0.8)
  assert_equal [1.0, :skipped, 'diagonal_angle'], [residual, status, reason]
end
```

Update the transformation stubs so `Geom::Transformation.rotation` records `:rotation`, `new(point)` records `:translation`, and `scaling(ORIGIN, x, 1.0, 1.0)` records `:scaling` with its exact arguments. Change `test/text_mode_placement_test.rb` to expect `[:scaling, :translation, :rotation]` while leaving every anchor assertion unchanged.

In `test/geometry_builder_text_fallback_test.rb`, add scale-, translation-, and rotation-failure cases that assert all created mesh entities are erased before `add_text` is called. Add a cleanup-failure case that asserts no Label is added and `text_delivery_failures` contains a `_partial_cleanup_failed` reason.

- [ ] **Step 2: Run the focused tests and record the expected RED result**

Run:

```powershell
ruby test/mesh_text_visual_parity_test.rb
ruby test/geometry_builder_text_fallback_test.rb
ruby test/text_mode_placement_test.rb
```

Expected: missing local-X helper errors; transform-order assertion sees translation before rotation; failure tests reveal partial mesh entities remain.

- [ ] **Step 3: Implement validated matrix and bbox width factors**

Add:

```ruby
MESH_TEXT_RESIDUAL_MIN = 0.50
MESH_TEXT_AXIS_ANGLE_TOL_DEG = 3.0

def mesh_text_matrix_x_scale(item)
  value = item.respond_to?(:trusted_text_matrix_x_scale) ?
            item.trusted_text_matrix_x_scale.to_f : 0.0
  value.finite? && value > 0.0 ? value : 1.0
rescue StandardError
  1.0
end

def mesh_text_entities_width_inches(created)
  mins = []
  maxs = []
  Array(created).each do |entity|
    next unless entity.respond_to?(:bounds)
    bounds = entity.bounds
    mins << bounds.min.x.to_f
    maxs << bounds.max.x.to_f
  end
  return nil if mins.empty? || maxs.empty?
  width = maxs.max - mins.min
  width.finite? && width > 0.0 ? width : nil
rescue StandardError
  nil
end

def mesh_text_bbox_run_width_inches(item, display_angle)
  values = [:bbox_x0, :bbox_y0, :bbox_x1, :bbox_y1].map do |name|
    return nil unless item.respond_to?(name) && !item.send(name).nil?
    item.send(name).to_f
  end
  return nil unless values.all? { |value| value.finite? }
  return nil if (values[2] - values[0]).abs <= 1.0e-9 ||
                (values[3] - values[1]).abs <= 1.0e-9
  box = PageTransform.transform_bbox(values[0], values[1], values[2], values[3],
                                     @media_box, @page_rotation)
  angle = PageTransform.normalize_angle(display_angle).abs
  points = if angle <= MESH_TEXT_AXIS_ANGLE_TOL_DEG
             (box[2] - box[0]).abs
           elsif (angle - 90.0).abs <= MESH_TEXT_AXIS_ANGLE_TOL_DEG
             (box[3] - box[1]).abs
           else
             return nil
           end
  width = points * PDF_POINT_TO_INCH * @scale
  width.finite? && width > 0.0 ? width : nil
rescue StandardError
  nil
end

def mesh_text_residual_x_scale(item, created, display_angle, matrix_x)
  angle = PageTransform.normalize_angle(display_angle).abs
  unless angle <= MESH_TEXT_AXIS_ANGLE_TOL_DEG ||
         (angle - 90.0).abs <= MESH_TEXT_AXIS_ANGLE_TOL_DEG
    return [1.0, :skipped, 'diagonal_angle']
  end
  generated = mesh_text_entities_width_inches(created)
  target = mesh_text_bbox_run_width_inches(item, display_angle)
  return [1.0, :skipped, 'invalid_width'] unless generated && target
  width_after_matrix = generated * matrix_x.to_f
  return [1.0, :skipped, 'invalid_width'] unless width_after_matrix.finite? && width_after_matrix > 0.0
  factor = target / width_after_matrix
  return [1.0, :skipped, 'no_overflow'] if factor >= 1.0
  return [1.0, :rejected_outlier, 'residual_below_0_50'] if factor < MESH_TEXT_RESIDUAL_MIN
  [factor, :fitted, 'bbox_overflow_shrink']
rescue StandardError
  [1.0, :skipped, 'fit_exception']
end
```

- [ ] **Step 4: Implement exact transform order and verified cleanup**

Add:

```ruby
def erase_partial_mesh_entities(entities, created)
  doomed = Array(created).compact
  return true if doomed.empty?
  entities.erase_entities(*doomed)
  remaining = entities.respond_to?(:to_a) ? entities.to_a : []
  (doomed & remaining).empty?
rescue StandardError => e
  Logger.warn('GeometryBuilder', "partial 3D text cleanup failed: #{e.message}")
  false
end
```

Refactor `place_mesh_text` around these invariants:

```ruby
profile = mesh_text_font_profile(item)
pdf_em_height = mesh_text_pdf_em_height_inches(item)
height = mesh_text_height_inches(item, display_angle, page_h, profile)
count_before = entities.to_a.length
created = []
phase = :generation
begin
  success = entities.add_3d_text(item.text, TextAlignLeft, profile[:family],
                                 profile[:bold], profile[:italic], height,
                                 0.0, 0.0, true, 0.0)
  created = entities.to_a[count_before..-1] || []
  unless success && !created.empty?
    reason = success ? 'text3d_mesh_empty' : 'text3d_mesh_unavailable'
    cleanup_ok = erase_partial_mesh_entities(entities, created)
    unless cleanup_ok
      record_text_delivery_failure(requested_mode, "#{reason}_partial_cleanup_failed")
      return false
    end
    return fallback_mesh_text_to_label(entities, item, origin_x, origin_y, layer,
                                       requested_mode, mesh_failure_reason(requested_mode, reason))
  end
  matrix_x = mesh_text_matrix_x_scale(item)
  residual_x, fit_status, fit_reason =
    mesh_text_residual_x_scale(item, created, display_angle, matrix_x)
  total_x = matrix_x * residual_x
  phase = :scale
  scale = Geom::Transformation.scaling(ORIGIN, total_x, 1.0, 1.0)
  entities.transform_entities(scale, *created)
  phase = :translation
  entities.transform_entities(Geom::Transformation.new(pt), *created)
  if display_angle.abs > 0.1
    phase = :rotation
    rotation = Geom::Transformation.rotation(pt, Z_AXIS, display_angle.degrees)
    entities.transform_entities(rotation, *created)
  end
rescue StandardError => e
  created = entities.to_a[count_before..-1] || [] if created.empty?
  reason = phase == :generation ? 'text3d_generation_exception' :
                                  "text3d_#{phase}_transform_failed"
  Logger.warn('GeometryBuilder', "#{reason}: #{e.message}")
  unless erase_partial_mesh_entities(entities, created)
    record_text_delivery_failure(requested_mode, "#{reason}_partial_cleanup_failed")
    return false
  end
  return fallback_mesh_text_to_label(entities, item, origin_x, origin_y, layer,
                                     requested_mode, mesh_failure_reason(requested_mode, reason))
end
```

After this block, retain the existing face/material/layer updates, counters, provenance, and return value, replacing the old `new_ents` references with `created`. Task 5 records `pdf_em_height`, `profile`, `matrix_x`, `residual_x`, `fit_status`, `fit_reason`, `total_x`, and failure phase.

- [ ] **Step 5: Run local-X, cleanup, placement, and face-preservation tests**

Run:

```powershell
ruby test/mesh_text_visual_parity_test.rb
ruby test/mesh_text_scaling_test.rb
ruby test/geometry_builder_text_fallback_test.rb
ruby test/text_mode_placement_test.rb
ruby test/shop_bom_visual_parity_regression_test.rb
ruby test/text_label_placement_test.rb
```

Expected: PASS; every successful 3D Text placement uses exact `[total_x, 1.0, 1.0]`, anchors stay unchanged, filled faces remain, and failed partial meshes cannot coexist with Labels.

- [ ] **Step 6: Commit local-X correction and cleanup**

```powershell
git add test/mesh_text_visual_parity_test.rb test/mesh_text_scaling_test.rb test/geometry_builder_text_fallback_test.rb test/text_mode_placement_test.rb test/shop_bom_visual_parity_regression_test.rb test/text_label_placement_test.rb extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb
git commit -m "fix: fit and clean native 3D text meshes"
```

### Task 5: Make every 3D Text metric and fallback decision truthful in the report

**Files:**
- Modify: `test/mesh_text_visual_parity_test.rb`
- Modify: `test/qa_report_test.rb`
- Modify: `test/import_report_parity_floor_test.rb`
- Modify: `test/fixtures/sketchup_report_parity_floor.json`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb:52-62,177-186,578-669`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/main.rb:317-332,1014-1024,1416-1422,1535-1540`
- Modify: `extracted/sketchup_ext/bc_pdf_vector_importer/qa_report.rb:266-318`

**Interfaces:**
- Consumes: Task 3 font profile and Task 4 matrix/residual/transform results.
- Produces: `result[:mesh_text_telemetry] -> Array<Hash>`, `stats[:mesh_text_telemetry]`, and compatible `report[:extra][:text_height_crosscheck]` with distinct PDF-em and SketchUp-letter-height summaries.

- [ ] **Step 1: Write failing telemetry and report tests**

Add to `test/mesh_text_visual_parity_test.rb`:

```ruby
def test_success_telemetry_distinguishes_em_letter_height_and_x_factors
  builder = builder_with_fonts(['Arial Narrow'])
  item = render_item('ONE FRAME', 'Arial Narrow', 1491.0 / 2048.0)
  item.trusted_text_matrix_x_scale = 1.436458
  entities = DummyTransformEntities.new
  assert builder.send(:place_mesh_text, entities, item, 0.0, 0.0, nil)
  sample = builder.send(:mesh_text_telemetry).last
  assert_in_delta 12.0 / 72.0, sample[:pdf_em_height_in], 1.0e-12
  assert_in_delta 0.121337890625, sample[:sketchup_letter_height_in], 1.0e-12
  assert_in_delta 1.436458, sample[:matrix_x], 1.0e-6
  assert sample.key?(:residual_x)
  assert sample.key?(:total_x)
  assert_equal 'Arial Narrow', sample[:delivered_font]
end
```

Replace the old flat fixture in `test/qa_report_test.rb` with:

```ruby
stats = {
  pages: 1, primitives: 5, edges: 5, text: 3, layers: [], elapsed_seconds: 0.2,
  mesh_text_telemetry: [
    { pdf_em_height_in: 0.1666666667, sketchup_letter_height_in: 0.121337890625,
      letter_height_ratio: 1491.0 / 2048.0, metric_source: :known_arial_family,
      matrix_x: 1.436458, residual_x: 0.90, total_x: 1.2928122,
      fit_status: :fitted, fit_reason: 'bbox_overflow_shrink',
      outcome: :complete, requested_font: 'Arial Narrow', delivered_font: 'Arial Narrow' },
    { pdf_em_height_in: 0.10, sketchup_letter_height_in: 0.072802734375,
      letter_height_ratio: 1491.0 / 2048.0, metric_source: :default_arial_family,
      matrix_x: 1.0, residual_x: 1.0, total_x: 1.0,
      fit_status: :rejected_outlier, fit_reason: 'residual_below_0_50',
      outcome: :failed_rotation, requested_font: 'RomanT', delivered_font: 'Arial',
      font_substitution_reason: 'RomanT unavailable; using Arial' }
  ],
  text_height_fallback_count: 2
}
report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('t.pdf', {}, stats)
crosscheck = report[:extra][:text_height_crosscheck]
assert_equal 'pdf_em_x_font_metric_then_local_x', crosscheck[:policy]
assert_equal 2, crosscheck[:sample_count]
assert_equal 1, crosscheck[:fitted_count]
assert_equal 1, crosscheck[:rejected_outlier_count]
assert_equal 1, crosscheck[:failed_transform_count]
assert_equal 2, crosscheck[:fallback_count]
assert_equal 1, crosscheck[:font_substitutions]['RomanT unavailable; using Arial']
assert_in_delta 0.10, crosscheck[:pdf_em_height_in][:min], 1.0e-6
assert_in_delta 0.121337890625,
                crosscheck[:sketchup_letter_height_in][:max], 1.0e-9
```

Keep the existing fallback-only and no-mesh cases. Update the parity-floor fixture so `text_height_crosscheck` is conditional native-3D telemetry rather than a required field for label-only imports.

- [ ] **Step 2: Run tests and record the expected RED result**

Run:

```powershell
ruby test/mesh_text_visual_parity_test.rb
ruby test/qa_report_test.rb
ruby test/import_report_parity_floor_test.rb
```

Expected: missing telemetry reader/result fields and the old `nominal_pt_to_inch_x_scale` policy.

- [ ] **Step 3: Record one structured sample for every mesh attempt**

Initialize `@mesh_text_telemetry = []`, add `mesh_text_telemetry: Array(@mesh_text_telemetry)` to `build`, and add:

```ruby
def record_mesh_text_telemetry(sample)
  @mesh_text_telemetry ||= []
  @mesh_text_telemetry << sample
rescue StandardError
  nil
end

def mesh_text_telemetry
  Array(@mesh_text_telemetry)
rescue StandardError
  []
end
```

On success, record:

```ruby
record_mesh_text_telemetry(
  pdf_em_height_in: pdf_em_height,
  sketchup_letter_height_in: height,
  letter_height_ratio: profile[:letter_height_ratio],
  metric_source: profile[:metric_source],
  requested_font: item.respond_to?(:source_font_family) ? item.source_font_family : nil,
  delivered_font: profile[:family],
  font_substitution_reason: profile[:substitution_reason],
  matrix_x: matrix_x,
  residual_x: residual_x,
  total_x: total_x,
  fit_status: fit_status,
  fit_reason: fit_reason,
  outcome: :complete
)
```

Record the same known values on generation or transform failure with `outcome: :failed_generation`, `:failed_scale`, `:failed_translation`, or `:failed_rotation`. Preserve `text_height_samples` as a compatibility array of delivered SketchUp letter heights and preserve `text_height_fallback_count`.

- [ ] **Step 4: Merge telemetry from both builder paths**

Add to `main.rb`:

```ruby
def self.merge_mesh_text_telemetry!(stats, samples)
  stats[:mesh_text_telemetry] ||= []
  Array(samples).each do |sample|
    stats[:mesh_text_telemetry] << sample.dup if sample.is_a?(Hash)
  end
rescue StandardError => e
  Logger.warn('Pipeline', "merge mesh text telemetry failed: #{e.message}")
end
```

Initialize `mesh_text_telemetry: []` in `stats` and call the helper after both `builder.build` and `fallback_builder.build`.

- [ ] **Step 5: Summarize structured telemetry without hiding compatibility data**

Replace `text_height_crosscheck_block` and add two private helpers:

```ruby
def numeric_summary(values)
  sorted = Array(values).map { |value| value.to_f }
                        .select { |value| value.finite? && value > 0.0 }.sort
  return { count: 0, min: 0.0, median: 0.0, max: 0.0 } if sorted.empty?
  { count: sorted.length, min: sorted.first.round(8),
    median: sorted[sorted.length / 2].round(8), max: sorted.last.round(8) }
end

def value_counts(samples, field)
  counts = {}
  Array(samples).each do |sample|
    value = sample[field] || sample[field.to_s]
    next if value.nil? || value.to_s.empty?
    key = value.to_s
    counts[key] = counts.fetch(key, 0) + 1
  end
  counts
end

def text_height_crosscheck_block(stats)
  samples = Array(stats[:mesh_text_telemetry] || stats['mesh_text_telemetry'])
  fallbacks = (stats[:text_height_fallback_count] ||
               stats['text_height_fallback_count']).to_i
  if samples.empty?
    legacy = Array(stats[:text_height_samples] || stats['text_height_samples'])
    return nil if legacy.empty? && fallbacks.zero?
    letter = numeric_summary(legacy)
    return { sample_count: letter[:count], min_in: letter[:min],
             median_in: letter[:median], max_in: letter[:max],
             policy: 'legacy_letter_height_samples', fallback_count: fallbacks }
  end
  field = lambda { |sample, name| sample[name] || sample[name.to_s] }
  outcomes = value_counts(samples, :outcome)
  fits = value_counts(samples, :fit_status)
  letter = numeric_summary(samples.map { |sample| field.call(sample, :sketchup_letter_height_in) })
  {
    sample_count: samples.length,
    min_in: letter[:min], median_in: letter[:median], max_in: letter[:max],
    policy: 'pdf_em_x_font_metric_then_local_x',
    pdf_em_height_in: numeric_summary(samples.map { |sample| field.call(sample, :pdf_em_height_in) }),
    sketchup_letter_height_in: letter,
    letter_height_ratio: numeric_summary(samples.map { |sample| field.call(sample, :letter_height_ratio) }),
    metric_sources: value_counts(samples, :metric_source),
    matrix_x: numeric_summary(samples.map { |sample| field.call(sample, :matrix_x) }),
    residual_x: numeric_summary(samples.map { |sample| field.call(sample, :residual_x) }),
    total_x: numeric_summary(samples.map { |sample| field.call(sample, :total_x) }),
    fitted_count: fits.fetch('fitted', 0),
    skipped_count: fits.fetch('skipped', 0),
    rejected_outlier_count: fits.fetch('rejected_outlier', 0),
    failed_transform_count: ['failed_scale', 'failed_translation', 'failed_rotation']
                              .inject(0) { |sum, key| sum + outcomes.fetch(key, 0) },
    fallback_count: fallbacks,
    font_substitutions: value_counts(samples, :font_substitution_reason),
    note: 'PDF em height is converted by a trusted font-level ratio; only local X may be reconciled.'
  }
rescue StandardError
  nil
end
```

- [ ] **Step 6: Run telemetry/report and compatibility gates**

Run:

```powershell
ruby test/mesh_text_visual_parity_test.rb
ruby test/qa_report_test.rb
ruby test/import_report_parity_floor_test.rb
ruby test/ruby22_compat_test.rb
python tools/check_su2017_ruby_compat.py extracted/sketchup_ext
```

Expected: PASS; the report distinguishes em from letter height and exposes every fit, outlier, transform failure, substitution, and fallback count.

- [ ] **Step 7: Commit truthful reporting**

```powershell
git add test/mesh_text_visual_parity_test.rb test/qa_report_test.rb test/import_report_parity_floor_test.rb test/fixtures/sketchup_report_parity_floor.json extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder.rb extracted/sketchup_ext/bc_pdf_vector_importer/main.rb extracted/sketchup_ext/bc_pdf_vector_importer/qa_report.rb
git commit -m "fix: report native 3D text metric decisions"
```

### Task 6: Prove visual parity in SketchUp 2017, then version and publish

**Files:**
- Modify after acceptance only: `README.md:6`
- Modify after acceptance only: `extracted/sketchup_ext/bc_pdf_vector_importer.rb:20`
- Modify after acceptance only: `extracted/sketchup_ext/bc_pdf_vector_importer/metadata.rb:9`
- Evidence outside git: `C:/TMP/su_text3d_live_20260715/`

**Interfaces:**
- Consumes: Tasks 1-5, the `1015 - Rev 0.pdf` fixture, build-only RBZ evidence, a freshly downloaded and byte-verified published RBZ for any host work, verified installed plugin bytes, and proven live probe scripts.
- Produces: passing full suite, Ruby 2.2 proof, release artifact, installed-byte hashes, saved `.skp`, report JSON, probe JSON, registered screenshot, measured acceptance, version `3.7.95`, and pushed commits. Q&A authority remains gated on the follow-on five-mode host matrix.

> **Safety override (2026-07-16):** The historical host-install steps below
> are superseded. Never install or copy bytes from a working tree, build
> directory, local candidate, or locally rebuilt RBZ into SketchUp's Plugins
> directory. Host installation is allowed only from a release artifact freshly
> downloaded from the authoritative release channel, after its SHA-256 matches
> the published value, after every SketchUp process is confirmed closed, and
> with explicit operator approval through the normal RBZ installer.

- [ ] **Step 1: Run all focused tests as a fail-fast gate**

Run:

```powershell
$tests = @(
  'test/pdf_font_metadata_test.rb',
  'test/text_parser_transform_test.rb',
  'test/text_item_metadata_propagation_test.rb',
  'test/text_angle_hint_test.rb',
  'test/mesh_text_visual_parity_test.rb',
  'test/mesh_text_height_faithful_test.rb',
  'test/mesh_text_scaling_test.rb',
  'test/geometry_builder_text_fallback_test.rb',
  'test/text_mode_placement_test.rb',
  'test/text_scale_regression_test.rb',
  'test/qa_report_test.rb',
  'test/import_report_parity_floor_test.rb',
  'test/ruby22_compat_test.rb'
)
foreach ($test in $tests) { ruby $test; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE } }
```

Expected: every test exits 0.

- [ ] **Step 2: Run the complete suite and both Ruby 2.2 gates**

Run:

```powershell
Get-ChildItem -LiteralPath test -Filter '*_test.rb' | ForEach-Object {
  ruby $_.FullName
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
python tools/check_su2017_ruby_compat.py extracted/sketchup_ext
ruby tools/ruby22_syntax_check.rb --include-tests
docker run --rm -v "${PWD}:/work" -w /work ruby:2.2 ruby test/mesh_text_visual_parity_test.rb
```

Expected: full suite PASS, compatibility checker PASS, syntax checker PASS, and the Ruby 2.2 behavioral test PASS.

- [ ] **Step 3: Build and inspect an unversioned release candidate**

Run:

```powershell
$candidate = 'C:\TMP\su_text3d_release_candidate_20260715'
New-Item -ItemType Directory -Path $candidate -Force | Out-Null
python build_release.py --require-poppler-smoke --out $candidate
python tools/test_build_release.py
```

Expected: builder, bundled-helper smoke, and release-builder tests exit 0.

- [ ] **Step 4: Freeze the candidate without touching the host**

Do not install the local candidate. Record its SHA-256 for build evidence only.
Any later host validation must consume a freshly downloaded, published release
whose SHA-256 matches the authoritative published value. Confirm every
SketchUp process is closed before an operator-approved RBZ installation through
the normal installer. Direct loader/folder moves or copies are prohibited.

Expected: candidate build evidence is retained, and the live host is unchanged.

- [ ] **Step 5: Run live probes only after a separate safe release install**

Precondition: the installed extension came from a freshly downloaded published
RBZ, its SHA-256 matched the authoritative published value before installation,
and the install occurred only after every SketchUp process was closed. A local
candidate or working tree does not satisfy this precondition.

Run each probe in a fresh host process:

```powershell
$su = 'C:\Program Files\SketchUp\SketchUp 2017\SketchUp.exe'
Start-Process -FilePath $su -ArgumentList @('-RubyStartup', 'C:\TMP\su_text3d_live_probe_20260715.rb') -Wait
Start-Process -FilePath $su -ArgumentList @('-RubyStartup', 'C:\TMP\su_text3d_width_probe_20260715.rb') -Wait
Get-Content -LiteralPath 'C:\TMP\su_text3d_live_20260715\probe_result.json' -Raw
Get-Content -LiteralPath 'C:\TMP\su_text3d_live_20260715\text3d_width_measurements.json' -Raw
```

Expected host facts: Ruby `2.2.4`, SketchUp `17.2.2555`, requested/reported mode `text3d`, all 289 expected spans delivered, zero silent mode fallback, zero height fallback, no raster substitution, nonempty report/model/image artifacts, and structured em/letter/X telemetry.

- [ ] **Step 6: Perform the registered visual acceptance**

Use the source render `C:/TMP/su_text3d_live_20260715/1015_source-1.png`, the new top view `C:/TMP/su_text3d_live_20260715/1015_text3d_top.png`, and linework registration. Acceptance requires all of the following:

```text
SECTION A and SECTION B visible width error <= 5%
SECTION A and SECTION B visible height error <= 2 registered pixels
BILL OF MATERIAL header and rows do not cross table rules
E-E and F-F dimension text does not cross neighboring dimension lines
GALVANIZED subtitle and title-block text do not overlap adjacent rules
rotated and diagonal spans preserve source angle and baseline
flat capitals, descenders, parentheses, fractions, and plus/minus-90-degree runs retain plausible baseline-relative bounds
no microscopic text, erased faces, duplicate partial mesh, or raster substitution
installed loader/plugin hashes match the byte-verified downloaded release RBZ
```

If any line fails, do not bump the version or edit Q&A authority. Add a failing regression test for the observed defect, return to the responsible task, and rerun Steps 1-6.

- [ ] **Step 7: Bump to 3.7.95 only after acceptance and rebuild/reprobe final bytes**

Use `apply_patch` to change exactly these values:

```text
README.md badge: 3.7.94 -> 3.7.95
extracted/sketchup_ext/bc_pdf_vector_importer.rb PLUGIN_VERSION: 3.7.94 -> 3.7.95
extracted/sketchup_ext/bc_pdf_vector_importer/metadata.rb VERSION: 3.7.94 -> 3.7.95
```

Then run:

```powershell
python build_release.py --require-poppler-smoke --out C:\TMP\su_text3d_release_final_20260715
python tools/test_build_release.py
```

Do not install the locally rebuilt final RBZ. Publish through the authorized
release workflow first. For any later host probe, download that published RBZ
freshly, verify its SHA-256 against the published release value, confirm all
SketchUp processes are closed, obtain operator approval, and install with the
normal RBZ workflow. Never copy or move working-tree or expanded-RBZ files into
the Plugins directory.

Expected: all Step 5-6 facts remain true and `plugin_version` is `3.7.95`.

- [ ] **Step 8: Freeze acceptance evidence and leave Q&A authority unchanged**

Run:

```powershell
$evidence = @(
  'C:\TMP\su_text3d_release_final_20260715\SketchUp-PDF-Importer_v3.7.95.rbz',
  'C:\TMP\su_text3d_live_20260715\probe_result.json',
  'C:\TMP\su_text3d_live_20260715\text3d_width_measurements.json',
  'C:\TMP\su_text3d_live_20260715\1015_text3d_live.skp',
  'C:\TMP\su_text3d_live_20260715\1015_text3d_top.png'
)
Get-FileHash -Algorithm SHA256 -LiteralPath $evidence | Format-Table -AutoSize
```

Expected: every evidence file exists and has a SHA256. Do not edit, archive, quarantine, or delete any Q&A document in this plan. The follow-on host-matrix plan owns the final Q&A authority update, QA007 repair, recovery check, and removal of stale instructions after all modes pass.

- [ ] **Step 9: Final review, commit, and push**

Run:

```powershell
git diff --check
git status --short
git log --oneline --decorate -8
```

Request a specification review and a code-quality review of the complete diff. After both approve and all evidence is fresh:

```powershell
git add README.md extracted/sketchup_ext/bc_pdf_vector_importer.rb extracted/sketchup_ext/bc_pdf_vector_importer/metadata.rb
git commit -m "release: publish SketchUp importer 3.7.95"
git push origin main
git status --short --branch
```

Expected: push succeeds; local `main` and `origin/main` match; working tree is clean. Commit Q&A changes in their owning repository if one exists; otherwise report their absolute paths and hashes without pretending they were pushed.

## Follow-On Boundary

After Task 6 passes, create and execute a separate design/plan for the host-result contract and adjacent false-green paths: page outcomes, forced Raster multi-page/report flow, SVG empty/partial cleanup, Labels+OCG extraction routing, distinct Geometry/Glyph semantics, explicit mode host startup, saved-model/result JSON, and release consumption of a fresh five-mode SketchUp matrix. This boundary prevents those independent changes from obscuring whether native 3D Text itself achieved visual parity.
