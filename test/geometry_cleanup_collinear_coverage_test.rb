require 'minitest/autorun'

module Geom
  class Vector3d
    attr_reader :x, :y, :z
    def initialize(x, y, z)
      @x, @y, @z = x.to_f, y.to_f, z.to_f
    end
    def cross(other)
      self.class.new(y * other.z - z * other.y,
                     z * other.x - x * other.z,
                     x * other.y - y * other.x)
    end
    def dot(other)
      x * other.x + y * other.y + z * other.z
    end
    def length
      Math.sqrt(dot(self))
    end
  end
  class Point3d < Vector3d
    def -(other)
      Vector3d.new(x - other.x, y - other.y, z - other.z)
    end
    def distance(other)
      (self - other).length
    end
  end
end

module Sketchup
  Vertex = Struct.new(:position) do
    def valid?; true; end
  end
  class Group
    attr_reader :entities
    def initialize(entities); @entities = entities; end
    def valid?; true; end
  end
  class Edge
    attr_accessor :layer, :material, :hidden, :soft, :smooth, :casts_shadows
    attr_reader :start, :end
    def initialize(start, finish)
      @start, @end = start, finish
      @valid = true
      @layer = :drawing
      @hidden = @soft = @smooth = false
      @casts_shadows = true
    end
    def valid?; @valid; end
    def erase!; @valid = false; end
    def faces; []; end
    def length; line[1].length; end
    def line; [@start.position, @end.position - @start.position]; end
    def hidden?; @hidden; end
    def soft?; @soft; end
    def smooth?; @smooth; end
    def casts_shadows?; @casts_shadows; end
    def attribute_dictionaries; @dictionaries; end
    def attributes=(value); @dictionaries = value; end
    attr_accessor :curve
  end
end

module BlueCollarSystems
  module PDFVectorImporter
    module Logger
      def self.warn(*args)
        raise "unexpected cleanup error: #{args.inspect}"
      end
    end
  end
end
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/geometry_cleanup'

