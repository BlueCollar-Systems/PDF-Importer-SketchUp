#!/usr/bin/env ruby
# Scratch reproduction (host-free) for the 3.7.144 Labels ResumeMismatch:
#   "page 1 retained entity signature changed"
#
# Mechanism under test:
#   * GeometryBuilder#build (Labels, import_text, group_per_page) always creates
#     a nested "Text" group inside the page group BEFORE placing any item
#     (geometry_builder.rb:229-232).
#   * Since #54 every finite-bbox Labels item advances by proof and creates no
#     native Sketchup::Text, so that "Text" group stays EMPTY. The Labels ->
#     3D Text span groups are placed in builder.page_group.entities
#     (main.rb:4443-4451), not in the "Text" group.
#   * SketchUp suspends its empty-group/definition cleanup between
#     start_operation and commit_operation (thomthom, SketchUp api-issue-tracker
#     #797) and runs it at commit. main.rb certifies the page group at 4902
#     (inside the operation, so the empty group is still a child and is part of
#     collect_entity_signature) and commits at 4909. PageOrchestrator then
#     re-validates immediately (import_run_control.rb:715 -> :345 -> :466) and
#     the empty "Text" group is gone -> signature differs -> ResumeMismatch.
#
# The fake Model below reproduces exactly that host semantic: commit_operation
# purges any Group whose entities are empty. Everything else (GeometryBuilder,
# ImportRunControl::Controller signature walk, PageOrchestrator) is the real
# product code loaded from this repository.

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
    def self.scaling(x_scale, y_scale = nil, z_scale = nil)
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

# ---------------------------------------------------------------------------
# Minimal SketchUp host double with the ONE semantic that matters here:
# empty groups survive inside an operation and are purged at commit_operation.
# ---------------------------------------------------------------------------
module FakeHost
  module Ids
    @next = 1000
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
    def invalidate!; @valid = false; end
    def vertices; @points; end
    def normal; Struct.new(:z).new(1.0); end
    def reverse!; self; end
    def hidden?; false; end
  end

  class Text < Leaf
    attr_reader :text, :point, :vector
    def initialize(text, point, vector)
      super('Text', [point])
      @text = text; @point = point; @vector = vector
    end
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
    def empty?; @entities.length.zero?; end
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

    def add_text(text, point, vector = nil)
      entity = Text.new(text, point, vector || Geom::Vector3d.new(0, 0, 0))
      @items << entity
      entity
    end

    def transform_entities(_t, *_e); true; end
    def erase_entities(*entities)
      entities.flatten.each { |e| @items.delete(e) }
    end
    def erase_entity(entity); @items.delete(entity); entity; end
    def explode_group(group, children)
      @items.delete(group); @items.concat(children); children
    end

    # SketchUp cleanup: drop empty groups (recursively) -- called by the model
    # at commit_operation, never inside the operation.
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
      @operation_open = false
      @purged_groups = 0
    end

    def line_styles; nil; end
    def start_operation(*_a); @operation_open = true; end
    def abort_operation; @operation_open = false; true; end

    def commit_operation
      @operation_open = false
      # thomthom / api-issue-tracker #797: empty group + definition cleanup is
      # suspended between start_operation and commit_operation.
      @purged_groups += @active_entities.purge_empty_groups!
      true
    end
  end
end

