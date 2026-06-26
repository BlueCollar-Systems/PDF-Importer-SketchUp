#!/usr/bin/env ruby
# test/text_label_placement_test.rb
# Headless checks for label anchor heuristics and 1017 PDF text extraction.
# Golden tier: 1017 coordinate assertions below. Unit tier: text_category_placement_test.rb

require 'fileutils'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/external_text_extractor'
require_relative '../corpus_paths'

pdf_1017 = ENV['BCS_1017_PDF'].to_s
pdf_1017 = BlueCollarSystems::PDFVectorImporter::CorpusPaths.resolve_corpus_pdf('1017 - Rev 0.pdf').to_s if pdf_1017.empty?
PDF_1017 = pdf_1017
PDF_TOL = 1.5
TextAlignLeft = 0

class Numeric
  def degrees
    self.to_f * Math::PI / 180.0
  end
end

$failures = []
$pass_count = 0

def assert_true(cond, msg)
  return $pass_count += 1 if cond
  $failures << msg
end

def assert_near(actual, expected, tol, msg)
  assert_true((actual.to_f - expected.to_f).abs <= tol, msg)
end

# Stub SketchUp Geom types used by geometry_builder helpers.
module Geom
  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end

  class Vector3d
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end

  class Transformation
    attr_reader :args, :kind
    def initialize(*args)
      @args = args
      @kind = :translation
    end
    def self.rotation(*args)
      t = new(*args)
      t.instance_variable_set(:@kind, :rotation)
      t
    end
  end
end

ORIGIN = Geom::Point3d.new(0, 0, 0)
Z_AXIS = Geom::Vector3d.new(0, 0, 1)

class DummyTextEntity
  attr_accessor :layer, :display_leader, :vector
end

class DummyMeshEntity
  attr_accessor :layer
end

class DummyEntities
  attr_reader :texts, :mesh_calls, :entities, :transforms

  def initialize
    @texts = []
    @mesh_calls = []
    @entities = []
    @transforms = []
  end

  def to_a
    @entities
  end

  def add_text(text, point, vector = nil)
    ent = DummyTextEntity.new
    @texts << [text, point, vector, ent]
    ent
  end

  def add_3d_text(text, align, font, bold, italic, height, tol, extrusion, filled, z)
    @mesh_calls << { text: text, height: height }
    ent = DummyMeshEntity.new
    @entities << ent
    true
  end

  def transform_entities(*args)
    @transforms << args
  end
end

module Sketchup
  class Model
    def layers; @layers ||= {}; end
    def layers_add(name); layers[name] = name; end
  end
end

load File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb')

builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
  Sketchup::Model.new,
  [],
  [],
  [0, 0, 612, 792],
  scale_factor: 1.0,
  import_text: true,
  use_3d_text: false
)

center_item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
  'QUAN', 100.0, 200.0, 8.0, 0.0, 'pdftotext', nil, 90.0, 198.0, 130.0, 210.0
)
x, y, angle = builder.send(:label_insertion_pdf, center_item)
assert_true(builder.send(:should_center_label?, 'QUAN', 40.0, 8.0, 0.0),
            'BOM header QUAN should center in wide table cell')
assert_true((x - 101.2).abs < 1.0, "centered BOM header should shift X toward bbox center (got #{x})")
assert_true(y > center_item.bbox_y0, 'baseline should sit above bbox bottom')
assert_true(angle.abs < 0.01, 'horizontal label keeps angle')

quan_qty = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
  '2', 110.0, 180.0, 8.0, -90.0, 'pdftotext', nil, 108.0, 160.0, 118.0, 200.0
)
builder.send(:prepare_bom_table_context, [
  BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
    'QUAN', 100.0, 200.0, 8.0, 0.0, 'pdftotext', nil, 98.0, 198.0, 130.0, 210.0
  ),
  BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
    'MARK', 140.0, 200.0, 8.0, 0.0, 'pdftotext', nil, 138.0, 198.0, 170.0, 210.0
  ),
  quan_qty
])
narrow_qty = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
  '1', 109.0, 175.0, 8.0, 0.0, 'pdftotext', nil, 108.0, 166.0, 113.4, 175.1
)
assert_true(builder.send(:bom_table_quantity_label?, '1', 5.4, 9.1, 0.0, narrow_qty),
            'QUAN-column single-digit qty should classify in relaxed BOM cells')
