#!/usr/bin/env ruby
# test/text_angle_hint_test.rb
# Internal PDF text matrix angles enrich external bbox text items.

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/main'

$failures = []
$pass_count = 0

def assert_true(cond, msg)
  return $pass_count += 1 if cond
  $failures << msg
end

def assert_near(actual, expected, tol, msg)
  assert_true((actual.to_f - expected.to_f).abs <= tol, msg)
end

ti = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem

external = [
  ti.new('w1023', 822.0, 760.0, 33.0, 0.0, 'pdftotext', nil,
         822.0, 760.0, 833.0, 794.0, nil),
  ti.new('p1016', 868.0, 703.0, 11.0, 0.0, 'pdftotext', nil,
         868.0, 703.0, 900.0, 714.0, nil)
]

internal = [
  ti.new('w1023', 831.0, 760.0, 11.0, -90.0, 'F1', 1.0,
         nil, nil, nil, nil, nil),
  ti.new('p1016', 868.0, 703.0, 11.0, 41.0, 'F1', 1.0,
         nil, nil, nil, nil, nil)
]

merged = BlueCollarSystems::PDFVectorImporter.apply_internal_text_angle_hints(
  external, internal
)

assert_near(merged[0].angle, -90.0, 0.01,
            'near matching internal angle should enrich external bbox item')
assert_near(merged[0].x, 831.0, 0.01,
            'angle enrichment should adopt internal text-matrix X origin')
assert_near(merged[0].y, 760.0, 0.01,
            'angle enrichment should adopt internal text-matrix Y origin')
assert_near(merged[0].font_size, 11.0, 0.01,
            'angle enrichment should adopt internal nominal text size')
assert_near(merged[0].bbox_x0, external[0].bbox_x0, 0.01,
            'angle enrichment must preserve external bbox placement')
assert_near(merged[1].angle, 41.0, 0.01,
            'matching rotated part marks should accept source text-matrix angle')
assert_near(merged[1].font_size, 11.0, 0.01,
            'matching rotated part marks should keep internal nominal size')

horizontal = [
  ti.new('HORIZ', 400.0, 500.0, 2.0, 0.0, 'pdftotext', nil,
         400.0, 496.0, 420.0, 502.0, nil)
]
horizontal_hints = [
  ti.new('HORIZ', 402.0, 498.0, 8.0, 0.0, 'F1', 8.0,
         nil, nil, nil, nil, nil)
]
horizontal_merged = BlueCollarSystems::PDFVectorImporter.apply_internal_text_angle_hints(
  horizontal, horizontal_hints
)
assert_near(horizontal_merged[0].font_size, 8.0, 0.01,
            'horizontal external bbox text should adopt internal nominal size')
assert_near(horizontal_merged[0].angle, 0.0, 0.01,
            'horizontal nominal size enrichment should preserve horizontal angle')

far_internal = [
  ti.new('w1023', 1800.0, 1600.0, 11.0, -90.0, 'F1', 1.0,
         nil, nil, nil, nil, nil)
]
far_merged = BlueCollarSystems::PDFVectorImporter.apply_internal_text_angle_hints(
  [external[0]], far_internal
)
assert_near(far_merged[0].angle, 0.0, 0.01,
            'far internal text must not rotate an unrelated external item')

# Poppler bbox output commonly omits leading/trailing spaces.  The nearby
# internal source span is the semantic-content authority; bbox geometry still
# comes from the external item.
semantic_external = [
  ti.new('A', 100.0, 200.0, 10.0, 0.0, 'pdftotext', nil,
         100.0, 200.0, 110.0, 212.0, nil)
]
semantic_internal = [
  ti.new(' A ', 100.0, 200.0, 10.0, 0.0, 'F1', 10.0,
         nil, nil, nil, nil, nil),
  ti.new('   ', 130.0, 200.0, 10.0, 0.0, 'F1', 10.0,
         nil, nil, nil, nil, nil)
]
semantic_internal[1].source_decode_complete = true
semantic_merged = BlueCollarSystems::PDFVectorImporter.apply_internal_text_angle_hints(
  semantic_external, semantic_internal
)
assert_true(semantic_merged[0].text == ' A ',
            'internal source text must restore exact leading/trailing spaces')
