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
  attr_reader :persistent_id

  @@next_persistent_id = 20_000

  BoundsPoint = Struct.new(:x, :y, :z)
  Bounds = Struct.new(:min, :max)

  def initialize(typename = 'Edge', broken_typename = false, width = 0.2)
    @@next_persistent_id += 1
    @persistent_id = @@next_persistent_id
    @typename = typename
    @broken_typename = broken_typename
    @bounds = Bounds.new(BoundsPoint.new(0.0, 0.0, 0.0),
                         BoundsPoint.new(width, 0.1, 0.0))
  end

  def typename
    raise 'forced late typename failure' if @broken_typename
    @typename
  end

  def bounds
    @bounds
  end
end

class StableMeshWrapper
  attr_reader :persistent_id

  def initialize(persistent_id)
    @persistent_id = persistent_id
  end
end

class RewrappedMeshCollection
  attr_reader :erased_ids

  def initialize(ids, erase_mode = :remove)
    @ids = ids.dup
    @erase_mode = erase_mode
    @erased_ids = []
  end

  def to_a
    @ids.map { |id| StableMeshWrapper.new(id) }
  end

  def erase_entities(*entities)
    ids = entities.flatten.map(&:persistent_id)
    @erased_ids.concat(ids)
    @ids.delete_if { |id| ids.include?(id) } if @erase_mode == :remove
    true
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
    @generated_width = options.key?(:generated_width) ?
      options[:generated_width] : 0.25
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
      @generated = [
        TextFallbackEntity.new('Edge', broken, @generated_width),
        TextFallbackEntity.new('Face', false, @generated_width)
      ]
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
    return Object.new if @label_result == :unstable

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

class TelemetryLayerManager
  def resolve(_name)
    Object.new
  end

  def match_pdf_layers
    false
  end

  def text_fallback_layer
    Object.new
  end
end

