#!/usr/bin/env ruby
# Cross-mode placement contracts: Labels / 3D Text / Geometry / Glyphs.
# Placement must be fixed in-mode; a transform bug must never be hidden by
# switching representation (TEXTMODE-1).
#
# Adopted (R22) from the parked parity WIP: only the contracts that hold on
# the shipped design. The font-metric and fragment-suppression assertions
# stay parked with codex/sketchup-3d-text-parity pending its own review.

require_relative 'mesh_text_scaling_test'

class PlacementLabelEntity
  attr_accessor :layer, :vector, :display_leader
  attr_reader :point, :persistent_id, :text

  def initialize(text, point, vector)
    @text = text
    @point = point
    @vector = vector
    @display_leader = true
    @persistent_id = FidelityFixtureIdentity.next_entity_id
  end

  def typename
    'Text'
  end
end

class LabelModeEntities < DummyTransformEntities
  attr_reader :texts, :mesh_calls

  def initialize
    super()
    @texts = []
    @mesh_calls = []
  end

  def add_text(text, point, vector = nil)
    ent = PlacementLabelEntity.new(text, point, vector)
    @entities << ent
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
      scale_factor: 1.0, import_text: true, use_3d_text: use_3d,
      native_font_identity_resolver: lambda { |source|
        {
          source_span_id: source.source_span_id,
          pdf_font_identity: 'embedded:test-font',
          installed_family: 'Test Exact Font',
          exact_family_match: true,
          verified: true
        }
      }
    )
  end

  # 3D Text mesh anchor is the raw PDF baseline-left point; Labels use a
  # bbox-centered heuristic, so the raw PDF anchor is preserved for mesh text.
  def test_horizontal_labels_and_text3d_share_pdf_anchor
    label_b = make_mode_builder(use_3d: false)
    mesh_b = make_mode_builder(use_3d: true)
    item = identified_text_item(
      'QUAN', 100.0, 200.0, 8.0, 0.0, 'pdftotext', nil,
      90.0, 198.0, 130.0, 210.0
    )
    mx, my, ma = mesh_b.send(:mesh_text_insertion_pdf, item)
    assert_in_delta item.x, mx, 0.01
    assert_in_delta item.y, my, 0.01
    assert_in_delta 0.0, ma, 0.01
  end

  # Rotated 3D Text transform order: translation to the anchor, then rotation
  # about that anchor. No bbox scaling and no post-rotation nudges, ever.
  def test_rotated_mesh_transform_order_is_translate_rotate
    b = make_mode_builder(use_3d: true)
    item = identified_text_item(
      'a1001', 140.0, 250.0, 8.0, 90.0, 'pdftotext', nil,
      140.0, 250.0, 148.0, 292.0
    )
    ents = DummyTransformEntities.new
    assert b.send(:place_mesh_text, ents, item, 0.0, 0.0, 'TextLayer')
    kinds = ents.transforms.map { |args| args.first.kind }
    assert_equal [:translation, :rotation], kinds,
                 'rotated 3D Text must move, then rotate; no bbox scaling'
    attempt = b.text_attempts.fetch(0)
    assert_equal item.source_span_id, attempt[:source_span_id]
    assert_equal :text3d, attempt[:delivered_mode]
    assert attempt[:placement_verified]
    assert attempt[:rotation_verified]
    assert attempt[:width_verified]
    assert attempt[:height_verified]
    assert(
      !File.read(File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb'),
                 encoding: 'UTF-8')
           .include?('mesh_text_post_rotation_offset'),
      'mesh_text_post_rotation_offset must stay banned'
    )
  end

  # SketchUp::Text cannot rotate its glyphs; Text#vector controls only the
  # leader. The native rung must therefore leave no artifact and emit the
  # adjacent Labels -> 3D Text proof for the pipeline controller.
  def test_labels_mode_proves_rotated_native_label_is_host_unsupported
    b = make_mode_builder(use_3d: false)
    item = identified_text_item(
      'a1001', 140.0, 250.0, 8.0, 90.0, 'pdftotext', nil,
      140.0, 250.0, 148.0, 292.0
    )
    ents = LabelModeEntities.new
    refute b.send(:place_text, ents, item, 0.0, 0.0, 792.0, 'TextLayer')
    assert_empty ents.texts
    assert_empty ents.mesh_calls
    attempt = b.text_attempts.fetch(0)
    assert_equal item.source_span_id, attempt[:source_span_id]
    assert_nil attempt[:delivered_mode]
    rung = attempt[:attempt_history].fetch(0)
    assert_equal :failed, rung[:outcome]
    assert_equal :labels, rung[:transition_proof][:from_mode]
    assert_equal :text3d, rung[:transition_proof][:to_mode]
    assert_equal :host_representation_unsupported,
                 rung[:transition_proof][:reason_code]
  end

  # Geometry and Glyphs may share free SVG extraction, but their host entity
  # structures are deliberately distinct: raw edges vs reusable components.
  def test_geometry_and_glyphs_force_distinct_host_entity_structures
    # Explicit UTF-8 for the bare ruby:2.2 container (US-ASCII default).
    main = File.read(File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'),
                     encoding: 'UTF-8')
    assert_match(/requested_text_mode == :geometry/, main)
    assert_match(/raw_edge_glyphs: true,\s*\n\s*flatten_glyph_instances: true/, main)
    assert_match(/raw_edge_glyphs: false,\s*\n\s*flatten_glyph_instances: false/, main)
    assert_match(/Raw Text Path Geometry/, main)
    assert_match(/Glyph Components/, main)
  end
end