class GeometryCleanupCollinearCoverageTest < Minitest::Test
  Cleanup = BlueCollarSystems::PDFVectorImporter::GeometryCleanup

  class Entities < Array
    attr_accessor :join_failure
    def initialize
      super
      @vertices = {}
    end
    def vertex(coords)
      key = coords.map(&:to_f)
      @vertices[key] ||= Sketchup::Vertex.new(Geom::Point3d.new(*key))
    end
    def line(first, last)
      edge = Sketchup::Edge.new(vertex(first), vertex(last))
      self << edge
      edge
    end
    def add_line(first, last)
      return nil if @join_failure == :nil
      raise 'native add failed' if @join_failure == :raise
      edge = line([first.x, first.y, first.z], [last.x, last.y, last.z])
      if @join_failure == :setter
        def edge.material=(_value); raise 'native material setter failed'; end
      elsif @join_failure == :ignored_setter
        def edge.material=(_value); end
      end
      edge
    end
    def live
      select(&:valid?)
    end
  end

  def covered?(entities, point)
    sample = Geom::Point3d.new(*point)
    entities.live.any? do |edge|
      first, last = edge.start.position, edge.end.position
      (first.distance(sample) + sample.distance(last) - first.distance(last)).abs < 1.0e-10
    end
  end

  def test_nested_same_ray_edges_keep_the_entire_source_union
    entities = Entities.new
    entities.line([12, 4, 0], [0, 4, 0])
    entities.line([12, 4, 0], [7, 4, 0])
    assert covered?(entities, [10, 4, 0])
    joins = Cleanup.join_collinear_edges(entities, 0.001)
    (0..12).each { |x| assert covered?(entities, [x, 4, 0]), "lost source x=#{x}" }
    assert_equal 0, joins
    assert_equal 2, entities.live.length
  end

  def test_same_ray_guard_is_independent_of_edge_orientation_and_axis
    [[[2, 0, 0], [2, 12, 0], [2, 7, 0]],
     [[0, 0, 12], [0, 0, 0], [0, 0, 7]]].each do |shared, far, near|
      [false, true].each do |reverse|
        entities = Entities.new
        entities.line(*(reverse ? [far, shared] : [shared, far]))
        entities.line(*(reverse ? [shared, near] : [near, shared]))
        assert_equal 0, Cleanup.join_collinear_edges(entities, 0.001)
        assert_equal 2, entities.live.length
        assert covered?(entities, shared)
        assert covered?(entities, far)
      end
    end
  end

  def test_a_true_between_endpoint_junction_still_joins_and_preserves_coverage
    entities = Entities.new
    entities.line([0, 4, 0], [4, 4, 0])
    entities.line([9, 4, 0], [4, 4, 0])
    entities.line([9, 4, 0], [12, 4, 0])
    assert_equal 2, Cleanup.join_collinear_edges(entities, 0.001)
    assert_equal 1, entities.live.length
    (0..12).each { |x| assert covered?(entities, [x, 4, 0]) }
  end

  def test_different_styles_are_not_joined
    [:layer, :material, :hidden, :soft, :smooth, :casts_shadows].each do |field|
      entities = Entities.new
      first = entities.line([0, 0, 0], [4, 0, 0])
      second = entities.line([4, 0, 0], [8, 0, 0])
      value = [:layer, :material].include?(field) ? :other_style : !first.public_send(field)
      second.public_send("#{field}=", value)
      assert_equal 0, Cleanup.join_collinear_edges(entities, 0.001), field.to_s
      assert_equal 2, entities.live.length
    end
  end

  def test_matching_style_is_retained_on_replacement
    entities = Entities.new
    entities.line([0, 0, 0], [4, 0, 0])
    entities.line([4, 0, 0], [8, 0, 0])
    entities.each do |edge|
      edge.layer = :source_layer
      edge.material = :source_ink
      edge.hidden = edge.soft = edge.smooth = true
      edge.casts_shadows = false
    end
    assert_equal 1, Cleanup.join_collinear_edges(entities, 0.001)
    result = entities.live.fetch(0)
    assert_equal :source_layer, result.layer
    assert_equal :source_ink, result.material
    assert result.hidden?
    assert result.soft?
    assert result.smooth?
    refute result.casts_shadows?
  end

  def test_attributed_edges_remain_owned_and_unchanged
    entities = Entities.new
    first = entities.line([0, 0, 0], [4, 0, 0])
    second = entities.line([4, 0, 0], [8, 0, 0])
    first.attributes = [{ 'source' => 'first' }]
    second.attributes = [{ 'source' => 'second' }]
    assert_equal 0, Cleanup.join_collinear_edges(entities, 0.001)
    assert_equal [first, second], entities.live
  end

  def test_nonparallel_and_branching_strokes_remain_unchanged
    entities = Entities.new
    entities.line([0, 0, 0], [4, 0, 0])
    entities.line([4, 0, 0], [8, 2, 0])
    assert_equal 0, Cleanup.join_collinear_edges(entities, 0.001)
    entities.line([4, 0, 0], [4, 4, 0])
    assert_equal 0, Cleanup.join_collinear_edges(entities, 0.001)
    assert_equal 3, entities.live.length
  end

  def test_native_curve_members_are_not_replaced_by_unowned_lines
    entities = Entities.new
    first = entities.line([0, 0, 0], [4, 0, 0])
    second = entities.line([4, 0, 0], [8, 0, 0])
    first.curve = second.curve = Object.new
    assert_equal 0, Cleanup.join_collinear_edges(entities, 0.001)
    assert_equal [first, second], entities.live
  end

  def test_failed_native_replacement_must_abort_instead_of_reporting_success
    [:nil, :raise, :setter, :ignored_setter].each do |failure|
      entities = Entities.new
      entities.line([0, 0, 0], [4, 0, 0])
      entities.line([4, 0, 0], [8, 0, 0])
      entities.each { |edge| edge.material = :source_ink }
      entities.join_failure = failure
      error = assert_raises(Cleanup::CleanupFailure) do
        Cleanup.join_collinear_edges(entities, 0.001)
      end
      assert_match(/collinear source-edge cleanup failed/, error.message)
    end
  end

  def test_nested_cleanup_propagates_destructive_failure_to_the_operation_owner
    children = Entities.new
    children.line([0, 0, 0], [4, 0, 0])
    children.line([4, 0, 0], [8, 0, 0])
    children.join_failure = :nil
    error = assert_raises(Cleanup::CleanupFailure) do
      Cleanup.cleanup([Sketchup::Group.new(children)], :merge_tolerance => 0.0005)
    end
    assert_match(/native host did not create/, error.message)
  end
end
