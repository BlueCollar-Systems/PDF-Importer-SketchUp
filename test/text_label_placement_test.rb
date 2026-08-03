#!/usr/bin/env ruby
# test/text_label_placement_test.rb
# Headless checks for label anchor heuristics and optional external-reference extraction.
# Unit tier: text_category_placement_test.rb

require 'fileutils'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/external_text_extractor'
require 'bc_pdf_vector_importer/text_source_identity'
require_relative '../corpus_paths'

PDF_EXTERNAL_REFERENCE = BlueCollarSystems::PDFVectorImporter::CorpusPaths
                         .resolve_acceptance_pdf(
                           'shop-bom-tier1', 'BCS_TIER1_USER_PDF'
                         )
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

def require_acceptance_item(item, description)
  assert_true(!item.nil?, "tier-1 acceptance input is missing #{description}")
  item
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
  attr_reader :persistent_id, :point, :text

  def initialize(id, text, point, vector)
    @persistent_id = id
    @text = text
    @point = point
    @vector = vector
    @display_leader = true
  end

  def typename
    'Text'
  end

  def display_leader?
    @display_leader
  end
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
    @next_id = 100
  end

  def to_a
    @entities
  end

  def add_text(text, point, vector = nil)
    @next_id += 1
    effective_vector = vector || Geom::Vector3d.new(0, 0, 0)
    ent = DummyTextEntity.new(@next_id, text, point, effective_vector)
    @entities << ent
    @texts << [text, point, effective_vector, ent]
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

  def erase_entities(*entities)
    entities.flatten.each { |entity| @entities.delete(entity) }
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
  'QUAN', 100.0, 200.0, 8.0, 0.0, 'pdftotext', nil,
  90.0, 198.0, 130.0, 210.0, nil, 'text_span:1:0'
)
x, y, angle = builder.send(:label_insertion_pdf, center_item)
assert_true(builder.send(:should_center_label?, 'QUAN', 40.0, 8.0, 0.0),
            'BOM header QUAN should center in wide table cell')
# The private golden oracle calibrates BOM headers at 0.55em per glyph.
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
assert_true(builder.send(:label_angle_pdf, narrow_qty).abs < 0.01,
            'QUAN-column qty should stay horizontal in BOM table')
mark_item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem.new(
  '7309FR4', 145.0, 175.0, 8.0, -90.0, 'pdftotext', nil, 144.0, 166.0, 183.9, 175.1
)
assert_true(builder.send(:label_angle_pdf, mark_item).abs < 0.01,
            'MARK-column labels must stay horizontal even with tall pdftotext bbox')
qx, qy, qang = builder.send(:label_insertion_pdf, quan_qty)
assert_true(builder.send(:bom_table_quantity_label?, '2', 10.0, 42.0, -90.0),
            'narrow vertical numeric cell should classify as BOM quantity')
assert_true(qang.abs < 0.01, "BOM quantity should stay horizontal (got #{qang})")
assert_true((qx - 111.25).abs < 2.0, "BOM quantity should center in narrow QUAN cell (got #{qx})")

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

horiz_vec = builder.send(:zero_label_leader_vector)
assert_true(horiz_vec.x.abs < 0.01 && horiz_vec.y.abs < 0.01,
            'horizontal labels should use zero direction vector for SU 2017')

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
  'p7303', 150.0, 220.0, 8.0, 90.0, 'pdftotext', nil,
  148.0, 210.0, 158.0, 246.0, nil, 'text_span:1:1'
)
rotated_entities = DummyEntities.new
rotated_builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
  Sketchup::Model.new,
  [],
  [],
  [0, 0, 612, 792],
  scale_factor: 1.0,
  import_text: true,
  use_3d_text: false
)
rotated_builder.send(:place_annotation_label, rotated_entities, rotated_label, 0.0, 0.0, 'TextLayer')
assert_true(rotated_entities.texts.empty?,
            'SketchUp Text leader vectors must not be misreported as label rotation')
assert_true(rotated_entities.to_a.empty?,
            'known rotated-label host impossibility must leave no artifact')
assert_true(rotated_entities.mesh_calls.empty?,
            'Labels mode must not silently create 3D text/geometry for rotated text')
rotated_failure = rotated_builder.text_delivery_failures.first
assert_true(rotated_failure &&
            rotated_failure[:reason] == 'label_rotation_unsupported_by_host',
            'rotated Labels must emit the affirmative host-limitation reason')
