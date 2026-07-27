#!/usr/bin/env ruby
# test/text_category_placement_test.rb
# Category-based label placement rules — synthetic TextItem fixtures (no private validation PDF strings).

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

# --- Single-digit spans never infer 90° from bbox aspect (LOOP-1 placement
# gate 9/17 residual, R-A adjacent). A lone digit's natural bbox is often
# taller than 1.6x its width, while a truly 90°-rotated single glyph yields
# the OPPOSITE aspect — so the vertical-dimension inference can never be
# right for one-character text. Refusing these as unsupported rotations
# dropped stacked-fraction halves and whole numbers. ---
frac_numerator = make_item('1', 100.0, 278.55, 103.89, 285.03, angle: 0.0, font_size: 6.0)
assert_true(!builder.send(:vertical_dimension_bbox?, frac_numerator, 3.89, 6.48),
            'single-digit stacked-fraction numerator is not a vertical dimension run')
assert_true(builder.send(:label_angle_pdf, frac_numerator).abs < 0.01,
            'stacked-fraction numerator digit stays horizontal')

frac_denominator = make_item('4', 100.0, 268.55, 103.89, 275.03, angle: 0.0, font_size: 6.0)
assert_true(builder.send(:label_angle_pdf, frac_denominator).abs < 0.01,
            'stacked-fraction denominator digit stays horizontal')

whole_beside_fraction = make_item('2', 80.0, 273.52, 86.67, 284.62, angle: 0.0, font_size: 11.0)
assert_true(builder.send(:label_angle_pdf, whole_beside_fraction).abs < 0.01,
            'whole-number digit beside a stacked fraction stays horizontal')

# Multi-character narrow-tall numeric runs keep the vertical inference.
tall_run = make_item('12', 100.0, 500.0, 104.0, 520.0, angle: 0.0, font_size: 8.0)
assert_true(builder.send(:vertical_dimension_bbox?, tall_run, 4.0, 20.0),
            'multi-digit narrow-tall run still infers a vertical dimension')

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
assert_true(builder.send(:zero_label_leader_vector).y.abs < 0.01,
            'weld fraction uses the active zero leader vector')

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

# --- Chord spec: general feet-inch + parenthesis pattern (not a job-number literal) ---
assert_true(builder.send(:chord_spec_label?, "18'-2 ("), 'chord spec pattern recognized')
assert_true(!builder.send(:chord_spec_label?, "4'-0\""), 'plain feet-inch is not chord spec')

bom = make_item('MARK', 90.0, 200.0, 140.0, 210.0, angle: 0.0, font_size: 8.0)
bx, = builder.send(:label_insertion_pdf, bom)
assert_true(bx > 90.0 && bx < 115.0, 'BOM header X shifts toward bbox center')

# --- Rotated bbox origins: geometry-capable representations preserve the angle;
# native Labels reject it before add_text because Text#vector is only a leader. ---
assert_true(builder.send(:angle_requires_rotated_origin?, 45.0),
            '45° source text should use the rotated-origin calculation')

# --- Centered mesh anchor: bbox centering happens once, shared by Labels/3D Text ---
bom_mesh_x, _, _ = builder.send(:mesh_label_anchor_pdf, bom)
assert_near(bom_mesh_x, bx, 0.001, 'mesh anchor matches centered label insertion X')

# --- BOM table orientation regression (mirrors PRIVATE-01 QUAN|MARK|DESCRIPTION) ---
# QUAN single-digit quantities must render UPRIGHT (0deg), not rotated 90deg.
# MARK/DESCRIPTION cells stay horizontal. Only genuinely PDF-rotated field
# dimensions should rotate — see label_angle_pdf QUAN-column branch (R26).
bom_quan_hdr = make_item('QUAN', 98.0, 698.0, 130.0, 710.0, font_size: 8.0)
bom_mark_hdr = make_item('MARK', 140.0, 698.0, 176.0, 710.0, font_size: 8.0)
bom_desc_hdr = make_item('DESCRIPTION', 200.0, 698.0, 290.0, 710.0, font_size: 8.0)
# QUAN column digits: tall/narrow pdftotext glyph bbox, PDF angle 0.
bom_q1 = make_item('1', 108.0, 684.0, 113.0, 694.0, font_size: 8.0)
bom_q3 = make_item('3', 107.0, 668.0, 114.0, 678.0, font_size: 8.0)
bom_q2 = make_item('2', 107.0, 636.0, 114.0, 646.0, font_size: 8.0)
bom_mark_txt = make_item('1017FR1', 140.0, 684.0, 180.0, 694.0, font_size: 8.0)
bom_mark_pm  = make_item('w1023', 140.0, 668.0, 170.0, 678.0, font_size: 8.0)
bom_desc_txt = make_item('W12X30', 200.0, 684.0, 250.0, 694.0, font_size: 8.0)
bom_items = [bom_quan_hdr, bom_mark_hdr, bom_desc_hdr,
             bom_q1, bom_q3, bom_q2, bom_mark_txt, bom_mark_pm, bom_desc_txt]
builder.send(:prepare_bom_table_context, bom_items)

[bom_q1, bom_q3, bom_q2].each do |q|
  assert_true(builder.send(:bom_table_quan_column?, q),
              "BOM digit #{q.text} classified in QUAN column")
  _, _, qang = builder.send(:label_insertion_pdf, q)
  assert_true(qang.abs < 0.01,
              "BOM QUAN digit #{q.text} renders upright, not rotated (got #{qang})")
end

q3x, = builder.send(:label_insertion_pdf, bom_q3)
q3_center = (bom_q3.bbox_x0.to_f + bom_q3.bbox_x1.to_f) * 0.5
assert_true((q3x - q3_center).abs < 5.0,
            "BOM QUAN digit centers within its cell (got #{q3x}, cell center #{q3_center})")

_, _, mtxt_ang = builder.send(:label_insertion_pdf, bom_mark_txt)
assert_true(mtxt_ang.abs < 0.01, 'BOM MARK cell stays horizontal (not forced vertical)')
_, _, mpm_ang = builder.send(:label_insertion_pdf, bom_mark_pm)
assert_true(mpm_ang.abs < 0.01, 'BOM MARK part label w1023 stays horizontal at PDF angle 0')
_, _, desc_ang = builder.send(:label_insertion_pdf, bom_desc_txt)
assert_true(desc_ang.abs < 0.01, 'BOM DESCRIPTION cell stays horizontal')

# Stacked-fraction dimension outside the BOM band still resolves horizontal.
bom_frac = make_item('3 5/16', 400.0, 200.0, 412.0, 230.0, font_size: 6.0)
assert_true(builder.send(:label_angle_pdf, bom_frac).abs < 0.01,
            'stacked fraction dimension stays horizontal with BOM context active')

if $failures.empty?
  puts "PASS: #{$pass_count} category placement assertions"
  exit 0
end

puts "FAIL: #{$failures.length} assertion(s)"
$failures.each { |f| puts "  - #{f}" }
exit 1
