#!/usr/bin/env ruby
# Cross-mode placement contracts: Labels / 3D Text / Geometry / Glyphs.
# Fixes alignment in-mode; never switches representation to hide transform bugs.

require 'minitest/autorun'
require_relative 'mesh_text_scaling_test'

class LabelModeEntities < DummyTransformEntities
  attr_reader :texts, :mesh_calls

  def initialize
    super()
    @texts = []
    @mesh_calls = []
  end

  def add_text(text, point, vector = nil)
    ent = Object.new
    def ent.display_leader=(*); end
    def ent.display_leader; false; end
    def ent.vector; @vector; end
    def ent.vector=(v); @vector = v; end
    ent.vector = vector
    @texts << { text: text, point: point, vector: vector, entity: ent }
    ent
  end

  def add_3d_text(text, align, font, bold, italic, height, tol, extrusion, filled, z)
    @mesh_calls << { text: text, height: height }
    super
  end
end

class AllModesPlacementContractTest < Minitest::Test
  ARIAL_RATIO = 1491.0 / 2048.0

  def make_builder(use_3d:)
    GB.new(
      Object.new, [], [], LETTER,
      scale_factor: 1.0, import_text: true, use_3d_text: use_3d,
      installed_font_families: ['Arial']
    )
  end

  def test_horizontal_labels_and_text3d_share_pdf_anchor
    label_b = make_builder(use_3d: false)
    mesh_b = make_builder(use_3d: true)
    item = TI.new('QUAN', 100.0, 200.0, 8.0, 0.0, 'pdftotext', nil,
                  90.0, 198.0, 130.0, 210.0)
    lx, ly, la = label_b.send(:text_insertion_pdf, item)
    mx, my, ma = mesh_b.send(:mesh_text_insertion_pdf, item)
    assert_in_delta lx, mx, 0.01
    assert_in_delta ly, my, 0.01
    assert_in_delta la, ma, 0.01
  end

  def test_text3d_height_uses_font_letter_ratio_not_raw_em
    b = make_builder(use_3d: true)
    item = TI.new('SECTION', 50.0, 100.0, 12.0, 0.0, 'Arial', nil,
                  50.0, 100.0, 150.0, 112.0)
    item.source_font_family = 'Arial'
    item.font_to_sketchup_letter_ratio = ARIAL_RATIO
    item.font_to_sketchup_letter_ratio_source = :known_arial_family
    h = b.send(:mesh_text_height_inches, item, 0.0, 792.0)
    assert_in_delta (12.0 / 72.0) * ARIAL_RATIO, h, 1.0e-9
  end

  def test_rotated_mesh_transform_order_is_scale_translate_rotate
    b = make_builder(use_3d: true)
    item = TI.new('a1001', 140.0, 250.0, 8.0, 90.0, 'pdftotext', nil,
                  140.0, 250.0, 148.0, 292.0)
    ents = DummyTransformEntities.new
    b.send(:place_mesh_text, ents, item, 0.0, 0.0, 'TextLayer')
    kinds = ents.transforms.map { |args| args.first.kind }
    assert_equal [:scaling, :translation, :rotation], kinds,
                 'rotated 3D Text must scale about ORIGIN, then move, then rotate'
    assert(
      !File.read(File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb'))
           .include?('mesh_text_post_rotation_offset'),
      'mesh_text_post_rotation_offset must stay banned'
    )
  end

  def test_labels_mode_keeps_native_label_for_rotated_text
    b = make_builder(use_3d: false)
    item = TI.new('a1001', 140.0, 250.0, 8.0, 90.0, 'pdftotext', nil,
                  140.0, 250.0, 148.0, 292.0)
    ents = LabelModeEntities.new
    b.send(:place_text, ents, item, 0.0, 0.0, 792.0, 'TextLayer')
    assert_equal 1, ents.texts.length
    assert_empty ents.mesh_calls
  end

  def test_geometry_and_glyphs_share_svg_renderer_path
    main = File.read(File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'))
    assert_match(/SvgTextRenderer\.render/, main)
    assert_match(
      /fallback_use_3d = \[:text3d, :geometry, :glyphs\]\.include\?\(requested_text_mode\)/,
      main
    )
  end

  def test_contained_fragment_ghosts_are_suppressed
    parser = BlueCollarSystems::PDFVectorImporter::TextParser.new([], {})
    keep = TI.new('1/4 (TYP.)', 100.0, 200.0, 8.0, 35.0, 'F1')
    ghost = TI.new('1/4', 101.0, 200.5, 8.0, 35.0, 'F1')
    unrelated = TI.new('1/4', 400.0, 200.0, 8.0, 0.0, 'F1')
    out = parser.send(:suppress_contained_fragments, [keep, ghost, unrelated])
    texts = out.map { |it| it.text }
    assert_equal ['1/4 (TYP.)', '1/4'], texts
  end
end
