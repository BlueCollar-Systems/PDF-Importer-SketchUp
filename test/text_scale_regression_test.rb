# frozen_string_literal: true
# Script-style regression checks for 3D text height (3D-TEXT-SCALE).

SRC_ROOT = File.expand_path('../extracted/sketchup_ext', __dir__)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

load File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'text_parser.rb')
load File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb')

def assert_near(a, b, tol, msg)
  raise "#{msg} (got #{a}, expected #{b})" if (a.to_f - b.to_f).abs > tol
end

module Sketchup
  class Model
    def layers
      @layers ||= {}
    end
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

item_class = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem
pt_to_in = BlueCollarSystems::PDFVectorImporter::GeometryBuilder::PDF_POINT_TO_INCH

undersized_bbox = item_class.new(
  'W12X30', 100.0, 200.0, 6.0, 0.0, 'Helvetica', 6.0,
  100.0, 190.0, 160.0, 204.0
)
assert_near(
  builder.send(:effective_font_size_pts, undersized_bbox),
  6.0,
  0.0001,
  'bbox mismatch must not change effective font size (nominal parity)'
)

pdftotext_item = item_class.new(
  'QUAN', 100.0, 200.0, 12.0, 0.0, 'pdftotext', nil,
  90.0, 198.0, 130.0, 210.0
)
mesh_h = builder.send(:mesh_text_height_inches, pdftotext_item, 0.0, 792.0)
letter_height_ratio = builder.send(
  :mesh_text_letter_height_ratio, pdftotext_item
)
assert_near(
  mesh_h,
  12.0 * pt_to_in * letter_height_ratio,
  0.0005,
  'pdftotext 3D text height must convert the nominal PDF em into the ' \
    'SketchUp letter_height domain exactly once'
)

oversized_bbox = item_class.new(
  '13/16', 200.0, 300.0, 18.0, 0.0, 'Helvetica', 18.0,
  200.0, 292.0, 220.0, 304.0
)
assert_near(
  builder.send(:effective_font_size_pts, oversized_bbox),
  18.0,
  0.0001,
  'bbox mismatch must not shrink effective font size'
)

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
assert_near(
  portrait_h,
  rotated_h,
  0.0005,
  'mesh text height must be independent of page /Rotate'
)

puts 'text_scale_regression_test.rb: PASS'
