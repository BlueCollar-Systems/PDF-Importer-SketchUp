#!/usr/bin/env ruby
require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

module Geom
  class Point3d
    attr_reader :x, :y, :z

    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def distance(other)
      dx = x - other.x
      dy = y - other.y
      dz = z - other.z
      Math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
    end
  end

  class Transformation
    attr_reader :origin, :scale

    def initialize(origin = nil, scale = 1.0)
      @origin = origin
      @scale = scale.to_f
    end

    def self.translation(origin)
      new(origin, 1.0)
    end

    def self.scaling(x_scale, y_scale = nil, z_scale = nil)
      if y_scale.nil? || z_scale.nil?
        raise ArgumentError,
              'SketchUp 2017 requires explicit three-axis scaling'
      end
      unless x_scale.to_f == y_scale.to_f && y_scale.to_f == z_scale.to_f
        raise ArgumentError, 'test expects uniform scaling'
      end
      new(nil, x_scale)
    end

    def *(other)
      Transformation.new(origin || other.origin, scale * other.scale)
    end
  end
end

module Sketchup
  def self.status_text=(_value); end
end

require 'bc_pdf_vector_importer/content_stream_parser'
require 'bc_pdf_vector_importer/arc_fitter'
require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/import_run_control'
require 'bc_pdf_vector_importer/geometry_builder'

