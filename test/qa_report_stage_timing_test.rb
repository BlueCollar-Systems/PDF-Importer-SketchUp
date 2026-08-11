#!/usr/bin/env ruby
# frozen_string_literal: true

# performance.phases must report the per-stage timings the pipeline already collects.
#
# WHY THIS EXISTS
# ---------------
# `stats[:pipeline_performance]` is populated throughout the import (main.rb:2997-3000
# accumulator, the raster key map at main.rb:3010, text3d_render_ms at 4298, explode
# timing in geometry_builder, parse/render timers in svg_3d_text_renderer). The report
# writer then threw all of it away:
#
#     perf[:phases] = { total_ms: elapsed_ms } if elapsed_ms > 0
#
# A real report for `1011 (1 OF 2) - Rev 0 / text` therefore showed 96,800 ms of elapsed
# time with a single `total_ms` bucket and no breakdown. Optimising against that is
# guessing -- and guessing already cost a day here: a bbox-cache hypothesis measured 2.8x
# in a synthetic test and produced zero end-to-end gain.
#
# This closes open decision D-23-4 from the 2026-06-23 performance round, whose own top
# regret was recorded as "measure, don't infer".
#
# Three properties are asserted, and each one guards a specific way this can go wrong:
#   * stage timings actually reach the report (the original defect);
#   * non-timing counters can NEVER be reported as milliseconds (a byte count read as ms
#     would silently corrupt every future optimisation decision);
#   * `unaccounted_ms` exposes how much of the elapsed time the breakdown fails to
#     explain -- without it a partial breakdown reads exactly like a complete one, which
#     is the same false-completeness trap as a returncode-only PASS.

require 'minitest/autorun'
require 'json'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'

QA = BlueCollarSystems::PDFVectorImporter::QAReport

