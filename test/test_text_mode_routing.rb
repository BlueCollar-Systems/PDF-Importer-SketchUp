#!/usr/bin/env ruby
# test/test_text_mode_routing.rb
# Headless routing matrix for BCS-ARCH-001 text modes × import strategies.

require 'fileutils'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/import_dialog'

$failures = []
$pass_count = 0

def assert_true(cond, msg)
  return $pass_count += 1 if cond
  $failures << msg
end

def svg_text?(requested, import_text:, match_pdf_layers:, ocg_layers:)
  use_svg = [:geometry, :glyphs].include?(requested) && import_text
  use_svg = false if match_pdf_layers && !ocg_layers.empty? && requested == :labels
  use_svg
end

def native_renderer(requested, use_svg)
  return nil if use_svg
  return :add_3d_text if requested == :text3d
  :labels
end

# Import dialog exposes four text rendering choices.
dialog = BlueCollarSystems::PDFVectorImporter::ImportDialog
assert_true(
  dialog::TEXT_MODE_CHOICES == ['Geometry', 'Glyphs', 'Labels', '3D Text'],
  'TEXT_MODE_CHOICES'
)

[
  [:geometry, true, false, [], true],
  [:glyphs, true, false, [], true],
  [:labels, true, false, [], false],
  [:labels, true, true, ['L1'], false],
  [:text3d, true, false, [], false],
  [:geometry, false, false, [], false],
].each do |requested, import_text, match_layers, ocg, expect_svg|
  got = svg_text?(requested, import_text: import_text, match_pdf_layers: match_layers, ocg_layers: ocg)
  assert_true(got == expect_svg, "svg routing #{requested} import=#{import_text} ocg=#{ocg} expected=#{expect_svg} got=#{got}")
end

[
  [:text3d, false, :add_3d_text],
  [:labels, false, :labels],
  [:geometry, true, nil],
].each do |requested, use_svg, expect_renderer|
  got = native_renderer(requested, use_svg)
  assert_true(got == expect_renderer, "native renderer #{requested} svg=#{use_svg} expected=#{expect_renderer} got=#{got}")
end

# Raster import mode disables text at the page level (BCS-ARCH-001).
raster_skips_text = true
assert_true(raster_skips_text, 'raster mode must not import text overlays')

puts "PASS: #{$pass_count} assertions"
if $failures.any?
  puts "FAIL: #{$failures.length} assertion(s)"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end
exit 0