require 'bc_pdf_vector_importer/geometry_builder'

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

  def make_result_builder(item, entities, use_3d_text = true, requested_text_mode = :text3d)
    BlueCollarSystems::PDFVectorImporter::GeometryBuilder.new(
      nil, [], [item], [0, 0, 612, 792],
      import_text: true,
      use_3d_text: use_3d_text,
      requested_text_mode: requested_text_mode,
      group_per_page: false,
      target_entities: entities,
      layer_manager: TelemetryLayerManager.new,
      installed_font_families: ['Arial'],
      page_number: 7
    )
  end

  def telemetry_item(angle = 0.0)
    item = make_item(angle)
    item.source_span_id = 'span-telemetry-1'
    item.source_font_family = 'Arial'
    item.font_to_sketchup_letter_ratio = 1491.0 / 2048.0
    item.font_to_sketchup_letter_ratio_source = :known_arial_family
    item.trusted_text_matrix_x_scale = 1.0
    item
  end

  def force_verified_mesh_fit(builder)
    builder.define_singleton_method(:mesh_text_residual_x_scale) do |*_args|
      [0.9, :fitted, 'bbox_overflow_shrink', true]
    end
    builder
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

  def test_transform_exceptions_remove_unverified_native_text_without_changing_representation
    assert_transform_failures_fail_closed(:raise)
  end

  def test_rejected_residual_outlier_fails_closed_without_switching_representation
    sentinel = TextFallbackEntity.new('Sentinel')
    builder = make_builder(true, [])
    entities = TextFallbackEntities.new(
      :success, :success, sentinel: sentinel, generated_width: 1.0
    )

    delivered = builder.send(
      :place_mesh_text, entities, make_item(0.0), 0.0, 0.0, 'Text'
    )

    assert_equal false, delivered
    assert_empty entities.labels
    assert_equal [sentinel], entities.entities
    assert_equal [
      {
        requested: :text3d,
        reason: 'text3d_visual_fidelity_unverified_residual_below_0_50',
        count: 1,
        representation_fallback_allowed: false
      }
    ], builder.text_delivery_failures
    sample = builder.mesh_text_telemetry.last
    assert_operator sample[:residual_x], :<, 0.5
    assert_equal :failed_visual_verification, sample[:outcome]
    assert_equal :visual_verification, sample[:failure_phase]
    assert_equal :none, sample[:delivered_mode]
    assert_equal false, sample[:visual_fidelity_verified]
    assert_equal false, sample[:representation_fallback_allowed]
  end

  def test_mesh_delta_uses_stable_ids_across_rewrapped_preexisting_entities
    builder = make_builder(true, [])
    before = [StableMeshWrapper.new(1)]
    after = [StableMeshWrapper.new(1), StableMeshWrapper.new(2)]

    created = builder.send(:mesh_text_created_entities, before, after)

    assert_equal [2], created.map(&:persistent_id),
                 'rewrapped preexisting mesh entities must never become attempt-owned'
  end

  def test_rewrapped_mesh_cleanup_verifies_stable_id_absence
    builder = make_builder(true, [])
    created = [StableMeshWrapper.new(2)]

    removed = RewrappedMeshCollection.new([1, 2], :remove)
    assert_equal true,
                 builder.send(:erase_partial_mesh_entities, removed, created)
    assert_equal [2], removed.erased_ids
    assert_equal [1], removed.to_a.map(&:persistent_id)

    noop = RewrappedMeshCollection.new([1, 2], :noop)
    assert_equal false,
                 builder.send(:erase_partial_mesh_entities, noop, created),
                 'new wrappers must not make a no-op erase look verified'
  end

  def test_mesh_delta_rejects_duplicate_or_unreadable_stable_ids
    builder = make_builder(true, [])
    duplicate = [StableMeshWrapper.new(1), StableMeshWrapper.new(1)]
    unreadable = [Object.new]

    assert_raises(RuntimeError) do
      builder.send(:mesh_text_created_entities, [], duplicate)
    end
    assert_raises(RuntimeError) do
      builder.send(:mesh_text_created_entities, [], unreadable)
    end
  end

  def test_under_width_no_overflow_cannot_claim_visual_verification
    builder = make_result_builder(
      telemetry_item,
      TextFallbackEntities.new(:success, :success, generated_width: 0.2)
    )

    sample = builder.build[:mesh_text_telemetry].first

    assert_equal :skipped, sample[:fit_status]
    assert_equal 'no_overflow', sample[:fit_reason]
    assert_equal false, sample[:visual_fidelity_verified]
    assert_equal false, sample[:fit_measurement_verified]
    assert_equal :none, sample[:delivered_mode]
  end

  def test_missing_width_measurement_cannot_claim_visual_verification
    builder = make_result_builder(
      telemetry_item,
      TextFallbackEntities.new(:success, :success, generated_width: 0.0)
    )

    sample = builder.build[:mesh_text_telemetry].first

    assert_equal 'invalid_width', sample[:fit_reason]
    assert_equal false, sample[:fit_measurement_verified]
    assert_equal false, sample[:visual_fidelity_verified]
    assert_equal :none, sample[:delivered_mode]
  end

  def test_false_transform_returns_remove_unverified_native_text_without_changing_representation
    assert_transform_failures_fail_closed(:false)
  end

  def assert_transform_failures_fail_closed(failure_mode)
    {
      scaling: 'scale',
      translation: 'translation',
      rotation: 'rotation'
    }.each do |kind, reason_phase|
      sentinel = TextFallbackEntity.new('Sentinel')
      builder = make_builder(true, [])
      force_verified_mesh_fit(builder)
      entities = TextFallbackEntities.new(
        :success,
        :success,
        sentinel: sentinel,
        transform_failures: { kind => failure_mode }
      )

      delivered = builder.send(:place_mesh_text, entities, make_item(45.0), 0.0, 0.0, 'Text')

      refute delivered, "#{kind} #{failure_mode} must fail the native attempt"
      assert_empty entities.labels,
                   "#{kind} #{failure_mode} must not switch representation"
      assert_equal [sentinel], entities.entities,
                   "#{kind} #{failure_mode} left unverified native geometry behind"
      assert_equal entities.generated.map(&:object_id).sort,
                   entities.erase_calls.flatten.map(&:object_id).sort,
                   "#{kind} #{failure_mode} did not remove the failed native attempt"
      assert entities.transforms.all? { |args| !args[1..-1].any? { |e| e.equal?(sentinel) } },
             "#{kind} #{failure_mode} transformed a preexisting sentinel"
      assert_empty builder.text_fallbacks
      assert_equal [
        {
          requested: :text3d,
          reason: "text3d_#{reason_phase}_transform_failed",
          count: 1,
          representation_fallback_allowed: false
        }
      ], builder.text_delivery_failures
      sample = builder.mesh_text_telemetry.last
      assert_equal :none, sample[:delivered_mode]
      assert_equal reason_phase.to_sym, sample[:failure_phase]
      assert_equal "text3d_#{reason_phase}_transform_failed",
                   sample[:failure_reason]
      assert_equal false, sample[:visual_fidelity_verified]
      assert_equal :complete, sample[:cleanup_outcome]
      assert_equal false, sample[:representation_fallback_allowed]
    end
  end

  def test_cleanup_failures_never_overlay_a_label_and_are_truthful
    [:exception, :noop, :partial, :verification].each do |cleanup_failure|
      sentinel = TextFallbackEntity.new('Sentinel')
      builder = make_builder(true, [])
      entities = TextFallbackEntities.new(
        :false_after_create,
        :success,
        sentinel: sentinel,
        cleanup_failure: cleanup_failure
      )

      delivered = builder.send(:place_mesh_text, entities, make_item(2.0), 0.0, 0.0, 'Text')

      refute delivered, "cleanup #{cleanup_failure} must route to the page terminal rung"
      assert_empty entities.labels, "cleanup #{cleanup_failure} overlaid a Label"
      assert_equal [
        {
          requested: :text3d,
          reason: 'text3d_mesh_unavailable_partial_cleanup_failed',
          count: 1,
          representation_fallback_allowed: false
        }
      ], builder.text_delivery_failures
    end
  end

  def test_pre_generation_anchor_exception_fails_closed_without_changing_representation
    builder = make_builder(true, [])
    builder.define_singleton_method(:mesh_label_anchor_pdf) { |_item| raise 'forced anchor failure' }
    entities = TextFallbackEntities.new(:success, :success)

    delivered = builder.send(:place_mesh_text, entities, make_item, 0.0, 0.0, 'Text')

    refute delivered
    assert_empty entities.mesh_calls
    assert_empty entities.labels
    assert_empty builder.text_fallbacks
    assert_equal [
      {
        requested: :text3d,
        reason: 'text3d_pre_generation_exception',
        count: 1,
        representation_fallback_allowed: false
      }
    ], builder.text_delivery_failures
    sample = builder.mesh_text_telemetry.last
    assert_equal :none, sample[:delivered_mode]
    assert_equal :failed_pre_generation, sample[:outcome]
    assert_equal :pre_generation, sample[:failure_phase]
    assert_equal :not_required, sample[:cleanup_outcome]
    assert_equal false, sample[:representation_fallback_allowed]
  end

  def test_late_entity_inspection_exception_cannot_overlay_a_label_on_native_mesh
    builder = make_builder(true, [])
    force_verified_mesh_fit(builder)
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

  def test_label_without_stable_entity_identity_is_never_certified
    provenance = []
    builder = make_builder(false, provenance, :labels)
    entities = TextFallbackEntities.new(:success, :unstable)

    delivered = builder.send(
      :place_annotation_label, entities, make_item, 0.0, 0.0, 'Text'
    )

    assert_equal false, delivered
    assert_empty provenance
    assert_equal [
      {
        requested: :labels,
        reason: 'label_resulting_entity_identity_unverified',
        count: 1,
        representation_fallback_allowed: false
      }
    ], builder.text_delivery_failures
  end

  def test_build_result_records_exactly_one_truthful_sample_for_every_mesh_attempt
    scenarios = [
      {
        name: 'success',
        entities: TextFallbackEntities.new(:success, :success),
        outcome: :complete,
        failure_phase: nil,
        delivered_mode: :text3d,
        cleanup_outcome: :not_required
      },
      {
        name: 'generation unavailable',
        entities: TextFallbackEntities.new(:false, :success),
        outcome: :failed_generation,
        failure_phase: :generation,
        delivered_mode: :labels,
        cleanup_outcome: :not_required
      },
      {
        name: 'generation empty',
        entities: TextFallbackEntities.new(:empty, :success),
        outcome: :failed_generation,
        failure_phase: :generation,
        delivered_mode: :labels,
        cleanup_outcome: :not_required
      },
      {
        name: 'generation exception',
        entities: TextFallbackEntities.new(:raise, :success),
        outcome: :failed_generation,
        failure_phase: :generation,
        delivered_mode: :labels,
        cleanup_outcome: :not_required
      },
      {
        name: 'generation exception after creation',
        entities: TextFallbackEntities.new(:raise_after_create, :success),
        outcome: :failed_generation,
        failure_phase: :generation,
        delivered_mode: :labels,
        cleanup_outcome: :complete
      },
      {
        name: 'scale false',
        entities: TextFallbackEntities.new(
          :success, :success, transform_failures: { scaling: :false }
        ),
        outcome: :failed_scale,
        failure_phase: :scale,
        delivered_mode: :none,
        cleanup_outcome: :complete
      },
      {
        name: 'scale exception',
        entities: TextFallbackEntities.new(
          :success, :success, transform_failures: { scaling: :raise }
        ),
        outcome: :failed_scale,
        failure_phase: :scale,
        delivered_mode: :none,
        cleanup_outcome: :complete
      },
      {
        name: 'translation false',
        entities: TextFallbackEntities.new(
          :success, :success, transform_failures: { translation: :false }
        ),
        outcome: :failed_translation,
        failure_phase: :translation,
        delivered_mode: :none,
        cleanup_outcome: :complete
      },
      {
        name: 'translation exception',
        entities: TextFallbackEntities.new(
          :success, :success, transform_failures: { translation: :raise }
        ),
        outcome: :failed_translation,
        failure_phase: :translation,
        delivered_mode: :none,
        cleanup_outcome: :complete
      },
      {
        name: 'rotation false',
        entities: TextFallbackEntities.new(
          :success, :success, transform_failures: { rotation: :false }
        ),
        outcome: :failed_rotation,
        failure_phase: :rotation,
        delivered_mode: :none,
        cleanup_outcome: :complete
      },
      {
        name: 'rotation exception',
        entities: TextFallbackEntities.new(
          :success, :success, transform_failures: { rotation: :raise }
        ),
        outcome: :failed_rotation,
        failure_phase: :rotation,
        delivered_mode: :none,
        cleanup_outcome: :complete
      },
      {
        name: 'cleanup exception',
        entities: TextFallbackEntities.new(
          :false_after_create,
          :success,
          cleanup_failure: :exception
        ),
        outcome: :failed_cleanup,
        failure_phase: :cleanup,
        delivered_mode: :none,
        cleanup_outcome: :failed
      },
      {
        name: 'cleanup no-op',
        entities: TextFallbackEntities.new(
          :false_after_create,
          :success,
          cleanup_failure: :noop
        ),
        outcome: :failed_cleanup,
        failure_phase: :cleanup,
        delivered_mode: :none,
        cleanup_outcome: :failed
      },
      {
        name: 'cleanup partial',
        entities: TextFallbackEntities.new(
          :false_after_create,
          :success,
          cleanup_failure: :partial
        ),
        outcome: :failed_cleanup,
        failure_phase: :cleanup,
        delivered_mode: :none,
        cleanup_outcome: :failed
      },
      {
        name: 'cleanup verification exception',
        entities: TextFallbackEntities.new(
          :false_after_create,
          :success,
          cleanup_failure: :verification
        ),
        outcome: :failed_cleanup,
        failure_phase: :cleanup,
        delivered_mode: :none,
        cleanup_outcome: :failed
      }
    ]

    scenarios.each do |scenario|
      rotation_case = scenario[:failure_phase] == :rotation
      result_builder = make_result_builder(
        telemetry_item(rotation_case ? 45.0 : 0.0), scenario[:entities]
      )
      force_verified_mesh_fit(result_builder) if rotation_case
      result = result_builder.build
      samples = result[:mesh_text_telemetry]

      assert_equal 1, Array(samples).length, "#{scenario[:name]} duplicated or lost its attempt"
      sample = samples.first
      assert_equal 7, sample[:page], scenario[:name]
      assert_equal 'span-telemetry-1', sample[:source_span_id], scenario[:name]
      assert_equal :text3d, sample[:requested_mode], scenario[:name]
      assert_equal scenario[:outcome], sample[:outcome], scenario[:name]
      if scenario[:failure_phase].nil?
        assert_nil sample[:failure_phase], scenario[:name]
      else
        assert_equal scenario[:failure_phase], sample[:failure_phase], scenario[:name]
      end
      assert_equal scenario[:delivered_mode], sample[:delivered_mode], scenario[:name]
      assert_equal scenario[:cleanup_outcome], sample[:cleanup_outcome], scenario[:name]
      if scenario[:delivered_mode] == :text3d
        assert_equal 'Arial', sample[:delivered_font], scenario[:name]
      else
        assert_nil sample[:delivered_font], scenario[:name]
      end
    end
  end

  def test_pre_generation_failure_and_labels_to_3d_rescue_each_record_one_attempt
    pre_item = telemetry_item
    pre_entities = TextFallbackEntities.new(:success, :success)
    pre_builder = make_result_builder(pre_item, pre_entities)
    pre_builder.define_singleton_method(:mesh_label_anchor_pdf) do |_item|
      raise 'forced anchor failure'
    end
    pre_sample = pre_builder.build[:mesh_text_telemetry].first
    assert_equal :failed_pre_generation, pre_sample[:outcome]
    assert_equal :pre_generation, pre_sample[:failure_phase]
    assert_equal :none, pre_sample[:delivered_mode]
    assert_nil pre_sample[:delivered_font]
    assert_equal false, pre_sample[:representation_fallback_allowed]

    rescue_entities = TextFallbackEntities.new(:success, :nil)
    rescue_result = make_result_builder(
      telemetry_item, rescue_entities, false, :labels
    ).build
    assert_equal 1, rescue_result[:mesh_text_telemetry].length
    rescue_sample = rescue_result[:mesh_text_telemetry].first
    assert_equal :fallback_text3d, rescue_sample[:outcome]
    assert_equal :labels, rescue_sample[:requested_mode]
    assert_equal :text3d, rescue_sample[:delivered_mode]
    assert_equal 'add_text_unavailable', rescue_sample[:upstream_fallback_reason]
    assert_equal 'Arial', rescue_sample[:delivered_font]
  end

  def test_telemetry_storage_failure_is_counted_without_breaking_text_delivery
    exploding_ledger = Object.new
    def exploding_ledger.<<(_sample)
      raise 'forced telemetry storage failure'
    end

    builder = make_result_builder(
      telemetry_item, TextFallbackEntities.new(:success, :success)
    )
    builder.instance_variable_set(:@mesh_text_telemetry, exploding_ledger)

    builder.send(
      :place_mesh_text,
      builder.instance_variable_get(:@target_entities),
      telemetry_item,
      0.0,
      0.0,
      'Text'
    )

    assert_equal 1, builder.mesh_text_telemetry_record_failure_count
  end

  def test_failed_3d_and_labels_rungs_preserve_ordered_attempt_history
    result = make_result_builder(
      telemetry_item,
      TextFallbackEntities.new(:false, :nil)
    ).build
    sample = result[:mesh_text_telemetry].first
    history = sample[:attempt_history]

    assert_equal [:text3d, :labels], history.map { |entry| entry[:mode] }
    assert_equal :failed_generation, history[0][:outcome]
    assert_equal 'text3d_mesh_unavailable', history[0][:reason]
    assert_equal :failed, history[1][:outcome]
    assert_equal 'text3d_mesh_unavailable_labels_unavailable',
                 history[1][:reason]
    assert_equal :none, sample[:delivered_mode]
  end

  def test_height_metric_fallback_records_reason_on_affected_attempt
    ratio = Object.new
    def ratio.to_f
      raise RangeError, 'forced metric conversion failure'
    end

    builder = make_result_builder(
      telemetry_item,
      TextFallbackEntities.new(:success, :success)
    )
    builder.define_singleton_method(:mesh_text_font_profile) do |_item|
      {
        family: 'Arial', bold: false, italic: false,
        letter_height_ratio: ratio,
        metric_source: :forced_metric,
        substitution_reason: nil
      }
    end

    result = builder.build
    sample = result[:mesh_text_telemetry].first
    assert_equal 1, result[:text_height_fallback_count]
    assert_match(/RangeError.*forced metric conversion failure/,
                 sample[:height_fallback_reason])
    assert_equal false, sample[:source_height_verified]
    assert_equal false, sample[:visual_fidelity_verified]
    assert_equal :none, sample[:delivered_mode],
                 'minimum-height fallback is not visual delivery proof'
    assert_equal 'text3d_source_height_unverified', sample[:failure_reason]
  end

  def test_nonfinite_and_nonpositive_height_metrics_use_the_minimum_without_changing_representation
    [0.0, -1.0, Float::NAN, Float::INFINITY].each do |ratio|
      builder = make_result_builder(
        telemetry_item,
        TextFallbackEntities.new(:success, :success)
      )
      builder.define_singleton_method(:mesh_text_font_profile) do |_item|
        {
          family: 'Arial', bold: false, italic: false,
          letter_height_ratio: ratio,
          metric_source: :forced_invalid_metric,
          substitution_reason: nil
        }
      end

      result = builder.build
      sample = result[:mesh_text_telemetry].first
      assert_equal 1, result[:text_height_fallback_count], ratio.inspect
      assert_match(/invalid.*height/i, sample[:height_fallback_reason], ratio.inspect)
      assert_equal false, sample[:source_height_verified], ratio.inspect
      assert_equal false, sample[:visual_fidelity_verified], ratio.inspect
      assert_equal :none, sample[:delivered_mode], ratio.inspect
      assert_equal :failed_visual_verification, sample[:outcome], ratio.inspect
    end
  end

  def test_attempt_ledger_initialization_failure_is_counted
    item = telemetry_item
    calls = 0
    item.define_singleton_method(:source_font_family) do
      calls += 1
      raise 'forced attempt initialization failure' if calls == 1
      'Arial'
    end
    result = make_result_builder(
      item,
      TextFallbackEntities.new(:success, :success)
    ).build

    assert_equal 1,
                 result[:mesh_text_telemetry_initialization_failure_count]
    assert_equal 1, result[:mesh_text_telemetry].length
  end
end
