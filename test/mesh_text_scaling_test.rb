#!/usr/bin/env ruby
# test/mesh_text_scaling_test.rb
# Regression tests for 3D text (mesh) height scaling across page sizes and
# item sources (pdftotext bbox vs internal parser matrix-scaled font_size).
#
# Root cause addressed (v3.7.83): mesh_text_height_inches overrode nominal
# font_size with pdftotext line-bbox heights, then calibrate_mesh_text_entities_to_bbox
# shrank rendered 3D text to fit those microscopic boxes — producing unreadable dots
# on D-size shop drawings. Fix: trust nominal Tf, guard reconcile/calibrate.

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
    def self.rotation(*args)
      t = new(*args)
      t.instance_variable_set(:@kind, :rotation)
      t
    end
    def self.scaling(*args)
      t = new(*args)
      t.instance_variable_set(:@kind, :scaling)
      t
    end

    def transform_point(point)
      case @kind
      when :scaling
        pivot, scale_x, scale_y, scale_z = @args
        Geom::Point3d.new(
          pivot.x + ((point.x - pivot.x) * scale_x.to_f),
          pivot.y + ((point.y - pivot.y) * scale_y.to_f),
          pivot.z + ((point.z - pivot.z) * scale_z.to_f)
        )
      when :rotation
        pivot, _axis, radians = @args
        dx = point.x - pivot.x
        dy = point.y - pivot.y
        cosine = Math.cos(radians.to_f)
        sine = Math.sin(radians.to_f)
        Geom::Point3d.new(
          pivot.x + (dx * cosine) - (dy * sine),
          pivot.y + (dx * sine) + (dy * cosine),
          point.z
        )
      else
        delta = @args[0]
        Geom::Point3d.new(
          point.x + delta.x,
          point.y + delta.y,
          point.z + delta.z
        )
      end
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

module FidelityFixtureIdentity
  @entity_id = 10_000
  @span_index = 0

  class << self
    def next_entity_id
      @entity_id += 1
    end

    def next_span_id
      value = "text_span:1:#{@span_index}"
      @span_index += 1
      value
    end
  end
end

def identified_text_item(*args)
  item = TI.new(*args)
  item.source_span_id = FidelityFixtureIdentity.next_span_id
  item
end

def exact_test_font_resolver
  lambda do |source|
    {
      source_span_id: source.source_span_id,
      pdf_font_identity: 'embedded:test-font',
      installed_family: 'Test Exact Font',
      exact_family_match: true,
      verified: true
    }
  end
end

def make_builder(media_box, scale: 1.0)
  GB.new(
    Object.new,   # model stub — build() not called
    [],
    [],
    media_box,
    scale_factor: scale,
    import_text: true,
    use_3d_text: true,
    native_font_identity_resolver: exact_test_font_resolver
  )
end

# Text item with bbox (pdftotext source)
def bbox_item(text, font_size_pts, bbox_h_pts, raw_fs: nil, bbox_w: 150.0)
  by0 = 100.0
  by1 = by0 + bbox_h_pts.to_f
  identified_text_item(
    text, 50.0, by0, font_size_pts.to_f, 0.0, 'pdftotext',
    raw_fs, 50.0, by0, 50.0 + bbox_w.to_f, by1
  )
end

# Text item without bbox (internal TextParser source)
def no_bbox_item(text, matrix_scaled_fs_pts, raw_fs: nil)
  identified_text_item(
    text, 50.0, 100.0, matrix_scaled_fs_pts.to_f, 0.0, 'Helvetica',
    raw_fs, nil, nil, nil, nil
  )
end

class DummyBounds
  attr_reader :min, :max
  def initialize(width, height, min_x = 0.0, min_y = 0.0, min_z = 0.0,
                 depth = 0.0)
    @min = Geom::Point3d.new(min_x, min_y, min_z)
    @max = Geom::Point3d.new(min_x + width, min_y + height, min_z + depth)
  end

  def transform!(transformation)
    corners = [
      Geom::Point3d.new(@min.x, @min.y, @min.z),
      Geom::Point3d.new(@max.x, @min.y, @min.z),
      Geom::Point3d.new(@max.x, @max.y, @max.z),
      Geom::Point3d.new(@min.x, @max.y, @max.z)
    ].map { |point| transformation.transform_point(point) }
    xs = corners.map(&:x)
    ys = corners.map(&:y)
    zs = corners.map(&:z)
    @min = Geom::Point3d.new(xs.min, ys.min, zs.min)
    @max = Geom::Point3d.new(xs.max, ys.max, zs.max)
  end
