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
end
