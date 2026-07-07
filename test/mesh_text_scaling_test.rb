#!/usr/bin/env ruby
# test/mesh_text_scaling_test.rb
# Regression tests for 3D text (mesh) height scaling across page sizes and
# item sources (pdftotext bbox vs internal parser matrix-scaled font_size).
#
# Root cause addressed: mesh_text_height_inches previously used a raw_font_size
# branch gated on a page-relative threshold (page_h * 0.04) causing wildly
# different heights on non-Letter/non-A4 pages. A 0.55 damping factor was
# also applied before pts→inches conversion producing double-damping on bbox
# items. The fix uses a single, page-size-independent pipeline.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT  = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/text_parser'

# ── Minimal SketchUp stubs ────────────────────────────────────────────────────
module Geom
  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x=0,y=0,z=0); @x=x.to_f; @y=y.to_f; @z=z.to_f; end
  end
  class Vector3d
    attr_accessor :x, :y, :z
    def initialize(x=0,y=0,z=0); @x=x.to_f; @y=y.to_f; @z=z.to_f; end
  end
  class Transformation
    attr_reader :args, :kind
    def initialize(*args)
      @args = args
      @kind = :translation
    end
    def self.rotation(*); new; end
    def self.scaling(*args)
      t = new(*args)
      t.instance_variable_set(:@kind, :scaling)
      t
    end
  end
end
ORIGIN  = Geom::Point3d.new(0,0,0)
Z_AXIS  = Geom::Vector3d.new(0,0,1)
TextAlignLeft = 0
class Numeric; def degrees; self.to_f * Math::PI / 180.0; end; end

load File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb')

GB  = BlueCollarSystems::PDFVectorImporter::GeometryBuilder
TI  = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem

# Page sizes in PDF points [x0,y0,w,h] — all standard and non-standard
LETTER  = [0, 0, 612, 792]
A4      = [0, 0, 595, 842]
ANSI_D  = [0, 0, 1584, 2448]  # 22"×34" — large-format shop drawing
ARCH_D  = [0, 0, 1728, 2592]  # 24"×36"
ANSI_E  = [0, 0, 2448, 3168]  # 34"×44" — very large
TALL_A1 = [0, 0, 1684, 2384]  # ISO A1

def make_builder(media_box, scale: 1.0)
  GB.new(
    Object.new,   # model stub — build() not called
    [],
    [],
    media_box,
    scale_factor: scale,
    import_text: true,
    use_3d_text: true
  )
end

# Text item with bbox (pdftotext source)
def bbox_item(text, font_size_pts, bbox_h_pts, raw_fs: nil, bbox_w: 150.0)
  by0 = 100.0
  by1 = by0 + bbox_h_pts.to_f
  TI.new(text, 50.0, by0, font_size_pts.to_f, 0.0, 'pdftotext',
         raw_fs, 50.0, by0, 50.0 + bbox_w.to_f, by1)
end

# Text item without bbox (internal TextParser source)
def no_bbox_item(text, matrix_scaled_fs_pts, raw_fs: nil)
  TI.new(text, 50.0, 100.0, matrix_scaled_fs_pts.to_f, 0.0, 'Helvetica',
         raw_fs, nil, nil, nil, nil)
end

class DummyBounds
  attr_reader :min, :max
  def initialize(width, height)
    @min = Geom::Point3d.new(0, 0, 0)
    @max = Geom::Point3d.new(width, height, 0)
  end
end

class DummyRenderedTextEntity
  def initialize(width, height)
    @bounds = DummyBounds.new(width, height)
  end

  def bounds
    @bounds
  end
end

class DummyTransformEntities
  attr_reader :transforms

  def initialize
    @transforms = []
  end

  def transform_entities(*args)
    @transforms << args
  end
end

# ── Constants from geometry_builder.rb ───────────────────────────────────────
CAP_RATIO = GB::MESH_TEXT_BBOX_CAP_RATIO  # 0.72
PT_TO_IN  = GB::PDF_POINT_TO_INCH         # 1/72
MIN_IN    = GB::MESH_TEXT_HEIGHT_MIN_IN   # 0.01
MAX_IN    = GB::MESH_TEXT_HEIGHT_MAX_IN   # 1.5

