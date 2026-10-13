require 'minitest/autorun'

# Repeated components share physical definition-local edges, while each
# instance keeps its own material, transform and source identity. Fake host only.
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_3d_text_renderer'

class OutlineTraversalCollection
  attr_reader :reads
  attr_accessor :members
  def initialize(members)
    @members = members
    @reads = 0
  end
  def to_a
    @reads += 1
    @members.dup
  end
end

class OutlineTraversalDefinition
  attr_reader :entities
  def initialize(members)
    @entities = OutlineTraversalCollection.new(members)
  end
end

class OutlineTraversalEdge
  attr_reader :writes
  attr_accessor :material
  def initialize(reject = false)
    @hidden = false
    @reject = reject
    @writes = 0
    @material = :source_edge_material
  end
  def typename; 'Edge'; end
  def hidden=(value)
    @writes += 1
    @hidden = value unless @reject
  end
  def hidden?; @hidden; end
  def reset_visible!; @hidden = false; end
end

class OutlineTraversalFace
  attr_accessor :material, :back_material
  def initialize
    @material = :front_source_color
    @back_material = :back_source_color
  end
  def typename; 'Face'; end
end

class OutlineTraversalInstance
  attr_reader :definition
  attr_accessor :material, :transformation, :source_span_id
  def initialize(definition, index = 0)
    @definition = definition
    @material = [:red, :blue, :green][index % 3]
    @transformation = [index.to_f, 2.0 * index, index.even? ? 1.0 : -1.0]
    @source_span_id = 'fictional-span-' + index.to_s
  end
  def typename; 'ComponentInstance'; end
end

class OutlineTraversalGroup
  attr_reader :entities, :attributes
  attr_accessor :material, :transformation, :definition
  def initialize(members)
    @entities = OutlineTraversalCollection.new(members)
    @material = :source_group_color
    @transformation = [99.0, 37.0, 0.0]
    @attributes = {['BC_PDF_Importer', 'source_alpha'] => 0.75,
                   ['BC_PDF_Importer', 'source_span_id'] => 'fictional-source-span',
                   ['BC_PDF_Importer', 'source_ink_rgb'] => [12, 34, 56]}
  end
  def typename; 'Group'; end
  def set_attribute(dictionary, key, value)
    @attributes[[dictionary, key]] = value
  end
end