class QAReportStageTimingTest < Minitest::Test
  def base_stats(extra = {})
    # build_from_stats derives elapsed_ms from :elapsed_seconds (qa_report.rb:46),
    # so 96.8 s reproduces the real 96,800 ms report from 1011/text.
    {
      pages: 1, primitives: 5649, edges: 10, text: 791, arcs: 0,
      layers: [], text_renderers: [], elapsed_seconds: 96.8
    }.merge(extra)
  end

  def build(stats)
    QA.build_from_stats('C:/corpus/1011.pdf', { import_mode: 'vector' }, stats)
  end

  # --- the original defect -------------------------------------------------

  def test_collected_stage_timings_reach_the_report
    stats = base_stats(pipeline_performance: {
      item_delivery_ms: 41_000.0,
      text3d_render_ms: 30_500.0,
      commit_ms: 9_000.0,
      post_build_ms: 2_500.0
    })
    phases = build(stats)[:performance][:phases]

    assert_equal 41_000.0, phases[:item_delivery_ms],
                 'a collected stage timing must not be discarded by the report writer'
    assert_equal 30_500.0, phases[:text3d_render_ms]
    assert_equal 9_000.0, phases[:commit_ms]
    assert_equal 2_500.0, phases[:post_build_ms]
  end

  def test_total_ms_is_retained_for_existing_consumers
    stats = base_stats(pipeline_performance: { commit_ms: 10.0 })
    phases = build(stats)[:performance][:phases]
    assert_equal 96_800.0, phases[:total_ms],
                 'total_ms is pre-existing API; adding a breakdown must not remove it'
  end

  def test_phases_still_present_when_nothing_was_collected
    phases = build(base_stats)[:performance][:phases]
    assert_equal 96_800.0, phases[:total_ms]
    assert_equal 96_800.0, phases[:unaccounted_ms],
                 'with no stages measured, the whole elapsed time is unaccounted for'
  end

  # --- counters must never masquerade as milliseconds ----------------------

  def test_non_timing_counters_are_kept_out_of_phases
    stats = base_stats(pipeline_performance: {
      commit_ms: 1_000.0,
      glyph_component_definition_count: 412,
      raster_png_temp_bytes: 8_388_608,
      raster_pixel_proof_temp_bytes: 1_024,
      commit_includes_source_binding_verification: true
    })
    perf = build(stats)[:performance]

    %i[glyph_component_definition_count raster_png_temp_bytes
       raster_pixel_proof_temp_bytes commit_includes_source_binding_verification].each do |key|
      refute perf[:phases].key?(key),
             "#{key} is not a duration; reporting it as a phase would corrupt every " \
             'later optimisation decision'
    end
    assert_equal 412, perf[:counters][:glyph_component_definition_count]
    assert_equal 8_388_608, perf[:counters][:raster_png_temp_bytes]
    assert_equal true, perf[:counters][:commit_includes_source_binding_verification]
  end

  # --- honesty about incompleteness ---------------------------------------

  def test_unaccounted_ms_exposes_the_unexplained_remainder
    stats = base_stats(pipeline_performance: {
      item_delivery_ms: 40_000.0, commit_ms: 6_800.0
    })
    phases = build(stats)[:performance][:phases]
    assert_equal 50_000.0, phases[:unaccounted_ms],
                 '96800 total - 46800 measured = 50000 unexplained; a partial breakdown ' \
                 'must say so rather than look complete'
  end

  def test_unaccounted_ms_never_goes_negative
    # Stages can overlap (a parent stage may enclose a child), so the sum can exceed the
    # total. That must not surface as a negative duration.
    stats = base_stats(pipeline_performance: {
      item_delivery_ms: 90_000.0, text3d_render_ms: 50_000.0
    })
    assert_equal 0.0, build(stats)[:performance][:phases][:unaccounted_ms]
  end

  # --- determinism (priority 6) -------------------------------------------

  def test_stage_keys_are_emitted_in_deterministic_order
    collected = { view_fit_ms: 1.0, commit_ms: 2.0, entity_diff_ms: 3.0, diagnostics_ms: 4.0 }
    first = build(base_stats(pipeline_performance: collected))[:performance][:phases].keys
    second = build(base_stats(pipeline_performance: collected))[:performance][:phases].keys
    assert_equal first, second
    stages = first.reject { |k| %i[total_ms unaccounted_ms].include?(k) }
    assert_equal stages.sort, stages,
                 'same input must produce the same key order every run'
  end

  # --- measurement must not change what was delivered ---------------------

  def test_delivered_result_is_untouched_by_the_timing_change
    plain = build(base_stats)[:result]
    timed = build(base_stats(pipeline_performance: { commit_ms: 500.0 }))[:result]
    assert_equal plain, timed,
                 'this is a measurement-only change: primitives/text/warnings must be ' \
                 'byte-identical whether or not stage timings were collected'
    assert_equal 5649, timed[:primitives]
    assert_equal 791, timed[:text_entities]
  end

  # --- aggregate (parent) stages must not be summed as leaves ---------------
  #
  # Found by running the real thing. The first leased canary on 1011/text reported
  # unaccounted_ms = 0.0, implying the breakdown explained 100% of the runtime. It did
  # not: page_total_ms is a PARENT that encloses the child stages, so summing every
  # *_ms key exceeded total_ms and the clamp drove the remainder to zero. That is the
  # exact false-completeness failure unaccounted_ms exists to prevent, so the clamp was
  # hiding the very thing the field is for.
  #
  # Aggregates are identified by the `_total_ms` suffix rather than a hand-listed set,
  # for the same reason phases are identified by `_ms`: a list would drift as stages are
  # added, a naming rule cannot. Both known aggregates (page_total_ms, raster_total_ms)
  # already follow it.

  # Exact values from the 2026-08-10 leased canary, 1011 (1 OF 2) - Rev 0 / text.
  REAL_CANARY_STAGES = {
    page_total_ms: 72_522.0,          # aggregate: encloses everything below
    text3d_render_ms: 21_014.8,
    text3d_record_ms: 13_470.3,
    post_build_ms: 5_256.3,
    commit_ms: 5_023.8,
    text_extract_ms: 4_738.4,
    content_stream_parse_ms: 937.7,
    embedded_image_scan_ms: 822.2,
    prebuild_analysis_ms: 565.6,
    svg_source_render_ms: 522.4,
    view_fit_ms: 197.6,
    text3d_transform_ms: 7.8,
    xobject_expand_ms: 3.5,
    page_data_ms: 3.5,
    post_commit_cleanup_ms: 0.0,
    entity_diff_ms: 0.0
  }.freeze

  def test_real_canary_remainder_is_not_falsely_zero
    stats = base_stats(elapsed_seconds: 77.6,
                       pipeline_performance: REAL_CANARY_STAGES.dup)
    phases = build(stats)[:performance][:phases]

    # Leaves sum to 47,307.6 ms of a 77,600 ms run once BOTH parents are excluded.
    #
    # This expectation was originally 25,036.1, which still double-counted post_build_ms
    # (5,256.3 ms) as a leaf -- the suffix rule only caught page_total_ms. The correction
    # is exactly that stage's value, which is what confirmed post_build_ms encloses
    # commit/cleanup/diff/fit/diagnostics rather than sitting beside them.
    assert_in_delta 30_292.4, phases[:unaccounted_ms], 0.2,
                    'both page_total_ms and post_build_ms are parents; counting either ' \
                    'as a leaf understates how much of the run is unexplained'
    refute_equal 0.0, phases[:unaccounted_ms]
  end

  def test_aggregate_stages_are_still_reported_just_not_summed
    stats = base_stats(elapsed_seconds: 77.6,
                       pipeline_performance: REAL_CANARY_STAGES.dup)
    phases = build(stats)[:performance][:phases]
    assert_equal 72_522.0, phases[:page_total_ms],
                 'an aggregate is useful information; exclude it from the sum, not the report'
  end

  def test_which_keys_were_treated_as_aggregates_is_declared
    stats = base_stats(elapsed_seconds: 77.6,
                       pipeline_performance: REAL_CANARY_STAGES.dup)
    perf = build(stats)[:performance]
    # Both parents present in that stage set must be declared. Originally this expected
    # only page_total_ms, because the suffix rule could not see that post_build_ms is
    # also a parent.
    assert_equal %w[page_total_ms post_build_ms],
                 Array(perf[:phase_aggregates]).map(&:to_s).sort,
                 'reinterpreting a key must be auditable, never silent magic'
  end

  def test_raster_total_ms_is_also_an_aggregate
    stats = base_stats(elapsed_seconds: 10.0, pipeline_performance: {
      raster_total_ms: 9_000.0, raster_render_ms: 6_000.0,
      raster_verify_ms: 2_000.0, raster_cleanup_ms: 1_000.0
    })
    phases = build(stats)[:performance][:phases]
    assert_equal 1_000.0, phases[:unaccounted_ms],
                 '10000 total - 9000 of raster leaves = 1000; the raster aggregate ' \
                 'must not be double-counted'
  end

  def test_flat_stage_set_without_aggregates_is_unaffected
    stats = base_stats(pipeline_performance: {
      item_delivery_ms: 40_000.0, commit_ms: 6_800.0
    })
    perf = build(stats)[:performance]
    assert_equal 50_000.0, perf[:phases][:unaccounted_ms]
    assert_nil perf[:phase_aggregates],
               'nothing to declare when no aggregate is present'
  end

  # --- parents are DECLARED, not inferred from names ------------------------
  #
  # The `_total_ms` suffix rule shipped in #29 was a generalisation from a sample of two
  # (page_total_ms, raster_total_ms). The codebase does not follow that convention:
  # main.rb spans show post_build_ms (line 4620 -> 4710) enclosing FIVE children --
  # commit_ms (4622-4638), post_commit_cleanup_ms (4647-4659), entity_diff_ms
  # (4671-4679), view_fit_ms (4687-4690) and diagnostics_ms (4700-4703). Their sum
  # (7,157.9 ms) matches post_build_ms (7,200.4 ms) to within its own 42 ms of overhead.
  #
  # Because post_build_ms is not named `*_total_ms`, the suffix rule counted it AND its
  # children, so the real canary reported unaccounted_ms = 2,027.4 ms (3.0% unexplained)
  # when the truth is 9,227.8 ms (13.6%). Under-reporting incompleteness by 4.5x is the
  # same false-completeness failure #29 was meant to end, arriving by a different route.
  #
  # Nesting is therefore an explicit declaration. A naming convention only works if the
  # code follows it, and any *_ms key that is neither a declared parent nor a known leaf
  # is surfaced in `phase_unclassified` so a new stage cannot be silently misattributed.

  # Exact phases from the v3.7.131 leased canary, 1011 (1 OF 2) - Rev 0 / text.
  V37131_PHASES = {
    page_total_ms: 60_946.3,          # parent: the per-page loop
    post_build_ms: 7_200.4,           # parent: encloses commit/cleanup/diff/fit/diagnostics
    text3d_render_ms: 25_799.8,
    text3d_record_ms: 16_187.2,
    commit_ms: 6_908.4,               # child of post_build_ms
    text_extract_ms: 5_720.7,
    content_stream_parse_ms: 1_390.4,
    embedded_image_scan_ms: 1_004.7,
    prebuild_analysis_ms: 700.3,
    svg_source_render_ms: 693.0,
    view_fit_ms: 249.5,               # child of post_build_ms
    text3d_transform_ms: 13.2,
    page_data_ms: 3.0,
    xobject_expand_ms: 2.0,
    entity_diff_ms: 0.0,              # child of post_build_ms
    post_commit_cleanup_ms: 0.0       # child of post_build_ms
  }.freeze

  def test_post_build_is_recognised_as_a_parent_despite_its_name
    stats = base_stats(elapsed_seconds: 67.9, pipeline_performance: V37131_PHASES.dup)
    perf = build(stats)[:performance]
    assert_includes Array(perf[:phase_aggregates]).map(&:to_s), 'post_build_ms',
                    'post_build_ms encloses five children; counting it as a leaf '                     'double-counts them'
  end

  def test_real_v37131_remainder_is_not_understated
    stats = base_stats(elapsed_seconds: 67.9, pipeline_performance: V37131_PHASES.dup)
    phases = build(stats)[:performance][:phases]
    # Leaves sum to 58,672.2 ms of 67,900 ms once both parents are excluded.
    assert_in_delta 9_227.8, phases[:unaccounted_ms], 0.5,
                    'suffix-only classification reported 2,027.4 ms (3.0%); the real '                     'figure is 9,227.8 ms (13.6%)'
  end

  def test_all_three_known_parents_are_declared
    stats = base_stats(elapsed_seconds: 100.0, pipeline_performance: {
      page_total_ms: 50_000.0, post_build_ms: 20_000.0, raster_total_ms: 10_000.0,
      commit_ms: 19_000.0, raster_render_ms: 9_000.0, text_extract_ms: 30_000.0
    })
    declared = Array(build(stats)[:performance][:phase_aggregates]).map(&:to_s).sort
    assert_equal %w[page_total_ms post_build_ms raster_total_ms], declared
  end

  def test_an_unknown_stage_is_surfaced_not_silently_counted
    stats = base_stats(pipeline_performance: {
      commit_ms: 100.0, brand_new_stage_ms: 5_000.0
    })
    perf = build(stats)[:performance]
    assert_includes Array(perf[:phase_unclassified]).map(&:to_s), 'brand_new_stage_ms',
                    'a stage nobody classified must be flagged, because it may be a '                     'parent and silently double-count its children'
  end

  def test_known_stages_produce_no_unclassified_noise
    stats = base_stats(elapsed_seconds: 67.9, pipeline_performance: V37131_PHASES.dup)
    assert_nil build(stats)[:performance][:phase_unclassified],
               'every stage in the real canary is classified; no false alarms'
  end

  def test_report_is_json_serializable_with_phases_and_counters
    stats = base_stats(pipeline_performance: {
      commit_ms: 1.5, glyph_component_definition_count: 7
    })
    round_trip = JSON.parse(JSON.generate(build(stats)))
    assert_equal 1.5, round_trip['performance']['phases']['commit_ms']
    assert_equal 7, round_trip['performance']['counters']['glyph_component_definition_count']
  end
end
