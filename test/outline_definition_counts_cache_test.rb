#!/usr/bin/env ruby
# 3D Text outline edges: hidden and read back once per glyph definition per
# page, not once per span group that places the glyph.
#
# Every span group still gets its own edge counts and its own persisted
# policy, equal to a full walk. Fake host only; all fixtures are made up.

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_solid_cache'

class CountsCacheCollection
  attr_reader :reads
  def initialize(members)
    @members = members
    @reads = 0
  end

  def to_a
    @reads += 1
    @members.dup
  end
end

class CountsCacheEdge
  attr_reader :writes, :readbacks
  def initialize
    @hidden = false
    @writes = 0
    @readbacks = 0
  end

  def typename; 'Edge'; end

  def hidden=(value)
    @writes += 1
    @hidden = value
  end

  def hidden?
    @readbacks += 1
    @hidden
  end
end

class CountsCacheFace
  def typename; 'Face'; end
end

class CountsCacheGroup
  attr_reader :entities, :attributes
  def initialize(members)
    @entities = CountsCacheCollection.new(members)
    @attributes = {}
  end

  def typename; 'Group'; end

  def set_attribute(dictionary, key, value)
    @attributes[[dictionary, key]] = value
  end
end

class CountsCacheDefinition
  attr_reader :entities
  def initialize(members)
    @entities = CountsCacheCollection.new(members)
  end
end

class CountsCacheInstance
  attr_reader :definition
  def initialize(definition)
    @definition = definition
  end

  def typename; 'ComponentInstance'; end
end