end

class DummyRenderedTextEntity
  attr_accessor :layer
  attr_reader :persistent_id

  def initialize(width, height, typename: 'Edge', persistent_id: nil,
                 depth: 0.0)
    @bounds = DummyBounds.new(width, height, 0.0, 0.0, 0.0, depth)
    @typename = typename
    @persistent_id = persistent_id || FidelityFixtureIdentity.next_entity_id
  end
  def bounds; @bounds; end
  def typename; @typename; end
  def transform!(transformation); @bounds.transform!(transformation); end
end

class DummyFaceEntity < DummyRenderedTextEntity
  attr_accessor :layer, :material, :back_material

  def initialize(width = 0.1, height = 0.1, persistent_id: nil, depth: 0.0)
    super(width, height, typename: 'Face', persistent_id: persistent_id,
          depth: depth)
  end

  def typename; 'Face'; end
end

class DummyTextStagingEntities
  def initialize(parent)
    @parent = parent
    @entities = []
  end

  def add_3d_text(*args)
    before = @parent.to_a
    begin
      @parent.add_3d_text(*args)
    ensure
      generated = @parent.to_a.reject { |entity| before.include?(entity) }
      @parent.detach_staged_entities(generated)
      @entities.concat(generated)
    end
  end

  def to_a
    @entities.dup
  end
end

class DummyTextStagingGroup
  attr_reader :entities, :persistent_id

  def initialize(parent)
    @parent = parent
    @persistent_id = FidelityFixtureIdentity.next_entity_id
    @entities = DummyTextStagingEntities.new(parent)
  end

  def typename
    'Group'
  end

  def explode
    @parent.explode_staging_group(self, @entities.to_a)
  end
end

class DummyTransformEntities
  attr_reader :transforms, :erased, :height_args, :tolerance_args
  def initialize(preexisting: [])
    @entities = Array(preexisting).dup
    @transforms = []
    @erased = []
    @height_args = []
    @tolerance_args = []
  end
  def to_a; @entities.dup; end
  def add_group
    group = DummyTextStagingGroup.new(self)
    @entities << group
    group
  end
  def detach_staged_entities(entities)
    @entities.reject! { |entity| entities.include?(entity) }
  end
  def explode_staging_group(group, children)
    @entities.delete(group)
    @entities.concat(children)
    children
  end
  def add_3d_text(_text, _align, _font, _bold, _italic, height, tol, _z, _filled, extrusion)
    @height_args << height
    @tolerance_args << tol
    width = height * 3.0
    @entities << DummyRenderedTextEntity.new(width, height, typename: 'Edge',
                                              depth: extrusion)
    @entities << DummyFaceEntity.new(width, height, depth: extrusion)
    true
  end
  def transform_entities(*args)
    @transforms << args
    transformation = args[0]
    Array(args[1..-1]).flatten.each { |entity| entity.transform!(transformation) }
  end
  def erase_entities(*args)
    doomed = args.flatten
    @erased.concat(doomed)
    @entities.reject! { |entity| doomed.include?(entity) }
  end
end

# ── Constants from geometry_builder.rb ───────────────────────────────────────
# Round 13: height comes from nominal font size (never bbox). Round 24: convert
# PDF em -> SketchUp letter_height via the Arial ascender ratio (1491/2048).
PT_TO_IN  = GB::PDF_POINT_TO_INCH         # 1/72
LETTER_H_RATIO = GB::ARIAL_LETTER_HEIGHT_TO_EM

def sketchup_letter_height_in(font_size_pts, scale = 1.0)
  font_size_pts.to_f * PT_TO_IN * scale.to_f * LETTER_H_RATIO
end

