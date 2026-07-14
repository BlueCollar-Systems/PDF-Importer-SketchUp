#!/usr/bin/env ruby
# TEXTMODE-1 production-path lock: renderer statistics emitted by main.rb must
# leave the report with either the requested text mode delivered or an honest
# requested/delivered/reason fallback record.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/main'

class TextModeOneInvariantTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter

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
    original = IMP.method(:import_page_as_raster)
    IMP.define_singleton_method(:import_page_as_raster) do |*args|
      raster_calls << args
      true
    end

    page_group = Struct.new(:hidden).new(false)
    stats = {
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
        Object.new, 'x.pdf', 1, [0, 0, 612, 792], {}, Time.now, 0.0,
        [0, 0, 612, 792], page_group, :text3d, stats, failures
      )
      assert promoted
      assert_equal true, page_group.hidden
      assert_equal 1, raster_calls.length
      report = report_for(stats[:text_renderers])
      assert_requested_equals_delivered_or_reported(report, '3d_text', 'raster')
      assert_equal 1, stats[:text_renderers].length
    ensure
      IMP.define_singleton_method(:import_page_as_raster, original)
    end
  end

  def test_terminal_raster_erases_page_vectors_when_grouping_is_disabled
    raster_calls = []
    original = IMP.method(:import_page_as_raster)
    IMP.define_singleton_method(:import_page_as_raster) do |*args|
      raster_calls << args
      true
    end

    entities = Class.new do
      attr_reader :erased

      def initialize
        @erased = []
      end

      def erase_entities(*items)
        @erased.concat(items)
      end
    end.new
    model = Struct.new(:active_entities).new(entities)
    vector_entity = Object.new
    stats = { text_renderers: [] }
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
end