assert_true(rotated_failure && rotated_failure[:transition_proof] &&
            rotated_failure[:transition_proof][:to_mode] == :text3d,
            'rotated Labels may advance only to the adjacent verified rung')

if PDF_EXTERNAL_REFERENCE && File.file?(PDF_EXTERNAL_REFERENCE)
  items = BlueCollarSystems::PDFVectorImporter::ExternalTextExtractor.extract(PDF_EXTERNAL_REFERENCE, 1)
  items ||= []
  BlueCollarSystems::PDFVectorImporter::TextSourceIdentity.assign!(items, 1)
  builder.send(:prepare_bom_table_context, items)
  golden_item_count = 342
  assert_true(items && items.length == golden_item_count,
              "tier-1 acceptance coverage requires exactly #{golden_item_count} labels " \
              "(got #{items ? items.length : 0})")
  with_bbox = items.count { |it| builder.send(:label_has_bbox?, it) }
  assert_true(with_bbox > 100,
              "tier-1 acceptance items should carry dense bbox metadata (got #{with_bbox})")
  headers = items.select { |it| it.text.to_s.strip =~ /\A(QUAN|MARK|DESCRIPTION)\z/i }
  assert_true(!headers.empty?, 'external reference should include BOM header labels')
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

  bom_qty_three = items.find do |it|
    it.text.to_s.strip == '3' &&
      (it.bbox_x0.to_f - 1955.06).abs < 1.0 &&
      (it.bbox_y0.to_f - 1522.31).abs < 1.0
  end
  if bom_qty_three
    bx, by, bang = builder.send(:label_insertion_pdf, bom_qty_three)
    assert_near(bx, 1956.29, PDF_TOL, "BOM quantity 3 X should center in QUAN cell (got #{bx})")
    assert_near(by, 1524.96, PDF_TOL, "BOM quantity 3 Y baseline (got #{by})")
    assert_true(bang.abs < 0.01, "BOM quantity 3 should stay horizontal (got #{bang})")
  end

  part_mark_pattern = /\A[a-z]\d+\z/i
  section_part = require_acceptance_item(
    items.select { |it| part_mark_pattern =~ it.text.to_s.strip }
         .min_by { |it| (it.bbox_y0.to_f - 684.21).abs },
    'the section part mark'
  )
  if section_part
    px, py, pang = builder.send(:label_insertion_pdf, section_part)
    assert_near(px, section_part.bbox_x0.to_f, 0.05, "section part-mark X should anchor at bbox x0 (got #{px})")
    assert_near(py, 686.15, PDF_TOL, "section part-mark Y baseline near section P-P (got #{py})")
    assert_true(pang.abs < 0.01, "section part-mark angle should be horizontal (got #{pang})")
  end

  dim_half = items.find { |it| it.text.to_s.strip == '1 1/2' && (it.bbox_x0.to_f - 1434.71).abs < 1.0 }
  if dim_half
    dx, dy, dang = builder.send(:label_insertion_pdf, dim_half)
    assert_near(dx, 1435.63, PDF_TOL, "1 1/2 X should center in narrow vertical bbox (got #{dx})")
    assert_near(dy, 689.32, PDF_TOL, "1 1/2 Y baseline for stacked fraction (got #{dy})")
    assert_true(dang.abs < 0.01, "1 1/2 angle must be horizontal, not stacked-fraction false tilt (got #{dang})")
    assert_true(builder.send(:zero_label_leader_vector).y.abs < 0.01,
                '1 1/2 must use the active zero leader vector')
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

  # SECTION C-C source-specific placement anchors, located without committing
  # private drawing identifiers.
  def find_cc_label(items, text_matcher, bbox_x0)
    items.find do |it|
      text = it.text.to_s.strip
      matches = text_matcher.is_a?(Regexp) ? (text_matcher =~ text) : text == text_matcher
      matches && (it.bbox_x0.to_f - bbox_x0).abs < 1.5
    end
  end

  cc_4_0 = find_cc_label(items, "4'-0", 514.0)
  if cc_4_0
    fx, fy, fang = builder.send(:label_insertion_pdf, cc_4_0)
    assert_near(fx, 514.66, PDF_TOL, "SECTION C-C 4'-0\" X should center in dim bbox (got #{fx})")
    assert_near(fy, 1612.20, PDF_TOL, "SECTION C-C 4'-0\" Y baseline (got #{fy})")
    assert_true(fang.abs < 0.01, "SECTION C-C 4'-0\" angle should be horizontal (got #{fang})")
  end

  cc_mixed_dimension = require_acceptance_item(
    find_cc_label(items, /\A\d+'-\d+(?: \d+\/\d+)?\z/, 504.84),
    'the SECTION C-C mixed dimension'
  )
  if cc_mixed_dimension
    mx, my, mang = builder.send(:label_insertion_pdf, cc_mixed_dimension)
    assert_near(mx, 505.77, PDF_TOL, "SECTION C-C mixed dimension X should center in dim bbox (got #{mx})")
    assert_near(my, 1592.03, PDF_TOL, "SECTION C-C mixed dimension Y baseline (got #{my})")
    assert_true(mang.abs < 0.01, "SECTION C-C mixed dimension angle should be horizontal (got #{mang})")
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
    assert_true(builder.send(:zero_label_leader_vector).y.abs < 0.01,
                'SECTION C-C 3/16" weld must use the active zero leader vector')
  end

  cc_typ = find_cc_label(items, 'TYP.', 465.84)
  if cc_typ
    tx, ty, tang = builder.send(:label_insertion_pdf, cc_typ)
    assert_near(tx, 465.84, PDF_TOL, "SECTION C-C TYP. X should anchor at bbox x0 (got #{tx})")
    assert_near(ty, 1551.48, PDF_TOL, "SECTION C-C TYP. Y baseline (got #{ty})")
    assert_true(tang.abs < 0.01, "SECTION C-C TYP. angle should be horizontal (got #{tang})")
  end

  cc_part_mark = require_acceptance_item(
    find_cc_label(items, part_mark_pattern, 474.24),
    'the SECTION C-C part mark'
  )
  if cc_part_mark
    w3x, w3y, _ = builder.send(:label_insertion_pdf, cc_part_mark)
    assert_near(w3x, 474.24, PDF_TOL, "SECTION C-C part-mark X should anchor at bbox x0 (got #{w3x})")
    assert_near(w3y, 1529.39, PDF_TOL, "SECTION C-C part-mark Y baseline (got #{w3y})")
  end

  cc_section = items.find { |it| it.text.to_s.strip == 'SECTION - C - C' }
  if cc_section
    sx, sy, _ = builder.send(:label_insertion_pdf, cc_section)
    assert_near(sx, 463.56, PDF_TOL, "SECTION C-C title X should anchor at bbox x0 (got #{sx})")
    assert_near(sy, 1420.08, PDF_TOL, "SECTION C-C title Y baseline (got #{sy})")
  end

  # Main elevation / truss acceptance reference view.
  def find_main_label(items, text_matcher, bbox_x0, bbox_y0 = nil)
    items.find do |it|
      text = it.text.to_s.strip
      matches = text_matcher.is_a?(Regexp) ? (text_matcher =~ text) : text == text_matcher
      matches &&
        (it.bbox_x0.to_f - bbox_x0).abs < 2.0 &&
        (bbox_y0.nil? || (it.bbox_y0.to_f - bbox_y0).abs < 8.0)
    end
  end

  top_chord = require_acceptance_item(
    items.select { |it| it.text.to_s =~ /\bW\d+X\d+\b/i }
         .min_by do |it|
           x, y, = builder.send(:label_insertion_pdf, it)
           (x - 694.29).abs + (y - 1056.95).abs
         end,
    'the main structural profile label'
  )
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

  main_span = require_acceptance_item(
    find_main_label(items, /\A\d+'-\d+(?: \d+\/\d+)?\z/, 733.44, 1032.51),
    'the main span dimension'
  )
  if main_span
    mx, my, _ = builder.send(:label_insertion_pdf, main_span)
    assert_near(mx, 734.53, PDF_TOL, "main span X should center in dim bbox (got #{mx})")
    assert_near(my, 1034.99, PDF_TOL, "main span Y baseline (got #{my})")
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

  connection_part = require_acceptance_item(
    find_main_label(items, part_mark_pattern, 822.74, 760.18),
    'the connection part mark'
  )
  if connection_part
    wx, wy, wang = builder.send(:label_insertion_pdf, connection_part)
    assert_near(wx, 822.74, PDF_TOL, "connection part-mark X left-anchored at bbox x0 (got #{wx})")
    assert_near(wy, 762.12, PDF_TOL, "connection part-mark Y baseline (got #{wy})")
    assert_true(wang.abs < 0.01, "connection part mark stays horizontal — tall bbox is not 90° (got #{wang})")
  end

  # Connection detail region in the brace/member cluster.
  connection_part_one = require_acceptance_item(
    find_main_label(items, part_mark_pattern, 868.8, 703.41),
    'the first connection-detail part mark'
  )
  if connection_part_one
    px, py, _ = builder.send(:label_insertion_pdf, connection_part_one)
    assert_near(px, 868.8, PDF_TOL, "first connection-detail part-mark X at bbox x0 (got #{px})")
    assert_near(py, 705.35, PDF_TOL, "first connection-detail part-mark Y baseline (got #{py})")
  end

  connection_part_two = require_acceptance_item(
    find_main_label(items, part_mark_pattern, 639.72, 782.97),
    'the second connection-detail part mark'
  )
  if connection_part_two
    px, py, _ = builder.send(:label_insertion_pdf, connection_part_two)
    assert_near(px, 639.72, PDF_TOL, "second connection-detail part-mark X at bbox x0 (got #{px})")
    assert_near(py, 784.91, PDF_TOL, "second connection-detail part-mark Y baseline (got #{py})")
  end

  # SECTION A-A diagonal brace part marks.
  brace_part_left = require_acceptance_item(
    find_main_label(items, part_mark_pattern, 782.16, 297.45),
    'the left SECTION A-A brace part mark'
  )
  if brace_part_left
    ax, ay, aang = builder.send(:label_insertion_pdf, brace_part_left)
    assert_near(ax, 782.16, PDF_TOL, "SECTION A-A left brace part-mark X left-anchored at bbox x0 (got #{ax})")
    assert_near(ay, 299.39, PDF_TOL, "SECTION A-A left brace part-mark Y baseline (got #{ay})")
    assert_true(aang.abs < 0.01,
                "SECTION A-A left brace part mark stays horizontal per PDF angle (got #{aang})")
  end

  brace_part_right = require_acceptance_item(
    find_main_label(items, part_mark_pattern, 901.55, 296.38),
    'the right SECTION A-A brace part mark'
  )
  if brace_part_right
    ax, ay, aang = builder.send(:label_insertion_pdf, brace_part_right)
    assert_near(ax, 901.55, PDF_TOL, "SECTION A-A right brace part-mark X left-anchored at bbox x0 (got #{ax})")
    assert_near(ay, 298.32, PDF_TOL, "SECTION A-A right brace part-mark Y baseline (got #{ay})")
    assert_true(aang.abs < 0.01,
                "SECTION A-A right brace part mark stays horizontal per PDF angle (got #{aang})")
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
  failure_start = builder.text_delivery_failures.length
  items.each do |item|
    builder.send(:place_text, placed_entities, item, 0.0, 0.0, 792.0, 'TextLayer')
  end
  extra_placements = items.inject(0) do |acc, it|
    acc + (builder.send(:stacked_vertical_dimension_labels?, it) ?
             it.text.to_s.strip.split(/\s+/).length - 1 : 0)
  end
  expected_placements = items.length + extra_placements
  placed_total = placed_entities.entities.count do |entity|
    entity.respond_to?(:typename) && entity.typename.to_s == 'Text'
  end + placed_entities.mesh_calls.length
  delivery_failures = builder.text_delivery_failures[failure_start..-1] || []
  rotation_transitions = delivery_failures.select do |failure|
    proof = failure[:transition_proof]
    failure[:reason] == 'label_rotation_unsupported_by_host' &&
      failure[:source_span_id].to_s =~ /\Atext_span:1:\d+\z/ &&
      proof && proof[:source_span_id] == failure[:source_span_id] &&
      proof[:affirmative_impossibility] == true &&
      proof[:from_mode] == :labels && proof[:to_mode] == :text3d
  end
  assert_true(delivery_failures.length == rotation_transitions.length,
              'every undelivered acceptance label must have an item-bound rotation-impossibility transition')
  assert_true(placed_total + rotation_transitions.length == expected_placements,
              "all external-reference labels must place or prove the adjacent rotation transition " \
              "(got #{placed_total} placements + #{rotation_transitions.length} proofs of #{expected_placements})")
  puts "  External reference: #{items.length} text items, #{with_bbox} with bbox, #{headers.length} BOM headers"
else
  puts '  SKIP: set BCS_PRIVATE_VALIDATION_ROOT or BCS_TIER1_USER_PDF'
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