class SourceOutlineSharedDefinitionTest < Minitest::Test
  SUBJECT = BlueCollarSystems::PDFVectorImporter::Svg3DTextRenderer

  def test_many_instances_have_identical_unique_edge_proof_with_one_definition_scan
    edges = [OutlineTraversalEdge.new, OutlineTraversalEdge.new]
    face = OutlineTraversalFace.new
    definition = OutlineTraversalDefinition.new(edges + [face])
    instances = 20.times.map { |index| OutlineTraversalInstance.new(definition, index) }
    root = OutlineTraversalGroup.new(instances)
    before = instances.map { |item| [item.material, item.transformation.dup, item.source_span_id] }
    visited = []
    SUBJECT.send(:visit_source_outline_entities, root, {}) { |entity| visited << entity }
    assert_equal instances, visited.select { |entity| entity.typename == 'ComponentInstance' }
    definition.entities.instance_variable_set(:@reads, 0)
    counts = SUBJECT.govern_source_outline_visual_style!(root)
    assert_equal 2, counts[:edge_count]
    assert_equal 2, counts[:hidden_edge_count]
    assert_equal 0, counts[:visible_edge_count]
    assert_equal true, counts[:contour_edges_hidden_verified]
    assert_equal [1, 1], edges.map(&:writes)
    assert_equal [:source_edge_material, :source_edge_material], edges.map(&:material)
    assert_equal(1, definition.entities.reads)
    assert_equal before, instances.map { |item| [item.material, item.transformation.dup, item.source_span_id] }
    assert_equal :source_group_color, root.material
    assert_equal :front_source_color, face.material
    assert_equal :back_source_color, face.back_material
    assert_equal [12, 34, 56], root.attributes[['BC_PDF_Importer', 'source_ink_rgb']]
    assert_equal 'fictional-source-span', root.attributes[['BC_PDF_Importer', 'source_span_id']]
    assert_equal 0.75, root.attributes[['BC_PDF_Importer', 'source_alpha']]
  end

  def test_nested_shared_definition_graph_visits_every_distinct_instance
    shared = OutlineTraversalDefinition.new([OutlineTraversalEdge.new, OutlineTraversalEdge.new])
    nested = [OutlineTraversalInstance.new(shared, 10), OutlineTraversalInstance.new(shared, 11)]
    outer = OutlineTraversalDefinition.new(nested + [OutlineTraversalEdge.new])
    top = [OutlineTraversalInstance.new(outer, 20), OutlineTraversalInstance.new(outer, 21), OutlineTraversalInstance.new(shared, 22)]
    root = OutlineTraversalGroup.new(top)
    visited = []
    SUBJECT.send(:visit_source_outline_entities, root, {}) { |entity| visited << entity }
    instance_callbacks = visited.select { |entity| entity.typename == 'ComponentInstance' }
    assert_equal 5, instance_callbacks.length
    assert_equal (top + nested).sort_by(&:object_id), instance_callbacks.sort_by(&:object_id)
    assert_equal 3, visited.count { |entity| entity.typename == 'Edge' }
    assert_equal(1, outer.entities.reads)
    assert_equal(1, shared.entities.reads)
  end

  def test_definition_dedup_is_local_to_one_governance_call
    edge = OutlineTraversalEdge.new
    definition = OutlineTraversalDefinition.new([edge])
    root = OutlineTraversalGroup.new([OutlineTraversalInstance.new(definition), OutlineTraversalInstance.new(definition, 1)])
    first = SUBJECT.govern_source_outline_visual_style!(root)
    edge.reset_visible!
    second = SUBJECT.govern_source_outline_visual_style!(root)
    assert_equal first, second
    assert_equal 2, edge.writes
    assert edge.hidden?
    assert_equal(2, definition.entities.reads)
  end

  def test_bad_hidden_state_readback_is_not_hidden_by_a_different_good_definition
    good = OutlineTraversalDefinition.new([OutlineTraversalEdge.new])
    bad_edge = OutlineTraversalEdge.new(true)
    bad = OutlineTraversalDefinition.new([bad_edge])
    root = OutlineTraversalGroup.new([OutlineTraversalInstance.new(good), OutlineTraversalInstance.new(good, 1), OutlineTraversalInstance.new(bad, 2)])
    error = assert_raises(RuntimeError) { SUBJECT.govern_source_outline_visual_style!(root) }
    assert_match(/hidden-state readback failed/, error.message)
    assert_equal 1, bad_edge.writes
    refute root.attributes.key?(['BC_PDF_Importer', 'contour_edges_hidden_verified'])
  end

  def test_entities_branch_takes_precedence_over_definition_alias
    alias_edge = OutlineTraversalEdge.new
    definition = OutlineTraversalDefinition.new([alias_edge])
    local_edges = [OutlineTraversalEdge.new, OutlineTraversalEdge.new]
    groups = local_edges.map { |edge| OutlineTraversalGroup.new([edge]) }
    groups.each { |group| group.definition = definition }
    counts = SUBJECT.govern_source_outline_visual_style!(OutlineTraversalGroup.new(groups))
    assert_equal 2, counts[:edge_count]
    assert local_edges.all?(&:hidden?)
    refute alias_edge.hidden?
    assert_equal 0, definition.entities.reads
  end

  def test_distinct_definitions_are_never_deduplicated_by_equal_shape_or_material
    edges = [OutlineTraversalEdge.new, OutlineTraversalEdge.new]
    definitions = edges.map { |edge| OutlineTraversalDefinition.new([edge]) }
    root = OutlineTraversalGroup.new(definitions.map { |definition| OutlineTraversalInstance.new(definition) })
    counts = SUBJECT.govern_source_outline_visual_style!(root)
    assert_equal 2, counts[:edge_count]
    assert_equal [1, 1], definitions.map { |definition| definition.entities.reads }
    assert_equal [1, 1], edges.map(&:writes)
  end

  def test_cyclic_definition_alias_does_not_recurse_forever
    edge = OutlineTraversalEdge.new
    definition = OutlineTraversalDefinition.new([])
    nested = OutlineTraversalInstance.new(definition, 2)
    definition.entities.members = [nested, edge]
    root = OutlineTraversalGroup.new([OutlineTraversalInstance.new(definition, 1)])
    counts = SUBJECT.govern_source_outline_visual_style!(root)
    assert_equal 1, counts[:edge_count]
    assert edge.hidden?
    assert_equal(1, definition.entities.reads)
  end

  def test_face_only_definition_does_not_become_verified_edge_delivery
    definition = OutlineTraversalDefinition.new([OutlineTraversalFace.new])
    root = OutlineTraversalGroup.new([OutlineTraversalInstance.new(definition), OutlineTraversalInstance.new(definition, 1)])
    counts = SUBJECT.govern_source_outline_visual_style!(root)
    assert_equal 0, counts[:edge_count]
    assert_equal false, counts[:contour_edges_hidden_verified]
    assert_equal false, root.attributes[['BC_PDF_Importer', 'contour_edges_hidden_verified']]
  end
end