assert_true(builder.send(:label_angle_pdf, narrow_qty).abs > 45.0,
            'QUAN-column qty should stay vertical in BOM table')
mark_item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
  '1017FR1', 145.0, 175.0, 8.0, -90.0, 'pdftotext', nil, 144.0, 166.0, 183.9, 175.1
)
assert_true(builder.send(:label_angle_pdf, mark_item).abs < 0.01,
            'MARK-column labels must stay horizontal even with tall pdftotext bbox')
qx, qy, qang = builder.send(:label_insertion_pdf, quan_qty)
assert_true(builder.send(:bom_table_quantity_label?, '2', 10.0, 42.0, -90.0),
            'narrow vertical numeric cell should classify as BOM quantity')
assert_true(qang.abs > 80.0, "BOM quantity should stay vertical (got #{qang})")
assert_true(qang < 0.0, "negative PDF angle should preserve sign (got #{qang})")
assert_true((qx - 109.0).abs < 2.0, "BOM quantity should center in narrow QUAN cell (got #{qx})")

dim_item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
  '7 1/8', 50.0, 300.0, 6.0, 0.0, 'pdftotext', nil, 48.0, 298.0, 72.0, 306.0
)
dx, dy, dim_angle = builder.send(:label_insertion_pdf, dim_item)
assert_true(!builder.send(:should_center_label?, dim_item.text, 24.0, 6.0, 0.0),
            'dimension text must stay left-aligned at bbox x0')
assert_true((dx - 48.0).abs < 0.01, "dimension label X should anchor at bbox x0 (got #{dx})")
assert_true(dim_angle.abs < 0.01, 'dimension label angle should be horizontal')

internal_item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
  'NOTE', 120.0, 400.0, 10.0, 0.0, 'Helvetica', 10.0
)
ix, iy, _ = builder.send(:label_insertion_pdf, internal_item)
assert_true(ix == 120.0 && iy == 400.0, 'internal parser baseline anchor should remain unchanged')

horiz_vec = builder.send(:label_direction_vector, 0.0)
assert_true(horiz_vec.x.abs < 0.01 && horiz_vec.y.abs < 0.01,
            'horizontal labels should use zero direction vector for SU 2017')

frac_vec = builder.send(:label_direction_vector, -6.4)
assert_true(frac_vec.x.abs < 0.01 && frac_vec.y.abs < 0.01,
            'mild fraction kerning tilt should keep zero direction vector')

rot_vec = builder.send(:label_direction_vector, 90.0)
assert_true(rot_vec.y.abs > 0.99, 'vertical labels should use rotated direction vector')

dummy_entities = DummyEntities.new
builder.send(:place_text, dummy_entities, center_item, 0.0, 0.0, 792.0, 'TextLayer')
assert_true(dummy_entities.texts.length == 1,
            "bbox-backed label should place exactly one SketchUp label (got #{dummy_entities.texts.length})")
placed_text, placed_point, placed_vector, _ = dummy_entities.texts.first
assert_true(placed_text == 'QUAN', "placed text should be QUAN (got #{placed_text.inspect})")
assert_true(placed_point.respond_to?(:x) && placed_point.respond_to?(:y),
            'placed label should receive a SketchUp point, not a raw Float')
assert_true(placed_vector.respond_to?(:x) && placed_vector.respond_to?(:y),
            'placed label should receive a direction vector')

rotated_label = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
  'p1052', 150.0, 220.0, 8.0, 90.0, 'pdftotext', nil, 148.0, 210.0, 158.0, 246.0
)
rotated_entities = DummyEntities.new
builder.send(:place_annotation_label, rotated_entities, rotated_label, 0.0, 0.0, 'TextLayer')
assert_true(rotated_entities.texts.length == 1,
            "Labels mode must create a native SketchUp label for rotated text (got #{rotated_entities.texts.length})")
assert_true(rotated_entities.mesh_calls.empty?,
            'Labels mode must not silently create 3D text/geometry for rotated text')

