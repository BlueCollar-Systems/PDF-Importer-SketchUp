#!/usr/bin/env ruby

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext') unless defined?(SRC_ROOT)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

module Geom
  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def distance(other)
      dx = x - other.x.to_f
      dy = y - other.y.to_f
      dz = z - other.z.to_f
      Math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
    end
  end unless const_defined?(:Point3d)
end

require 'bc_pdf_vector_importer/svg_3d_text_renderer'

class Svg3DBounds
  attr_reader :min, :max

  def initialize(points)
    @min = Geom::Point3d.new(points.map(&:x).min, points.map(&:y).min,
                             points.map(&:z).min)
    @max = Geom::Point3d.new(points.map(&:x).max, points.map(&:y).max,
                             points.map(&:z).max)
  end
end

class Svg3DNormal
  attr_accessor :z
  def initialize(z = 1.0); @z = z; end
end

class Svg3DFace
  attr_reader :persistent_id, :pushpull_calls

  def initialize(owner, id, points)
    @owner = owner
    @persistent_id = id
    @points = points
    @normal = Svg3DNormal.new(1.0)
    @depth = 0.0
    @pushpull_calls = []
  end

  def typename; 'Face'; end
  def normal; @normal; end
  def reverse!; @normal.z *= -1.0; self; end

  def pushpull(depth)
    @pushpull_calls << depth.to_f
    @depth = depth.to_f
  end

  def bounds
    raised = @points.map { |p| Geom::Point3d.new(p.x, p.y, @depth) }
    Svg3DBounds.new(@points + raised)
  end

  def erase!
    @owner.erase_entities(self)
    true
  end
end

class Svg3DEntities
  attr_reader :erased, :groups

  def initialize(options = {})
    @options = options
    @items = []
    @erased = []
    @groups = []
    @next_id = options[:first_id] || 100
  end

  def next_id
    @next_id += 1
  end

  def to_a; @items.dup; end

  def add_group
    group = Svg3DGroup.new(self, next_id, @options)
    @items << group
    @groups << group
    group
  end

  def add_face(points)
    raise 'synthetic face creation failure' if @options[:fail_add_face]
    if @options[:translate_created_faces]
      dx, dy = @options[:translate_created_faces]
      points = Array(points).map do |point|
        Geom::Point3d.new(point.x + dx.to_f, point.y + dy.to_f, point.z)
      end
    end
    face = Svg3DFace.new(self, next_id, points)
    @items << face
    face
  end

  def erase_entities(*entities)
    entities.flatten.each do |entity|
      @items.delete(entity)
      @groups.delete(entity)
      @erased << entity
    end
  end
end

class Svg3DGroup
  attr_accessor :name, :layer
  attr_reader :persistent_id, :entities, :attributes

  def initialize(owner, id, options)
    @owner = owner
    @persistent_id = id
    @entities = Svg3DEntities.new(options.merge(first_id: id * 100))
    @attributes = {}
  end

  def typename; 'Group'; end

  def set_attribute(dictionary, key, value)
    @attributes[[dictionary, key]] = value
  end

  def bounds
    points = []
    @entities.to_a.each do |entity|
      next unless entity.respond_to?(:bounds)
      box = entity.bounds
      points << box.min << box.max
    end
    raise 'empty group bounds' if points.empty?
    Svg3DBounds.new(points)
  end

  def erase!
    @owner.erase_entities(self)
    true
  end
end

Svg3DSpan = Struct.new(:text, :font_name, :source_span_id,
                       :bbox_x0, :bbox_y0, :bbox_x1, :bbox_y1)

