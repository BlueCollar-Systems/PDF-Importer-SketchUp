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

  class Transformation
    attr_reader :matrix

    def initialize(values)
      @matrix = Array(values).map(&:to_f)
    end
  end unless const_defined?(:Transformation)
end

require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/svg_item_representation_renderer'

class ItemVectorBounds
  attr_reader :min, :max

  def initialize(points)
    @min = Geom::Point3d.new(
      points.map(&:x).min, points.map(&:y).min, points.map(&:z).min
    )
    @max = Geom::Point3d.new(
      points.map(&:x).max, points.map(&:y).max, points.map(&:z).max
    )
  end
end

class SvgItemRepresentationPointNormalizationTest < Minitest::Test
  Renderer =
    BlueCollarSystems::PDFVectorImporter::SvgItemRepresentationRenderer

  def test_exact_collinear_interior_vertex_is_removed_before_host_edge_creation
    points = [
      Geom::Point3d.new(0, 0, 0),
      Geom::Point3d.new(1, 0, 0),
      Geom::Point3d.new(2, 0, 0),
      Geom::Point3d.new(2, 1, 0)
    ]

    normalized = Renderer.normalized_points(points)

    assert_equal [[0.0, 0.0], [2.0, 0.0], [2.0, 1.0]],
                 normalized.map { |point| [point.x, point.y] }
  end

  def test_near_collinear_curve_vertex_is_preserved
    points = [
      Geom::Point3d.new(0, 0, 0),
      Geom::Point3d.new(1, 0.00001, 0),
      Geom::Point3d.new(2, 0, 0)
    ]

    normalized = Renderer.normalized_points(points)

    assert_equal 3, normalized.length
  end
end

class ItemVectorEdge
  attr_reader :persistent_id, :attributes, :points

  def initialize(id, first, last)
    @persistent_id = id
    @points = [first, last]
    @attributes = {}
  end

  def typename; 'Edge'; end
  def bounds; ItemVectorBounds.new(@points); end
  def hidden?; false; end

  def set_attribute(dictionary, key, value)
    @attributes[[dictionary, key]] = value
  end
end

class ItemVectorDefinition
  attr_reader :name, :entities

  def initialize(name, counter)
    @name = name
    @entities = ItemVectorEntities.new(self, {}, counter)
  end
end

class ItemVectorDefinitions
  attr_reader :items

  def initialize(counter)
    @counter = counter
    @items = []
  end

  def add(name)
    definition = ItemVectorDefinition.new(name, @counter)
    @items << definition
    definition
  end
end

class ItemVectorModel
  attr_reader :definitions

  def initialize(counter = [100])
    @definitions = ItemVectorDefinitions.new(counter)
  end
end

class ItemVectorComponentInstance
  attr_accessor :layer
  attr_reader :persistent_id, :definition, :transformation, :attributes

  def initialize(id, definition, transformation)
    @persistent_id = id
    @definition = definition
    @transformation = transformation
    @attributes = {}
  end

  def typename; 'ComponentInstance'; end
  def hidden?; false; end

  def set_attribute(dictionary, key, value)
    @attributes[[dictionary, key]] = value
  end

  def bounds
    matrix = transformation.matrix
    points = definition.entities.to_a.inject([]) do |all, edge|
      all + Array(edge.points)
    end.map do |point|
      Geom::Point3d.new(
        (point.x * matrix[0]) + (point.y * matrix[4]) + matrix[12],
        (point.x * matrix[1]) + (point.y * matrix[5]) + matrix[13],
        (point.z * matrix[10]) + matrix[14]
      )
    end
    ItemVectorBounds.new(points)
  end
end