assert_true(semantic_merged.any? { |item| item.text == '   ' },
            'whitespace-only internal source spans must not disappear')

# A decoder can recover only trailing spaces from an otherwise undecodable
# painted source run.  If that internal anchor is already owned by Poppler's
# visible bbox item, appending the whitespace fragment would invent a second
# source span at the same ink and make exact delivery impossible.
shadow_external = [
  ti.new("\u03A61", 724.7812, 552.8345, 7.0, 0.0, 'pdftotext', nil,
         724.7812, 552.8345, 734.2592, 562.1515, nil)
]
shadow_internal = [
  ti.new('   ', 724.7812, 552.8345, 7.0, 0.0, '/T1_0', 1.0,
         nil, nil, nil, nil, nil)
]
shadow_internal[0].source_decode_complete = false
shadow_merged = BlueCollarSystems::PDFVectorImporter.apply_internal_text_angle_hints(
  shadow_external, shadow_internal
)
assert_true(shadow_merged.length == 1 && shadow_merged[0].text == "\u03A61",
            'unresolved raw source codes must suppress an incomplete whitespace-only decode')

overlap_internal = [
  ti.new(' ', 724.7812, 552.8345, 7.0, 0.0, '/T1_0', 1.0,
         nil, nil, nil, nil, nil)
]
overlap_internal[0].source_decode_complete = true
overlap_merged = BlueCollarSystems::PDFVectorImporter.apply_internal_text_angle_hints(
  shadow_external, overlap_internal
)
assert_true(overlap_merged.length == 2 && overlap_merged[1].text == ' ',
            'a completely decoded whitespace operand must survive even when its anchor overlaps visible ink')

# Dense shop drawings repeat short strings such as dimensions and bolt counts.
# Matching must stay indexed by normalized text instead of normalizing and
# scanning every internal hint for every external item.
mod = BlueCollarSystems::PDFVectorImporter
singleton = class << mod; self; end
singleton.send(
  :alias_method,
  :__text_angle_hint_test_original_normalize_text_key,
  :normalize_text_key
)
normalize_calls = 0
singleton.send(:define_method, :normalize_text_key) do |value|
  normalize_calls += 1
  __text_angle_hint_test_original_normalize_text_key(value)
end
begin
  dense_external = []
  dense_internal = []
  120.times do |index|
    x = index.to_f * 10.0
    dense_external << ti.new(
      'BOLT', x, 100.0, 6.0, 0.0, 'pdftotext', nil,
      x, 96.0, x + 8.0, 104.0, nil
    )
    dense_internal << ti.new(
      'BOLT', x + 1.0, 100.0, 6.0, index.even? ? 0.0 : 90.0,
      'F1', 6.0, nil, nil, nil, nil, nil
    )
  end
  dense_merged = mod.apply_internal_text_angle_hints(
    dense_external, dense_internal
  )
  assert_true(
    dense_merged.length == dense_external.length,
    'indexed angle-hint matching must preserve the dense source inventory'
  )
  assert_near(
    dense_merged[119].x, dense_internal[119].x, 0.01,
    'indexed angle-hint matching must still select the nearest repeated string'
  )
  assert_true(
    normalize_calls < 1000,
    "dense angle-hint matching normalized text #{normalize_calls} times; " \
      'expected a bounded indexed pass'
  )
ensure
  singleton.send(
    :alias_method,
    :normalize_text_key,
    :__text_angle_hint_test_original_normalize_text_key
  )
  singleton.send(
    :remove_method,
    :__text_angle_hint_test_original_normalize_text_key
  )
end

timing_stats = {}
BlueCollarSystems::PDFVectorImporter.record_pipeline_timing!(
  timing_stats, :page_parse_ms, 12.5
)
BlueCollarSystems::PDFVectorImporter.record_pipeline_timing!(
  timing_stats, :page_parse_ms, 7.5
)
assert_near(
  timing_stats[:pipeline_performance][:page_parse_ms], 20.0, 0.001,
  'pipeline phase timings must accumulate across pages'
)

puts
if $failures.empty?
  puts "PASS: #{$pass_count} assertions"
  exit 0
else
  puts "FAIL: #{$failures.length} assertion(s)"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end
