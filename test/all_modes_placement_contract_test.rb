#!/usr/bin/env ruby
# Cross-mode placement contracts: Labels / 3D Text / Geometry / Glyphs.
# Placement must be fixed in-mode; a transform bug must never be hidden by
# switching representation (TEXTMODE-1).
#
# Adopted (R22) from the parked parity WIP: only the contracts that hold on
# the shipped design. The font-metric and fragment-suppression assertions
# stay parked with codex/sketchup-3d-text-parity pending its own review.

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
  def make_mode_builder(use_3d:)
    GB.new(
      Object.new, [], [], LETTER,
      scale_factor: 1.0, import_text: true, use_3d_text: use_3d
    )
  end

  # Labels and 3D Text must anchor a horizontal span at the same PDF point —
  # switching modes must never move text.
  def test_horizontal_labels_and_text3d_share_pdf_anchor
    label_b = make_mode_builder(use_3d: false)
    mesh_b = make_mode_builder(use_3d: true)
    item = TI.new('QUAN', 100.0, 200.0, 8.0, 0.0, 'pdftotext', nil,
                  90.0, 198.0, 130.0, 210.0)
    lx, ly, la = label_b.send(:text_insertion_pdf, item)
    mx, my, ma = mesh_b.send(:mesh_text_insertion_pdf, item)
    assert_in_delta lx, mx, 0.01
    assert_in_delta ly, my, 0.01
    assert_in_delta la, ma, 0.01
  end

  # Rotated 3D Text transform order: width fit about ORIGIN (pre-rotation
  # run axis), then the single translation to the anchor, then the single
  # rotation about that anchor. No post-rotation nudges, ever.
  def test_rotated_mesh_transform_order_is_scale_translate_rotate
    b = make_mode_builder(use_3d: true)
    item = TI.new('a1001', 140.0, 250.0, 8.0, 90.0, 'pdftotext', nil,
                  140.0, 250.0, 148.0, 292.0)
    ents = DummyTransformEntities.new
    assert b.send(:place_mesh_text, ents, item, 0.0, 0.0, 'TextLayer')
    kinds = ents.transforms.map { |args| args.first.kind }
    assert_equal [:scaling, :translation, :rotation], kinds,
                 'rotated 3D Text must scale about ORIGIN, then move, then rotate'
    assert(
      !File.read(File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb'),
                 encoding: 'UTF-8')
           .include?('mesh_text_post_rotation_offset'),
      'mesh_text_post_rotation_offset must stay banned'
    )
  end

  # Labels mode must deliver a native rotated label — never silently a mesh.
  def test_labels_mode_keeps_native_label_for_rotated_text
    b = make_mode_builder(use_3d: false)
    item = TI.new('a1001', 140.0, 250.0, 8.0, 90.0, 'pdftotext', nil,
                  140.0, 250.0, 148.0, 292.0)
    ents = LabelModeEntities.new
    b.send(:place_text, ents, item, 0.0, 0.0, 792.0, 'TextLayer')
    assert_equal 1, ents.texts.length
    assert_empty ents.mesh_calls
  end

  # Geometry and Glyphs are both SVG-rendered representations routed through
  # the same renderer with 3D Text fallback semantics.
  def test_geometry_and_glyphs_share_svg_renderer_path
    # Explicit UTF-8 for the bare ruby:2.2 container (US-ASCII default).
    main = File.read(File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'),
                     encoding: 'UTF-8')
    assert_match(/SvgTextRenderer\.render/, main)
    assert_match(
      /fallback_use_3d = \[:text3d, :geometry, :glyphs\]\.include\?\(requested_text_mode\)/,
      main
    )
  end
end