class ItemVectorEntities
  attr_reader :erased

  def initialize(owner = nil, options = {}, counter = nil)
    @owner = owner
    @options = options
    @counter = counter || [100]
    @items = []
    @erased = []
  end

  def next_id
    @counter[0] += 1
  end

  def to_a; @items.dup; end

  def add_preexisting(entity)
    @items << entity
    entity
  end

  def add_group
    group = ItemVectorGroup.new(self, next_id, @options, @counter)
    @items << group
    if @owner.nil? && @options[:add_top_level_peer_after_group]
      @options.delete(:add_top_level_peer_after_group)
      @items << ItemVectorEdge.new(
        next_id, Geom::Point3d.new, Geom::Point3d.new(1, 1, 0)
      )
    end
    group
  end

  def add_edges(points)
    if @options[:translate_created_edges]
      dx, dy = @options[:translate_created_edges]
      points = Array(points).map do |point|
        Geom::Point3d.new(point.x + dx.to_f, point.y + dy.to_f, point.z)
      end
    end
    created = []
    Array(points).each_cons(2) do |first, last|
      edge = ItemVectorEdge.new(next_id, first, last)
      @items << edge
      created << edge
      if @options[:raise_after_first_edge]
        @options.delete(:raise_after_first_edge)
        raise 'synthetic host edge failure after partial creation'
      end
    end
    created
  end

  def add_instance(definition, transformation)
    instance = ItemVectorComponentInstance.new(
      next_id, definition, transformation
    )
    @items << instance
    instance
  end

  def erase_entities(*entities)
    entities.flatten.each do |entity|
      @items.delete(entity)
      @erased << entity
    end
  end
end

class ItemVectorGroup
  attr_accessor :name, :layer
  attr_reader :persistent_id, :entities, :attributes

  def initialize(owner, id, options, counter)
    @owner = owner
    @persistent_id = id
    @entities = ItemVectorEntities.new(self, options, counter)
    @attributes = {}
  end

  def typename; 'Group'; end
  def hidden?; false; end

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
    ItemVectorBounds.new(points)
  end
end

class SvgItemRepresentationRendererTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  RENDERER = IMP::SvgItemRepresentationRenderer
  FIDELITY = IMP::RepresentationFidelity
  ITEM = IMP::TextParser::TextItem
  MEDIA_BOX = [0.0, 0.0, 100.0, 100.0].freeze

  def item(source_id = 'text_span:1:0', x0 = 9.0, y0 = 19.0,
           x1 = 22.0, y1 = 32.0)
    ITEM.new('A', 10.0, 20.0, 12.0, 0.0, 'F1', 12.0,
             x0, y0, x1, y1, nil, source_id)
  end

  def square_svg(x = 10, y = 80)
    '<svg xmlns="http://www.w3.org/2000/svg" width="100pt" height="100pt" ' \
      'viewBox="0 0 100 100"><defs><g id="glyph-0-0"><path ' \
      'd="M 0 0 L 10 0 L 10 -10 L 0 -10 Z"/></g></defs><g>' \
      "<use href=\"#glyph-0-0\" x=\"#{x}\" y=\"#{y}\"/></g></svg>"
  end

  def source_context
    {
      importer_id: FIDELITY::IMPORTER_ID,
      page_number: 1,
      render_status: :complete,
      font_inventory_status: :complete,
      page_failures: []
    }
  end

  def render(entities, mode, svg = square_svg, source = item)
    RENDERER.render_svg(
      entities, svg, MEDIA_BOX, source, mode,
      :scale => 1.0, :svg_page_box => MEDIA_BOX,
      :source_context => source_context
    )
  end

  def test_geometry_is_flat_owned_source_bound_raw_edges
    entities = ItemVectorEntities.new
    result = render(entities, :geometry)

    assert_equal true, result[:ok]
    assert_equal :geometry, result[:mode]
    assert_equal 'persistent_id:101', result[:group_entity_id]
    assert_equal ['persistent_id:101'], result[:created_entity_ids]
    assert_equal 'text_span:1:0', result[:source_span_id]
    assert_equal true, result[:entity_type_verified]
    assert_equal true, result[:visual_fidelity_verified]
    assert_operator result[:edge_count], :>, 0
    assert result[:group].entities.to_a.all? { |entity| entity.typename == 'Edge' }
    assert result[:group].entities.to_a.all? do |edge|
      edge.attributes[['BC_PDF_Importer', 'source_span_id']] == 'text_span:1:0'
    end
    assert_equal 'geometry', result[:group].attributes[
      ['BC_PDF_Importer', 'representation']
    ]
  end

  def test_glyphs_are_physically_distinct_per_glyph_groups_not_flat_geometry
    entities = ItemVectorEntities.new
    result = render(entities, :glyphs)

    assert_equal true, result[:ok]
    assert_equal :glyphs, result[:mode]
    assert_equal 1, result[:glyph_group_count]
    assert_equal 1, result[:group].entities.to_a.length
    glyph = result[:group].entities.to_a.first
    assert_equal 'Group', glyph.typename
    assert glyph.entities.to_a.all? { |entity| entity.typename == 'Edge' }
    assert_equal 'text_span:1:0', glyph.attributes[
      ['BC_PDF_Importer', 'source_span_id']
    ]
    assert_equal 'glyphs', result[:group].attributes[
      ['BC_PDF_Importer', 'representation']
    ]
    refute_equal result[:physical_entity_ids], ['persistent_id:101']
  end

  def test_each_rung_returns_its_own_item_specific_impossibility_proof
    entities = ItemVectorEntities.new
    glyphs = render(entities, :glyphs, square_svg(70, 20))
    geometry = render(entities, :geometry, square_svg(70, 20))

    refute glyphs[:ok]
    refute geometry[:ok]
    glyph_proof = glyphs[:transition_proof]
    geometry_proof = geometry[:transition_proof]
    assert_equal [:glyphs, :geometry],
                 [glyph_proof[:from_mode], glyph_proof[:to_mode]]
    assert_equal [:geometry, :raster],
                 [geometry_proof[:from_mode], geometry_proof[:to_mode]]
    refute_equal glyph_proof[:attempted_renderer],
                 geometry_proof[:attempted_renderer]
    refute_equal glyph_proof[:evidence][:representation_contract_checked],
                 geometry_proof[:evidence][:representation_contract_checked]
    assert_empty entities.to_a
  end

  def test_missing_bbox_returns_item_specific_impossibility_for_each_rung
    source = item('text_span:1:7', nil, nil, nil, nil)

    [:glyphs, :geometry].each do |mode|
      entities = ItemVectorEntities.new
      result = render(entities, mode, square_svg, source)

      refute result[:ok]
      assert_equal :source_item_bbox_unavailable,
                   result[:transition_proof][:reason_code]
      assert_equal mode, result[:transition_proof][:from_mode]
      assert_empty entities.to_a
    end
  end

  def test_ink_covered_ligature_is_owned_as_one_source_outline
    source = ITEM.new('AB', 10.0, 20.0, 12.0, 0.0, 'F1', 12.0,
                      9.0, 19.0, 22.0, 32.0, nil, 'text_span:1:0')
    glyph_entities = ItemVectorEntities.new
    geometry_entities = ItemVectorEntities.new

    glyphs = render(glyph_entities, :glyphs, square_svg, source)
    geometry = render(geometry_entities, :geometry, square_svg, source)

    assert_equal true, glyphs[:ok],
                 'source-ink coverage may own a ligature as one glyph outline'
    assert_equal true, geometry[:ok]
    assert_equal [0], glyphs[:placement_indices]
    assert_equal [0], geometry[:placement_indices]
    assert_equal :exact_glyph_ownership, glyphs[:association_strategy]
    assert_equal 1, glyph_entities.to_a.length
    assert_equal 1, geometry_entities.to_a.length
  end

  def test_geometry_can_deliver_an_unambiguous_ligature_that_glyphs_cannot_own
    source = ITEM.new('AB', 10.0, 20.0, 12.0, 0.0, 'F1', 12.0,
                      9.0, 19.0, 22.0, 32.0, nil, 'text_span:1:0')
    svg = square_svg
    opts = { :scale => 1.0, :svg_page_box => MEDIA_BOX }
    placed = IMP::CairoGlyphSource.model_space_loops(svg, MEDIA_BOX, opts)
    pens = Array(placed).map do |entry|
      {
        :x => Array(entry[:pen_pdf])[0],
        :y => Array(entry[:pen_pdf])[1],
        :placement_index => entry[:placement_index]
      }
    end
    match = IMP::CairoGlyphSource.match_spans(pens, [source], MEDIA_BOX)
    glyph_entities = ItemVectorEntities.new
    geometry_entities = ItemVectorEntities.new
    shared = {
      :scale => 1.0, :svg_page_box => MEDIA_BOX,
      :source_context => source_context,
      :precomputed_placed => placed, :precomputed_pens => pens,
      :precomputed_match => match
    }

    glyphs = RENDERER.render_svg(
      glyph_entities, svg, MEDIA_BOX, source, :glyphs, shared
    )
    geometry = RENDERER.render_svg(
      geometry_entities, svg, MEDIA_BOX, source, :geometry, shared
    )

    refute glyphs[:ok],
           'Glyphs needs one exact owned placement for each visible source glyph'
    assert_equal true, geometry[:ok],
                 'flat Geometry may preserve one combined source outline'
    assert_equal :bbox_raw_outline_set, geometry[:association_strategy]
    assert_equal [0], geometry[:placement_indices]
    assert_empty glyph_entities.to_a
    assert_equal 1, geometry_entities.to_a.length
  end

  def test_geometry_rejects_a_bbox_candidate_owned_by_a_peer_item
    source = ITEM.new('AB', 10.0, 20.0, 12.0, 0.0, 'F1', 12.0,
                      9.0, 19.0, 22.0, 32.0, nil, 'text_span:1:0')
    peer = ITEM.new('C', 10.0, 20.0, 12.0, 0.0, 'F1', 12.0,
                    9.0, 19.0, 22.0, 32.0, nil, 'text_span:1:1')
    entities = ItemVectorEntities.new

    result = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, source, :geometry,
      :source_context => source_context, :peer_items => [peer]
    )

    refute result[:ok]
    assert_equal [0], result[:transition_proof][:evidence][
      :peer_ambiguous_placement_indices
    ]
    assert_empty entities.to_a,
                 'ambiguous peer geometry must not be duplicated into a group'
  end

  def test_exact_item_vector_placement_inside_peer_bbox_is_never_reclaimed
    source = item('text_span:1:0')
    peer = item('text_span:1:1')

    [:glyphs, :geometry].each do |mode|
      entities = ItemVectorEntities.new
      result = RENDERER.render_svg(
        entities, square_svg, MEDIA_BOX, source, mode,
        :source_context => source_context, :peer_items => [peer]
      )

      refute result[:ok],
             "#{mode} must not reclaim a renderer placement inside a peer bbox"
      assert_equal [0], result[:transition_proof][:evidence][
        :peer_ambiguous_placement_indices
      ]
      assert_empty entities.to_a
    end
  end

  def test_partial_host_geometry_is_cleaned_without_touching_preexisting_peers
    entities = ItemVectorEntities.new(nil, :raise_after_first_edge => true)
    preexisting = ItemVectorEdge.new(77, Geom::Point3d.new,
                                     Geom::Point3d.new(1, 1, 0))
    entities.add_preexisting(preexisting)

    error = assert_raises(FIDELITY::ContractError) do
      render(entities, :geometry)
    end

    assert_match(/host edge failure/i, error.message)
    assert_equal [preexisting], entities.to_a
    assert_equal ['persistent_id:101'],
                 entities.erased.map { |entity| FIDELITY.stable_entity_id(entity) }
  end

  def test_failed_item_renderer_never_erases_a_concurrent_top_level_peer
    entities = ItemVectorEntities.new(
      nil,
      :raise_after_first_edge => true,
      :add_top_level_peer_after_group => true
    )

    error = assert_raises(FIDELITY::ContractError) do
      render(entities, :geometry)
    end

    assert_match(/host edge failure/i, error.message)
    assert_equal ['Edge'], entities.to_a.map(&:typename)
    assert_equal ['Group'], entities.erased.map(&:typename)
  end

  def test_same_size_geometry_at_wrong_coordinates_is_rejected_and_cleaned
    entities = ItemVectorEntities.new(
      nil, :translate_created_edges => [3.0, -2.0]
    )

    error = assert_raises(FIDELITY::ContractError) do
      render(entities, :geometry)
    end

    assert_match(/bounds do not match source outlines/i, error.message)
    assert_empty entities.to_a
  end

  def test_final_evidence_rejects_post_verification_translation
    entities = ItemVectorEntities.new
    result = render(entities, :geometry)
    result[:source_page_transformation] = [
      1.0, 0.0, 0.0, 0.0,
      0.0, 1.0, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      0.0, 0.0, 0.0, 1.0
    ]
    result[:page_transform_verified] = true
    result[:group].entities.to_a.each do |edge|
      edge.instance_variable_get(:@points).each { |point| point.x += 3.0 }
    end

    error = assert_raises(FIDELITY::ContractError) do
      RENDERER.finalize_source_evidence!(result, item)
    end

    assert_match(/final bounds differ from source outlines/i, error.message)
  end

  def test_precomputed_page_inventory_avoids_reparsing_svg_per_item
    svg = square_svg
    source = item
    opts = {
      :scale => 1.0,
      :svg_page_box => MEDIA_BOX,
      :source_context => source_context
    }
    placed = IMP::CairoGlyphSource.model_space_loops(svg, MEDIA_BOX, opts)
    pens = Array(placed).map do |entry|
      {
        :x => Array(entry[:pen_pdf])[0],
        :y => Array(entry[:pen_pdf])[1],
        :placement_index => entry[:placement_index]
      }
    end
    match = IMP::CairoGlyphSource.match_spans(pens, [source], MEDIA_BOX)
    entities = ItemVectorEntities.new

    result = IMP::CairoGlyphSource.stub(
      :model_space_loops,
      lambda { |_svg, _media_box, _opts| raise 'full SVG reparsed' }
    ) do
      RENDERER.render_svg(
        entities, svg, MEDIA_BOX, source, :glyphs,
        opts.merge(
          :precomputed_placed => placed,
          :precomputed_pens => pens,
          :precomputed_match => match
        )
      )
    end

    assert_equal true, result[:ok]
    assert_equal [0], result[:placement_indices]
  end

  def test_page_peer_owner_index_preserves_exact_overlap_checks
    pens = [
      { :x => 10.0, :y => 20.0, :placement_index => 0 },
      { :x => 70.0, :y => 20.0, :placement_index => 1 }
    ]
    peer_boxes = {
      'text_span:1:0' => [9.0, 19.0, 22.0, 32.0],
      'text_span:1:1' => [9.5, 19.5, 11.0, 21.0],
      'text_span:1:2' => [69.0, 19.0, 82.0, 32.0]
    }

    owners = RENDERER.build_placement_peer_owners(pens, peer_boxes)

    assert_equal ['text_span:1:0', 'text_span:1:1'], owners[0].sort
    assert_equal ['text_span:1:2'], owners[1]
  end

  def test_precomputed_peer_owners_reject_overlap_without_rescanning_peers
    source = item('text_span:1:0')
    placed = IMP::CairoGlyphSource.model_space_loops(
      square_svg, MEDIA_BOX, :scale => 1.0, :svg_page_box => MEDIA_BOX
    )
    pens = Array(placed).map do |entry|
      {
        :x => Array(entry[:pen_pdf])[0],
        :y => Array(entry[:pen_pdf])[1],
        :placement_index => entry[:placement_index]
      }
    end
    match = IMP::CairoGlyphSource.match_spans(pens, [source], MEDIA_BOX)
    entities = ItemVectorEntities.new

    result = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, source, :glyphs,
      :source_context => source_context,
      :precomputed_placed => placed,
      :precomputed_pens => pens,
      :precomputed_match => match,
      :precomputed_peer_owners => {
        0 => ['text_span:1:0', 'text_span:1:1']
      }
    )

    refute result[:ok]
    assert_equal [0], result[:transition_proof][:evidence][
      :peer_ambiguous_placement_indices
    ]
    assert_empty entities.to_a
  end

  def test_isolated_exact_match_rejects_the_whole_span_when_one_peer_overlaps
    match = {
      :placement_matches => [
        { :source_span_id => 'text_span:1:0', :placement_index => 0 },
        { :source_span_id => 'text_span:1:0', :placement_index => 1 }
      ]
    }
    pens = [
      { :x => 10.0, :y => 20.0, :placement_index => 0 },
      { :x => 70.0, :y => 20.0, :placement_index => 1 }
    ]
    peer_boxes = {
      'text_span:1:0' => [9.0, 19.0, 82.0, 32.0],
      'text_span:1:1' => [9.0, 19.0, 22.0, 32.0]
    }
    owners = RENDERER.build_placement_peer_owners(pens, peer_boxes)

    selection = RENDERER.select_item_placements(
      'text_span:1:0', :glyphs, match, pens, MEDIA_BOX, nil,
      peer_boxes, owners
    )

    assert_empty selection[:indices],
                 'Glyphs must not silently omit the overlapping source glyph'
    assert_equal [0], selection[:ambiguous_indices]
    assert_equal [0, 1], selection[:candidate_indices]
    assert_equal :exact_glyph_ownership, selection[:strategy]
  end

  def test_page_wide_unique_assignment_keeps_exact_glyphs_inside_peer_bboxes
    match = {
      :placement_matches => [
        { :source_span_id => 'text_span:1:0', :placement_index => 0 },
        { :source_span_id => 'text_span:1:0', :placement_index => 1 },
        { :source_span_id => 'text_span:1:1', :placement_index => 2 }
      ]
    }
    pens = [
      { :x => 10.0, :y => 20.0, :placement_index => 0 },
      { :x => 70.0, :y => 20.0, :placement_index => 1 },
      { :x => 11.0, :y => 20.0, :placement_index => 2 }
    ]
    peer_boxes = {
      'text_span:1:0' => [9.0, 19.0, 82.0, 32.0],
      'text_span:1:1' => [9.0, 19.0, 22.0, 32.0]
    }
    owners = RENDERER.build_placement_peer_owners(pens, peer_boxes)

    selection = RENDERER.select_item_placements(
      'text_span:1:0', :glyphs, match, pens, MEDIA_BOX, nil,
      peer_boxes, owners
    )

    assert_equal [0, 1], selection[:indices]
    assert_empty selection[:ambiguous_indices]
    assert_equal [0, 1], selection[:candidate_indices]
    assert_equal :exact_glyph_ownership, selection[:strategy]
  end

  def test_glyph_component_cache_reuses_one_exact_definition
    entities = ItemVectorEntities.new
    model = ItemVectorModel.new
    cache = {}
    opts = {
      :scale => 1.0,
      :svg_page_box => MEDIA_BOX,
      :source_context => source_context,
      :model => model,
      :glyph_component_cache => cache
    }

    first = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, item, :glyphs, opts
    )
    second = RENDERER.render_svg(
      entities, square_svg, MEDIA_BOX, item, :glyphs, opts
    )

    assert_equal true, first[:ok]
    assert_equal true, second[:ok]
    assert_equal 1, model.definitions.items.length
    assert_equal 1, cache.length
    [first, second].each do |result|
      glyph = result[:group].entities.to_a.first
      assert_equal 'ComponentInstance', glyph.typename
      assert_equal 'glyphs', glyph.attributes[
        ['BC_PDF_Importer', 'representation']
      ]
    end
  end

  def test_incomplete_page_inventory_is_a_hard_stop_not_a_fallback_proof
    entities = ItemVectorEntities.new
    context = source_context.merge(:render_status => :failed)

    error = assert_raises(FIDELITY::ContractError) do
      RENDERER.render_svg(
        entities, square_svg(70, 20), MEDIA_BOX, item, :geometry,
        :source_context => context
      )
    end

    assert_match(/inventory/i, error.message)
    assert_empty entities.to_a
  end
end