class LabelsEmptyTextGroupResumeSignatureTest < Minitest::Test
  IRC = BlueCollarSystems::PDFVectorImporter::ImportRunControl
  Builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder
  Parser = BlueCollarSystems::PDFVectorImporter::ContentStreamParser
  Item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem
  MEDIA_BOX = [0, 0, 612, 792].freeze

  def identity
    {
      :pdf_sha256 => 'a' * 64, :options_sha256 => 'b' * 64,
      :importer_sha256 => 'c' * 64, :package_sha256 => 'd' * 64,
      :source_tree_sha256 => 'e' * 64
    }
  end

  def line_path(y)
    a = [0.0, y]
    b = [72.0, y]
    segments = [Parser::Segment.new(:move, [a]),
                Parser::Segment.new(:line, [a, b])]
    Parser::VectorPath.new(
      [Parser::SubPath.new(segments, false)],
      true, false, [0, 0, 0], [0, 0, 0], 1.0, 0, 0, nil,
      [1, 0, 0, 1, 0, 0], nil
    )
  end

  # Finite-bbox horizontal Labels items: since #54 each one records the
  # label_source_size_unsupported_by_host proof and creates no native Text.
  def finite_bbox_items(count)
    count.times.map do |i|
      Item.new("A#{i}", 10.0, 20.0 + (i * 12), 9.0, 0.0, 'Arial', nil,
               10.0, 20.0 + (i * 12), 25.0, 29.0 + (i * 12), nil,
               "text_span:1:#{i}")
    end
  end

  def build_labels_page(model, items)
    builder = Builder.new(
      model, [line_path(10.0), line_path(20.0)], items, MEDIA_BOX,
      :group_per_page => true, :detect_arcs => false, :import_fills => false,
      :import_text => true, :use_3d_text => false,
      :requested_text_mode => :labels, :page_number => 1
    )
    result = builder.build
    [builder, result]
  end

  # RED (mechanism): the same host semantic that main.rb relies on --
  # certify at main.rb:4902 inside the operation, commit at :4909, immediate
  # PageOrchestrator re-validation at import_run_control.rb:715 -> :345 -> :466.
  def test_labels_page_certified_before_commit_still_validates_after_commit
    model = FakeHost::Model.new
    model.start_operation('PDF Import', true)
    builder, result = build_labels_page(model, finite_bbox_items(3))

    # #54 contract holds: every item advanced by proof, no native Text.
    assert_equal 3, result[:text_delivery_failures].length
    assert_equal 0, result[:text_objects]
    assert(result[:text_delivery_failures].all? do |f|
      f[:reason] == 'label_source_size_unsupported_by_host' &&
        f[:transition_proof].is_a?(Hash)
    end)

    controller = IRC::Controller.new(
      :model => model, :pages => [1], :requested_mode => :labels,
      :identity => identity, :clock => lambda { 0.0 }
    )
    controller.certify_page!(builder.page_group, 1, :next_y_offset => 0.0)
    assert_equal [1], controller.resumable_pages,
                 'sanity: inside the operation the signature is stable'

    model.commit_operation

    # This is what happens in-host on 3.7.144 Labels: after commit the empty
    # nested "Text" group is purged, the retained tree changed, and the
    # orchestrator's immediate re-validation raises.
    controller.resumable_pages
  rescue IRC::ResumeMismatch => e
    flunk "certified Labels page must survive commit_operation, but: " \
          "#{e.message} (empty groups purged at commit: #{model.purged_groups})"
  end

  # RED (root cause, builder-local): with import_text and every item advancing
  # by proof, GeometryBuilder must not leave an empty nested "Text" group in
  # the page group -- SketchUp will delete it at commit and change the
  # certified retained tree.
  def test_labels_build_leaves_no_empty_text_group_in_page_group
    model = FakeHost::Model.new
    builder, = build_labels_page(model, finite_bbox_items(2))

    empty_children = builder.page_group.entities.to_a.select do |child|
      child.is_a?(FakeHost::Group) && child.entities.length.zero?
    end
    assert_empty empty_children.map(&:name),
                 'GeometryBuilder#build must not retain an empty group ' \
                 '(SketchUp purges empty groups at commit_operation)'
    assert_nil builder.text_group,
               'text_group must be nil when no native Text was placed'
  end

  # GREEN today (control): pre-#54 shape -- when the "Text" group is
  # non-empty (a native Text was placed) commit does not change the tree.
  # Demonstrates why 3.7.143 Labels (653 native Text) passed the same cell.
  def test_non_empty_text_group_survives_commit_and_revalidation
    model = FakeHost::Model.new
    model.start_operation('PDF Import', true)
    builder = Builder.new(
      model, [line_path(10.0)], finite_bbox_items(1), MEDIA_BOX,
      :group_per_page => true, :detect_arcs => false, :import_fills => false,
      :import_text => true, :use_3d_text => false,
      :requested_text_mode => :labels, :page_number => 1
    )
    # Pre-#54 shape: the Labels rung delivers a native Text into the "Text"
    # group during build.
    native_label = lambda do |entities, item, *_rest|
      entities.add_text(item.text, Geom::Point3d.new(0, 0, 0))
      true
    end
    builder.stub(:place_text, native_label) { builder.build }
    refute_nil builder.text_group
    assert_equal 1, builder.text_group.entities.length

    controller = IRC::Controller.new(
      :model => model, :pages => [1], :requested_mode => :labels,
      :identity => identity, :clock => lambda { 0.0 }
    )
    controller.certify_page!(builder.page_group, 1)
    model.commit_operation
    assert_equal [1], controller.resumable_pages
    assert_equal 0, model.purged_groups
  end

  # Text/3D Text control: no builder text items -> no "Text" group at all,
  # which is why text/3d_text 3.7.144 pass the same cell.
  def test_no_builder_text_items_creates_no_text_group
    model = FakeHost::Model.new
    builder = Builder.new(
      model, [line_path(10.0)], [], MEDIA_BOX,
      :group_per_page => true, :detect_arcs => false, :import_fills => false,
      :import_text => false, :requested_text_mode => :text3d
    )
    builder.build
    assert_nil builder.text_group
    assert_empty builder.page_group.entities.to_a.select { |c|
      c.is_a?(FakeHost::Group) && c.entities.length.zero?
    }
  end

  def build_color_page(model, empty, heavy = false)
    kept = heavy ? 500.times.map { |i| line_path(10.0 + i) } : [line_path(10.0)]
    colored = line_path(30.0)
    colored.subpaths.first.segments.last.points[1] = [0.001, 30.0] if empty
    colored.stroke_color = [0.25, 0.5, 0.75]
    builder = Builder.new(model, kept + [colored], [], MEDIA_BOX,
      :group_per_page => true, :group_by_color => true,
      :detect_arcs => false, :import_fills => false, :import_text => false,
      :requested_text_mode => :text3d)
    [builder, builder.build]
  end

  def color_group(builder)
    builder.page_group.entities.to_a.find { |child| child.name == 'Color_3F7FBF' }
  end

  def test_empty_source_color_group_does_not_change_signature_at_commit
    [false, true].each do |heavy|
      model = FakeHost::Model.new
      model.start_operation('PDF Import', true)
      builder, result = build_color_page(model, true, heavy)
      assert_nil color_group(builder), 'an undelivered short source path must not leave an empty color group'
      assert_equal heavy ? 500 : 1, result[:edges]
      controller = IRC::Controller.new(:model => model, :pages => [1],
        :requested_mode => :text3d, :identity => identity, :clock => lambda { 0.0 })
      controller.certify_page!(builder.page_group, 1)
      model.commit_operation
      assert_equal [1], controller.resumable_pages
      assert_equal 0, model.purged_groups
    end
  end

  def test_color_cleanup_after_page_finalization_preserves_unowned_groups
    model = FakeHost::Model.new
    builder, = build_color_page(model, false)
    colored = color_group(builder)
    refute_nil colored
    colored.entities.erase_entities(colored.entities.to_a)
    unrelated = builder.page_group.entities.add_group
    unrelated.name = 'Color_USER'
    assert_equal 1, builder.prune_empty_color_groups!
    refute colored.valid?
    assert unrelated.valid?, 'cleanup owns only groups created by this builder'
    assert_includes builder.page_group.entities.to_a, unrelated
    assert_equal 0, builder.prune_empty_color_groups!, 'cleanup is idempotent'
  end

  def test_empty_color_group_ignored_erase_fails_instead_of_certifying
    model = FakeHost::Model.new
    builder, = build_color_page(model, false)
    colored = color_group(builder)
    colored.entities.erase_entities(colored.entities.to_a)
    def colored.erase!; true; end
    error = assert_raises(RuntimeError) { builder.prune_empty_color_groups! }
    assert_match(/empty color group/, error.message)
    assert colored.valid?
  end

  def test_nonempty_color_group_and_strict_signature_remain_unchanged
    model = FakeHost::Model.new
    builder, = build_color_page(model, false)
    colored = color_group(builder)
    before = colored.entities.to_a
    assert_equal 0, builder.prune_empty_color_groups!
    assert_equal before, colored.entities.to_a
    controller = IRC::Controller.new(:model => model, :pages => [1],
      :requested_mode => :text3d, :identity => identity, :clock => lambda { 0.0 })
    controller.certify_page!(builder.page_group, 1)
    model.commit_operation
    assert_equal [1], controller.resumable_pages
    colored.entities.erase_entities(before.first)
    assert_raises(IRC::ResumeMismatch) { controller.resumable_pages }
  end

  def build_empty_fill_page(model, heavy = false)
    kept = heavy ? 500.times.map { |i| line_path(10.0 + i) } : [line_path(10.0)]
    empty_fill = line_path(30.0)
    empty_fill.stroke = false
    empty_fill.fill = true
    empty_fill.subpaths.first.segments.pop
    builder = Builder.new(model, kept + [empty_fill], [], MEDIA_BOX,
      :group_per_page => true, :group_by_color => true,
      :detect_arcs => false, :import_fills => true, :import_text => false,
      :requested_text_mode => :text3d)
    [builder, builder.build]
  end

  def test_empty_fill_group_does_not_change_signature_at_commit
    [false, true].each do |heavy|
      model = FakeHost::Model.new
      model.start_operation('PDF Import', true)
      builder, result = build_empty_fill_page(model, heavy)
      assert_equal heavy ? 500 : 1, result[:edges]
      controller = IRC::Controller.new(:model => model, :pages => [1],
        :requested_mode => :text3d, :identity => identity, :clock => lambda { 0.0 })
      controller.certify_page!(builder.page_group, 1)
      model.commit_operation
      assert_equal [1], controller.resumable_pages
      assert_equal 0, model.purged_groups
      assert_empty builder.fill_only_groups
    end
  end

  def build_owned_fill_page(model)
    builder, = build_empty_fill_page(model)
    parent = builder.page_group.entities
    group = parent.add_group
    group.name = 'PDF Fill'
    group.entities.add_edges([Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(1, 1, 0)])
    builder.instance_variable_get(:@source_group_parents)[group] = parent
    builder.fill_only_groups << { :group => group }
    [builder, group, parent]
  end

  def test_fill_cleanup_preserves_nonempty_and_unowned_groups
    model = FakeHost::Model.new
    builder, group, parent = build_owned_fill_page(model)
    unrelated = parent.add_group
    unrelated.name = 'PDF Fill'
    controller = IRC::Controller.new(:model => model, :pages => [1],
      :requested_mode => :text3d, :identity => identity, :clock => lambda { 0.0 })
    before = controller.send(:entity_signature, builder.page_group)
    assert_equal 0, builder.prune_empty_source_groups!
    assert_equal before, controller.send(:entity_signature, builder.page_group)
    assert group.valid?
    assert unrelated.valid?
    group.entities.erase_entities(group.entities.to_a)
    assert_equal 1, builder.prune_empty_source_groups!
    refute group.valid?
    assert unrelated.valid?, 'matching names do not establish ownership'
    assert_empty builder.fill_only_groups
    assert_equal 0, builder.prune_empty_source_groups!
  end

  def test_fill_cleanup_ignored_erase_cannot_pass_certification
    builder, group, = build_owned_fill_page(FakeHost::Model.new)
    group.entities.erase_entities(group.entities.to_a)
    def group.erase!; true; end
    error = assert_raises(RuntimeError) { builder.prune_empty_source_groups! }
    assert_match(/host did not remove an empty source group/, error.message)
    assert group.valid?
    assert_equal [group], builder.fill_only_groups.map { |row| row[:group] }
  end

  def test_fill_cleanup_refuses_changed_parent_ownership
    builder, group, parent = build_owned_fill_page(FakeHost::Model.new)
    group.entities.erase_entities(group.entities.to_a)
    parent.erase_entity(group)
    error = assert_raises(RuntimeError) { builder.prune_empty_source_groups! }
    assert_match(/lost its source-owned parent/, error.message)
    assert group.valid?
  end

  def test_already_removed_fill_is_removed_from_display_metadata_only
    builder, group, = build_owned_fill_page(FakeHost::Model.new)
    group.erase!
    assert_equal 0, builder.prune_empty_source_groups!
    assert_empty builder.fill_only_groups
    assert_equal 0, builder.prune_empty_source_groups!
  end

  def test_fill_inside_retained_batch_is_pruned_after_page_cleanup
    model = FakeHost::Model.new
    model.start_operation('PDF Import', true)
    builder, = build_empty_fill_page(model, true)
    parent = builder.page_group.entities
    clip_parent = builder.send(:staged_geometry_target, parent, 999)
    fill = clip_parent.add_group
    fill.name = 'PDF Clipped Fill'
    fill.entities.add_edges([Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(1, 1, 0)])
    builder.instance_variable_get(:@source_group_parents)[fill] = clip_parent
    builder.fill_only_groups << { :group => fill }
    builder.send(:finalize_geometry_staging!)
    fill.entities.erase_entities(fill.entities.to_a)
    assert_equal 2, builder.prune_empty_source_groups!
    controller = IRC::Controller.new(:model => model, :pages => [1],
      :requested_mode => :text3d, :identity => identity, :clock => lambda { 0.0 })
    controller.certify_page!(builder.page_group, 1)
    model.commit_operation
    assert_equal [1], controller.resumable_pages
    assert_equal 0, model.purged_groups
    assert_empty builder.fill_only_groups
  end

  def test_retained_batch_inside_fill_is_pruned_after_page_cleanup
    model = FakeHost::Model.new
    model.start_operation('PDF Import', true)
    builder, fill, = build_owned_fill_page(model)
    fill.entities.erase_entities(fill.entities.to_a)
    builder.send(:configure_geometry_staging!, true)
    batch_entities = builder.send(:staged_geometry_target, fill.entities, 999)
    batch_entities.add_edges([Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(1, 1, 0)])
    builder.send(:finalize_geometry_staging!)
    batch_entities.erase_entities(batch_entities.to_a)
    assert_equal 2, builder.prune_empty_source_groups!
    controller = IRC::Controller.new(:model => model, :pages => [1],
      :requested_mode => :text3d, :identity => identity, :clock => lambda { 0.0 })
    controller.certify_page!(builder.page_group, 1)
    model.commit_operation
    assert_equal [1], controller.resumable_pages
    assert_equal 0, model.purged_groups
    assert_empty builder.fill_only_groups
  end
end
