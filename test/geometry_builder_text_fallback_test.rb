#!/usr/bin/env ruby
# TEXTMODE-1: native SketchUp text APIs may fail per span.  The importer must
# deliver the nearest viable representation and record the substitution.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/text_parser'

TextAlignLeft = 0 unless defined?(TextAlignLeft)

class Numeric
  def degrees
    to_f * Math::PI / 180.0
  end
end

module Geom
  class Point3d
    attr_accessor :x, :y, :z

    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end

  class Vector3d
    attr_accessor :x, :y, :z

    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end
  end

  class Transformation
    attr_reader :args, :kind

    def initialize(*args)
      @args = args
      @kind = :translation
    end

    def self.rotation(*args)
      transform = new(*args)
      transform.instance_variable_set(:@kind, :rotation)
      transform
    end

    def self.scaling(*args)
      transform = new(*args)
      transform.instance_variable_set(:@kind, :scaling)
      transform
    end
  end
end

ORIGIN = Geom::Point3d.new(0, 0, 0) unless defined?(ORIGIN)
Z_AXIS = Geom::Vector3d.new(0, 0, 1) unless defined?(Z_AXIS)

class TextFallbackEntity
  attr_accessor :layer, :display_leader, :vector, :material, :back_material

  def initialize(typename = 'Edge', broken_typename = false)
    @typename = typename
    @broken_typename = broken_typename
  end

  def typename
    raise 'forced late typename failure' if @broken_typename
    @typename
  end
end

class TextFallbackEntities
  attr_reader :labels, :mesh_calls, :entities, :generated, :transforms,
              :erase_calls, :sentinel

  def initialize(mesh_result, label_result, options = {})
    @mesh_result = mesh_result
    @label_result = label_result
    @transform_failures = options[:transform_failures] || {}
    @cleanup_failure = options[:cleanup_failure]
    @labels = []
    @mesh_calls = []
    @sentinel = options[:sentinel]
    @entities = @sentinel ? [@sentinel] : []
    @generated = []
    @transforms = []
    @erase_calls = []
    @erase_attempted = false
  end

  def to_a
    raise 'forced cleanup verification failure' if @cleanup_failure == :verification && @erase_attempted
    @entities.dup
  end

  def add_3d_text(*)
    @mesh_calls << true
    if [:false_after_create, :raise_after_create, :success, :broken_typename].include?(@mesh_result)
      broken = @mesh_result == :broken_typename
      @generated = [TextFallbackEntity.new('Edge', broken), TextFallbackEntity.new('Face')]
      @entities.concat(@generated)
    end
    raise 'forced mesh failure after creation' if @mesh_result == :raise_after_create
    raise 'forced mesh failure' if @mesh_result == :raise
    return false if @mesh_result == :false_after_create
    return false if @mesh_result == :false
    return true if @mesh_result == :empty
    true
  end

  def add_text(*)
    raise 'forced label failure' if @label_result == :raise
    return nil if @label_result == :nil

    entity = TextFallbackEntity.new
    @labels << entity
    entity
  end

  def transform_entities(*args)
    @transforms << args
    kind = args.first.respond_to?(:kind) ? args.first.kind : nil
    failure = @transform_failures[kind]
    raise "forced #{kind} transform failure" if failure == :raise
    return false if failure == :false
    true
  end

  def erase_entities(*entities)
    @erase_attempted = true
    doomed = entities.flatten
    @erase_calls << doomed
    raise 'forced erase failure' if @cleanup_failure == :exception
    return true if @cleanup_failure == :noop

    removable = @cleanup_failure == :partial ? doomed[0, 1] : doomed
    @entities.delete_if do |entity|
      removable.any? { |candidate| candidate.equal?(entity) }
    end
    true
  end
end

load File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'geometry_builder.rb')

