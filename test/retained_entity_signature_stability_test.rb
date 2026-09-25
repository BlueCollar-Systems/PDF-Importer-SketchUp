#!/usr/bin/env ruby
# Host-free regression for ResumeMismatch "page N retained entity signature changed"
# seen on SketchUp Make 2017 after a legitimate multi-page text3d import
# (2026-09-25 work-PC log: page 2 failed immediately after commit_operation).
#
# Mechanism under test (same host semantic as Labels empty-Text #57):
#   * page_certifier stamps entity_signature_sha256 inside the open operation
#   * SketchUp purges empty Groups at commit_operation (api-issue-tracker #797)
#   * PageOrchestrator re-validates via resumable_pages and must not raise when
#     only host housekeeping / sibling order / sub-quantum float rewrite changed
#   * a real edge move must still fail the retained signature check
#
# Ruby 2.2 compatible.

require 'minitest/autorun'
require 'digest'
require 'json'

SRC_ROOT = File.expand_path('../extracted/sketchup_ext', __dir__)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

require 'bc_pdf_vector_importer/import_run_control'

module SignatureFakeHost
  module Ids
    @next = 5000
    def self.next!
      @next += 1
    end
  end

  module Attributes
    def set_attribute(dict, key, value)
      (@attributes ||= {})[[dict.to_s, key.to_s]] = value
    end

    def get_attribute(dict, key, default = nil)
      (@attributes ||= {}).fetch([dict.to_s, key.to_s], default)
    end
  end

  class Point
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
    def to_a
      [@x, @y, @z]
    end
  end

  class Bounds
    def initialize(min, max)
      @min = min
      @max = max
    end
    attr_reader :min, :max
  end

  class Edge
    include Attributes
    attr_reader :start, :end, :persistent_id
    attr_accessor :hidden
    def initialize(persistent_id, a, b)
      @persistent_id = persistent_id
      @start = Point.new(*a)
      @end = Point.new(*b)
      @hidden = false
    end
    def typename
      'Edge'
    end
    def name
      ''
    end
    def hidden?
      @hidden == true
    end
    def valid?
      true
    end
    def bounds
      xs = [@start.x, @end.x]
      ys = [@start.y, @end.y]
      zs = [@start.z, @end.z]
      Bounds.new(Point.new(xs.min, ys.min, zs.min),
                 Point.new(xs.max, ys.max, zs.max))
    end
  end

  class Entities
    def initialize(owner)
      @owner = owner
      @items = []
    end
    def to_a
      @items.dup
    end
    def length
      @items.length
    end
    def <<(entity)
      @items << entity
      entity
    end
    def add_group
      group = Group.new(self)
      @items << group
      group
    end
    def add_line(a, b)
      edge = Edge.new(Ids.next!, a, b)
      @items << edge
      edge
    end
    def delete(entity)
      @items.delete(entity)
    end
    def replace!(items)
      @items = items.dup
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

  class Group
    include Attributes
    attr_reader :entities, :persistent_id
    attr_accessor :name, :hidden
    def initialize(parent_entities = nil)
      @parent_entities = parent_entities
      @persistent_id = Ids.next!
      @entities = Entities.new(self)
      @name = ''
      @hidden = false
      @valid = true
      @transformation = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    end
    def typename
      'Group'
    end
    def transformation
      OpenStructish.new(@transformation)
    end
    def transformation=(values)
      @transformation = values.dup
    end
    def hidden?
      @hidden == true
    end
    def valid?
      @valid == true
    end
    def erase!
      @valid = false
      @entities.replace!([])
      @parent_entities.delete(self) if @parent_entities
      true
    end
    def bounds
      points = @entities.to_a.flat_map do |child|
        next [] unless child.respond_to?(:bounds)
        b = child.bounds
        [b.min, b.max]
      end
      return Bounds.new(Point.new, Point.new) if points.empty?
      Bounds.new(
        Point.new(points.map(&:x).min, points.map(&:y).min, points.map(&:z).min),
        Point.new(points.map(&:x).max, points.map(&:y).max, points.map(&:z).max)
      )
    end
  end

  class OpenStructish
    def initialize(values)
      @values = values
    end
    def to_a
      @values
    end
  end

  class Model
    include Attributes
    attr_reader :active_entities, :purged_groups
    def initialize
      @active_entities = Entities.new(self)
      @purged_groups = 0
      @operation_open = false
    end
    def start_operation(*_a)
      @operation_open = true
    end
    def commit_operation
      @operation_open = false
      @purged_groups += @active_entities.purge_empty_groups!
      true
    end
  end
