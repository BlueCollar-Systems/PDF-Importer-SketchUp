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

class ItemVectorEdge
  attr_reader :persistent_id, :attributes

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

  def test_geometry_can_deliver_an_unambiguous_ligature_that_glyphs_cannot_own
    source = ITEM.new('AB', 10.0, 20.0, 12.0, 0.0, 'F1', 12.0,
                      9.0, 19.0, 22.0, 32.0, nil, 'text_span:1:0')
    glyph_entities = ItemVectorEntities.new
    geometry_entities = ItemVectorEntities.new

    glyphs = render(glyph_entities, :glyphs, square_svg, source)
    geometry = render(geometry_entities, :geometry, square_svg, source)

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