if File.exist?(PDF_1017)
  # 342 = 346 raw pdftotext words minus 2 angle-mark stitch merges (a1+00+5 → a1005/a1006).
  GOLDEN_1017_ITEM_COUNT = 342
  items = BlueCollarSystems::PDFVectorImporter::ExternalTextExtractor.extract(PDF_1017, 1)
  assert_true(items && items.length == GOLDEN_1017_ITEM_COUNT,
              "1017 PDF regression guard: need exactly #{GOLDEN_1017_ITEM_COUNT} labels (got #{items ? items.length : 0})")
  with_bbox = items.count { |it| builder.send(:label_has_bbox?, it) }
  assert_true(with_bbox > 100, "1017 text items should carry bbox metadata (got #{with_bbox})")
  headers = items.select { |it| it.text.to_s.strip =~ /\A(QUAN|MARK|DESCRIPTION)\z/i }
  assert_true(!headers.empty?, '1017 PDF should include BOM header labels')
  headers.each do |h|
    bw = (h.bbox_x1 - h.bbox_x0).abs
    est_w = h.text.to_s.strip.length * h.font_size.to_f * 0.55
    if bw > est_w * 1.15
      assert_true(builder.send(:should_center_label?, h.text, bw, h.font_size, h.angle),
                  "wide BOM header #{h.text} should use center heuristic")
    else
      assert_true(!builder.send(:should_center_label?, h.text, bw, h.font_size, h.angle),
                  "tight BOM header #{h.text} should left-align at bbox x0")
    end
  end

  def find_label(items, pattern)
    items.find { |it| it.text.to_s.strip =~ pattern }
  end

  quan = find_label(items, /\AQUAN\z/i)
  if quan
    qx, qy, qang = builder.send(:label_insertion_pdf, quan)
    assert_near(qx, 1948.62, PDF_TOL, "QUAN X should stay centered in BOM cell (got #{qx})")
    assert_near(qy, 1656.59, PDF_TOL, "QUAN Y baseline (got #{qy})")
    assert_true(qang.abs < 0.01, "QUAN angle should be horizontal (got #{qang})")
  end

  p1052 = items.select { |it| it.text.to_s.strip == 'p1052' }
                 .min_by { |it| (it.bbox_y0.to_f - 684.21).abs }
  if p1052
    px, py, pang = builder.send(:label_insertion_pdf, p1052)
    assert_near(px, p1052.bbox_x0.to_f, 0.05, "p1052 X should anchor at bbox x0 (got #{px})")
    assert_near(py, 686.15, PDF_TOL, "p1052 Y baseline near section P-P (got #{py})")
    assert_true(pang.abs < 0.01, "p1052 angle should be horizontal (got #{pang})")
  end

  dim_half = items.find { |it| it.text.to_s.strip == '1 1/2' && (it.bbox_x0.to_f - 1434.71).abs < 1.0 }
  if dim_half
    dx, dy, dang = builder.send(:label_insertion_pdf, dim_half)
    assert_near(dx, 1435.63, PDF_TOL, "1 1/2 X should center in narrow vertical bbox (got #{dx})")
    assert_near(dy, 689.32, PDF_TOL, "1 1/2 Y baseline for stacked fraction (got #{dy})")
    assert_true(dang.abs < 0.01, "1 1/2 angle must be horizontal, not stacked-fraction false tilt (got #{dang})")
    assert_true(builder.send(:label_direction_vector, dang).y.abs < 0.01,
                '1 1/2 must use zero direction vector')
  end

  dim_916 = items.find { |it| it.text.to_s.strip == '1 9/16' && (it.bbox_x0.to_f - 1949.40).abs < 1.0 }
  if dim_916
    dx, dy, dang = builder.send(:label_insertion_pdf, dim_916)
    assert_near(dx, 1949.40, PDF_TOL, "1 9/16 X should anchor at bbox x0 (got #{dx})")
    assert_near(dy, 807.97, PDF_TOL, "1 9/16 Y baseline (got #{dy})")
    assert_true(dang.abs < 0.01, "1 9/16 angle should be horizontal (got #{dang})")
  end

  holes = items.find { |it| it.text.to_s.strip == 'HOLES' && (it.bbox_x0.to_f - 1646.51).abs < 1.0 }
  if holes
    hx, hy, _ = builder.send(:label_insertion_pdf, holes)
    assert_near(hx, 1646.51, PDF_TOL, "HOLES X should anchor at bbox x0, not char-count center (got #{hx})")
    assert_true(!builder.send(:should_center_label?, holes.text, (holes.bbox_x1 - holes.bbox_x0).abs,
                              holes.font_size, holes.angle),
                'HOLES must not use table-cell centering heuristic')
  end

  leader = items.find { |it| it.text.to_s.strip == '8-15/16"Ø' && (it.bbox_x0.to_f - 1646.51).abs < 1.0 }
  if leader
    lx, ly, lang = builder.send(:label_insertion_pdf, leader)
    assert_near(lx, 1646.51, PDF_TOL, "8-15/16\"Ø X should anchor at bbox x0 (got #{lx})")
    assert_near(ly, 760.10, PDF_TOL, "8-15/16\"Ø Y baseline (got #{ly})")
    assert_true(lang.abs < 0.01, "8-15/16\"Ø angle should be horizontal (got #{lang})")
  end

  two_two_left = items.find { |it| it.text.to_s.strip == '2 2' && (it.bbox_x0.to_f - 1436.65).abs < 1.0 }
  if two_two_left
    tokens = two_two_left.text.to_s.strip.split(/\s+/)
    expected_y = [727.36, 744.76]
    tokens.each_with_index do |tok, idx|
      sub_by0, sub_by1 = builder.send(:stacked_dimension_row_bounds,
                                      two_two_left.bbox_y0.to_f,
                                      two_two_left.bbox_y1.to_f,
                                      idx,
                                      tokens.length)
      sub = builder.send(
        :sub_dimension_text_item,
        two_two_left,
        tok,
        two_two_left.bbox_x0.to_f,
        two_two_left.bbox_x1.to_f,
        sub_by0,
        sub_by1
      )
      sx, sy, sang = builder.send(:label_insertion_pdf, sub)
      assert_near(sx, 1440.30, PDF_TOL, "SECTION F-F #{tok} ##{idx + 1} X should center in gap (got #{sx})")
      assert_near(sy, expected_y[idx], PDF_TOL, "SECTION F-F #{tok} ##{idx + 1} Y baseline (got #{sy})")
      assert_true(sang.abs < 0.01, "SECTION F-F #{tok} ##{idx + 1} angle should be horizontal (got #{sang})")
    end
    assert_true(builder.send(:stacked_vertical_dimension_labels?, two_two_left),
                'SECTION F-F 2 2 should use stacked vertical dimension placement')
  end

  # SECTION C-C (1017 page 1) — horizontal beam w1023 between w1025 and 1017FR1
  def find_cc_label(items, text, bbox_x0)
    items.find do |it|
      it.text.to_s.strip == text && (it.bbox_x0.to_f - bbox_x0).abs < 1.5
    end
  end

  cc_4_0 = find_cc_label(items, "4'-0", 514.0)
  if cc_4_0
    fx, fy, fang = builder.send(:label_insertion_pdf, cc_4_0)
    assert_near(fx, 514.66, PDF_TOL, "SECTION C-C 4'-0\" X should center in dim bbox (got #{fx})")
    assert_near(fy, 1612.20, PDF_TOL, "SECTION C-C 4'-0\" Y baseline (got #{fy})")
    assert_true(fang.abs < 0.01, "SECTION C-C 4'-0\" angle should be horizontal (got #{fang})")
  end

  cc_311 = find_cc_label(items, "3'-11 3/4", 504.84)
  if cc_311
    mx, my, mang = builder.send(:label_insertion_pdf, cc_311)
    assert_near(mx, 505.77, PDF_TOL, "SECTION C-C 3'-11 3/4\" X should center in dim bbox (got #{mx})")
    assert_near(my, 1592.03, PDF_TOL, "SECTION C-C 3'-11 3/4\" Y baseline (got #{my})")
    assert_true(mang.abs < 0.01, "SECTION C-C 3'-11 3/4\" angle should be horizontal (got #{mang})")
  end

  cc_eighth = find_cc_label(items, '1/8', 368.77)
  if cc_eighth
    ex, ey, eang = builder.send(:label_insertion_pdf, cc_eighth)
    assert_near(ex, 370.70, PDF_TOL, "SECTION C-C 1/8\" X should center in narrow vertical bbox (got #{ex})")
    assert_near(ey, 1592.03, PDF_TOL, "SECTION C-C 1/8\" Y baseline (got #{ey})")
    assert_true(eang.abs < 0.01, "SECTION C-C 1/8\" angle should be horizontal (got #{eang})")
  end

  cc_vert = find_cc_label(items, '3 3/8', 574.76)
  if cc_vert
    vx, vy, vang = builder.send(:label_insertion_pdf, cc_vert)
    assert_near(vx, 575.13, PDF_TOL, "SECTION C-C 3 3/8\" X should center in narrow vertical bbox (got #{vx})")
    assert_near(vy, 1534.48, PDF_TOL, "SECTION C-C 3 3/8\" Y baseline (got #{vy})")
    assert_true(vang.abs < 0.01, "SECTION C-C 3 3/8\" angle should be horizontal (got #{vang})")
  end

  cc_weld = find_cc_label(items, '3/16', 420.37)
  if cc_weld
    wx, wy, wang = builder.send(:label_insertion_pdf, cc_weld)
    assert_near(wx, 420.37, PDF_TOL, "SECTION C-C 3/16\" weld X should anchor at bbox x0 (got #{wx})")
    assert_near(wy, 1542.16, PDF_TOL, "SECTION C-C 3/16\" weld Y baseline (got #{wy})")
    assert_true(wang.abs < 0.01, "SECTION C-C 3/16\" weld angle should be horizontal (got #{wang})")
    assert_true(builder.send(:label_direction_vector, wang).y.abs < 0.01,
                'SECTION C-C 3/16" weld must use zero direction vector')
  end

  cc_typ = find_cc_label(items, 'TYP.', 465.84)
  if cc_typ
    tx, ty, tang = builder.send(:label_insertion_pdf, cc_typ)
    assert_near(tx, 465.84, PDF_TOL, "SECTION C-C TYP. X should anchor at bbox x0 (got #{tx})")
    assert_near(ty, 1551.48, PDF_TOL, "SECTION C-C TYP. Y baseline (got #{ty})")
    assert_true(tang.abs < 0.01, "SECTION C-C TYP. angle should be horizontal (got #{tang})")
  end

  cc_w1023 = find_cc_label(items, 'w1023', 474.24)
  if cc_w1023
    w3x, w3y, _ = builder.send(:label_insertion_pdf, cc_w1023)
    assert_near(w3x, 474.24, PDF_TOL, "SECTION C-C w1023 X should anchor at bbox x0 (got #{w3x})")
    assert_near(w3y, 1529.39, PDF_TOL, "SECTION C-C w1023 Y baseline (got #{w3y})")
  end

  cc_section = items.find { |it| it.text.to_s.strip == 'SECTION - C - C' }
  if cc_section
    sx, sy, _ = builder.send(:label_insertion_pdf, cc_section)
    assert_near(sx, 463.56, PDF_TOL, "SECTION C-C title X should anchor at bbox x0 (got #{sx})")
    assert_near(sy, 1420.08, PDF_TOL, "SECTION C-C title Y baseline (got #{sy})")
  end

  # Main elevation / truss view (1017 page 1)
  def find_main_label(items, text, bbox_x0, bbox_y0 = nil)
    items.find do |it|
      it.text.to_s.strip == text &&
        (it.bbox_x0.to_f - bbox_x0).abs < 2.0 &&
        (bbox_y0.nil? || (it.bbox_y0.to_f - bbox_y0).abs < 8.0)
    end
  end

  top_chord = items.find { |it| it.text.to_s.include?("14'-0 (W12X30") }
  if top_chord
    tx, ty, tang = builder.send(:label_insertion_pdf, top_chord)
    assert_near(tx, 694.29, PDF_TOL, "main top chord spec X should center in bbox (got #{tx})")
    assert_near(ty, 1056.95, PDF_TOL, "main top chord spec Y baseline (got #{ty})")
    assert_true(tang.abs < 0.01, "main top chord spec angle should be horizontal (got #{tang})")
  end

  main_3_5 = find_main_label(items, "3'-5 1/2", 708.60, 1009.71)
  if main_3_5
    mx, my, _ = builder.send(:label_insertion_pdf, main_3_5)
    assert_near(mx, 709.37, PDF_TOL, "main 3'-5 1/2\" X should center in dim bbox (got #{mx})")
    assert_near(my, 1012.19, PDF_TOL, "main 3'-5 1/2\" Y baseline (got #{my})")
  end

  main_4_7 = find_main_label(items, "4'-7 1/2", 990.83, 1009.71)
  if main_4_7
    mx, my, _ = builder.send(:label_insertion_pdf, main_4_7)
    assert_near(mx, 991.60, PDF_TOL, "main 4'-7 1/2\" X should center in dim bbox (got #{mx})")
    assert_near(my, 1012.19, PDF_TOL, "main 4'-7 1/2\" Y baseline (got #{my})")
  end

  main_1_0 = find_main_label(items, "1'-0 3/4", 1189.44, 1009.71)
  if main_1_0
    mx, my, _ = builder.send(:label_insertion_pdf, main_1_0)
    assert_near(mx, 1190.21, PDF_TOL, "main 1'-0 3/4\" X should center in dim bbox (got #{mx})")
    assert_near(my, 1012.19, PDF_TOL, "main 1'-0 3/4\" Y baseline (got #{my})")
  end

  main_34 = find_main_label(items, '3/4', 1126.73, 969.28)
  if main_34
    mx, my, _ = builder.send(:label_insertion_pdf, main_34)
    assert_near(mx, 1129.19, PDF_TOL, "main 3/4\" offset X should center in bbox (got #{mx})")
    assert_near(my, 971.42, PDF_TOL, "main 3/4\" offset Y baseline (got #{my})")
  end

  main_1311 = find_main_label(items, "13'-11 1/4", 733.44, 1032.51)
  if main_1311
    mx, my, _ = builder.send(:label_insertion_pdf, main_1311)
    assert_near(mx, 734.53, PDF_TOL, "main 13'-11 1/4\" X should center in dim bbox (got #{mx})")
    assert_near(my, 1034.99, PDF_TOL, "main 13'-11 1/4\" Y baseline (got #{my})")
  end

  slope_12 = find_main_label(items, '12', 690.26, 731.97)
  if slope_12
    sx, sy, _ = builder.send(:label_insertion_pdf, slope_12)
    assert_near(sx, 692.68, PDF_TOL, "main slope 12 X should center in triangle bbox (got #{sx})")
    assert_near(sy, 734.54, PDF_TOL, "main slope 12 Y centered in triangle bbox (got #{sy})")
  end

  slope_1038 = find_main_label(items, '10 3/8', 706.80, 702.99)
  if slope_1038
    sx, sy, _ = builder.send(:label_insertion_pdf, slope_1038)
    assert_near(sx, 711.91, PDF_TOL, "main slope 10 3/8 X should center in triangle bbox (got #{sx})")
    assert_near(sy, 705.49, PDF_TOL, "main slope 10 3/8 Y baseline (got #{sy})")
  end

  w1023_diag = find_main_label(items, 'w1023', 822.74, 760.18)
  if w1023_diag
    wx, wy, wang = builder.send(:label_insertion_pdf, w1023_diag)
    assert_near(wx, 822.74, PDF_TOL, "connection w1023 X left-anchored at bbox x0 (got #{wx})")
    assert_near(wy, 762.12, PDF_TOL, "connection w1023 Y baseline (got #{wy})")
    assert_true(wang.abs < 0.01, "connection w1023 stays horizontal — tall bbox is not 90° (got #{wang})")
  end

  # Connection detail region (1017 page 1, brace/member cluster)
  conn_p1016 = find_main_label(items, 'p1016', 868.8, 703.41)
  if conn_p1016
    px, py, _ = builder.send(:label_insertion_pdf, conn_p1016)
    assert_near(px, 868.8, PDF_TOL, "connection p1016 X at bbox x0 (got #{px})")
    assert_near(py, 705.35, PDF_TOL, "connection p1016 Y baseline (got #{py})")
  end

  conn_p1017 = find_main_label(items, 'p1017', 639.72, 782.97)
  if conn_p1017
    px, py, _ = builder.send(:label_insertion_pdf, conn_p1017)
    assert_near(px, 639.72, PDF_TOL, "connection p1017 X at bbox x0 (got #{px})")
    assert_near(py, 784.91, PDF_TOL, "connection p1017 Y baseline (got #{py})")
  end

  # SECTION A-A diagonal brace part marks (1017 page 1)
  aa_a1006 = find_main_label(items, 'a1006', 782.16, 297.45)
  if aa_a1006
    ax, ay, aang = builder.send(:label_insertion_pdf, aa_a1006)
    assert_near(ax, 782.16, PDF_TOL, "SECTION A-A a1006 X left-anchored at bbox x0 (got #{ax})")
    assert_near(ay, 299.39, PDF_TOL, "SECTION A-A a1006 Y baseline (got #{ay})")
    assert_true(aang.abs < 0.01,
                "SECTION A-A a1006 stays horizontal per PDF angle (got #{aang})")
  end

  aa_a1005 = find_main_label(items, 'a1005', 901.55, 296.38)
  if aa_a1005
    ax, ay, aang = builder.send(:label_insertion_pdf, aa_a1005)
    assert_near(ax, 901.55, PDF_TOL, "SECTION A-A a1005 X left-anchored at bbox x0 (got #{ax})")
    assert_near(ay, 298.32, PDF_TOL, "SECTION A-A a1005 Y baseline (got #{ay})")
    assert_true(aang.abs < 0.01,
                "SECTION A-A a1005 stays horizontal per PDF angle (got #{aang})")
  end

  conn_78 = find_main_label(items, '7/8', 748.07, 752.11)
  if conn_78
    dx, dy, dang = builder.send(:label_insertion_pdf, conn_78)
    assert_near(dx, 750.51, PDF_TOL, "connection 7/8 X centered in bbox (got #{dx})")
    assert_near(dy, 754.25, PDF_TOL, "connection 7/8 Y baseline (got #{dy})")
    assert_true(dang.abs < 0.01, "connection 7/8 angle horizontal (got #{dang})")
  end

  conn_typ = find_main_label(items, 'TYP.', 736.07, 858.82)
  if conn_typ
    tx, ty, tang = builder.send(:label_insertion_pdf, conn_typ)
    assert_near(tx, 736.07, PDF_TOL, "connection TYP. X at bbox x0 (got #{tx})")
    assert_near(ty, 860.76, PDF_TOL, "connection TYP. Y baseline (got #{ty})")
    assert_true(tang.abs < 0.01, "connection TYP. angle horizontal (got #{tang})")
  end

  conn_1038_vert = find_main_label(items, '10 3/8', 1040.74, 737.61)
  if conn_1038_vert
    sx, sy, sang = builder.send(:label_insertion_pdf, conn_1038_vert)
    assert_near(sx, 1050.19, PDF_TOL, "connection vertical slope 10 3/8 X rotated in tall bbox (got #{sx})")
    assert_near(sy, 742.73, PDF_TOL, "connection vertical slope 10 3/8 Y rotated in tall bbox (got #{sy})")
    assert_near(sang, 90.0, PDF_TOL, "connection vertical slope 10 3/8 angle (got #{sang})")
  end

  main_4_0 = find_main_label(items, "4'-0", 1314.97, 759.57)
  if main_4_0
    vx, vy, vang = builder.send(:label_insertion_pdf, main_4_0)
    assert_near(vx, 1322.31, PDF_TOL, "main vertical 4'-0\" X rotated in tall bbox (got #{vx})")
    assert_near(vy, 760.28, PDF_TOL, "main vertical 4'-0\" Y rotated in tall bbox (got #{vy})")
    assert_near(vang, 90.0, PDF_TOL, "main vertical 4'-0\" angle (got #{vang})")
  end

  sec_bb = items.find { |it| it.text.to_s.strip == 'SECTION - B - B' }
  if sec_bb
    bx, by, _ = builder.send(:label_insertion_pdf, sec_bb)
    assert_near(bx, 783.25, PDF_TOL, "SECTION B-B title X should anchor at bbox x0 (got #{bx})")
    assert_near(by, 1123.56, PDF_TOL, "SECTION B-B title Y baseline (got #{by})")
  end

  main_weld = find_main_label(items, '1/4', 696.25, 849.03)
  if main_weld
    wx, wy, _ = builder.send(:label_insertion_pdf, main_weld)
    assert_near(wx, 696.25, PDF_TOL, "main weld 1/4\" X should anchor at bbox x0 (got #{wx})")
    assert_near(wy, 851.44, PDF_TOL, "main weld 1/4\" Y baseline (got #{wy})")
  end

  placed_entities = DummyEntities.new
  items.each do |item|
    builder.send(:place_text, placed_entities, item, 0.0, 0.0, 792.0, 'TextLayer')
  end
  extra_placements = items.inject(0) do |acc, it|
    acc + (builder.send(:stacked_vertical_dimension_labels?, it) ?
             it.text.to_s.strip.split(/\s+/).length - 1 : 0)
  end
  expected_placements = items.length + extra_placements
  placed_total = placed_entities.texts.length + placed_entities.mesh_calls.length
  assert_true(placed_total == expected_placements,
              "all 1017 bbox-backed labels should place (got #{placed_total} of #{expected_placements})")
  puts "  1017 PDF: #{items.length} text items, #{with_bbox} with bbox, #{headers.length} BOM headers"
else
  puts "  SKIP: 1017 PDF not found at #{PDF_1017}"
end

puts
if $failures.empty?
  puts "PASS: #{$pass_count} assertions"
  exit 0
else
  puts "FAIL: #{$failures.length} assertion(s)"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end
