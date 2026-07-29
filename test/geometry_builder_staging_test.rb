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
end

module Sketchup
  def self.status_text=(_value); end
end

require 'bc_pdf_vector_importer/content_stream_parser'
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

  class Group
    attr_accessor :name, :layer
    attr_reader :entities

    def initialize(parent)
      @parent = parent
      @entities = Entities.new
    end

    def explode
      @parent.explode_group(self, @entities.to_a)
    end
  end

  class Entities
    attr_reader :groups_created, :groups_exploded

    def initialize
      @items = []
      @groups_created = 0
      @groups_exploded = 0
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

    def explode_group(group, children)
      @items.delete(group)
      @items.concat(children)
      @groups_exploded += 1
      children
    end
  end

  class Model
    attr_reader :active_entities, :layers

    def initialize
      @active_entities = Entities.new
      @layers = Layers.new
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
    assert_equal 2, result[:geometry_staging][:batch_count]
    assert_equal 2, result[:geometry_staging][:explode_count]
    assert_equal 2, model.active_entities.groups_created
    assert_equal 2, model.active_entities.groups_exploded
    assert_equal 500, model.active_entities.to_a.length
    assert model.active_entities.to_a.all? { |entity| entity.is_a?(Edge) }
    endpoints = model.active_entities.to_a.values_at(0, -1).map do |edge|
      edge.start_point.y
    end
    assert_equal [0.0, 499.0 / 72.0], endpoints
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
end
