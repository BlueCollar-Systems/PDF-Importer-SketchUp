#!/usr/bin/env ruby
# The page stages that had no timer now report their time, so a host QA
# report shows where an import spent it: the white-mask pass, geometry
# cleanup and the empty-group pruning before certification.
#
# Nothing here reads a real drawing.

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class PipelineStageTimersTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  MAIN_RB = File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/main.rb', __dir__)

  def test_a_timed_stage_records_and_accumulates_its_milliseconds
    stats = {}
    value = IMP.time_pipeline_stage!(stats, :white_mask_ms) { :made_up_result }
    assert_equal :made_up_result, value
    first = stats[:pipeline_performance][:white_mask_ms]
    assert_kind_of Float, first
    assert_operator first, :>=, 0.0
    IMP.time_pipeline_stage!(stats, :white_mask_ms) { sleep 0.02 }
    assert_operator stats[:pipeline_performance][:white_mask_ms], :>=, first + 15.0
  end

  def test_a_stage_that_fails_still_reports_its_time_and_the_same_error
    stats = { :pipeline_performance => { :other_ms => 1.0 } }
    error = RuntimeError.new('made-up stage failure')
    raised = assert_raises(RuntimeError) do
      IMP.time_pipeline_stage!(stats, :geometry_cleanup_ms) { raise error }
    end
    assert_same error, raised
    assert stats[:pipeline_performance].key?(:geometry_cleanup_ms)
    assert_equal 1.0, stats[:pipeline_performance][:other_ms]
  end

  def pipeline_source
    File.read(MAIN_RB)[/^    def self\.run_pipeline\(model, path, opts\).*?^    def self\./m]
  end

  def timed_call(key, call)
    source = pipeline_source
    opener = source.index("time_pipeline_stage!(stats, :#{key})")
    refute_nil opener, "#{key} timer is missing from run_pipeline"
    position = source.index(call, opener)
    refute_nil position, "#{call} is not inside the #{key} timer"
    assert_operator position - opener, :<, 600, "#{call} must sit inside the #{key} timer"
  end

  def test_run_pipeline_times_the_white_mask_cleanup_and_pruning_stages
    timed_call('white_mask_ms', 'composition = compose_page_white_masks!(')
    timed_call('white_mask_ms', 'collect_page_composition_inventory!(')
    timed_call('geometry_cleanup_ms', 'GeometryCleanup.cleanup(')
    timed_call('prune_empty_groups_ms', 'builder.prune_empty_fill_groups!')
    timed_call('prune_empty_groups_ms', 'builder.prune_empty_page_groups!')
    assert_includes pipeline_source, 'stats[:pipeline_performance][:page_certify_ms] ='
  end

  def test_the_new_timers_reach_the_import_report
    stats = { :pages => 1, :primitives => 1,
              :pipeline_performance => { :white_mask_ms => 12.5, :geometry_cleanup_ms => 3.25,
                                         :prune_empty_groups_ms => 0.5, :page_certify_ms => 7.0 } }
    report = IMP::QAReport.build_from_stats('made_up.pdf', { :import_mode => 'auto' }, stats)
    timers = report[:extra][:pipeline_performance]
    assert_in_delta 12.5, timers['white_mask_ms'], 1.0e-9
    assert_in_delta 3.25, timers['geometry_cleanup_ms'], 1.0e-9
    assert_in_delta 0.5, timers['prune_empty_groups_ms'], 1.0e-9
    assert_in_delta 7.0, timers['page_certify_ms'], 1.0e-9
  end
end