class MeshTextScalingTest < Minitest::Test

  # ── Constants ──────────────────────────────────────────────────────────────
  def test_constants_sane
    assert_in_delta 1.0/72.0, PT_TO_IN, 1e-9
    assert_in_delta 0.72, CAP_RATIO, 0.001
    assert_equal 0.01, MIN_IN
    assert_equal 1.5,  MAX_IN
  end

  # ── Letter page, bbox item (standard case) ─────────────────────────────────
  def test_letter_bbox_item_standard_8pt
    b = make_builder(LETTER)
    item = bbox_item('MARK', 8.0, 10.0)   # 8pt font, 10pt bbox_h
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    expected = (10.0 * CAP_RATIO) * PT_TO_IN   # 7.2pt * (1/72) ≈ 0.1 in
    assert_in_delta expected, h, 0.001
    assert h >= MIN_IN
    assert h <= MAX_IN
  end

  # ── Large format (D-size) must give SAME height as Letter for same bbox ────
  def test_d_size_same_height_as_letter_for_identical_bbox
    b_letter = make_builder(LETTER)
    b_d      = make_builder(ANSI_D)
    item = bbox_item('MARK', 8.0, 10.0)

    h_letter = b_letter.send(:mesh_text_height_inches, item, 0.0, LETTER[3])
    h_d      = b_d.send(:mesh_text_height_inches, item, 0.0, ANSI_D[3])
    assert_in_delta h_letter, h_d, 0.0001,
      "D-size and Letter must produce identical height for same bbox (got #{h_d.round(4)} vs #{h_letter.round(4)})"
  end

  # ── 24×36 (ARCH_D) same as Letter ─────────────────────────────────────────
  def test_arch_d_same_height_as_letter
    b_letter = make_builder(LETTER)
    b_arch   = make_builder(ARCH_D)
    item = bbox_item('W12X30', 10.0, 12.0)
    assert_in_delta(
      b_letter.send(:mesh_text_height_inches, item, 0.0, LETTER[3]),
      b_arch.send(:mesh_text_height_inches, item, 0.0, ARCH_D[3]),
      0.0001, "ARCH_D height must match Letter for same bbox"
    )
  end

  # ── No-bbox item, matrix-scaled font_size ──────────────────────────────────
  def test_no_bbox_uses_matrix_scaled_font_size
    b = make_builder(LETTER)
    # 8pt after Tm scale, no bbox
    item = no_bbox_item('p1019', 8.0)
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    expected = [8.0, 1.0].max * PT_TO_IN
    assert_in_delta expected, h, 0.001
  end

  # ── No-bbox, large page — must NOT be page-h-dependent ────────────────────
  def test_no_bbox_large_page_not_page_dependent
    b_letter = make_builder(LETTER)
    b_e      = make_builder(ANSI_E)
    item = no_bbox_item('W24X55', 8.0)
    h_letter = b_letter.send(:mesh_text_height_inches, item, 0.0, LETTER[3])
    h_e      = b_e.send(:mesh_text_height_inches, item, 0.0, ANSI_E[3])
    assert_in_delta h_letter, h_e, 0.0001,
      "No-bbox height must not vary with page size (got #{h_e.round(5)} vs #{h_letter.round(5)})"
  end

  # ── raw_font_size must NOT affect output ───────────────────────────────────
  def test_raw_font_size_does_not_change_height_with_bbox
    b = make_builder(LETTER)
    item_no_raw  = bbox_item('W12X30', 8.0, 10.0, raw_fs: nil)
    item_big_raw = bbox_item('W12X30', 8.0, 10.0, raw_fs: 100.0)
    item_tiny_raw = bbox_item('W12X30', 8.0, 10.0, raw_fs: 1.0)
    h_no   = b.send(:mesh_text_height_inches, item_no_raw,   0.0, 792.0)
    h_big  = b.send(:mesh_text_height_inches, item_big_raw,  0.0, 792.0)
    h_tiny = b.send(:mesh_text_height_inches, item_tiny_raw, 0.0, 792.0)
    assert_in_delta h_no, h_big,  0.0001, "raw_font_size=100 must not inflate height (got #{h_big.round(5)})"
    assert_in_delta h_no, h_tiny, 0.0001, "raw_font_size=1 must not shrink height (got #{h_tiny.round(5)})"
  end

  # ── Tiny text must clamp to MIN ────────────────────────────────────────────
  def test_tiny_font_clamped_to_min
    b = make_builder(LETTER)
    # 0.1pt bbox height — below anything real; floor is [bh*CAP_RATIO, 1.0].max = 1.0pt
    item = bbox_item('x', 0.1, 0.1)
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    # 1.0pt * (1/72) ≈ 0.01389" — between MIN_IN and a sensible ceiling
    assert h >= MIN_IN,   "Tiny text must be >= MIN_IN (got #{h})"
    assert h <= 0.02,     "Tiny text must not inflate beyond 0.02\" (got #{h})"
  end

  # ── Giant bbox must clamp to MAX ───────────────────────────────────────────
  def test_huge_bbox_clamped_to_max
    b = make_builder(LETTER)
    # 300pt bbox height (title text)
    item = bbox_item('TITLE', 300.0, 300.0, bbox_w: 3000.0)
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    assert_in_delta MAX_IN, h, 0.0001
  end

  def test_long_text_is_fit_to_narrow_bbox_before_mesh_creation
    b = make_builder(LETTER)
    item = bbox_item('LONG CALLOUT TEXT', 24.0, 20.0, bbox_w: 30.0)

    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)

    assert h < 0.09, "Long text should shrink to bbox width before mesh creation (got #{h.round(5)})"
  end

  # ── import scale factor applied once ──────────────────────────────────────
  def test_import_scale_applied_once
    b1 = make_builder(LETTER, scale: 1.0)
    b2 = make_builder(LETTER, scale: 2.0)
    item = bbox_item('MARK', 8.0, 10.0)
    h1 = b1.send(:mesh_text_height_inches, item, 0.0, 792.0)
    h2 = b2.send(:mesh_text_height_inches, item, 0.0, 792.0)
    assert_in_delta h1 * 2.0, h2, 0.001,
      "scale:2 must produce exactly 2× the height (got #{h2.round(5)} vs #{(h1*2).round(5)})"
  end

  # ── A4 produces same result as Letter for same physical text ───────────────
  def test_a4_same_height_as_letter
    b_l = make_builder(LETTER)
    b_a = make_builder(A4)
    item = bbox_item('p1001', 9.0, 11.0)
    assert_in_delta(
      b_l.send(:mesh_text_height_inches, item, 0.0, LETTER[3]),
      b_a.send(:mesh_text_height_inches, item, 0.0, A4[3]),
      0.0001, "A4 and Letter must match"
    )
  end

  # ── Rotated item: angle param must not affect height ──────────────────────
  def test_angle_does_not_affect_height
    b = make_builder(LETTER)
    item = bbox_item('a1006', 8.0, 10.0)
    h0   = b.send(:mesh_text_height_inches, item,  0.0, 792.0)
    h90  = b.send(:mesh_text_height_inches, item, 90.0, 792.0)
    h270 = b.send(:mesh_text_height_inches, item, -90.0, 792.0)
    assert_in_delta h0, h90,  0.0001, "Height must not change for 90° rotation"
    assert_in_delta h0, h270, 0.0001, "Height must not change for -90° rotation"
  end

  # ── Reasonable range for typical shop drawing text ─────────────────────────
  def test_typical_shop_text_in_reasonable_range
    b = make_builder(ANSI_D)
    [
      ['piece mark',    8.0,  10.0],
      ['BOM header',    10.0, 12.0],
      ['dim string',    6.0,   8.0],
      ['section title', 14.0, 17.0],
    ].each do |label, fs, bh|
      item = bbox_item(label, fs, bh)
      h = b.send(:mesh_text_height_inches, item, 0.0, ANSI_D[3])
      assert h >= 0.05, "#{label}: height #{h.round(4)} too small (< 0.05\")"
      assert h <= 0.30, "#{label}: height #{h.round(4)} too large (> 0.30\")"
    end
  end

  # ── Non-standard crop box offset: large negative origin ───────────────────
  # Some PDFs have MediaBox origin at negative coordinates.
  def test_negative_origin_mediabox_no_effect_on_height
    negative_origin_box = [-100, -200, 512, 592]  # w=612, h=792 effectively
    b = make_builder(negative_origin_box)
    item = bbox_item('MARK', 8.0, 10.0)
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    expected = (10.0 * CAP_RATIO) * PT_TO_IN
    assert_in_delta expected, h, 0.001, "Negative MediaBox origin must not corrupt height"
  end

  # ── Zero / nil font_size fallback ─────────────────────────────────────────
  def test_zero_font_size_no_bbox_gives_min
    b = make_builder(LETTER)
    item = no_bbox_item('x', 0.0)
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    # [0.0, 1.0].max = 1.0pt → 1/72" ≈ 0.01389" > MIN_IN
    assert h >= MIN_IN
    assert h <= MAX_IN
  end

  # ── Vertical part mark: tall bbox + pdftotext angle 0 must use narrow axis ─
  def test_vertical_part_mark_infers_bbox_angle_when_raw_angle_zero
    b = make_builder(LETTER)
    item0 = TI.new('a1001', 50.0, 100.0, 8.0, 0.0, 'pdftotext',
                    nil, 50.0, 100.0, 58.0, 142.0)
    item90 = TI.new('a1001', 50.0, 100.0, 8.0, 90.0, 'pdftotext',
                     nil, 50.0, 100.0, 58.0, 142.0)
    h0  = b.send(:mesh_text_height_inches, item0, 0.0, LETTER[3])
    h90 = b.send(:mesh_text_height_inches, item90, 90.0, LETTER[3])
    assert_in_delta h0, h90, 0.0001,
                    'upright part mark in tall bbox must match explicit 90° height'
    assert h0 < 0.10,
           "vertical part mark must not scale to full bbox height (got #{h0.round(4)}\")"
  end

  # ── Rotated page: mesh height must match unrotated page for same bbox ─────
  def test_rotated_page_same_mesh_height_as_portrait
    item = bbox_item('p1052', 8.0, 10.0)
    b_portrait = make_builder(LETTER, scale: 1.0)
    b_rotated = GB.new(
      Object.new, [], [], LETTER, scale_factor: 1.0,
      import_text: true, use_3d_text: true, page_rotation: 270
    )
    h_portrait = b_portrait.send(:mesh_text_height_inches, item, 0.0, LETTER[3])
    h_rotated  = b_rotated.send(:mesh_text_height_inches, item, 0.0, LETTER[3])
    assert_in_delta h_portrait, h_rotated, 0.0001,
                    'page /Rotate must not change 3D text height for identical bbox'
  end

  # ── Existing golden: w1023 height must not blow up ────────────────────────
  def test_w1023_like_item_height
    b = make_builder(LETTER)
    # w1023: pdftotext item, bbox ~8pt tall
    item = bbox_item('w1023', 7.0, 8.5)
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    assert h < 0.12, "w1023-like height must not blow up (got #{h.round(5)})"
    assert h > 0.05, "w1023-like height must not be too small (got #{h.round(5)})"
  end

  def test_rendered_mesh_text_is_shrunk_to_source_bbox
    b = make_builder(LETTER)
    item = bbox_item('W12X30', 8.0, 10.0, bbox_w: 48.0)
    ents = DummyTransformEntities.new
    rendered = DummyRenderedTextEntity.new(10.0, 10.0)
    anchor = Geom::Point3d.new(0, 0, 0)

    b.send(:calibrate_mesh_text_entities_to_bbox, ents, [rendered], item, anchor)

    scale_call = ents.transforms.find { |args| args.first.respond_to?(:kind) && args.first.kind == :scaling }
    refute_nil scale_call, 'Oversized rendered 3D text must get a scaling transform'
    factor = scale_call.first.args.last
    assert factor < 1.0, "Expected shrink factor below 1.0, got #{factor.inspect}"
  end

  # ── calibrate grow path: undersized rendered text should be scaled up ──────
  # When mesh_text_fit_font_size_pts shrinks a font too aggressively (e.g.
  # short label in a wide bbox), the rendered geometry is much shorter than
  # the PDF bbox height. calibrate must grow it back up, capped at 1.3×.
  def test_calibrate_grows_undersized_rendered_text
    b = make_builder(LETTER)
    # bbox: 10pt high, 200pt wide (much wider than text needs → fit shrank font)
    item = bbox_item('A', 8.0, 10.0, bbox_w: 200.0)
    # Simulate: rendered text came out at 4pt height (in inches = 4/72)
    # bbox_y limit_in = 10 * (1/72) = 0.1389". 4/72 ≈ 0.0556" < 0.70 * 0.1389" → grow fires
    rendered_h_in = 4.0 / 72.0
    rendered_w_in = 3.0 / 72.0
    ents = DummyTransformEntities.new
    rendered = DummyRenderedTextEntity.new(rendered_w_in, rendered_h_in)
    anchor = Geom::Point3d.new(0, 0, 0)

    b.send(:calibrate_mesh_text_entities_to_bbox, ents, [rendered], item, anchor)

    scale_call = ents.transforms.find { |args| args.first.respond_to?(:kind) && args.first.kind == :scaling }
    refute_nil scale_call, 'Undersized rendered 3D text must be grown by calibrate'
    factor = scale_call.first.args.last
    assert factor > 1.0, "Expected grow factor > 1.0 for undersized text, got #{factor.inspect}"
    assert factor <= 1.3, "Grow factor must not exceed 1.3 cap (got #{factor.inspect})"
  end

  # ── calibrate: near-correct size should not fire any transform ─────────────
  def test_calibrate_no_transform_for_correct_size
    b = make_builder(LETTER)
    # bbox 10pt high → limit_y ≈ 0.1389". rendered at 0.9× limit → within tolerance.
    item = bbox_item('p1', 8.0, 10.0, bbox_w: 50.0)
    limit_y_in = 10.0 / 72.0
    ents = DummyTransformEntities.new
    rendered = DummyRenderedTextEntity.new(20.0 / 72.0, limit_y_in * 0.92)
    anchor = Geom::Point3d.new(0, 0, 0)

    b.send(:calibrate_mesh_text_entities_to_bbox, ents, [rendered], item, anchor)

    scale_call = ents.transforms.find { |args| args.first.respond_to?(:kind) && args.first.kind == :scaling }
    assert_nil scale_call, 'Near-correct size must not trigger any calibration transform'
  end

end
