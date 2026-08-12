#!/usr/bin/env ruby
# test/qa_report_substage_surfacing_test.rb
#
# text3d_render_ms and text3d_record_ms were the two largest entries in the phase table
# -- 22.9 s and 14.6 s of a 60 s import, 62% between them -- and both were opaque. The
# breakdown already existed in extra.text_renderers[].performance; nothing summed it or
# related it to the phase table, and 8.8 s (14.6%) of the run sat in unaccounted_ms
# because the geometry builder's spans were never registered as phases at all.
#
# These tests pin the surfacing, and specifically that promoting the two former leaves to
# declared parents does NOT double-count their children -- the defect that previously
# made unaccounted_ms read 0.0 and hid the very incompleteness it exists to expose.
require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'

class QAReportSubstageSurfacingTest < Minitest::Test
  R = BlueCollarSystems::PDFVectorImporter::QAReport

  # Measured on the real corpus canary 1011/text (run3), so this is a pin against
  # observed values rather than invented ones.
  CANARY_RENDERER_PERF = {
    :parse_ms => 6_077.0,
    :verification_ms => 5_961.1,
    :match_ms => 597.6,
    :span_build_ms => 9_305.7,
    :definition_build_ms => 1_650.8,
    :instance_placement_ms => 4_541.7,
    :evidence_physical_ms => 14_688.8,
    :evidence_bounds_ms => 44.8,
    :evidence_attach_ms => 42.9
  }.freeze
  CANARY_STAGING = { :builder_elapsed_ms => 6_165.6, :explode_ms => 5_249.6 }.freeze

  # total_ms is NOT a pipeline_performance key: QAReport derives it from elapsed_ms and
  # adds it to the performance block separately. Putting it here would misreport it as an
  # unclassified stage.
  def canary_stats
    {
      :pipeline_performance => {
        :page_total_ms => 54_614.0,
        # run3, matching CANARY_RENDERER_PERF. evidence_physical_ms is 99.0% of this
        # figure, which is where 14_837 comes from.
        :text3d_render_ms => 22_875.0, :text3d_record_ms => 14_837.0,
        :content_stream_parse_ms => 971.0, :commit_ms => 5_527.0
      },
      :text_renderers => [{ :performance => CANARY_RENDERER_PERF.dup }],
      :geometry_staging => [CANARY_STAGING.dup]
    }
  end

  # Self-consistent by construction, for the parent/child arithmetic invariants. Real
  # timers start and stop at slightly different points than their enclosing stage, so
  # mixing measured numbers into an exact-arithmetic assertion tests the fixture rather
  # than the code.
  def nested_stats
    {
      :pipeline_performance => {
        :text3d_render_ms => 1_000.0, :text3d_record_ms => 500.0,
        :commit_ms => 200.0
      },
      :text_renderers => [{
        :performance => {
          :parse_ms => 300.0, :verification_ms => 250.0, :match_ms => 50.0,
          :definition_build_ms => 100.0, :instance_placement_ms => 200.0,
          :evidence_physical_ms => 450.0, :evidence_bounds_ms => 25.0,
          :evidence_attach_ms => 20.0
        }
      }],
      :geometry_staging => [{ :builder_elapsed_ms => 400.0, :explode_ms => 350.0 }]
    }
  end

  def leaf_sum(phases, aggregates)
    phases.reject { |k, _| aggregates.include?(k) }
          .values.inject(0.0) { |a, b| a + b }
  end

  def split(stats)
    R.send(:split_pipeline_performance, stats)
  end

  def test_substages_are_summed_across_pages
    stats = {
      :pipeline_performance => {},
      :text_renderers => [
        { :performance => { :parse_ms => 100.0, :evidence_physical_ms => 10.0 } },
        { :performance => { :parse_ms => 250.0, :evidence_physical_ms => 5.5 } }
      ]
    }
    derived = R.send(:derived_substage_phases, stats)
    assert_equal 350.0, derived[:text3d_parse_ms]
    assert_equal 15.5, derived[:text3d_evidence_physical_ms]
  end

  def test_string_keys_survive_a_json_round_trip
    stats = {
      :pipeline_performance => {},
      'text_renderers' => [{ 'performance' => { 'parse_ms' => 42.0 } }],
      'geometry_staging' => [{ 'explode_ms' => 7.0 }]
    }
    derived = R.send(:derived_substage_phases, stats)
    assert_equal 42.0, derived[:text3d_parse_ms]
    assert_equal 7.0, derived[:geometry_explode_ms]
  end

  def test_absent_substage_is_absent_not_zero
    # A renderer that failed early omits its performance hash. Reporting 0.0 would claim
    # the stage ran and cost nothing.
    stats = { :pipeline_performance => {}, :text_renderers => [{ :degraded => true }] }
    derived = R.send(:derived_substage_phases, stats)
    assert_nil derived[:text3d_parse_ms]
    assert_empty derived
  end

  def test_impossible_durations_cannot_shrink_a_total
    stats = {
      :pipeline_performance => {},
      :text_renderers => [
        { :performance => { :parse_ms => 100.0 } },
        { :performance => { :parse_ms => -50.0 } },
        { :performance => { :parse_ms => 'fast' } }
      ]
    }
    assert_equal 100.0, R.send(:derived_substage_phases, stats)[:text3d_parse_ms]
  end

  def test_directly_recorded_phase_wins_over_derived
    stats = {
      :pipeline_performance => { :text3d_parse_ms => 999.0 },
      :text_renderers => [{ :performance => { :parse_ms => 1.0 } }]
    }
    phases, = split(stats)
    assert_equal 999.0, phases[:text3d_parse_ms]
  end

  def test_new_parents_are_reported_as_aggregates_not_summed_as_leaves
    phases, _counters, aggregates, unclassified = split(canary_stats)
    assert_includes aggregates, :text3d_render_ms
    assert_includes aggregates, :text3d_record_ms
    assert_includes aggregates, :geometry_builder_ms
    assert_includes aggregates, :page_total_ms
    assert_empty unclassified, "every surfaced sub-stage must be a declared leaf: #{unclassified.inspect}"
    # Still reported -- promoting to parent hides nothing.
    assert_equal 22_875.0, phases[:text3d_render_ms]
    assert_equal 14_837.0, phases[:text3d_record_ms]
  end

  def test_substages_appear_as_leaves_in_the_phase_table
    phases, = split(canary_stats)
    {
      :text3d_parse_ms => 6_077.0,
      :text3d_verification_ms => 5_961.1,
      :text3d_match_ms => 597.6,
      :text3d_definition_build_ms => 1_650.8,
      :text3d_instance_placement_ms => 4_541.7,
      :text3d_evidence_physical_ms => 14_688.8,
      :geometry_explode_ms => 5_249.6,
      :geometry_builder_ms => 6_165.6
    }.each do |key, expected|
      assert_in_delta expected, phases[key], 0.001, "#{key} missing or wrong"
    end
  end

  def test_span_build_ms_is_not_surfaced_because_its_children_are
    # span_build_ms encloses definition_build_ms + instance_placement_ms. Surfacing it as
    # a leaf alongside them would double-count; surfacing it as a parent would add a row
    # that explains nothing the children do not. Its untimed residual (~3.1 s) is meant to
    # remain visible in unaccounted_ms instead.
    phases, = split(canary_stats)
    refute phases.key?(:span_build_ms)
    refute phases.key?(:text3d_span_build_ms)
  end

  def test_surfacing_attributes_more_time_than_before
    # Same stats, with and without the renderer/staging records. Comparing the two
    # directly avoids pinning a remainder from a differently-shaped dataset.
    before_stats = { :pipeline_performance => nested_stats[:pipeline_performance].dup }
    before_phases, _c, before_agg, = split(before_stats)
    after_phases, _c2, after_agg, = split(nested_stats)

    # The two changes are coupled and must ship together. Promotion ALONE would lose
    # attribution: with the sub-stage records absent, text3d_render_ms and
    # text3d_record_ms are declared parents and contribute nothing to the leaf sum, so
    # only commit_ms is attributed.
    assert_in_delta 200.0, leaf_sum(before_phases, before_agg), 0.001,
                    'without records the promoted parents should contribute no leaves'
    # Surfacing is what restores it, and in more detail than the two opaque totals gave:
    # 900 render children + 495 evidence children + 350 explode + 200 commit.
    after_leaves = leaf_sum(after_phases, after_agg)
    assert_in_delta 1_945.0, after_leaves, 0.001,
                    'expected parse+verification+match+definition+instance+evidence*+explode+commit'
    assert after_leaves > leaf_sum(before_phases, before_agg) * 5
  end

  def test_children_never_exceed_their_declared_parent_in_exact_nesting
    phases, = split(nested_stats)
    render_children = [
      :text3d_parse_ms, :text3d_verification_ms, :text3d_match_ms,
      :text3d_definition_build_ms, :text3d_instance_placement_ms
    ]
    child_sum = render_children.inject(0.0) { |a, k| a + phases[k].to_f }
    assert child_sum <= phases[:text3d_render_ms],
           "children (#{child_sum.round(1)}) exceed text3d_render_ms " \
           "(#{phases[:text3d_render_ms]}) -- the parent/child mapping is wrong"

    record_children = [
      :text3d_evidence_physical_ms, :text3d_evidence_bounds_ms, :text3d_evidence_attach_ms
    ]
    record_sum = record_children.inject(0.0) { |a, k| a + phases[k].to_f }
    assert record_sum <= phases[:text3d_record_ms],
           "evidence children (#{record_sum.round(1)}) exceed text3d_record_ms"
  end

  def test_evidence_timers_can_marginally_exceed_the_record_timer_on_real_data
    # Documented, not asserted away. On run3 the evidence sub-stages sum to 14,776.5 ms
    # against a text3d_record_ms of 14,837.0 -- 99.6% -- because the evidence timers start
    # and stop at slightly different points than the enclosing record timer. They can
    # therefore cross 100% on some runs. That is a timer-boundary artifact, not double
    # counting, and it means unaccounted_ms must never be trusted to be exactly zero.
    phases, = split(canary_stats)
    record_sum = [
      :text3d_evidence_physical_ms, :text3d_evidence_bounds_ms, :text3d_evidence_attach_ms
    ].inject(0.0) { |a, k| a + phases[k].to_f }
    ratio = record_sum / phases[:text3d_record_ms]
    assert ratio > 0.95, "evidence should dominate text3d_record, got #{(ratio * 100).round(1)}%"
    assert ratio < 1.05, "evidence exceeding its parent by >5% would mean a wrong mapping"
  end

  def test_evidence_physical_is_the_single_largest_leaf
    # The finding this surfacing exists to make visible: proving the geometry is correct
    # costs more than any other single stage, and 8.9x more than building it.
    phases, _c, aggregates, = split(canary_stats)
    leaves = phases.reject { |k, _| aggregates.include?(k) }
    largest = leaves.max_by { |_k, v| v }
    assert_equal :text3d_evidence_physical_ms, largest.first
    assert phases[:text3d_evidence_physical_ms] >
           phases[:text3d_definition_build_ms] * 8.0
  end

  def test_missing_records_degrade_to_no_derived_phases
    stats = { :pipeline_performance => { :commit_ms => 10.0 } }
    phases, _c, _a, unclassified = split(stats)
    assert_equal 10.0, phases[:commit_ms]
    assert_empty unclassified
  end

  def test_non_hash_pipeline_performance_still_returns_empty_shape
    assert_equal [{}, {}, [], []], split({ :pipeline_performance => nil })
  end
end

