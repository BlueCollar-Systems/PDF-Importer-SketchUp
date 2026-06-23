#!/usr/bin/env ruby
# test/text_category_placement_test.rb
# Category-based label placement rules — synthetic TextItem fixtures (no 1017 strings).

require 'fileutils'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/text_parser'

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
end

load File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb')

Item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem

$failures = []
$pass_count = 0

def assert_true(cond, msg)
  return $pass_count += 1 if cond
  $failures << msg
end

def assert_near(actual, expected, tol, msg)
  assert_true((actual.to_f - expected.to_f).abs <= tol, msg)
end

def make_item(text, x0, y0, x1, y1, angle: 0.0, font_size: 10.0)
  Item.new(text, x0, y0, font_size, angle, 'pdftotext', nil, x0, y0, x1, y1)
end

builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
  nil, [], [], [0, 0, 612, 792], scale_factor: 1.0, import_text: true, use_3d_text: false
)

# --- Part marks: [wap]\d+ — PDF angle; tall bbox uses min(w,h) font; no false 90° ---
assert_true(builder.send(:part_mark_label?, 'w1023'), 'w-prefix part mark recognized')
assert_true(builder.send(:part_mark_label?, 'p1052'), 'p-prefix part mark recognized')
assert_true(builder.send(:part_mark_label?, 'a1006'), 'a-prefix part mark recognized')
assert_true(!builder.send(:part_mark_label?, '1017'), 'bare job number is not a part mark')
assert_true(!builder.send(:part_mark_label?, '4'), 'bare digit is not a part mark')

tall_w = make_item('w1023', 100.0, 200.0, 110.0, 240.0, angle: 0.0, font_size: 10.79)
wx, wy, wang = builder.send(:label_insertion_pdf, tall_w)
assert_near(wx, 100.0, 0.05, 'tall-bbox horizontal part mark anchors at bbox x0')
assert_true(wang.abs < 0.01, 'tall-bbox horizontal part mark keeps PDF angle 0')
eff_fs = builder.send(:effective_font_size_pts, tall_w)
assert_true(eff_fs <= 11.0, 'tall-bbox part mark uses min(w,h) for effective font size')

diag_a = make_item('a1005', 500.0, 300.0, 530.0, 312.0, angle: 45.0, font_size: 10.79)
_, _, dang = builder.send(:label_insertion_pdf, diag_a)
assert_true(dang.abs >= 8.0 && dang.abs < 75.0, 'diagonal part mark follows PDF angle band')

rot_w = make_item('w2001', 50.0, 50.0, 62.0, 80.0, angle: 90.0, font_size: 10.0)
_, _, rang = builder.send(:label_insertion_pdf, rot_w)
assert_true(rang.abs > 75.0, '90° PDF-angle part mark rotates to vertical')

# --- Dimensions: bbox aspect drives centering; angle stays horizontal when PDF ~0 ---
narrow_frac = make_item('1 1/2', 100.0, 300.0, 108.0, 330.0, angle: 0.0, font_size: 6.0)
assert_true(builder.send(:should_center_dimension_label?, narrow_frac.text, 8.0, 30.0, 6.0, 0.0),
            'stacked fraction in narrow vertical bbox should center')
fx, _, fang = builder.send(:label_insertion_pdf, narrow_frac)
assert_true(fx > 100.0 && fx < 108.0, 'narrow fraction dimension X centers in bbox')
assert_true(fang.abs < 0.01, 'narrow vertical dimension keeps horizontal angle')

feet_inch = make_item("4'-0\"", 200.0, 400.0, 240.0, 412.0, angle: 0.0, font_size: 8.0)
assert_true(builder.send(:should_center_dimension_label?, feet_inch.text, 40.0, 12.0, 8.0, 0.0),
            'feet-inch dim centers when bbox wider than glyphs')
