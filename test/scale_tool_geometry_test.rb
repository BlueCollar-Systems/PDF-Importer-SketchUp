require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/scale_tool'

MB_YESNO = 4 unless defined?(MB_YESNO)
IDYES = 6 unless defined?(IDYES)
ORIGIN = [0, 0, 0] unless defined?(ORIGIN)

module UI
  def self.messagebox(*_args); IDYES; end
end
module Geom
  class BoundingBox
    def add(bounds); @center = bounds.center if bounds.respond_to?(:center); end
    def valid?; !@center.nil?; end
    def center; @center; end
  end
  class Transformation
    def self.scaling(anchor, factor)
      @last_anchor = anchor
      factor
    end
    def self.last_anchor; @last_anchor; end
  end
end
module Sketchup
  class Edge
    attr_accessor :position
    def initialize; @position = 10.0; end
    def valid?; true; end
    def bounds; nil; end
  end
  class Group; end
  class ComponentInstance; end
end

class ScaleToolGeometryTest < Minitest::Test
  TOOL = BlueCollarSystems::PDFVectorImporter::ScaleTool
  class Entities < Array
    attr_accessor :calls, :failure
    def initialize; super; @calls = []; end
    def transform_entities(transform, entities)
      raise 'host rejected transform' if failure
      calls << entities.dup
      entities.each { |entity| entity.position *= transform }
    end
  end
  class Model
    attr_reader :entities, :selection, :operations
    def initialize
      @entities = Entities.new
      @selection = []
      @operations = []
    end
    def start_operation(*_args); @operations << :start; end
    def commit_operation; @operations << :commit; end
    def abort_operation; @operations << :abort; end
    def active_entities; @entities; end
    def active_view; nil; end
  end

  def test_selection_only_scales_native_edges_once_in_their_owning_entities
    model = Model.new
    edge = Sketchup::Edge.new
    model.entities << edge
    model.selection << edge
    TOOL.send(:apply_scale, model, 2.0, 'Selection Only', nil, nil, '2')
    assert_in_delta 20.0, edge.position, 1e-9
    assert_equal [[edge]], model.entities.calls
    assert_equal [:start, :commit], model.operations
  end

  def test_loose_drawing_scales_when_no_groups_are_present
    model = Model.new
    edge = Sketchup::Edge.new
    model.entities << edge
    TOOL.send(:apply_scale, model, 2.0, 'All Groups', nil, nil, '2')
    assert_in_delta 20.0, edge.position, 1e-9
    assert_equal [[edge]], model.entities.calls
  end

  def test_host_failure_aborts_the_operation
    model = Model.new
    edge = Sketchup::Edge.new
    model.entities << edge
    model.selection << edge
    model.entities.failure = true
    TOOL.send(:apply_scale, model, 2.0, 'Selection Only', nil, nil, '2')
    assert_equal [:start, :abort], model.operations
    assert_in_delta 10.0, edge.position, 1e-9
  end

  def test_nested_selection_anchor_is_converted_to_model_space
    point = Struct.new(:x) do
      def transform(context)
        self.class.new(x * context[:scale] + context[:offset])
      end
    end
    model = Model.new
    def model.edit_transform; { :scale => 2.0, :offset => 100.0 }; end
    edge = Sketchup::Edge.new
    center = point.new(5.0)
    edge.define_singleton_method(:bounds) { Struct.new(:center).new(center) }
    model.entities << edge
    model.selection << edge
    TOOL.send(:apply_scale, model, 2.0, 'Selection Only', nil, nil, '2')
    assert_in_delta 110.0, Geom::Transformation.last_anchor.x, 1e-9
    assert_equal [:start, :commit], model.operations
  end

  def test_reference_measurement_accounts_for_the_current_group_scale
    model = Model.new
    def model.edit_transform; { :scale => 2.0, :offset => 100.0 }; end
    edge = Sketchup::Edge.new
    def edge.length(context = nil); context ? 10.0 * context[:scale] : 10.0; end
    assert_in_delta 20.0, TOOL.send(:selected_edge_length, model, edge), 1e-9
  end

  def test_invalid_factor_does_not_open_a_native_operation
    model = Model.new
    TOOL.send(:apply_scale, model, Float::INFINITY, 'All Groups', nil, nil, 'Infinity')
    assert_equal [], model.operations
  end
end