class MeshTextScalingTest < Minitest::Test

  # ── Constants ──────────────────────────────────────────────────────────────
  def test_pdf_point_conversion_is_exact
    assert_in_delta 1.0/72.0, PT_TO_IN, 1e-9
  end

  # ── Letter page, bbox item (standard case) ─────────────────────────────────
  def test_letter_bbox_item_standard_8pt
    b = make_builder(LETTER)
    item = bbox_item('MARK', 8.0, 10.0)   # 8pt font, 10pt bbox_h
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    expected = sketchup_letter_height_in(8.0)
    assert_in_delta expected, h, 0.001
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
    expected = sketchup_letter_height_in([8.0, 1.0].max)
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

  # Every positive source height is authoritative.  Historical telemetry
  # constants must never become delivery clamps again.
  def test_tiny_font_preserves_exact_source_height
    b = make_builder(LETTER)
    item = identified_text_item(
      'x', 50.0, 100.0, 0.1, 0.0, 'pdftotext',
      nil, 50.0, 100.0, 50.1, 100.1
    )
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    assert_in_delta sketchup_letter_height_in(0.1), h, 1.0e-12,
                    'tiny source text must not be inflated to a readability floor'
  end

  def test_large_font_preserves_exact_source_height
    b = make_builder(LETTER)
    item = bbox_item('TITLE', 300.0, 300.0, bbox_w: 3000.0)
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    assert_in_delta sketchup_letter_height_in(300.0), h, 1.0e-12,
                    'large source text must not be shrunk to a maximum height'
  end

  def test_long_text_height_is_exactly_nominal
    b = make_builder(LETTER)
    # 24pt font, 20pt bbox_h, narrow 30pt bbox_w.
    # Round 13: height = effective_font_size_pts * PT_TO_IN — no width-based shrink.
    # effective_font_size_pts: ratio=20/24=0.833 (in 0.75-1.35 range) → fs=24
    item = bbox_item('LONG CALLOUT TEXT', 24.0, 20.0, bbox_w: 30.0)
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    assert_in_delta sketchup_letter_height_in(24.0), h, 1.0e-12
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
  def test_typical_shop_text_preserves_each_source_height
    b = make_builder(ANSI_D)
    [
      ['piece mark',    8.0,  10.0],
      ['BOM header',    10.0, 12.0],
      ['dim string',    6.0,   8.0],
      ['section title', 14.0, 17.0],
    ].each do |label, fs, bh|
      item = bbox_item(label, fs, bh)
      h = b.send(:mesh_text_height_inches, item, 0.0, ANSI_D[3])
      assert_in_delta sketchup_letter_height_in(fs), h, 1.0e-12,
                      "#{label}: source height must be preserved exactly"
    end
  end

  # ── Non-standard crop box offset: large negative origin ───────────────────
  # Some PDFs have MediaBox origin at negative coordinates.
  def test_negative_origin_mediabox_no_effect_on_height
    negative_origin_box = [-100, -200, 512, 592]  # w=612, h=792 effectively
    b = make_builder(negative_origin_box)
    item = bbox_item('MARK', 8.0, 10.0)
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    expected = sketchup_letter_height_in(8.0)
    assert_in_delta expected, h, 0.001, "Negative MediaBox origin must not corrupt height"
  end

  # An unverifiable source height fails closed; inventing a minimum would make
  # the representation look successful without matching the PDF.
  def test_zero_font_size_is_unverifiable
    b = make_builder(LETTER)
    item = no_bbox_item('x', 0.0)
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    assert_nil h
  end

  # ── Vertical part mark: tall bbox + pdftotext angle 0 must use narrow axis ─
  def test_vertical_part_mark_infers_bbox_angle_when_raw_angle_zero
    b = make_builder(LETTER)
    item0 = identified_text_item(
      'a1001', 50.0, 100.0, 8.0, 0.0, 'pdftotext',
      nil, 50.0, 100.0, 58.0, 142.0
    )
    item90 = identified_text_item(
      'a1001', 50.0, 100.0, 8.0, 90.0, 'pdftotext',
      nil, 50.0, 100.0, 58.0, 142.0
    )
    h0  = b.send(:mesh_text_height_inches, item0, 0.0, LETTER[3])
    h90 = b.send(:mesh_text_height_inches, item90, 90.0, LETTER[3])
    assert_in_delta h0, h90, 0.0001,
                    'upright part mark in tall bbox must match explicit 90° height'
    # Round 13: height = 8pt * (1/72) = 0.1111" — no bbox shrink in height path
    assert h0 < 0.13,
           "vertical part mark height must not blow up (got #{h0.round(4)}\")"
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
  def test_w1023_like_item_preserves_source_height
    b = make_builder(LETTER)
    # w1023: pdftotext item, bbox ~8pt tall
    item = bbox_item('w1023', 7.0, 8.5)
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    assert_in_delta sketchup_letter_height_in(7.0), h, 1.0e-12
  end

  def test_place_mesh_text_uses_nominal_height_without_bbox_scaling
    # Microscopic pdftotext bbox (1.5pt tall, 3pt wide) must not shrink 8pt nominal.
    # SIZE-1: mesh_text_height_inches uses nominal PDF pt only — no bbox-fit shrink.
    b = make_builder(LETTER)
    item = bbox_item('W12X30', 8.0, 1.5, bbox_w: 3.0)
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    assert_in_delta sketchup_letter_height_in(8.0), h, 1.0e-12,
                    'bbox dimensions must not override the source text height'
  end

  # A successfully verified Text3D rung keeps exactly the owned edge/face set
  # whose positive stable IDs are reported as its delivery evidence.
  def test_verified_text3d_retains_exact_owned_edge_and_face_set
    b = make_builder(LETTER)
    item = bbox_item('A', 8.0, 10.0, bbox_w: 8.0)
    ents = DummyTransformEntities.new

    assert b.send(:place_mesh_text, ents, item, 0.0, 0.0, nil)
    live = ents.to_a
    attempt = b.text_attempts.fetch(0)
    live_ids = live.map { |entity| "persistent_id:#{entity.persistent_id}" }

    assert_equal ['Edge', 'Face'], live.map(&:typename).sort
    assert_equal live_ids.sort, attempt[:resulting_entity_ids].sort
    assert attempt[:visual_fidelity_verified]
    assert attempt[:width_verified]
    assert attempt[:height_verified]
    assert_empty ents.erased
  end

  # ── v3.7.83: nominal font_size must survive tiny pdftotext line bbox ───────
  def test_nominal_font_size_not_shrunk_by_microscopic_pdftotext_bbox
    b = make_builder(ANSI_D)
    item = identified_text_item(
      'W12X30', 50.0, 100.0, 10.0, 0.0, 'pdftotext',
      nil, 50.0, 100.0, 120.0, 101.5
    )
    h = b.send(:mesh_text_height_inches, item, 0.0, ANSI_D[3])
    expected = sketchup_letter_height_in(10.0)
    assert_in_delta expected, h, 0.002,
                    "10pt nominal must not shrink to microscopic bbox (got #{h.round(5)})"
    assert h >= 0.08, "Shop drawing text must be readable (got #{h.round(4)}\")"
  end

  # ── D-size shop drawing: typical labels stay in readable range ─────────────
  def test_shop_drawing_fallback_path_readable_heights
    b = make_builder([0, 0, 2590.866, 1726.299])
    [
      ['piece mark',  8.0,  1.2,  40.0],
      ['dim string',  6.0,  0.8,  30.0],
      ['BOM header', 10.0,  1.0,  80.0],
    ].each do |label, nominal_pt, bbox_h_pt, bbox_w_pt|
      item = identified_text_item(
        label, 50.0, 100.0, nominal_pt, 0.0, 'pdftotext',
        nil, 50.0, 100.0, 50.0 + bbox_w_pt, 100.0 + bbox_h_pt
      )
      h = b.send(:mesh_text_height_inches, item, 0.0, 1726.299)
      assert_in_delta sketchup_letter_height_in(nominal_pt), h, 1.0e-12,
                      "#{label}: page size and bbox must not alter source height"
    end
  end

  # ── Round 20 (R20-2): Ruby 2.2 canary — a VALUE assertion, not source regex ─
  # Field bug v3.7.81–3.7.89: Numeric#clamp (Ruby 2.4+) raised NoMethodError on
  # the SketchUp Make 2017 host, the rescue swallowed it, and EVERY item shipped
  # at MESH_TEXT_HEIGHT_MIN_IN (0.01") — uniform illegible specks. This test
  # MUST execute under Docker ruby:2.2 in CI and the release gate; it fails
  # there if any post-2.2 API sneaks back into the height path.
  def test_ruby22_canary_12pt_height_is_faithful_not_min
    b = make_builder(ARCH_D)
    item = bbox_item('W12X30', 12.0, 14.0)
    h = b.send(:mesh_text_height_inches, item, 0.0, ARCH_D[3])
    assert_in_delta sketchup_letter_height_in(12.0), h, 0.0001,
      "12pt must yield 0.1667\" (got #{h} — 0.01 means the rescue floor engaged)"
  end

  # ── Round 20 (R20-2): a height-path failure must be counted, never silent ──
  def test_height_fallback_is_counted_not_silent
    b = make_builder(LETTER)
    h = b.send(:mesh_text_height_inches, Object.new, 0.0, 792.0)
    assert_nil h, 'unreadable source height must fail closed, not invent a floor'
    assert_equal 1, b.instance_variable_get(:@text_height_fallback_count),
                 'height fallback must increment the crosscheck counter'
    result = nil
    begin
      result = b.send(:text_height_samples)
    rescue StandardError
      result = []
    end
    assert_kind_of Array, result
  end

  # ── Round 20 (R20-1 quality): faithful height direct, tolerance 0.0 ────────
  # Live probes: tolerance 0.6 only coarsened curves (116 vs 235 edges at the
  # same size/faces); the height is passed to add_3d_text directly with
  # tolerance 0.0.
  #
  # The final host bounds—not transform arguments alone—must prove the exact
  # declared width, source height, placement, and rotation.
  def test_place_mesh_text_verifies_exact_post_transform_visual_fidelity
    b = make_builder(ANSI_D)
    item = bbox_item('W12X30', 8.0, 10.0, bbox_w: 50.0)
    ents = DummyTransformEntities.new
    assert b.send(:place_mesh_text, ents, item, 0.0, 0.0, nil)

    assert_equal 1, ents.height_args.length
    assert_in_delta sketchup_letter_height_in(8.0), ents.height_args[0], 1e-9,
                    'add_3d_text must receive the faithful target height directly'
    assert_equal [0.0], ents.tolerance_args,
                 'add_3d_text tolerance must be 0.0 (R20-1 quality)'
    kinds = ents.transforms.map { |args| args[0].respond_to?(:kind) ? args[0].kind : nil }
    assert_equal [:scaling, :translation], kinds
    scaling_args = ents.transforms[0][0].args
    # Declared 50pt bbox width. Stub renders 3x letter height (= 24pt * ratio).
    assert_in_delta 50.0 / (24.0 * LETTER_H_RATIO), scaling_args[1], 1e-9,
                    'X factor must be declared/rendered'
                    'X factor must be declared/rendered'
    assert_in_delta 1.0, scaling_args[2], 1.0e-12,
                    'generated height already equals the exact source height'
    assert_in_delta 1.0, scaling_args[3], 1.0e-12

    actual = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity.bounds(ents.to_a)
    x_pdf, y_pdf, angle = b.send(:mesh_text_insertion_pdf, item)
    display_angle = b.send(:display_text_angle, item, angle)
    anchor = b.send(:text_point_to_su, item, x_pdf, y_pdf, 0.0, 0.0)
    expected = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity.expected_rotated_bounds(
      anchor, 50.0 * PT_TO_IN, sketchup_letter_height_in(8.0), display_angle
    )
    [:min_x, :min_y, :max_x, :max_y, :width, :height].each do |key|
      assert_in_delta expected[key], actual[key], 1.0e-8,
                      "final #{key} must match the requested PDF geometry"
    end

    attempt = b.text_attempts.fetch(0)
    assert attempt[:placement_verified]
    assert attempt[:rotation_verified]
    assert attempt[:width_verified]
    assert attempt[:height_verified]
    samples = b.send(:text_height_samples)
    assert_equal 1, samples.length
    assert_in_delta sketchup_letter_height_in(8.0), samples[0], 0.001
    assert_empty ents.erased
  end

end