assert_true(!builder.send(:should_center_dimension_label?, '7 1/8', 24.0, 8.0, 6.0, 0.0),
            'wide horizontal fraction dim stays left-aligned')

# --- Weld callouts: any N/N fraction + TYP; baseline anchor, angle 0 ---
assert_true(builder.send(:weld_fraction_label?, '3/16', 20.0, 8.0),
            'horizontal weld fraction in wide short bbox')
assert_true(!builder.send(:weld_fraction_label?, '3/4', 12.0, 12.0),
            'square-bbox 3/4 is dimension not weld')
assert_true(!builder.send(:weld_fraction_label?, '1/8', 8.0, 30.0),
            'narrow vertical 1/8 is dimension not weld')
assert_true(builder.send(:annotation_like_label?, 'TYP.'), 'TYP annotation recognized')

weld = make_item('3/16', 420.0, 1540.0, 435.0, 1552.0, angle: -6.0, font_size: 8.0)
wx2, wy2, w_ang = builder.send(:label_insertion_pdf, weld)
assert_near(wx2, 420.0, 0.05, 'weld fraction anchors at bbox x0')
assert_true(w_ang.abs < 0.01, 'weld fraction forced horizontal')
assert_true(builder.send(:label_direction_vector, w_ang, weld).y.abs < 0.01,
            'weld fraction uses zero direction vector')

typ = make_item('TYP.', 465.0, 1550.0, 480.0, 1562.0, angle: 0.0, font_size: 8.0)
_, _, tang = builder.send(:label_insertion_pdf, typ)
assert_true(tang.abs < 0.01, 'TYP annotation stays horizontal')

# --- Stacked dims: multi-word numeric in tall bbox splits at placement ---
stacked = make_item('2 2', 100.0, 500.0, 108.0, 530.0, angle: 0.0, font_size: 8.0)
assert_true(builder.send(:stacked_vertical_dimension_labels?, stacked),
            'multi-token numeric in tall bbox is stacked dimension')
assert_true(!builder.send(:tall_single_text_bbox?, stacked),
            'stacked dim parent is not treated as single tall bbox')

# --- BOM headers: short uppercase in wide cells center when bbox >> est width ---
assert_true(builder.send(:should_center_label?, 'MARK', 50.0, 8.0, 0.0),
            'BOM header MARK centers in wide cell')
assert_true(builder.send(:should_center_label?, 'QTY', 45.0, 8.0, 0.0),
            'BOM header QTY centers in wide cell')
assert_true(!builder.send(:should_center_label?, 'DESCRIPTION', 30.0, 8.0, 0.0),
            'tight BOM cell does not center')

# --- Chord spec: general feet-inch + parenthesis pattern (not 1017 literal) ---
assert_true(builder.send(:chord_spec_label?, "18'-2 ("), 'chord spec pattern recognized')
assert_true(!builder.send(:chord_spec_label?, "4'-0\""), 'plain feet-inch is not chord spec')

bom = make_item('MARK', 90.0, 200.0, 140.0, 210.0, angle: 0.0, font_size: 8.0)
bx, = builder.send(:label_insertion_pdf, bom)
assert_true(bx > 90.0 && bx < 115.0, 'BOM header X shifts toward bbox center')

# --- Rotated labels: >8° uses mesh path (SU 2017 add_text vector unreliable) ---
assert_true(builder.send(:angle_needs_geometry_text?, 45.0, 8.0),
            '45° label should prefer geometry mesh over screen-space vector')

# --- Centered mesh anchor: bbox centering happens once, shared by Labels/3D Text ---
bom_mesh_x, _, _ = builder.send(:mesh_label_anchor_pdf, bom)
assert_near(bom_mesh_x, bx, 0.001, 'mesh anchor matches centered label insertion X')

if $failures.empty?
  puts "PASS: #{$pass_count} category placement assertions"
  exit 0
end

puts "FAIL: #{$failures.length} assertion(s)"
$failures.each { |f| puts "  - #{f}" }
exit 1