class GeometryBuilderStagingTest < Minitest::Test
  Parser = BlueCollarSystems::PDFVectorImporter::ContentStreamParser
  Builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder

  class Layer
    attr_reader :name

    def initialize(name)
      @name = name
    end
  end

  class Layers
    def initialize
      @layers = {}
    end

    def [](name)
      @layers[name]
    end

    def add(name)
      @layers[name] = Layer.new(name)
    end
  end

  class Edge
    attr_accessor :layer
    attr_reader :start_point, :end_point

    def initialize(start_point, end_point)
      @start_point = start_point
      @end_point = end_point
    end
  end

  class Face
    attr_accessor :layer, :material, :back_material
    attr_reader :points

    def initialize(points = [])
      @points = Array(points)
    end

    def normal
      Struct.new(:z).new(1.0)
    end

    def reverse!
      self
    end
  end

  class Group
    attr_accessor :name, :layer, :transformation
    attr_reader :entities

    def initialize(parent)
      @parent = parent
      @entities = Entities.new(false)
    end

    def explode
      @parent.explode_group(self, @entities.to_a)
    end
  end

  class ComponentDefinition
    attr_reader :name, :entities

    def initialize(name)
      @name = name
      @entities = Entities.new(false)
    end
  end

  class Definitions
    attr_reader :items

    def initialize
      @items = []
    end

    def add(name)
      definition = ComponentDefinition.new(name)
      @items << definition
      definition
    end
  end

  class ComponentInstance
    attr_accessor :layer
    attr_reader :definition, :transformation

    def initialize(definition, transformation)
      @definition = definition
      @transformation = transformation
    end
  end

  class Entities
    attr_reader :groups_created, :groups_exploded, :faces_created,
                :instances_created

    def initialize(reject_small_faces = false)
      @items = []
      @groups_created = 0
      @groups_exploded = 0
      @faces_created = 0
      @instances_created = 0
      @reject_small_faces = reject_small_faces
    end

    def to_a
      @items.dup
    end

    def add_group
      group = Group.new(self)
      @items << group
      @groups_created += 1
      group
    end

    def add_edges(points)
      edges = Array(points).each_cons(2).map do |start_point, end_point|
        Edge.new(start_point, end_point)
      end
      @items.concat(edges)
      edges
    end

    def add_face(points)
      if @reject_small_faces
        xs = Array(points).map { |point| point.x.to_f }
        ys = Array(points).map { |point| point.y.to_f }
        max_extent = [(xs.max - xs.min).abs, (ys.max - ys.min).abs].max
        raise ArgumentError, 'Points are not planar' if max_extent < 0.002
      end
      face = Face.new(points)
      @items << face
      @faces_created += 1
      face
    end

    def add_instance(definition, transformation)
      instance = ComponentInstance.new(definition, transformation)
      @items << instance
      @instances_created += 1
      instance
    end

    def explode_group(group, children)
      if children.any? { |entity| entity.is_a?(ComponentInstance) }
        raise 'SketchUp 2017 must not explode a staging group containing ' \
              'an inverse-scaled component instance'
      end
      @items.delete(group)
      @items.concat(children)
      @groups_exploded += 1
      children
    end
  end

  class Model
    attr_reader :active_entities, :layers, :definitions

    def initialize(reject_small_faces = false)
      @active_entities = Entities.new(reject_small_faces)
      @layers = Layers.new
      @definitions = Definitions.new
    end

    def line_styles
      nil
    end
  end

  def test_heavy_page_builds_exact_geometry_in_bulk_exploded_batches
    model = Model.new
    paths = 500.times.map { |index| line_path(index.to_f) }
    builder = Builder.new(
      model, paths, [], [0, 0, 612, 792],
      :group_per_page => false, :detect_arcs => false,
      :import_fills => false
    )

    result = builder.build

    assert_equal 500, result[:edges]
    assert_equal true, result[:geometry_staging][:enabled]
    assert_equal 3, result[:geometry_staging][:batch_count]
    assert_equal 3, result[:geometry_staging][:explode_count]
    assert_equal 3, model.active_entities.groups_created
    assert_equal 3, model.active_entities.groups_exploded
    assert_equal 500, model.active_entities.to_a.length
    assert model.active_entities.to_a.all? { |entity| entity.is_a?(Edge) }
    endpoints = model.active_entities.to_a.values_at(0, -1).map do |edge|
      edge.start_point.y
    end
    assert_equal [0.0, 499.0 / 72.0], endpoints
  end

  def test_filled_closed_path_preserves_exact_boundary_without_arc_reconstruction
    model = Model.new
    fitter = BlueCollarSystems::PDFVectorImporter::ArcFitter
    singleton = class << fitter; self; end
    singleton.class_eval do
      alias_method :detect_arcs_before_filled_boundary_test,
                   :detect_arcs_in_polyline
    end
    arc_detection_calls = 0
    singleton.send(:define_method, :detect_arcs_in_polyline) do |*_args|
      arc_detection_calls += 1
      []
    end
    builder = Builder.new(
      model, [filled_path], [], [0, 0, 612, 792],
      :group_per_page => false, :detect_arcs => true,
      :import_fills => true
    )

    result = builder.build

    assert_equal 0, arc_detection_calls,
                 'filled source boundaries must not be replaced by fitted arcs'
    assert_equal 1, result[:faces],
                 'the exact filled source boundary must create a face'
    assert_equal 1, model.active_entities.faces_created
  ensure
    if singleton
      singleton.class_eval do
        if method_defined?(:detect_arcs_before_filled_boundary_test)
          alias_method :detect_arcs_in_polyline,
                       :detect_arcs_before_filled_boundary_test
          remove_method :detect_arcs_before_filled_boundary_test
        end
      end
    end
  end

  def test_sub_tolerance_fills_batch_into_one_exact_scaled_instance
    model = Model.new(true)
    builder = Builder.new(
      model, [tiny_filled_path(0.0), tiny_filled_path(72.0)], [],
      [0, 0, 612, 792],
      :group_per_page => false, :detect_arcs => false,
      :import_fills => true
    )

    result = builder.build

    assert_equal 2, result[:faces],
                 'every host-sub-tolerance PDF fill must still create a face'
    assert_equal 0, model.active_entities.groups_created
    assert_equal 0, model.active_entities.groups_exploded,
                 'the tiny batch instance must never be exploded in SketchUp 2017'
    assert_equal 1, model.definitions.items.length,
                 'one target/style batch must use one safe-scale definition'
    definition = model.definitions.items.first
    assert_equal 2, definition.entities.faces_created,
                 'every exact source fill must remain a physical face'
    instances = model.active_entities.to_a.select do |entity|
      entity.is_a?(ComponentInstance)
    end
    assert_equal 1, instances.length,
                 'hundreds of tiny fills must not become hundreds of host instances'
    instance = instances.first
    assert instance.definition.equal?(definition)
    assert_in_delta 0.001, instance.transformation.scale, 1.0e-12
    assert_in_delta 0.0, instance.transformation.origin.x, 1.0e-12
    definition_xs = definition.entities.to_a.grep(Face).flat_map do |face|
      face.points.map { |point| point.x.to_f }
    end
    assert_operator definition_xs.max, :>=, 1000.0,
                    'the second source fill must remain one inch from the first'
  end

  def test_heavy_page_keeps_micro_fill_batch_outside_exploded_staging_groups
    model = Model.new(true)
    paths = 500.times.map { |index| tiny_filled_path(index.to_f) }
    builder = Builder.new(
      model, paths, [], [0, 0, 612, 792],
      :group_per_page => false, :detect_arcs => false,
      :import_fills => true
    )

    result = builder.build

    assert_equal true, result[:geometry_staging][:enabled]
    assert_equal 3, result[:geometry_staging][:explode_count]
    assert_equal 500, result[:faces]
    instances = model.active_entities.to_a.grep(ComponentInstance)
    assert_equal 1, instances.length,
                 'one stable destination/style must retain one tiny-fill batch'
    assert_equal 500, instances.first.definition.entities.faces_created
  end

  def test_progress_callback_brackets_native_geometry_and_text_phases
    model = Model.new
    events = []
    builder = Builder.new(
      model, [line_path(0.0)], [], [0, 0, 612, 792],
      :group_per_page => false, :detect_arcs => false,
      :progress_callback => lambda do |phase, detail|
        events << [phase, detail]
      end
    )

    builder.build

    phases = events.map(&:first)
    assert_equal(
      [
        :geometry_started,
        :geometry_completed,
        :text_started,
        :text_completed,
        :build_completed
      ],
      phases
    )
    assert_equal 1, events[0][1][:path_count]
    assert_equal 0, events[2][1][:text_item_count]
  end

  def test_run_controller_cancels_before_first_geometry_batch
    controller = BlueCollarSystems::PDFVectorImporter::ImportRunControl::Controller.new(
      :pages => [7],
      :requested_mode => :geometry,
      :cancel_probe => lambda { true },
      :clock => lambda { 0.0 }
    )
    builder = Builder.new(
      Model.new, [line_path(0.0)], [], [0, 0, 612, 792],
      :group_per_page => false, :detect_arcs => false,
      :page_number => 7, :run_controller => controller
    )

    error = assert_raises(
      BlueCollarSystems::PDFVectorImporter::ImportRunControl::ImportCancelled
    ) { builder.build }
    assert_equal 7, error.next_page
    assert_equal :geometry_path, error.snapshot[:stage]
    assert_equal 0, error.snapshot[:completed]
  end

  def test_progress_callback_cancellation_is_not_swallowed
    error = BlueCollarSystems::PDFVectorImporter::ImportRunControl::ImportCancelled.new(
      [], 1, { :stage => :geometry_started }
    )
    builder = Builder.new(
      Model.new, [line_path(0.0)], [], [0, 0, 612, 792],
      :group_per_page => false, :detect_arcs => false,
      :progress_callback => lambda { |_phase, _detail| raise error }
    )

    raised = assert_raises(
      BlueCollarSystems::PDFVectorImporter::ImportRunControl::ImportCancelled
    ) { builder.build }
    assert_same error, raised
  end

  private

  def line_path(y)
    start_point = [0.0, y]
    end_point = [72.0, y]
    segments = [
      Parser::Segment.new(:move, [start_point]),
      Parser::Segment.new(:line, [start_point, end_point])
    ]
    Parser::VectorPath.new(
      [Parser::SubPath.new(segments, false)],
      true, false, [0, 0, 0], [0, 0, 0], 1.0, 0, 0, nil,
      [1, 0, 0, 1, 0, 0], nil
    )
  end

  def filled_path
    points = [
      [0.0, 0.0],
      [72.0, 0.0],
      [90.0, 36.0],
      [72.0, 72.0],
      [0.0, 72.0]
    ]
    segments = [Parser::Segment.new(:move, [points.first])]
    points.each_cons(2) do |left, right|
      segments << Parser::Segment.new(:line, [left, right])
    end
    Parser::VectorPath.new(
      [Parser::SubPath.new(segments, true)],
      true, true, [0, 0, 0], nil, 1.0, 0, 0, nil,
      [1, 0, 0, 1, 0, 0], nil
    )
  end

  def tiny_filled_path(offset_x)
    points = [
      [offset_x, 0.0],
      [offset_x + 0.12, 0.0],
      [offset_x + 0.12, 0.12],
      [offset_x, 0.12]
    ]
    segments = [Parser::Segment.new(:move, [points.first])]
    points.each_cons(2) do |left, right|
      segments << Parser::Segment.new(:line, [left, right])
    end
    Parser::VectorPath.new(
      [Parser::SubPath.new(segments, true)],
      false, true, [0, 0, 0], nil, 1.0, 0, 0, nil,
      [1, 0, 0, 1, 0, 0], nil
    )
  end
end
