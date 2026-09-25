#!/usr/bin/env ruby
# Host-free reproduction (Ruby 2.2-safe) of the 2026-09-25 work-PC failure:
#   "PDF import failed: page 2 retained entity signature changed"
#   import_run_control.rb:466 validate_page_entry! <- :345 resumable_pages
#
# Mechanism under test:
#   * GeometryBuilder#build creates a "PDF Fill" container for a fill-only path
#     BEFORE any of its subpaths is drawn (fill_targets). A fill path whose
#     every subpath is open, degenerate or rejected by the host leaves that
#     container EMPTY.
#   * SketchUp suspends empty-group cleanup between start_operation and
#     commit_operation (thomthom, api-issue-tracker #797). main.rb certifies
#     the page group inside the operation (the empty container is still part of
#     the signature) and commits afterwards; the host then purges the container
#     and PageOrchestrator's immediate re-validation reads a different digest.
#   * prune_empty_color_groups! only covered @color_groups, and the empty
#     "Text" group only its own case. The fix removes the builder's empty fill
#     containers and then every empty group under the page before certification,
#     and the mismatch message now names what vanished.
#
# The fake host below has that one semantic: commit_operation purges empty
# groups, recursively. GeometryBuilder and ImportRunControl are the product
# code from this repository.

require 'minitest/autorun'
require 'digest'

SRC_ROOT = File.expand_path('../extracted/sketchup_ext', __dir__)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

TextAlignLeft = 0 unless defined?(TextAlignLeft)

class Numeric
  def degrees
    to_f * Math::PI / 180.0
  end unless method_defined?(:degrees)
end

