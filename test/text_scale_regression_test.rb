# frozen_string_literal: true
# Regression tests for 3D text / label font-size reconciliation (3D-TEXT-SCALE).

SRC_ROOT = File.expand_path('../extracted/sketchup_ext', __dir__)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

load File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'text_parser.rb')
load File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb')

def assert_true(cond, msg)
  raise "#{msg}" unless cond
end

def assert_near(a, b, tol, msg)
  raise "#{msg} (got #{a}, expected #{b})" if (a.to_f - b.to_f).abs > tol
end

module Sketchup
  class Model
    def layers; @layers ||= {}; end
    def layers_add(name); layers[name] = name; end
  end
end

builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
  Sketchup::Model.new,
  [],
  [],
  [0, 0, 612, 792],
  scale_factor: 1.0,
  import_text: true,
  use_3d_text: true
)

Item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem

# Tf undershoots bbox (CTM-inflated footprint) — should grow toward bbox height.
undersized = Item.new(
  'W12X30', 100.0, 200.0, 6.0, 0.0, 'Helvetica', 6.0,
  100.0, 190.0, 160.0, 204.0
)
eff = builder.send(:effective_font_size_pts, undersized)
assert_true(eff >= 13.0, "CTM/bbox mismatch should grow effective font size (got #{eff})")

# pdftotext path: bbox height is authoritative; 3D mesh height must not be halved.
pdftotext_item = Item.new(
  'QUAN', 100.0, 200.0, 12.0, 0.0, 'pdftotext', nil,
  90.0, 198.0, 130.0, 210.0
)
mesh_h = builder.send(:mesh_text_height_inches, pdftotext_item, 0.0, 792.0)
cap_ratio = BlueCollarSystems::PDFVectorImporter::GeometryBuilder::MESH_TEXT_BBOX_CAP_RATIO
expected_h = 12.0 * cap_ratio * BlueCollarSystems::PDFVectorImporter::GeometryBuilder::PDF_POINT_TO_INCH
assert_near(mesh_h, expected_h, 0.0005,
            'pdftotext 3D text height should use bbox cap ratio without extra 0.55 damping')

# Non-uniform matrix simulation: effective size stored on item should reconcile.
oversized = Item.new(
  '13/16', 200.0, 300.0, 18.0, 0.0, 'Helvetica', 18.0,
  200.0, 292.0, 220.0, 304.0
)
eff_small = builder.send(:effective_font_size_pts, oversized)
assert_true(eff_small <= 12.0, "Tf overshoot vs bbox should shrink (got #{eff_small})")

# Mesh height must use PDF-space bbox angle, not display angle after /Rotate.
rotated_builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
  Sketchup::Model.new,
  [],
  [],
  [0, 0, 612, 792],
  scale_factor: 1.0,
  import_text: true,
  use_3d_text: true,
  page_rotation: 270
)
portrait_h = builder.send(:mesh_text_height_inches, pdftotext_item, 0.0, 792.0)
rotated_h = rotated_builder.send(:mesh_text_height_inches, pdftotext_item, 0.0, 792.0)
assert_near(portrait_h, rotated_h, 0.0005,
            'mesh text height must be independent of page /Rotate')

puts 'text_scale_regression_test.rb: PASS'
