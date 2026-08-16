# test/import_run_control_test.rb
# Deterministic complexity/progress/cancel contracts for expensive imports.
# Ruby 2.2 compatible -- no keyword arguments, safe navigation, or newer APIs.

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_run_control'

class ImportRunControlTest < Minitest::Test
  IRC = BlueCollarSystems::PDFVectorImporter::ImportRunControl

  class FakeClock
    def initialize(values)
      @values = values.dup
      @last = @values.first || 0.0
    end

    def call
      @last = @values.shift unless @values.empty?
      @last
    end
  end

  def controller(opts = {})
    defaults = {
      :pages => [1, 2],
      :requested_mode => :text3d,
      :clock => FakeClock.new([0.0])
    }
    IRC::Controller.new(defaults.merge(opts))
  end

  def test_assessment_has_exact_thresholds_and_mode_weight
    normal = controller.assess(:paths => 1_999)
    large = controller.assess(:paths => 2_000)
    very_large = controller.assess(:paths => 8_000)

    assert_equal :normal, normal[:class]
    assert_equal :large, large[:class]
    assert_equal :very_large, very_large[:class]
    assert_equal 8_000, very_large[:work_units]

    text3d = controller.assess(
      :text_items => 1_200,
      :glyph_placements => 5_000
    )
    assert_equal :very_large, text3d[:class]
    assert_equal 9_800, text3d[:work_units]
    assert_equal 4, text3d[:mode_weight]
  end

  def test_assessment_rejects_negative_non_integer_and_unknown_counts
    assert_raises(ArgumentError) { controller.assess(:paths => -1) }
    assert_raises(ArgumentError) { controller.assess(:paths => 1.5) }
    assert_raises(ArgumentError) { controller.assess(:surprise => 1) }
  end

  def test_progress_is_monotonic_and_eta_requires_measured_completed_work
    events = []
    clock = FakeClock.new([0.0, 10.0, 20.0, 30.0])
    run = controller(:clock => clock, :status_sink => lambda { |s| events << s })

    first = run.progress(:text_item, :completed => 0, :total => 100)
    second = run.progress(:text_item, :completed => 25, :total => 100)
    third = run.progress(:text_item, :completed => 20, :total => 100)

    assert_equal 0.0, first[:percentage]
    assert_nil first[:eta_seconds]
    assert_equal 25.0, second[:percentage]
    assert_in_delta 30.0, second[:eta_seconds], 0.001
    assert_equal 25.0, third[:percentage], 'progress must never move backwards'
    assert_equal [first, second, third], events
  end

  def test_progress_clamps_completion_and_has_stable_page_context
    run = controller(:clock => FakeClock.new([5.0, 7.0]))
    snapshot = run.progress(
      :geometry_path,
      :completed => 120,
      :total => 100,
      :page => 2,
      :page_index => 2,
      :page_total => 2
    )

    assert_equal :geometry_path, snapshot[:stage]
    assert_equal 100, snapshot[:completed]
    assert_equal 100, snapshot[:total]
    assert_equal 100.0, snapshot[:percentage]
    assert_equal 2, snapshot[:page]
    assert_equal 2, snapshot[:page_index]
    assert_equal 2, snapshot[:page_total]
    assert_equal 0.0, snapshot[:eta_seconds]
  end

  def test_checkpoint_raises_dedicated_cancellation_with_retained_pages
    probes = 0
    run = controller(
      :cancel_probe => lambda { probes += 1; true },
      :clock => FakeClock.new([0.0, 1.0])
    )
    run.retain_page!(1)

    error = assert_raises(IRC::ImportCancelled) do
      run.checkpoint!(
        :text_item,
        :completed => 1,
        :total => 1_200,
        :page => 2
      )
    end

    assert_equal 1, probes
    assert_equal [1], error.retained_pages
    assert_equal 2, error.next_page
    assert_equal :text_item, error.snapshot[:stage]
    assert_equal true, error.cancelled?
  end

  def test_cancelled_result_explicitly_says_what_was_kept
    run = controller(:cancel_probe => lambda { true })
    run.retain_page!(1)
    error = assert_raises(IRC::ImportCancelled) do
      run.checkpoint!(:page, :page => 2, :completed => 1, :total => 2)
    end
    result = run.cancelled_result(error)

    assert_equal true, result[:cancelled]
    assert_equal [1], result[:retained_pages]
    assert_equal 2, result[:next_page]
    assert_match(/Page 1 was kept/, result[:message])
    assert_match(/Resume starts at page 2/, result[:message])
  end

  def test_escape_probe_uses_high_bit_without_requiring_windows_in_tests
    values = [0, 0x8000]
    probe = IRC::EscapeCancelProbe.new(lambda { |_key| values.shift })

    refute probe.call
    assert probe.call
  end

  def test_controller_accepts_a_callable_object_without_proc_arity
    probe = Class.new do
      attr_reader :calls

      def initialize
        @calls = 0
      end

      def call
        @calls += 1
        false
      end
    end.new
    run = controller(
      :cancel_probe => probe,
      :clock => FakeClock.new([0.0, 1.0])
    )

    snapshot = run.checkpoint!(:page, :page => 1, :completed => 0, :total => 1)

    assert_equal :page, snapshot[:stage]
    assert_equal 1, probe.calls
  end

  def test_journal_stats_omit_per_span_evidence_payloads
    group = FakeCertGroup.new(7)
    model = FakeCertModel.new(group)
    run = journal_controller(model)
    bulky = {
      :edges => 5649,
      :text => 791,
      :text_renderers => [{ :group => group, :depths => [0.015625] * 791 }],
      :text_attempts => [{ :expected_evidence => { :geometry_payload => { :n => 1 } } }],
      :source_provenance_objects => [{ :expected_evidence => { :style_payload => { :n => 2 } } }],
      :pipeline_performance => { :commit_ms => 12.5 }
    }

    run.certify_page!(group, 1, :stats => bulky)
    stored = run.journal['pages'][0]['stats']

    assert_equal 5649, stored['edges']
    assert_equal 791, stored['text']
    assert_in_delta 12.5, stored['pipeline_performance']['commit_ms'], 0.001
    refute stored.key?('text_renderers'),
           'resume journal must not clone 3D Text renderer rows'
    refute stored.key?('text_attempts'),
           'resume journal must not clone per-span expected_evidence trees'
    refute stored.key?('source_provenance_objects'),
           'resume journal must not clone provenance expected_evidence trees'
  end

  def test_entity_signature_uses_numeric_point_order_and_detects_geometry_change
    run = journal_controller(FakeCertModel.new)
    left = FakeCertGroup.new(
      1,
      [FakeCertEdge.new(11, [0.0, 0.0, 0.0], [10.0, 9.0, 0.0])]
    )
    right = FakeCertGroup.new(
      1,
      [FakeCertEdge.new(11, [0.0, 0.0, 0.0], [10.0, 9.0, 0.0])]
    )
    moved = FakeCertGroup.new(
      1,
      [FakeCertEdge.new(11, [0.0, 0.0, 0.0], [10.0, 10.0, 0.0])]
    )

    first = run.send(:entity_signature, left)
    second = run.send(:entity_signature, right)
    changed = run.send(:entity_signature, moved)

    assert_match(/\A[0-9a-f]{64}\z/, first)
    assert_equal first, second
    refute_equal first, changed
  end

  def journal_controller(model)
    digest = 'ab' * 32
    IRC::Controller.new(
      :pages => [1],
      :requested_mode => :text3d,
      :model => model,
      :identity => {
        'pdf_sha256' => digest,
        'options_sha256' => digest,
        'importer_sha256' => digest,
        'package_sha256' => digest,
        'source_tree_sha256' => digest
      },
      :clock => FakeClock.new([0.0])
    )
  end

  class FakeCertPoint
    attr_reader :x, :y, :z

    def initialize(values)
      @x = values[0].to_f
      @y = values[1].to_f
      @z = values[2].to_f
    end

    def to_a
      [@x, @y, @z]
    end
  end

  class FakeCertEdge
    attr_reader :start, :end

    def initialize(persistent_id, start_xyz, end_xyz)
      @persistent_id = persistent_id
      @start = FakeCertPoint.new(start_xyz)
      @end = FakeCertPoint.new(end_xyz)
    end

    def persistent_id
      @persistent_id
    end

    def typename
      'Edge'
    end

    def name
      ''
    end

    def bounds
      FakeCertBounds.new(@start, @end)
    end
  end

  class FakeCertBounds
    attr_reader :min, :max

    def initialize(min_point, max_point)
      @min = min_point
      @max = max_point
    end
  end

  class FakeCertGroup
    attr_reader :entities

    def initialize(persistent_id, children = [])
      @persistent_id = persistent_id
      @entities = children
      @attrs = {}
    end

    def persistent_id
      @persistent_id
    end

    def typename
      'Group'
    end

    def name
      'PDF Page 1'
    end

    def valid?
      true
    end

    def bounds
      FakeCertBounds.new(
        FakeCertPoint.new([0.0, 0.0, 0.0]),
        FakeCertPoint.new([1.0, 1.0, 0.0])
      )
    end

    def set_attribute(_dict, key, value)
      @attrs[key.to_s] = value
    end

    def get_attribute(_dict, key, default = nil)
      @attrs.key?(key.to_s) ? @attrs[key.to_s] : default
    end
  end

  class FakeCertModel
    def initialize(group = nil)
      @group = group
      @attrs = {}
    end

    def get_attribute(dict, key, default = nil)
      @attrs[[dict, key]] || default
    end

    def set_attribute(dict, key, value)
      @attrs[[dict, key]] = value
    end

    def active_entities
      @group ? [@group] : []
    end
  end
end