end

class RetainedEntitySignatureStabilityTest < Minitest::Test
  IRC = BlueCollarSystems::PDFVectorImporter::ImportRunControl

  def identity
    {
      :pdf_sha256 => 'a' * 64,
      :options_sha256 => 'b' * 64,
      :importer_sha256 => 'c' * 64,
      :package_sha256 => 'd' * 64,
      :source_tree_sha256 => 'e' * 64
    }
  end

  def controller(model)
    IRC::Controller.new(
      :model => model,
      :pages => [2],
      :requested_mode => :text3d,
      :identity => identity,
      :clock => lambda { 0.0 }
    )
  end

  def page_with_content_and_empty_child(model)
    page = model.active_entities.add_group
    page.name = 'PDF Page 2'
    page.entities.add_line([0.0, 0.0, 0.0], [10.0, 0.0, 0.0])
    page.entities.add_line([0.0, 1.0, 0.0], [10.0, 1.0, 0.0])
    empty = page.entities.add_group
    empty.name = 'ephemeral empty'
    [page, empty]
  end

  # RED before fix / GREEN after: empty nested group is certified away, commit
  # purges it, resumable_pages must still accept the page.
  def test_empty_nested_group_does_not_break_post_commit_resume_validation
    model = SignatureFakeHost::Model.new
    model.start_operation('PDF Import', true)
    page, empty = page_with_content_and_empty_child(model)
    assert_equal 0, empty.entities.length

    run = controller(model)
    run.certify_page!(page, 2, :next_y_offset => 12.0, :stats => { :edges => 2 })
    refute empty.valid?, 'certify must remove empty groups before signing'
    assert_equal [2], run.resumable_pages

    model.commit_operation
    assert_equal [2], run.resumable_pages
  end

  def test_sibling_order_rewrite_does_not_change_signature
    model = SignatureFakeHost::Model.new
    page = model.active_entities.add_group
    a = page.entities.add_line([0.0, 0.0, 0.0], [5.0, 0.0, 0.0])
    b = page.entities.add_line([0.0, 2.0, 0.0], [5.0, 2.0, 0.0])
    run = controller(model)

    first = run.send(:entity_signature, page)
    page.entities.replace!([b, a])
    second = run.send(:entity_signature, page)

    assert_equal first, second
  end

  def test_sub_quantum_float_noise_does_not_change_signature
    model = SignatureFakeHost::Model.new
    page = model.active_entities.add_group
    edge = page.entities.add_line([0.0, 0.0, 0.0], [10.0, 0.0, 0.0])
    run = controller(model)

    first = run.send(:entity_signature, page)
    edge.end.x = 10.0 + 1.0e-7
    second = run.send(:entity_signature, page)

    assert_equal first, second
  end

  def test_real_geometry_change_still_changes_signature
    model = SignatureFakeHost::Model.new
    page = model.active_entities.add_group
    edge = page.entities.add_line([0.0, 0.0, 0.0], [10.0, 0.0, 0.0])
    run = controller(model)

    first = run.send(:entity_signature, page)
    edge.end.x = 11.0
    changed = run.send(:entity_signature, page)

    refute_equal first, changed
  end

  def test_real_geometry_change_still_fails_resume_validation
    model = SignatureFakeHost::Model.new
    model.start_operation('PDF Import', true)
    page = model.active_entities.add_group
    edge = page.entities.add_line([0.0, 0.0, 0.0], [10.0, 0.0, 0.0])
    run = controller(model)
    run.certify_page!(page, 2, :next_y_offset => 0.0)
    model.commit_operation

    edge.end.x = 12.0
    error = assert_raises(IRC::ResumeMismatch) { run.resumable_pages }
    assert_match(/page 2 retained entity signature changed/, error.message)
  end
end