class OutlineDefinitionCountsCacheTest < Minitest::Test
  SUBJECT = BlueCollarSystems::PDFVectorImporter::Svg3DTextRenderer

  # A glyph definition as the solid cache builds it: one group of faces and
  # edges inside the definition.
  def glyph(edge_count)
    edges = Array.new(edge_count) { CountsCacheEdge.new }
    inner = CountsCacheGroup.new(edges + [CountsCacheFace.new])
    [CountsCacheDefinition.new([inner]), edges]
  end

  # Span groups placing glyphs by index, some more than once.
  def page(definitions, layout)
    layout.map do |indices|
      CountsCacheGroup.new(indices.map { |index| CountsCacheInstance.new(definitions[index]) })
    end
  end

  LAYOUT = [[0, 1, 0], [1, 2], [2, 2, 0, 1], [0]].freeze

  def test_each_definition_is_hidden_once_per_page_and_every_group_keeps_its_counts
    plain_defs = [3, 5, 4].map { |n| glyph(n).first }
    reference = page(plain_defs, LAYOUT).map { |group| SUBJECT.govern_source_outline_visual_style!(group) }

    built = [3, 5, 4].map { |n| glyph(n) }
    definitions = built.map(&:first)
    edges = built.map(&:last)
    page_counts = {}
    cached = page(definitions, LAYOUT).map do |group|
      SUBJECT.govern_source_outline_visual_style!(group, page_counts)
    end

    assert_equal reference, cached, 'each span group keeps the counts of a full walk'
    edges.flatten.each do |edge|
      assert_equal 1, edge.writes, 'an edge is hidden once per page'
      assert_equal 1, edge.readbacks, 'and read back once per page'
      assert edge.hidden?
    end
    assert_equal [1, 1, 1], definitions.map { |definition| definition.entities.reads }
    assert cached.all? { |counts| counts[:contour_edges_hidden_verified] == true }
    refute cached.any? { |counts| counts.key?(:definition_walks) }
  end

  def test_every_group_still_persists_its_own_policy
    definitions = [glyph(2), glyph(3)].map(&:first)
    page_counts = {}
    groups = page(definitions, [[0, 1], [1], [0, 0]])
    groups.each { |group| SUBJECT.govern_source_outline_visual_style!(group, page_counts) }
    expected = [5, 3, 2]
    groups.each_with_index do |group, index|
      assert_equal expected[index], group.attributes[['BC_PDF_Importer', 'contour_edge_count']]
      assert_equal true, group.attributes[['BC_PDF_Importer', 'contour_edges_hidden_verified']]
    end
  end

  def test_a_definition_with_a_nested_component_is_walked_each_time
    shared, shared_edges = glyph(2)
    outer_edge = CountsCacheEdge.new
    outer = CountsCacheDefinition.new([CountsCacheInstance.new(shared), outer_edge])
    layout_groups = lambda do |defs|
      [CountsCacheGroup.new([CountsCacheInstance.new(defs[0]), CountsCacheInstance.new(defs[1])]),
       CountsCacheGroup.new([CountsCacheInstance.new(defs[0])])]
    end
    reference_shared, = glyph(2)
    reference_outer = CountsCacheDefinition.new([CountsCacheInstance.new(reference_shared), CountsCacheEdge.new])
    reference = layout_groups.call([reference_outer, reference_shared]).map do |group|
      SUBJECT.govern_source_outline_visual_style!(group)
    end
    page_counts = {}
    cached = layout_groups.call([outer, shared]).map do |group|
      SUBJECT.govern_source_outline_visual_style!(group, page_counts)
    end
    assert_equal reference, cached
    refute page_counts.key?(outer.object_id), 'a nesting definition is not remembered'
    assert page_counts.key?(shared.object_id)
    assert_equal 2, outer.entities.reads
    assert_equal [1, 1], shared_edges.map(&:writes)
  end

  def test_a_remembered_entry_for_another_object_is_not_used
    definition, edges = glyph(2)
    other, = glyph(7)
    page_counts = { definition.object_id => { :definition => other, :edge_count => 7, :hidden_edge_count => 7 } }
    counts = SUBJECT.govern_source_outline_visual_style!(
      CountsCacheGroup.new([CountsCacheInstance.new(definition)]), page_counts
    )
    assert_equal 2, counts[:edge_count]
    assert_equal [1, 1], edges.map(&:writes)
  end

  def test_without_a_page_cache_nothing_changes
    definition, edges = glyph(2)
    group = CountsCacheGroup.new([CountsCacheInstance.new(definition)])
    2.times { SUBJECT.govern_source_outline_visual_style!(group) }
    assert_equal [2, 2], edges.map(&:writes), 'every call hides again without a page cache'
  end

  def test_a_freshly_built_definition_is_remembered_from_its_build
    definition, edges = glyph(4)
    inner = definition.entities.to_a.first
    build = SUBJECT.govern_source_outline_visual_style!(inner)
    solid_cache = BlueCollarSystems::PDFVectorImporter::Svg3DTextSolidCache.new(nil, 0.0625)
    record = {
      :definition => definition,
      :build_metrics => {
        :contour_edge_count => build[:edge_count],
        :hidden_contour_edge_count => build[:hidden_edge_count],
        :outline_counts_cover_definition => SUBJECT.send(:definition_holds_only?, definition.entities, inner)
      }
    }
    SUBJECT.send(:remember_definition_outline!, solid_cache, record)
    reads = definition.entities.reads
    counts = SUBJECT.govern_source_outline_visual_style!(
      CountsCacheGroup.new([CountsCacheInstance.new(definition)]),
      solid_cache.outline_definition_counts
    )
    assert_equal 4, counts[:edge_count]
    assert_equal true, counts[:contour_edges_hidden_verified]
    assert_equal reads, definition.entities.reads, 'the build already walked it'
    assert_equal [1, 1, 1, 1], edges.map(&:writes)
  end

  def test_a_build_that_does_not_cover_the_definition_is_not_remembered
    definition, = glyph(2)
    solid_cache = BlueCollarSystems::PDFVectorImporter::Svg3DTextSolidCache.new(nil, 0.0625)
    [
      { :contour_edge_count => 2, :hidden_contour_edge_count => 2, :outline_counts_cover_definition => false },
      { :contour_edge_count => 2, :hidden_contour_edge_count => 1, :outline_counts_cover_definition => true },
      { :contour_edge_count => nil, :hidden_contour_edge_count => 2, :outline_counts_cover_definition => true }
    ].each do |metrics|
      SUBJECT.send(:remember_definition_outline!, solid_cache,
                   :definition => definition, :build_metrics => metrics)
      assert_empty solid_cache.outline_definition_counts
    end
    extra = CountsCacheDefinition.new([CountsCacheGroup.new([]), CountsCacheEdge.new])
    refute SUBJECT.send(:definition_holds_only?, extra.entities, extra.entities.to_a.first)
    assert SUBJECT.send(:definition_holds_only?, definition.entities, definition.entities.to_a.first)
  end
end