class GeometryBuilderTextFallbackTest < Minitest::Test
  Item = BlueCollarSystems::PDFVectorImporter::TextParser::TextItem

  def make_item(angle = 0.0)
    Item.new('A1', 10.0, 20.0, 9.0, angle, 'Arial', nil, 10.0, 20.0, 25.0, 30.0)
  end

  def make_builder(use_3d_text, provenance, requested_text_mode = nil)
    BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
      nil, [], [], [0, 0, 612, 792],
      import_text: true,
      use_3d_text: use_3d_text,
      provenance_bucket: provenance,
      requested_text_mode: requested_text_mode
    )
  end

  def assert_mesh_to_label_fallback(mesh_result, reason)
    provenance = []
    builder = make_builder(true, provenance)
    entities = TextFallbackEntities.new(mesh_result, :success)

    builder.send(:place_mesh_text, entities, make_item, 0.0, 0.0, 'Text')

    assert_equal 1, entities.labels.length
    assert_equal [
      { requested: :text3d, delivered: :labels, reason: reason, count: 1 }
    ], builder.text_fallbacks
    assert_equal 'native_label', provenance.last[:created_entity_type]
  end

  def test_false_mesh_result_delivers_a_label_and_records_the_fallback
    assert_mesh_to_label_fallback(:false, 'text3d_mesh_unavailable')
  end

  def test_empty_mesh_result_delivers_a_label_and_records_the_fallback
    assert_mesh_to_label_fallback(:empty, 'text3d_mesh_empty')
  end

  def test_mesh_exception_delivers_a_label_and_records_honest_provenance
    assert_mesh_to_label_fallback(:raise, 'text3d_generation_exception')
  end

  def test_false_result_after_creation_erases_only_partial_mesh_before_label
    assert_created_generation_failure_cleanup(:false_after_create, 'text3d_mesh_unavailable')
  end

  def test_generation_exception_after_creation_erases_only_partial_mesh_before_label
    assert_created_generation_failure_cleanup(:raise_after_create, 'text3d_generation_exception')
  end

  def assert_created_generation_failure_cleanup(mesh_result, reason)
    sentinel = TextFallbackEntity.new('Sentinel')
    builder = make_builder(true, [])
    entities = TextFallbackEntities.new(mesh_result, :success, sentinel: sentinel)

    delivered = builder.send(:place_mesh_text, entities, make_item, 0.0, 0.0, 'Text')

    assert delivered
    assert_equal 1, entities.labels.length
    assert_equal [sentinel], entities.entities
    assert_equal entities.generated.map(&:object_id).sort,
                 entities.erase_calls.flatten.map(&:object_id).sort
    assert_equal [
      { requested: :text3d, delivered: :labels, reason: reason, count: 1 }
    ], builder.text_fallbacks
  end

  def test_transform_exceptions_erase_created_mesh_before_label
    assert_transform_failures_cleanup(:raise)
  end

  def test_false_transform_returns_erase_created_mesh_before_label
    assert_transform_failures_cleanup(:false)
  end

  def assert_transform_failures_cleanup(failure_mode)
    {
      scaling: 'scale',
      translation: 'translation',
      rotation: 'rotation'
    }.each do |kind, reason_phase|
      sentinel = TextFallbackEntity.new('Sentinel')
      builder = make_builder(true, [])
      entities = TextFallbackEntities.new(
        :success,
        :success,
        sentinel: sentinel,
        transform_failures: { kind => failure_mode }
      )

      delivered = builder.send(:place_mesh_text, entities, make_item(45.0), 0.0, 0.0, 'Text')

      assert delivered, "#{kind} #{failure_mode} should deliver the cleaned Label fallback"
      assert_equal 1, entities.labels.length, "#{kind} #{failure_mode} must add one Label"
      assert_equal [sentinel], entities.entities, "#{kind} #{failure_mode} left partial mesh geometry"
      assert entities.transforms.all? { |args| !args[1..-1].any? { |e| e.equal?(sentinel) } },
             "#{kind} #{failure_mode} transformed a preexisting sentinel"
      assert_equal [
        {
          requested: :text3d,
          delivered: :labels,
          reason: "text3d_#{reason_phase}_transform_failed",
          count: 1
        }
      ], builder.text_fallbacks
    end
  end

  def test_cleanup_failures_never_overlay_a_label_and_are_truthful
    [:exception, :noop, :partial, :verification].each do |cleanup_failure|
      sentinel = TextFallbackEntity.new('Sentinel')
      builder = make_builder(true, [])
      entities = TextFallbackEntities.new(
        :success,
        :success,
        sentinel: sentinel,
        transform_failures: { scaling: :raise },
        cleanup_failure: cleanup_failure
      )

      delivered = builder.send(:place_mesh_text, entities, make_item(45.0), 0.0, 0.0, 'Text')

      refute delivered, "cleanup #{cleanup_failure} must route to the page terminal rung"
      assert_empty entities.labels, "cleanup #{cleanup_failure} overlaid a Label"
      assert_equal [
        {
          requested: :text3d,
          reason: 'text3d_scale_transform_failed_partial_cleanup_failed',
          count: 1
        }
      ], builder.text_delivery_failures
    end
  end

  def test_pre_generation_exception_still_falls_back_safely
    builder = make_builder(true, [])
    builder.define_singleton_method(:mesh_label_anchor_pdf) { |_item| raise 'forced anchor failure' }
    entities = TextFallbackEntities.new(:success, :success)

    delivered = builder.send(:place_mesh_text, entities, make_item, 0.0, 0.0, 'Text')

    assert delivered
    assert_empty entities.mesh_calls
    assert_equal 1, entities.labels.length
    assert_equal [
      {
        requested: :text3d,
        delivered: :labels,
        reason: 'text3d_pre_generation_exception',
        count: 1
      }
    ], builder.text_fallbacks
  end

  def test_late_entity_inspection_exception_cannot_overlay_a_label_on_native_mesh
    builder = make_builder(true, [])
    entities = TextFallbackEntities.new(:broken_typename, :success)

    delivered = builder.send(:place_mesh_text, entities, make_item(45.0), 0.0, 0.0, 'Text')

    assert delivered
    assert_empty entities.labels
    assert_equal 2, entities.entities.length
    assert_empty builder.text_fallbacks
  end

  def test_chained_geometry_mesh_failure_reports_the_original_requested_mode
    provenance = []
    builder = make_builder(true, provenance, :geometry)
    entities = TextFallbackEntities.new(:false, :success)

    builder.send(:place_mesh_text, entities, make_item, 0.0, 0.0, 'Text')

    assert_equal [
      {
        requested: :geometry,
        delivered: :labels,
        reason: 'text3d_mesh_unavailable',
        count: 1
      }
    ], builder.text_fallbacks
  end

  def test_both_native_text_apis_failing_is_exposed_for_the_page_raster_terminal
    provenance = []
    builder = make_builder(true, provenance)
    entities = TextFallbackEntities.new(:false, :nil)

    delivered = builder.send(:place_mesh_text, entities, make_item, 0.0, 0.0, 'Text')

    refute delivered
    assert_empty builder.text_fallbacks
    assert_equal [
      {
        requested: :text3d,
        reason: 'text3d_mesh_unavailable_labels_unavailable',
        count: 1
      }
    ], builder.text_delivery_failures
  end

  def test_unavailable_label_api_delivers_3d_text_and_records_honest_provenance
    provenance = []
    builder = make_builder(false, provenance)
    entities = TextFallbackEntities.new(:success, :nil)

    builder.send(:place_annotation_label, entities, make_item, 0.0, 0.0, 'Text')

    assert_equal 1, entities.mesh_calls.length
    assert_equal [
      { requested: :labels, delivered: :text3d, reason: 'add_text_unavailable', count: 1 }
    ], builder.text_fallbacks
    assert_equal 'native_3d_text', provenance.last[:created_entity_type]
  end
end