class SvgText3DRendererTest < Minitest::Test
  RENDERER = BlueCollarSystems::PDFVectorImporter::Svg3DTextRenderer
  FIDELITY = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
  MEDIA_BOX = [0.0, 0.0, 100.0, 100.0].freeze

  def complete_source_context(page_number = 1)
    {
      importer_id: FIDELITY::IMPORTER_ID,
      page_number: page_number,
      render_status: :complete,
      font_inventory_status: :complete,
      page_failures: []
    }
  end

  def square_svg(transform = nil)
    transform_attr = transform ? " transform=\"#{transform}\"" : ''
    '<svg xmlns="http://www.w3.org/2000/svg" width="100pt" height="100pt" ' \
      'viewBox="0 0 100 100"><defs><g id="glyph-0-0"><path ' \
      'd="M 0 0 L 10 0 L 10 -10 L 0 -10 Z"/></g></defs><g>' \
      "<use href=\"#glyph-0-0\" x=\"10\" y=\"80\"#{transform_attr}/></g></svg>"
  end

  def square_svg_with_unjoined_source_glyph
    '<svg xmlns="http://www.w3.org/2000/svg" width="100pt" height="100pt" ' \
      'viewBox="0 0 100 100"><defs><g id="glyph-0-0"><path ' \
      'd="M 0 0 L 10 0 L 10 -10 L 0 -10 Z"/></g></defs><g>' \
      '<use href="#glyph-0-0" x="10" y="80"/>' \
      '<use href="#glyph-0-0" x="70" y="20"/></g></svg>'
  end

  def span(id = 'text_span:1:0', box = [8.0, 18.0, 25.0, 35.0])
    Svg3DSpan.new('A', 'pdftotext', id, *box)
  end

  def test_exact_svg_outline_becomes_owned_filled_positive_depth_3d_text
    entities = Svg3DEntities.new
    result = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, [span], depth: 0.05
    )

    assert result[:ok], result[:failures].inspect
    assert_equal :svg_source_3d_text, result[:renderer]
    assert_equal 1, result[:span_results].length
    delivered = result[:span_results][0]
    assert_equal 'text_span:1:0', delivered[:source_span_id]
    assert delivered[:identity_verified]
    assert delivered[:placement_verified]
    assert delivered[:rotation_verified]
    assert delivered[:size_verified]
    assert delivered[:depth_verified]
    assert_operator delivered[:face_count], :>=, 1
    assert_operator delivered[:extruded_face_count], :>=, 1
    assert_in_delta 10.0 / 72.0, delivered[:width], 1.0e-7
    assert_in_delta 10.0 / 72.0, delivered[:height], 1.0e-7
    assert_in_delta 0.05, delivered[:depth], 1.0e-7
    assert_equal 'text_span:1:0',
      delivered[:group].attributes[['BC_PDF_Importer', 'source_span_id']]
    assert_empty result[:transition_proofs]
  end

  def test_unmatched_source_span_never_claims_that_source_outlines_are_absent
    entities = Svg3DEntities.new
    missing = span('text_span:1:7', [60.0, 60.0, 70.0, 70.0])
    result = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, [missing], depth: 0.05,
      source_context: complete_source_context
    )

    refute result[:ok]
    assert_empty result[:span_results]
    assert_equal 1, result[:transition_proofs].length
    proof = result[:transition_proofs][0]
    assert_equal 'text_span:1:7', proof[:source_span_id]
    assert_equal :text3d, proof[:from_mode]
    assert_equal :glyphs, proof[:to_mode]
    assert_equal :source_item_identity_unavailable, proof[:reason_code]
    assert_equal FIDELITY::IMPORTER_ID, proof[:importer_id]
    assert_equal 1, proof[:page_number]
    assert proof[:affirmative_impossibility]
    refute proof[:generic_failure]
    assert_equal :not_required, proof[:cleanup_outcome]
    refute_match(/no glyph placement|outlines? absent/i,
                 proof[:evidence][:source_observation])
    assert_equal 1, proof[:evidence][:unmatched_renderer_placement_count]
  end


  def test_incomplete_glyph_coverage_is_not_delivered_as_exact_3d_text
    long_span = Svg3DSpan.new(
      'TENLETTERS', 'pdftotext', 'text_span:1:0', 8.0, 18.0, 25.0, 35.0
    )
    result = RENDERER.render_svg(
      Svg3DEntities.new, square_svg, MEDIA_BOX, [long_span], depth: 0.05,
      source_context: complete_source_context
    )

    refute result[:ok]
    assert_empty result[:span_results]
    assert_empty result[:unmatched_source_results],
                 'partial ink must not survive as a second anonymous 3D object'
    assert_equal :source_item_identity_unavailable,
                 result[:transition_proofs][0][:reason_code]
    coverage = result[:match][:coverage_failures][0]
    assert_equal 10, coverage[:expected_glyph_count]
    assert_equal 1, coverage[:observed_glyph_count]
  end

  def test_each_transition_proof_contains_only_its_item_coverage_evidence
    first = Svg3DSpan.new(
      'FIRST', 'pdftotext', 'text_span:1:0', 8.0, 18.0, 25.0, 35.0
    )
    second = Svg3DSpan.new(
      'SECOND', 'pdftotext', 'text_span:1:1', 8.0, 18.0, 25.0, 35.0
    )
    synthetic_match = {
      placement_matches: [],
      unmatched_placements: [{ placement_index: 0 }],
      coverage_failures: [
        {
          source_span_id: 'text_span:1:0', expected_glyph_count: 5,
          observed_glyph_count: 1, placement_indices: [0]
        },
        {
          source_span_id: 'text_span:1:1', expected_glyph_count: 6,
          observed_glyph_count: 1, placement_indices: [0]
        }
      ]
    }

    result = BlueCollarSystems::PDFVectorImporter::CairoGlyphSource.stub(
      :match_spans, synthetic_match
    ) do
      RENDERER.render_svg(
        Svg3DEntities.new, square_svg, MEDIA_BOX, [first, second],
        depth: 0.05, source_context: complete_source_context,
        preserve_unmatched_source_placements: false
      )
    end

    assert_equal 2, result[:transition_proofs].length
    result[:transition_proofs].each do |proof|
      coverage = proof[:evidence][:glyph_coverage_failures]
      assert_equal [proof[:source_span_id]],
                   coverage.map { |failure| failure[:source_span_id] }.uniq
    end
  end

  def test_empty_key_page_font_inventory_failure_stops_without_absence_proof
    missing = span('text_span:1:7', [60.0, 60.0, 70.0, 70.0])
    context = complete_source_context.merge(
      page_failures: {
        '' => {
          scope: :page, page_number: 1,
          reason_code: :font_inventory_runtime_error,
          detail: 'page font inventory raised'
        }
      }
    )
    result = RENDERER.render_svg(
      Svg3DEntities.new, square_svg, MEDIA_BOX, [missing], depth: 0.05,
      source_context: context
    )

    refute result[:ok]
    assert_empty result[:transition_proofs]
    assert_equal 1, result[:failures].length
    failure = result[:failures][0]
    assert_equal :source_page_inventory_failed, failure[:reason_code]
    assert_equal true, failure[:generic_failure]
    assert_equal false, failure[:affirmative_impossibility]
  end

  def test_source_page_context_must_match_item_importer_and_page
    missing = span('text_span:1:7', [60.0, 60.0, 70.0, 70.0])
    contexts = [
      complete_source_context.merge(importer_id: 'different_importer'),
      complete_source_context(2)
    ]

    contexts.each do |context|
      result = RENDERER.render_svg(
        Svg3DEntities.new, square_svg, MEDIA_BOX, [missing], depth: 0.05,
        source_context: context
      )
      assert_empty result[:transition_proofs]
      assert_equal :source_page_evidence_mismatch,
                   result[:failures][0][:reason_code]
    end
  end

  def test_host_face_creation_exception_is_a_hard_failure_not_a_fallback_proof
    entities = Svg3DEntities.new(fail_add_face: true)
    result = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, [span], depth: 0.05
    )

    refute result[:ok]
    assert_empty result[:transition_proofs]
    assert_equal :host_face_creation_exception, result[:failures][0][:reason_code]
    assert result[:failures][0][:generic_failure]
    assert_empty entities.groups, 'partially created owned group must be erased'
  end

  def test_zero_or_negative_depth_cannot_be_reported_as_3d_text
    [0.0, -0.01].each do |depth|
      result = RENDERER.render_svg(
        Svg3DEntities.new, square_svg, MEDIA_BOX, [span], depth: depth
      )
      refute result[:ok]
      assert_empty result[:transition_proofs]
      assert_equal :nonpositive_extrusion_depth, result[:failures][0][:reason_code]
    end
  end

  def test_same_size_3d_text_at_wrong_coordinates_is_rejected_and_cleaned
    entities = Svg3DEntities.new(
      :translate_created_faces => [3.0, -2.0]
    )

    result = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, [span], :depth => 0.05
    )

    refute result[:ok]
    assert_empty result[:transition_proofs]
    assert_match(/width\/height verification failed/i,
                 result[:failures][0][:detail])
    assert_empty entities.groups
  end

  def test_final_evidence_rejects_post_verification_3d_translation
    result = RENDERER.render_svg(
      Svg3DEntities.new, square_svg, MEDIA_BOX, [span], :depth => 0.05
    )
    row = result[:span_results][0]
    row[:source_page_transformation] = [
      1.0, 0.0, 0.0, 0.0,
      0.0, 1.0, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      0.0, 0.0, 0.0, 1.0
    ]
    row[:page_transform_verified] = true
    row[:group].entities.to_a.each do |face|
      face.instance_variable_get(:@points).each { |point| point.y -= 2.0 }
    end

    error = assert_raises(FIDELITY::ContractError) do
      RENDERER.finalize_source_evidence!(row, span)
    end

    assert_match(/final bounds differ from source outlines/i, error.message)
  end

  def test_svg_rotation_matrix_is_preserved_and_reported
    # Matrix translates the original use by (+20,-10) and rotates its local
    # x-axis into model -y. The source transform itself is the identity proof;
    # no substitute font metrics participate.
    item = span('text_span:1:0', [28.0, 28.0, 45.0, 45.0])
    result = RENDERER.render_svg(
      Svg3DEntities.new, square_svg('matrix(0,1,-1,0,20,-10)'),
      MEDIA_BOX, [item], depth: 0.025
    )

    assert result[:ok], result[:failures].inspect
    delivered = result[:span_results][0]
    assert delivered[:rotation_verified]
    assert_equal [[0.0, 1.0, -1.0, 0.0, 20.0, -10.0]],
                 delivered[:source_matrices]
    assert_in_delta 0.025, delivered[:depth], 1.0e-7
  end

  def test_unjoined_svg_placement_is_preserved_as_verified_source_outline_3d
    entities = Svg3DEntities.new
    result = RENDERER.render_svg(
      entities, square_svg_with_unjoined_source_glyph, MEDIA_BOX, [span],
      depth: 0.05, page_number: 1
    )

    assert result[:ok], result[:failures].inspect
    assert_equal 1, result[:span_results].length
    assert_equal 1, result[:unmatched_source_results].length
    source = result[:unmatched_source_results][0]
    assert_equal :svg_glyph_placement, source[:source_kind]
    assert_nil source[:source_span_id]
    assert_equal 'svg_glyph_placements:page:1', source[:source_unit_id]
    assert_equal [1], source[:placement_indices]
    assert source[:identity_verified]
    assert source[:placement_verified]
    assert source[:rotation_verified]
    assert source[:size_verified]
    assert source[:depth_verified]
    assert_equal 'svg_glyph_placement',
      source[:group].attributes[['BC_PDF_Importer', 'source_kind']]
    assert_empty result[:transition_proofs]
    assert_empty result[:failures]
  end

  def test_subset_fallback_does_not_materialize_other_page_glyphs
    entities = Svg3DEntities.new
    result = RENDERER.render_svg(
      entities, square_svg_with_unjoined_source_glyph, MEDIA_BOX, [span],
      depth: 0.05, page_number: 1,
      preserve_unmatched_source_placements: false
    )

    assert result[:ok], result[:failures].inspect
    assert_equal 1, result[:span_results].length
    assert_empty result[:unmatched_source_results]
    assert_equal 1, entities.groups.length,
                 'item-subset fallback must not duplicate unrelated page text'
  end

  def test_svg_glyphs_without_semantic_spans_are_not_silently_discarded
    result = RENDERER.render_svg(
      Svg3DEntities.new, square_svg, MEDIA_BOX, [],
      depth: 0.025, page_number: 4
    )

    assert result[:ok], result[:failures].inspect
    refute result[:no_semantic_text]
    assert_empty result[:span_results]
    assert_equal 1, result[:unmatched_source_results].length
    assert_equal [0], result[:unmatched_source_results][0][:placement_indices]
    assert result[:unmatched_source_results][0][:depth_verified]
  end
end