module Geom
  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f; @y = y.to_f; @z = z.to_f
    end
    def to_a; [@x, @y, @z]; end
    def distance(o)
      Math.sqrt(((x - o.x)**2) + ((y - o.y)**2) + ((z - o.z)**2))
    end
  end

  class Vector3d
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f; @y = y.to_f; @z = z.to_f
    end
    def to_a; [@x, @y, @z]; end
  end

  class Transformation
    attr_reader :origin, :scale
    def initialize(origin = nil, scale = 1.0)
      @origin = origin
      @scale = scale.to_f
    end
    def self.translation(origin); new(origin, 1.0); end
    def self.scaling(x_scale, _y_scale = nil, _z_scale = nil)
      new(nil, x_scale)
    end
    def to_a
      [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    end
    def *(other); Transformation.new(origin || other.origin, scale * other.scale); end
  end
end

ORIGIN = Geom::Point3d.new(0, 0, 0) unless defined?(ORIGIN)
Z_AXIS = Geom::Vector3d.new(0, 0, 1) unless defined?(Z_AXIS)

module Sketchup
  class Color
    attr_reader :red, :green, :blue
    def initialize(red, green, blue)
      @red, @green, @blue = red, green, blue
    end
  end
  def self.status_text=(_value); end
end

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/content_stream_parser'
require 'bc_pdf_vector_importer/arc_fitter'
require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/import_run_control'
require 'bc_pdf_vector_importer/geometry_builder'

module PurgingHost
  module Ids
    @next = 5000
    def self.next!; @next += 1; end
  end

  module Attributes
    def set_attribute(dict, key, value)
      (@attributes ||= {})[[dict.to_s, key.to_s]] = value
    end

    def get_attribute(dict, key, default = nil)
      (@attributes ||= {}).fetch([dict.to_s, key.to_s], default)
    end
  end

  class Layer
    attr_reader :name
    def initialize(name); @name = name; end
  end

  class Layers
    def initialize; @layers = {}; end
    def [](name); @layers[name]; end
    def add(name); @layers[name] = Layer.new(name); end
  end

  class Leaf
    include Attributes
    attr_accessor :layer, :material, :back_material
    attr_reader :persistent_id, :typename, :points

    def initialize(typename, points)
      @typename = typename
      @points = points
      @persistent_id = Ids.next!
      @valid = true
    end

    def valid?; @valid; end
    def vertices; @points; end
    def normal; Struct.new(:z).new(1.0); end
    def reverse!; self; end
    def hidden?; false; end
  end

  class Group
    include Attributes
    attr_accessor :name, :layer
    attr_reader :entities, :persistent_id

    def initialize(parent)
      @parent = parent
      @entities = Entities.new
      @persistent_id = Ids.next!
      @valid = true
      @name = ''
    end

    def typename; 'Group'; end
    def valid?; @valid; end
    def hidden?; false; end
    def transformation; Geom::Transformation.new; end
    def erase!
      @parent.erase_entity(self)
      @valid = false
      true
    end
    def explode; @parent.explode_group(self, @entities.to_a); end
  end

  class Entities
    def initialize; @items = []; end
    def to_a; @items.dup; end
    def length; @items.length; end

    def add_group
      group = Group.new(self)
      @items << group
      group
    end

    def add_edges(points)
      edges = Array(points).each_cons(2).map { |a, b| Leaf.new('Edge', [a, b]) }
      @items.concat(edges)
      edges
    end

    def add_face(points)
      face = Leaf.new('Face', Array(points))
      @items << face
      face
    end

    def transform_entities(_t, *_e); true; end
    def erase_entities(*entities)
      entities.flatten.each { |e| @items.delete(e) }
    end
    def erase_entity(entity); @items.delete(entity); entity; end
    def explode_group(group, children)
      @items.delete(group); @items.concat(children); children
    end

    def purge_empty_groups!
      purged = 0
      @items.dup.each do |item|
        next unless item.is_a?(Group)
        purged += item.entities.purge_empty_groups!
        next unless item.entities.length.zero?
        @items.delete(item)
        item.instance_variable_set(:@valid, false)
        purged += 1
      end
      purged
    end
  end

  class Material
    attr_reader :name
    attr_accessor :color, :alpha, :texture
    def initialize(name)
      @name = name
      @alpha = 1.0
      @texture = nil
    end
  end

  class Materials
    def initialize; @items = {}; end
    def [](name); @items[name]; end
    def add(name)
      key = name
      key += '_1' while @items.key?(key)
      @items[key] = Material.new(key)
    end
  end

  class Model
    include Attributes
    attr_reader :active_entities, :layers, :definitions, :purged_groups, :materials

    def initialize
      @active_entities = Entities.new
      @layers = Layers.new
      @materials = Materials.new
      @definitions = Struct.new(:items).new([])
      @purged_groups = 0
    end

    def line_styles; nil; end
    def start_operation(*_a); true; end
    def abort_operation; true; end

    def commit_operation
      @purged_groups += @active_entities.purge_empty_groups!
      true
    end
  end
end

class EmptyFillGroupResumeSignatureTest < Minitest::Test
  IRC = BlueCollarSystems::PDFVectorImporter::ImportRunControl
  Builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder
  Parser = BlueCollarSystems::PDFVectorImporter::ContentStreamParser
  MEDIA_BOX = [0, 0, 612, 792].freeze

  def identity
    {
      :pdf_sha256 => 'a' * 64, :options_sha256 => 'b' * 64,
      :importer_sha256 => 'c' * 64, :package_sha256 => 'd' * 64,
      :source_tree_sha256 => 'e' * 64
    }
  end

  def path(points, stroke, fill, closed)
    segments = [Parser::Segment.new(:move, [points.first])]
    points.each_cons(2) { |a, b| segments << Parser::Segment.new(:line, [a, b]) }
    Parser::VectorPath.new(
      [Parser::SubPath.new(segments, closed)],
      stroke, fill, [0, 0, 0], [0.5, 0.5, 0.5], 1.0, 0, 0, nil,
      [1, 0, 0, 1, 0, 0], nil
    )
  end

  def stroke_line(y)
    path([[0.0, y], [72.0, y]], true, false, false)
  end

  # A fill-only path whose single subpath is OPEN: the host would fill it (a
  # PDF "f" closes implicitly) but the builder draws faces only for closed
  # subpaths, so its "PDF Fill" container receives nothing.
  def open_fill(y)
    path([[10.0, y], [40.0, y], [40.0, y + 20.0]], false, true, false)
  end

  def build_page(model, paths)
    builder = Builder.new(
      model, paths, [], MEDIA_BOX,
      :group_per_page => true, :group_by_color => true, :detect_arcs => false,
      :import_fills => true, :import_text => false,
      :requested_text_mode => :text3d, :page_number => 1
    )
    result = builder.build
    [builder, result]
  end

  def controller_for(model)
    IRC::Controller.new(
      :model => model, :pages => [1], :requested_mode => :text3d,
      :identity => identity, :clock => lambda { 0.0 }
    )
  end

  def empty_groups_below(container)
    found = []
    container.entities.to_a.each do |child|
      next unless child.is_a?(PurgingHost::Group)
      found << child if child.entities.length.zero?
      found.concat(empty_groups_below(child))
    end
    found
  end

  def certify_commit_and_revalidate(model, builder)
    controller = controller_for(model)
    controller.certify_page!(builder.page_group, 1)
    model.commit_operation
    [controller, controller.resumable_pages]
  end

  def test_open_fill_path_no_longer_leaves_an_empty_fill_container
    model = PurgingHost::Model.new
    builder, result = build_page(model, [stroke_line(10.0), stroke_line(20.0), open_fill(30.0)])
    assert_equal 2, result[:edges]
    assert_equal 0, result[:faces]
    assert_equal 0, empty_groups_below(builder.page_group).length,
                 'an empty "PDF Fill" group survived the build'
    assert builder.fill_only_groups.all? { |record| record[:group].valid? && record[:group].entities.length > 0 },
           'fill_only_groups still records a dead or empty container'
    _controller, pages = certify_commit_and_revalidate(model, builder)
    assert_equal [1], pages
    assert_equal 0, model.purged_groups, 'host commit still had an empty group to purge'
  end

  def test_heavy_page_with_bulk_staging_behaves_the_same
    model = PurgingHost::Model.new
    heavy = Builder::GEOMETRY_STAGING_PATH_THRESHOLD + 50
    paths = heavy.times.map { |i| stroke_line(10.0 + i) } + [open_fill(5.0), open_fill(6.0)]
    builder, result = build_page(model, paths)
    assert_equal heavy, result[:edges]
    assert_equal 0, empty_groups_below(builder.page_group).length
    _controller, pages = certify_commit_and_revalidate(model, builder)
    assert_equal [1], pages
    assert_equal 0, model.purged_groups
  end

  def test_prune_empty_page_groups_removes_nested_containers_left_by_any_stage
    model = PurgingHost::Model.new
    builder, _result = build_page(model, [stroke_line(10.0)])
    outer = builder.page_group.entities.add_group
    outer.name = 'Late Container'
    inner = outer.entities.add_group
    inner.name = 'Late Inner'
    kept = builder.page_group.entities.add_group
    kept.name = 'Kept'
    kept.entities.add_face([Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(1, 0, 0), Geom::Point3d.new(1, 1, 0)])
    removed = builder.prune_empty_page_groups!
    assert_equal ['Late Inner', 'Late Container'], removed, 'deepest empty group first, then its emptied parent'
    refute outer.valid?
    refute inner.valid?
    assert kept.valid?
    assert_equal 0, empty_groups_below(builder.page_group).length
    _controller, pages = certify_commit_and_revalidate(model, builder)
    assert_equal [1], pages
    assert_equal 0, model.purged_groups
  end

  def test_same_run_mismatch_names_the_group_the_host_purged
    model = PurgingHost::Model.new
    builder, _result = build_page(model, [stroke_line(10.0)])
    # A stage that adds an empty container AFTER the pre-certification prune
    # reproduces the unfixed failure; the message must now say what vanished.
    late = builder.page_group.entities.add_group
    late.name = 'PDF Fill'
    controller = controller_for(model)
    controller.certify_page!(builder.page_group, 1)
    model.commit_operation
    assert_equal 1, model.purged_groups
    error = assert_raises(IRC::ResumeMismatch) { controller.resumable_pages }
    assert_match(/\Apage 1 retained entity signature changed \(/, error.message)
    assert_match(/1 group\(s\) vanished since certification in this run/, error.message)
    assert_match(/group 'PDF Fill' pid #{late.persistent_id} depth 1 with 0 child\(ren\)/, error.message)
    assert_match(/entity counts changed: Group \d+->\d+/, error.message)
  end

  def test_true_resume_in_another_process_keeps_the_bare_message
    model = PurgingHost::Model.new
    builder, _result = build_page(model, [stroke_line(10.0)])
    controller = controller_for(model)
    controller.certify_page!(builder.page_group, 1)
    model.commit_operation
    assert_equal [1], controller.resumable_pages
    # A later session: a new controller on the same model has no census.
    builder.page_group.entities.add_group.entities.add_face(
      [Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(2, 0, 0), Geom::Point3d.new(2, 2, 0)]
    )
    resumed = controller_for(model)
    error = assert_raises(IRC::ResumeMismatch) { resumed.resumable_pages }
    assert_equal 'page 1 retained entity signature changed', error.message
  end

  def test_journal_digest_is_unchanged_by_the_census
    model = PurgingHost::Model.new
    builder, _result = build_page(model, [stroke_line(10.0), stroke_line(20.0)])
    controller = controller_for(model)
    entry = controller.certify_page!(builder.page_group, 1)
    # The journal digest is still the plain SHA-256 of the row stream; the
    # census is in-memory only and the journal schema did not move.
    assert_equal controller.send(:entity_signature, builder.page_group), entry['entity_signature_sha256']
    assert_match(/\A[0-9a-f]{64}\z/, entry['entity_signature_sha256'])
    assert_equal IRC::JOURNAL_SCHEMA, controller.journal['schema']
    refute controller.journal.key?('census')
  end
end
