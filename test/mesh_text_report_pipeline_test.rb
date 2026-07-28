#!/usr/bin/env ruby

require_relative 'geometry_builder_text_fallback_test'
require 'bc_pdf_vector_importer/main'
require 'json'
require 'tmpdir'

class MeshTextReportPipelineTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  Item = IMP::TextParser::TextItem

  def item(span_id, family)
    value = Item.new(
      span_id, 10.0, 20.0, 12.0, 0.0, family,
      nil, 10.0, 20.0, 40.0, 30.0
    )
    value.source_span_id = span_id
    value.source_font_family = family
    value.font_to_sketchup_letter_ratio = family == 'RomanT' ?
                                             1538.0 / 2048.0 :
                                             1491.0 / 2048.0
    value.font_to_sketchup_letter_ratio_source = :known_font
    value.trusted_text_matrix_x_scale = 1.0
    value
  end

  def builder_result(span_id, family)
    entities = TextFallbackEntities.new(:success, :success)
    builder = IMP::GeometryBuilder.new(
      nil, [], [item(span_id, family)], [0, 0, 612, 792],
      import_text: true,
      use_3d_text: true,
      requested_text_mode: :text3d,
      group_per_page: false,
      target_entities: entities,
      layer_manager: TelemetryLayerManager.new,
      installed_font_families: ['Arial'],
      page_number: 1
    )
    builder.define_singleton_method(:mesh_text_residual_x_scale) do |*_args|
      [1.0, :fitted, 'bbox_exact_match', true]
    end
    builder.build
  end

  def test_real_builder_results_append_through_main_and_written_report_json
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 2, layers: [],
      elapsed_seconds: 0.1, text_renderers: [],
      mesh_text_telemetry: [], text_font_substitutions: [],
      text_height_samples: []
    }

    IMP.merge_geometry_builder_text_result!(
      stats, 1, builder_result('primary-span', 'Arial'), true
    )
    IMP.merge_geometry_builder_text_result!(
      stats, 1, builder_result('fallback-span', 'RomanT'), true
    )

    assert_equal ['primary-span', 'fallback-span'],
                 stats[:mesh_text_telemetry].map { |sample| sample[:source_span_id] }
    assert_equal 2, stats[:text_height_samples].length
    assert_equal 1, stats[:text_font_substitutions].length

    report = IMP::QAReport.build_from_stats('pipeline.pdf', {}, stats)
    path = File.join(Dir.tmpdir, "mesh_text_report_pipeline_#{Process.pid}.json")
    begin
      assert_equal path, IMP::QAReport.write_json(report, path)
      loaded = JSON.parse(File.read(path))
      crosscheck = loaded['extra']['text_height_crosscheck']
      assert_equal 2, crosscheck['sample_count']
      assert_equal ['primary-span', 'fallback-span'],
                   crosscheck['attempts'].map { |sample| sample['source_span_id'] }
      assert_equal 1,
                   crosscheck['font_substitutions']['RomanT unavailable; using Arial']
    ensure
      File.delete(path) if File.exist?(path)
    end
  end

  def publication_stats
    {
      pages: 1, primitives: 1, edges: 1, text: 1, layers: [],
      elapsed_seconds: 0.1, text_mode: :labels,
      text_renderers: [
        {
          page: 1, requested_mode: :labels, delivered_mode: :labels,
          renderer: :labels, degraded: false, count: 1
        }
      ],
      source_provenance_objects: []
    }
  end

  def test_required_report_nil_return_is_an_explicit_pipeline_failure
    stats = publication_stats
    original_write = IMP::QAReport.method(:write_json)
    IMP::QAReport.define_singleton_method(:write_json) do |_report, _path|
      nil
    end

    begin
      result = IMP.publish_import_evidence!('pipeline.pdf', {}, stats)
      assert_equal false, result
      assert_equal false, IMP.pipeline_result_success?(stats)
      failure = stats[:import_report_failure]
      refute_nil failure
      assert_equal :publication, failure[:stage]
      assert_equal 'write_json_returned_nil', failure[:reason]
      assert_equal false, stats[:import_contract_ready]
    ensure
      IMP::QAReport.define_singleton_method(:write_json, original_write)
    end
  end

  def test_required_sidecar_nil_return_publishes_only_fail_closed_report
    stats = publication_stats
    stats[:source_provenance_objects] = [
      { span_id: 'text_span:1:0', created_entity_type: 'native_label' }
    ]
    reports = []
    original_write = IMP::QAReport.method(:write_json)
    original_sidecar = IMP.method(:write_source_provenance_sidecar)
    IMP::QAReport.define_singleton_method(:write_json) do |report, path|
      reports << Marshal.load(Marshal.dump(report))
      path
    end
    IMP.define_singleton_method(:write_source_provenance_sidecar) do |_path, _opts, _stats|
      nil
    end

    begin
      result = IMP.publish_import_evidence!('pipeline.pdf', {}, stats)
      assert_equal false, result
      assert_equal :source_provenance_sidecar,
                   stats[:import_report_failure][:stage]
      refute_empty reports
      contract = reports.last[:extra][:import_contract_ready]
      assert_equal false, contract[:ready]
      assert_equal false, contract[:checks][:report_publication]
    ensure
      IMP::QAReport.define_singleton_method(:write_json, original_write)
      IMP.define_singleton_method(:write_source_provenance_sidecar, original_sidecar)
    end
  end

  def test_required_sidecar_exception_is_captured_as_report_failure
    stats = publication_stats
    stats[:source_provenance_objects] = [
      { span_id: 'text_span:1:0', created_entity_type: 'native_label' }
    ]
    original_sidecar = IMP.method(:write_source_provenance_sidecar)
    IMP.define_singleton_method(:write_source_provenance_sidecar) do |_path, _opts, _stats|
      raise 'forced sidecar exception'
    end

    begin
      assert_equal false,
                   IMP.publish_import_evidence!('pipeline.pdf', {}, stats)
      failure = stats[:import_report_failure]
      assert_equal :source_provenance_sidecar, failure[:stage]
      assert_match(/forced sidecar exception/, failure[:reason])
      assert_equal false, IMP.pipeline_result_success?(stats)
    ensure
      IMP.define_singleton_method(:write_source_provenance_sidecar, original_sidecar)
    end
  end
end
