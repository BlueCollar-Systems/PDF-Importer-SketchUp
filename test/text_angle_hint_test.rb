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

puts
if $failures.empty?
  puts "PASS: #{$pass_count} assertions"
  exit 0
else
  puts "FAIL: #{$failures.length} assertion(s)"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end
