#!/usr/bin/env ruby
# TEXTMODE-1 production-path lock: renderer statistics emitted by main.rb must
# leave the report with either the requested text mode delivered or an honest
# requested/delivered/reason fallback record.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/main'

class AtomicRasterEntity
  attr_reader :persistent_id

  def initialize(persistent_id)
    @persistent_id = persistent_id
  end
end

class ExplodingPersistentIdEntity
  def persistent_id
    raise 'forced stable identity failure'
  end
end

class RewrappedAtomicEntities
  attr_reader :erased_ids

  def initialize(ids)
    @ids = ids.dup
    @erased_ids = []
  end

  def to_a
    @ids.map { |id| AtomicRasterEntity.new(id) }
  end

  def add(entity)
    @ids << entity.persistent_id
    entity
  end

  def erase_entities(*entities)
    ids = entities.flatten.map(&:persistent_id)
    @erased_ids.concat(ids)
    @ids.delete_if { |id| ids.include?(id) }
    true
  end
end

class AtomicRasterEntities
  attr_reader :erased

  def initialize(items = [], vector_failure = nil, raster_failure = nil)
    @items = items.dup
    @vector_failure = vector_failure
    @raster_failure = raster_failure
    @vectors = items.dup
    @erased = []
  end

  def to_a
    @items.dup
  end

  def add(entity)
    @items << entity
    entity
  end

  def erase_entities(*items)
    doomed = items.flatten
    vector_cleanup = doomed.any? do |item|
      @vectors.any? { |vector| vector.equal?(item) }
    end
    if vector_cleanup
      raise 'forced vector erase failure' if @vector_failure == :raise
      return true if @vector_failure == :noop
      if @vector_failure == :partial
        removable = doomed[0, 1]
        @items.delete_if do |item|
          removable.any? { |candidate| candidate.equal?(item) }
        end
        @erased.concat(removable)
        return true
      end
    elsif @raster_failure
      raise 'forced raster erase failure' if @raster_failure == :raise
      return true if @raster_failure == :noop
    end

    @items.delete_if do |item|
      doomed.any? { |candidate| candidate.equal?(item) }
    end
    @erased.concat(doomed)
    true
  end
end

class AtomicPageGroup
  attr_reader :hidden

  def initialize(mode = :success)
    @mode = mode
    @hidden = false
  end

  def hidden=(value)
    return if @mode == :noop && value
    @hidden = value
    raise 'forced group hide failure' if @mode == :raise_after_set && value
  end
end

class ReadOnlyAtomicPageGroup
  def hidden
    false
  end
end

class SnapshotOnlyAtomicEntities
  def initialize(items)
    @items = items
  end

  def to_a
    @items.dup
  end
end

class FirstSnapshotFailureAtomicEntities < AtomicRasterEntities
  def initialize(items = [])
    super(items)
    @snapshot_calls = 0
  end

  def to_a
    @snapshot_calls += 1
    raise 'forced initial active-entity snapshot failure' if @snapshot_calls == 1
    super
  end
end

class TextModeOneInvariantTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter

  def terminal_stats(extra = {})
    {
      text_renderers: [],
      mesh_text_telemetry: [],
      source_text_span_ids: ['text_span:1:0']
    }.merge(extra)
  end

  def report_for(renderers)
    IMP::QAReport.build_from_stats('x.pdf', {}, {
      pages: 1,
      primitives: 1,
      edges: 1,
      text: 1,
      layers: [],
      elapsed_seconds: 0.1,
      text_renderers: renderers
    })
  end

  def assert_requested_equals_delivered_or_reported(report, requested, delivered)
    return assert_equal requested, delivered if requested == delivered

    text = report[:fallback][:text]
    refute_nil text, 'a substituted text mode must be loud in fallback.text'
    assert_equal requested, text[:requested]
    assert_equal delivered, text[:delivered]
    refute_empty text[:reason].to_s
  end

  def test_main_merge_emits_a_reported_3d_text_to_labels_substitution
    stats = { text_renderers: [] }
    IMP.merge_text_mode_fallbacks!(stats, 1, [
      {
        requested: :text3d,
        delivered: :labels,
        reason: 'text3d_mesh_unavailable',
        count: 1
      }
    ])

    report = report_for(stats[:text_renderers])
    assert_requested_equals_delivered_or_reported(report, '3d_text', 'labels')
    assert_includes report[:extra][:diagnostics][:signals], 'text_mode_fallback'
  end

  def test_main_merge_coalesces_matching_span_fallbacks_into_one_report_record
    stats = { text_renderers: [] }
    IMP.merge_text_mode_fallbacks!(stats, 1, [
      { requested: :text3d, delivered: :labels, reason: 'text3d_mesh_unavailable', count: 1 },
      { requested: :text3d, delivered: :labels, reason: 'text3d_mesh_unavailable', count: 1 }
    ])

    assert_equal 1, stats[:text_renderers].length
    assert_equal 2, stats[:text_renderers].first[:count]
    assert_equal 2, report_for(stats[:text_renderers])[:fallback][:text][:count]
  end

  def test_terminal_text_failure_promotes_the_page_to_raster_and_reports_it
    raster_calls = []
    raster_entity = AtomicRasterEntity.new(501)
    active_entities = AtomicRasterEntities.new
    model = Struct.new(:active_entities).new(active_entities)
    original = IMP.method(:import_page_as_raster)
    IMP.define_singleton_method(:import_page_as_raster) do |*args|
      raster_calls << args
      args[0].active_entities.add(raster_entity)
      true
    end

    page_group = AtomicPageGroup.new
    stats = {
      source_text_span_ids: ['text_span:1:0'],
      text_renderers: [
        {
          page: 1,
          renderer: :labels,
          mode: :labels,
          requested_mode: :text3d,
          delivered_mode: :labels,
          degraded: true,
          reason: 'text3d_mesh_unavailable',
          count: 1
        }
      ],
      mesh_text_telemetry: [
        {
          page: 1, source_span_id: 'text_span:1:0', requested_mode: :text3d,
          delivered_mode: :none, outcome: :failed_cleanup,
          failure_phase: :cleanup, cleanup_outcome: :failed,
          failure_reason: 'text3d_mesh_unavailable',
          sketchup_letter_height_in: 0.1,
          attempt_history: [
            { mode: :text3d, outcome: :failed_generation,
              reason: 'text3d_mesh_unavailable' },
            { mode: :labels, outcome: :failed,
              reason: 'text3d_mesh_unavailable_labels_unavailable' }
          ]
        },
        {
          page: 2, source_span_id: 'span-other-page', requested_mode: :text3d,
          delivered_mode: :text3d, outcome: :complete,
          sketchup_letter_height_in: 0.2
        }
      ],
      text_height_samples: [0.1, 0.2],
      text_height_sample_pages: [1, 2],
      text_font_substitutions: [
        { page: 1, requested_font: 'RomanT', delivered_font: 'Arial' }
      ]
    }
    failures = [
      {
        requested: :text3d,
        reason: 'text3d_mesh_unavailable_labels_unavailable',
        count: 1
      }
    ]
    begin
      promoted = IMP.promote_text_delivery_failures_to_raster!(
        model, 'x.pdf', 1, [0, 0, 612, 792], {}, Time.now, 0.0,
        [0, 0, 612, 792], page_group, :text3d, stats, failures
      )
      assert promoted
      assert_equal true, page_group.hidden
      assert_equal 1, raster_calls.length
      raster_attempt = stats[:mesh_text_telemetry].first
      assert_equal true, raster_attempt[:superseded_by_raster]
      assert_equal :raster, raster_attempt[:delivered_mode]
      assert_equal :failed_cleanup, raster_attempt[:outcome],
                   'the original failure outcome must remain diagnosable'
      assert_equal 'text3d_mesh_unavailable', raster_attempt[:failure_reason]
      assert_equal [:text3d, :labels, :raster],
                   raster_attempt[:attempt_history].map { |entry| entry[:mode] }
      assert_equal 'text3d_mesh_unavailable_labels_unavailable',
                   raster_attempt[:labels_failure_reason]
      assert_equal 'text3d_mesh_unavailable_labels_unavailable',
                   raster_attempt[:terminal_reason]
      assert_equal :verified, raster_attempt[:terminal_cleanup_outcome]
      assert_equal ['persistent_id:501'], raster_attempt[:resulting_entity_ids]
      refute stats[:mesh_text_telemetry][1][:superseded_by_raster],
             'another page telemetry must not be mutated'
      assert_equal [0.2], stats[:text_height_samples],
                   'hidden page meshes are not delivered legacy height samples'
      assert_equal [2], stats[:text_height_sample_pages]
      assert_equal true, stats[:text_font_substitutions].first[:superseded_by_raster]
      report = report_for(stats[:text_renderers])
      assert_requested_equals_delivered_or_reported(report, '3d_text', 'raster')
      assert_equal 1, stats[:text_renderers].length
    ensure
      IMP.define_singleton_method(:import_page_as_raster, original)
    end
  end

  def test_terminal_raster_erases_page_vectors_when_grouping_is_disabled
    raster_calls = []
    vector_entity = AtomicRasterEntity.new(600)
    raster_entity = AtomicRasterEntity.new(601)
    entities = AtomicRasterEntities.new([vector_entity])
    model = Struct.new(:active_entities).new(entities)
    original = IMP.method(:import_page_as_raster)
    IMP.define_singleton_method(:import_page_as_raster) do |*args|
      raster_calls << args
      args[0].active_entities.add(raster_entity)
      true
    end
    stats = terminal_stats
    failures = [{ requested: :labels, reason: 'text_native_api_unavailable', count: 1 }]
    begin
      promoted = IMP.promote_text_delivery_failures_to_raster!(
        model, 'x.pdf', 1, [0, 0, 612, 792], {}, Time.now, 0.0,
        [0, 0, 612, 792], nil, :labels, stats, failures, [vector_entity]
      )
      assert promoted
      assert_equal [vector_entity], entities.erased
      assert_equal 1, raster_calls.length
    ensure
      IMP.define_singleton_method(:import_page_as_raster, original)
    end
  end

  def test_terminal_raster_refuses_missing_canonical_source_id_ledger
    entities = AtomicRasterEntities.new
    model = Struct.new(:active_entities).new(entities)
    stats = { text_renderers: [], mesh_text_telemetry: [] }
    failures = [
      { requested: :labels, reason: 'native_text_failed', count: 1 }
    ]
    original = IMP.method(:import_page_as_raster)
    IMP.define_singleton_method(:import_page_as_raster) do |*_args|
      raise 'raster must not run without canonical source IDs'
    end

    begin
      promoted = IMP.promote_text_delivery_failures_to_raster!(
        model, 'x.pdf', 1, [0, 0, 612, 792], {}, Time.now, 0.0,
        [0, 0, 612, 792], AtomicPageGroup.new, :labels, stats, failures
      )
      assert_equal false, promoted
      assert_equal 'page_text_source_identity_unavailable',
                   stats[:terminal_cleanup_failures].first[:reason]
    ensure
      IMP.define_singleton_method(:import_page_as_raster, original)
    end
  end

  def test_unknown_loose_page_snapshot_never_erases_preexisting_entities
    preexisting = AtomicRasterEntity.new(590)
    page_vector = AtomicRasterEntity.new(591)
    raster_entity = AtomicRasterEntity.new(592)
    entities = FirstSnapshotFailureAtomicEntities.new([preexisting])
    model = Struct.new(:active_entities).new(entities)
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 0, source_text_count: 1,
      source_text_span_ids: ['text_span:1:0'],
      text_mode: :text3d, layers: [], text_renderers: [],
      mesh_text_telemetry: [],
      import_report_publication_status: :published,
      import_report_path: 'snapshot_failure_import_report.json'
    }
    failures = [
      {
        requested: :text3d,
        reason: 'text3d_visual_fidelity_unverified',
        count: 1
      }
    ]
    raster_calls = []
    original = IMP.method(:import_page_as_raster)
    IMP.define_singleton_method(:import_page_as_raster) do |*args|
      raster_calls << args
      args[0].active_entities.add(raster_entity)
      true
    end

    begin
      before = IMP.active_entity_snapshot(model)
      assert_nil before, 'snapshot exceptions must retain an unknown sentinel'
      entities.add(page_vector)
      page_entities = IMP.page_entities_created_since(model, before)
      assert_nil page_entities,
                 'an unknown before-snapshot must never classify all active entities as page-owned'

      promoted = IMP.promote_text_delivery_failures_to_raster!(
        model, 'x.pdf', 1, [0, 0, 612, 792], {}, Time.now, 0.0,
        [0, 0, 612, 792], nil, :text3d, stats, failures, page_entities
      )

      assert_equal false, promoted
      assert_empty raster_calls, 'raster promotion must stop before mutating an unproven loose page'
      assert_includes entities.to_a, preexisting
      assert_includes entities.to_a, page_vector
      assert_empty entities.erased
      assert_equal 'loose_vector_provenance_unavailable',
                   stats[:terminal_cleanup_failures].first[:reason]
      assert_equal [1], stats[:failed_pages].map { |failure| failure[:page] }

      report = IMP::QAReport.build_from_stats('x.pdf', {}, stats)
      assert_equal false, report[:extra][:import_contract_ready][:ready]
      assert_equal false,
                   report[:extra][:import_contract_ready][:checks][:no_failed_pages]
    ensure
      IMP.define_singleton_method(:import_page_as_raster, original)
    end
  end

  def test_page_entity_delta_uses_stable_ids_across_rewrapped_entities
    before = [AtomicRasterEntity.new(1)]
    after = [AtomicRasterEntity.new(1), AtomicRasterEntity.new(2)]

    delta = IMP.entity_list_difference(after, before)

    refute_nil delta
    assert_equal [2], delta.map(&:persistent_id),
                 'a rewrapped preexisting entity must never become page-owned'
  end

  def test_page_entity_delta_keeps_comparison_failure_unknown
    delta = IMP.entity_list_difference(
      [ExplodingPersistentIdEntity.new], [AtomicRasterEntity.new(1)]
    )

    assert_nil delta,
               'stable identity failure must stay unknown instead of becoming known-empty'
  end

  def test_rewrapped_loose_page_cleanup_erases_only_the_new_stable_id
    entities = RewrappedAtomicEntities.new([1])
    model = Struct.new(:active_entities).new(entities)
    before = IMP.active_entity_snapshot(model)
    entities.add(AtomicRasterEntity.new(2))
    page_entities = IMP.page_entities_created_since(model, before)
    raster_entity = AtomicRasterEntity.new(3)
    original = IMP.method(:import_page_as_raster)
    IMP.define_singleton_method(:import_page_as_raster) do |*args|
      args[0].active_entities.add(raster_entity)
      true
    end
    item = Struct.new(:source_span_id).new('text_span:1:0')
    stats = {
      text_renderers: [], mesh_text_telemetry: [],
      source_text_span_ids: ['text_span:1:0']
    }
    failures = [
      { requested: :labels, reason: 'text_native_api_unavailable', count: 1 }
    ]

    begin
      promoted = IMP.promote_text_delivery_failures_to_raster!(
        model, 'x.pdf', 1, [0, 0, 612, 792], {}, Time.now, 0.0,
        [0, 0, 612, 792], nil, :labels, stats, failures, page_entities
      )
      assert_equal true, promoted
      assert_equal [2], entities.erased_ids
      assert_equal [1, 3], entities.to_a.map(&:persistent_id).sort
    ensure
      IMP.define_singleton_method(:import_page_as_raster, original)
    end
  end

  def test_terminal_raster_rolls_back_when_page_group_hide_fails
    [:raise_after_set, :noop].each_with_index do |mode, index|
      raster_entity = AtomicRasterEntity.new(701 + index)
      entities = AtomicRasterEntities.new
      model = Struct.new(:active_entities).new(entities)
      page_group = AtomicPageGroup.new(mode)
      stats = terminal_stats
      failures = [
        { requested: :text3d,
          reason: 'text3d_mesh_unavailable_labels_unavailable', count: 1 }
      ]
      original = IMP.method(:import_page_as_raster)
      IMP.define_singleton_method(:import_page_as_raster) do |*args|
        args[0].active_entities.add(raster_entity)
        true
      end

      begin
        promoted = IMP.promote_text_delivery_failures_to_raster!(
          model, 'x.pdf', 1, [0, 0, 612, 792], {}, Time.now, 0.0,
          [0, 0, 612, 792], page_group, :text3d, stats, failures
        )
        assert_equal false, promoted, mode
        refute_includes entities.to_a, raster_entity,
                        "#{mode}: new raster must be rolled back after hide failure"
        assert_equal false, page_group.hidden,
                     "#{mode}: prior group visibility must be restored"
        assert_equal [1], stats[:failed_pages].map { |failure| failure[:page] }, mode
        assert_equal 1, stats[:terminal_cleanup_failures].length, mode
      ensure
        IMP.define_singleton_method(:import_page_as_raster, original)
      end
    end
  end

  def test_terminal_raster_rolls_back_when_loose_vector_cleanup_is_not_verified
    [:raise, :noop, :partial].each_with_index do |mode, index|
      vectors = [
        AtomicRasterEntity.new(780 + index * 2),
        AtomicRasterEntity.new(781 + index * 2)
      ]
      raster_entity = AtomicRasterEntity.new(800 + index)
      entities = AtomicRasterEntities.new(vectors, mode)
      model = Struct.new(:active_entities).new(entities)
      stats = terminal_stats
      failures = [
        { requested: :labels,
          reason: 'add_text_unavailable_text3d_unavailable', count: 1 }
      ]
      original = IMP.method(:import_page_as_raster)
      IMP.define_singleton_method(:import_page_as_raster) do |*args|
        args[0].active_entities.add(raster_entity)
        true
      end

      begin
        invoke = proc do
          IMP.promote_text_delivery_failures_to_raster!(
            model, 'x.pdf', 1, [0, 0, 612, 792], {}, Time.now, 0.0,
            [0, 0, 612, 792], nil, :labels, stats, failures, vectors
          )
        end
        if mode == :partial
          assert_raises(IMP::TerminalRasterAtomicityError, mode.to_s, &invoke)
        else
          assert_equal false, invoke.call, mode
        end
        refute_includes entities.to_a, raster_entity,
                        "#{mode}: new raster must be rolled back"
        assert_equal [1], stats[:failed_pages].map { |failure| failure[:page] }, mode
        assert_equal 1, stats[:terminal_cleanup_failures].length, mode
      ensure
        IMP.define_singleton_method(:import_page_as_raster, original)
      end
    end
  end

  def test_terminal_raster_rolls_back_partial_image_when_raster_helper_returns_false
    vector = AtomicRasterEntity.new(900)
    raster = AtomicRasterEntity.new(901)
    entities = AtomicRasterEntities.new([vector])
    model = Struct.new(:active_entities).new(entities)
    stats = terminal_stats
    failures = [
      { requested: :text3d,
        reason: 'text3d_mesh_unavailable_labels_unavailable', count: 1 }
    ]
    original = IMP.method(:import_page_as_raster)
    IMP.define_singleton_method(:import_page_as_raster) do |*args|
      args[0].active_entities.add(raster)
      false
    end

    begin
      promoted = IMP.promote_text_delivery_failures_to_raster!(
        model, 'x.pdf', 1, [0, 0, 612, 792], {}, Time.now, 0.0,
        [0, 0, 612, 792], nil, :text3d, stats, failures, [vector]
      )
      assert_equal false, promoted
      assert_includes entities.to_a, vector
      refute_includes entities.to_a, raster,
                      'partially created raster must be rolled back'
      assert_equal 'raster_creation_failed_after_partial_creation',
                   stats[:terminal_cleanup_failures].first[:reason]
      assert_equal true,
                   stats[:terminal_cleanup_failures].first[:raster_rollback_verified]
    ensure
      IMP.define_singleton_method(:import_page_as_raster, original)
    end
  end

  def test_unverified_native_geometry_cannot_be_promoted_to_another_representation
    entities = AtomicRasterEntities.new
    model = Struct.new(:active_entities).new(entities)
    stats = terminal_stats
    failures = [
      {
        requested: :text3d,
        reason: 'text3d_scale_transform_failed',
        count: 1,
        representation_fallback_allowed: false
      }
    ]
    original = IMP.method(:import_page_as_raster)
    IMP.define_singleton_method(:import_page_as_raster) do |*_args|
      raise 'raster must not be attempted'
    end

    begin
      promoted = IMP.promote_text_delivery_failures_to_raster!(
        model, 'x.pdf', 1, [0, 0, 612, 792], {}, Time.now, 0.0,
        [0, 0, 612, 792], nil, :text3d, stats, failures
      )
      assert_equal false, promoted
      assert_equal 'representation_fallback_disallowed',
                   stats[:terminal_cleanup_failures].first[:reason]
    ensure
      IMP.define_singleton_method(:import_page_as_raster, original)
    end
  end

  def test_terminal_raster_records_failure_when_group_cannot_be_hidden
    entities = AtomicRasterEntities.new
    model = Struct.new(:active_entities).new(entities)
    stats = terminal_stats
    failures = [{ requested: :text3d, reason: 'native_text_failed', count: 1 }]

    promoted = IMP.promote_text_delivery_failures_to_raster!(
      model, 'x.pdf', 1, [0, 0, 612, 792], {}, Time.now, 0.0,
      [0, 0, 612, 792], ReadOnlyAtomicPageGroup.new, :text3d,
      stats, failures
    )

    assert_equal false, promoted
    assert_equal 'page_group_hide_unavailable',
                 stats[:terminal_cleanup_failures].first[:reason]
    assert_equal [1], stats[:failed_pages].map { |failure| failure[:page] }
  end

  def test_terminal_raster_records_failure_when_loose_vectors_cannot_be_erased
    vector = AtomicRasterEntity.new(950)
    entities = SnapshotOnlyAtomicEntities.new([vector])
    model = Struct.new(:active_entities).new(entities)
    stats = terminal_stats
    failures = [{ requested: :labels, reason: 'native_text_failed', count: 1 }]

    promoted = IMP.promote_text_delivery_failures_to_raster!(
      model, 'x.pdf', 1, [0, 0, 612, 792], {}, Time.now, 0.0,
      [0, 0, 612, 792], nil, :labels, stats, failures, [vector]
    )

    assert_equal false, promoted
    assert_equal 'loose_vector_cleanup_unavailable',
                 stats[:terminal_cleanup_failures].first[:reason]
    assert_equal [1], stats[:failed_pages].map { |failure| failure[:page] }
  end

  def test_unrollbackable_partial_raster_raises_atomicity_error
    raster = AtomicRasterEntity.new(902)
    entities = AtomicRasterEntities.new([], nil, :noop)
    model = Struct.new(:active_entities).new(entities)
    stats = terminal_stats
    failures = [
      { requested: :text3d,
        reason: 'text3d_mesh_unavailable_labels_unavailable', count: 1 }
    ]
    original = IMP.method(:import_page_as_raster)
    IMP.define_singleton_method(:import_page_as_raster) do |*args|
      args[0].active_entities.add(raster)
      false
    end

    begin
      error = assert_raises(IMP::TerminalRasterAtomicityError) do
        IMP.promote_text_delivery_failures_to_raster!(
          model, 'x.pdf', 1, [0, 0, 612, 792], {}, Time.now, 0.0,
          [0, 0, 612, 792], nil, :text3d, stats, failures, []
        )
      end
      assert_match(/rollback could not be verified/, error.message)
      assert_includes entities.to_a, raster
      assert_equal false,
                   stats[:terminal_cleanup_failures].first[:raster_rollback_verified]
    ensure
      IMP.define_singleton_method(:import_page_as_raster, original)
    end
  end

  def test_native_renderer_count_excludes_rescued_spans
    fallbacks = [
      { requested: :text3d, delivered: :labels, reason: 'text3d_mesh_unavailable', count: 2 }
    ]

    assert_equal 0, IMP.native_text_delivery_count(2, fallbacks)
    assert_equal 1, IMP.native_text_delivery_count(3, fallbacks)
  end

  def test_normal_native_label_delivery_needs_no_fallback_record
    stats = { text_renderers: [] }
    IMP.record_text_renderer(stats, 1,
      renderer: :labels,
      mode: :labels,
      requested_mode: :labels,
      degraded: false)

    report = report_for(stats[:text_renderers])
    assert_nil report[:fallback][:text]
    assert_requested_equals_delivered_or_reported(report, 'labels', 'labels')
  end

  def test_merge_geometry_builder_result_appends_both_builder_paths
    stats = {
      text_renderers: [],
      mesh_text_telemetry: [],
      text_font_substitutions: [],
      text_height_samples: []
    }
    primary = {
      text_fallbacks: [],
      mesh_text_telemetry: [
        { page: 1, source_span_id: 'primary', outcome: :complete,
          delivered_mode: :text3d, sketchup_letter_height_in: 0.1 }
      ],
      text_font_substitutions: [],
      text_height_samples: [0.1],
      text_height_fallback_count: 0
    }
    fallback = {
      text_fallbacks: [
        { requested: :geometry, delivered: :text3d,
          reason: 'svg_text_unavailable', count: 1 }
      ],
      mesh_text_telemetry: [
        { page: 1, source_span_id: 'fallback', outcome: :fallback_text3d,
          delivered_mode: :text3d, sketchup_letter_height_in: 0.2 }
      ],
      text_font_substitutions: [
        { requested_font: 'RomanT', delivered_font: 'Arial',
          reason: 'RomanT unavailable; using Arial' }
      ],
      text_height_samples: [0.2],
      text_height_fallback_count: 1
    }

    IMP.merge_geometry_builder_text_result!(stats, 1, primary, true)
    IMP.merge_geometry_builder_text_result!(stats, 1, fallback, true)

    assert_equal ['primary', 'fallback'],
                 stats[:mesh_text_telemetry].map { |sample| sample[:source_span_id] }
    assert_equal [0.1, 0.2], stats[:text_height_samples]
    assert_equal [1, 1], stats[:text_height_sample_pages]
    assert_equal 1, stats[:text_font_substitutions].length
    assert_equal 1, stats[:text_height_fallback_count]
    assert stats[:text_renderers].any? { |entry| entry[:delivered_mode] == :text3d }
  end

  def test_all_telemetry_merge_degradation_is_counted
    stats = {
      mesh_text_telemetry: [], text_font_substitutions: [], text_renderers: []
    }
    IMP.merge_mesh_text_telemetry!(stats, [nil, 'bad', { source_span_id: 'ok' }], 1)
    assert_equal 2, stats[:mesh_text_telemetry_invalid_sample_count]

    exploding_telemetry = Object.new
    def exploding_telemetry.<<(_value)
      raise 'forced telemetry merge failure'
    end
    stats[:mesh_text_telemetry] = exploding_telemetry
    IMP.merge_mesh_text_telemetry!(stats, [{ source_span_id: 'boom' }], 1)
    assert_equal 1, stats[:mesh_text_telemetry_merge_failure_count]

    stats[:text_font_substitutions] = []
    IMP.merge_text_font_substitutions!(
      stats,
      [nil, 'bad', { requested_font: 'RomanT', delivered_font: 'Arial' }],
      1
    )
    assert_equal 2, stats[:text_font_substitution_merge_failure_count]
    assert_equal 1, stats[:text_font_substitutions].length

    exploding_fonts = Object.new
    def exploding_fonts.<<(_value)
      raise 'forced font substitution merge failure'
    end
    stats[:text_font_substitutions] = exploding_fonts
    IMP.merge_text_font_substitutions!(
      stats, [{ requested_font: 'RomanT', delivered_font: 'Arial' }], 1
    )
    assert_equal 3, stats[:text_font_substitution_merge_failure_count]

    bad_payload = Class.new(Hash) do
      def [](_key)
        raise 'forced unified merge failure'
      end
    end.new
    IMP.merge_geometry_builder_text_result!(stats, 1, bad_payload, true)
    assert_equal 1, stats[:mesh_text_telemetry_outer_merge_failure_count]
  end
end
