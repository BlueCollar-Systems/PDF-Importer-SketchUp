#!/usr/bin/env ruby

require 'minitest/autorun'
require 'json'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'

QAReportTextItem = Struct.new(:text, :page_number, :bbox_x0, :bbox_y0, :id)

class QAReportTest < Minitest::Test
  def test_builds_import_report_schema
    stats = {
      pages: 2,
      primitives: 120,
      edges: 400,
      text: 15,
      arcs: 3,
      layers: ['PDF Import', 'A-Notes'],
      elapsed_seconds: 1.25,
      text_renderers: [
        { page: 1, renderer: :pdftocairo, text_source: :external, degraded: false },
        { page: 2, renderer: :labels, text_source: :internal, degraded: true }
      ],
      page_text_sources: { 1 => :external, 2 => :internal },
      text_mode: :geometry,
      resolved_scale: {
        factor: 48.0,
        notation: '1/4" = 1\'-0"',
        source: 'titleblock',
        confidence: 0.91
      }
    }
    opts = { import_mode: 'auto' }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('sample.pdf', opts, stats)

    assert_equal 'bcs.import_report/1.1', report[:schema]
    assert_equal 'sketchup', report[:host][:app]
    assert_equal 120, report[:result][:primitives]
    assert_equal 2, report[:result][:layers]
    assert_equal 2, report[:extra][:text_renderers].length
    assert_equal 'pdftocairo', report[:extra][:text_renderers][0]['renderer']
    assert_in_delta 48.0, report[:extra][:resolved_scale]['factor'], 0.01
    assert_equal 'high', report[:extra][:diagnostics][:quality_level]
    assert_includes report[:extra][:diagnostics][:signals], 'good_vector_content'
    assert_includes report[:extra][:diagnostics][:signals], 'pdf_layers_preserved'
    assert_includes report[:extra][:diagnostics][:signals], 'text_mode_geometry'
    assert report[:extra][:human_summary].to_s.include?('Imported')
    assert report[:extra][:human_summary].to_s.include?('sample.pdf')
  end

  def test_records_text_degradation_in_fallback_block
    stats = {
      pages: 1,
      primitives: 1,
      edges: 1,
      text: 1,
      layers: [],
      elapsed_seconds: 0.5,
      svg_renderer_missing: true,
      text_renderers: [
        { page: 1, renderer: :labels, degraded: true, note: 'Poppler/MuPDF not found' }
      ]
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('x.pdf', {}, stats)
    assert_equal true, report[:fallback][:used]
    assert_equal 'text_degraded_missing_svg_renderer', report[:fallback][:reason]
    assert_equal ['Poppler/MuPDF not found'], report[:fallback][:notes]
    assert_equal true, report[:extra][:svg_renderer_missing]
  end

  def test_records_requested_and_delivered_text_modes_in_fallback_block
    stats = {
      pages: 1,
      primitives: 1,
      edges: 1,
      text: 1,
      layers: [],
      elapsed_seconds: 0.5,
      text_renderers: [
        {
          page: 1,
          renderer: :labels,
          mode: :labels,
          requested_mode: :text3d,
          degraded: true,
          reason: 'text3d_mesh_unavailable',
          count: 1
        }
      ]
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('x.pdf', {}, stats)

    assert_equal true, report[:fallback][:used]
    assert_equal '3d_text', report[:fallback][:text][:requested]
    assert_equal 'labels', report[:fallback][:text][:delivered]
    assert_equal 'text3d_mesh_unavailable', report[:fallback][:text][:reason]
    assert_equal 1, report[:fallback][:text][:count]
    assert_includes report[:extra][:diagnostics][:signals], 'text_mode_fallback'
  end

  def test_aggregates_matching_text_mode_fallback_counts
    stats = {
      pages: 1,
      primitives: 1,
      edges: 1,
      text: 2,
      layers: [],
      text_renderers: [
        { requested_mode: :text3d, mode: :labels, degraded: true,
          reason: 'text3d_mesh_unavailable', count: 1 },
        { requested_mode: :text3d, mode: :labels, degraded: true,
          reason: 'text3d_mesh_unavailable', count: 1 }
      ]
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('x.pdf', {}, stats)
    assert_equal 2, report[:fallback][:text][:count]
  end

  def test_writes_json_file
    stats = { pages: 1, primitives: 1, edges: 1, text: 0, layers: [], text_renderers: [] }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('x.pdf', {}, stats)
    path = File.join(Dir.tmpdir, "qa_report_test_#{Process.pid}.json")
    begin
      written = BlueCollarSystems::PDFVectorImporter::QAReport.write_json(report, path)
      assert_equal path, written
      loaded = JSON.parse(File.read(path))
      assert_equal 'bcs.import_report/1.1', loaded['schema']
    ensure
      File.delete(path) if File.exist?(path)
    end
  end

  def test_flags_interactive_pdf_actions_without_executing_them
    path = File.join(Dir.tmpdir, "qa_report_interactive_#{Process.pid}.pdf")
    File.binwrite(path, "%PDF-1.7\n1 0 obj\n<< /OpenAction 2 0 R /AA <<>> /JS (app.alert) >>\nendobj\n")
    stats = { pages: 1, primitives: 1, edges: 1, text: 0, layers: [], text_renderers: [] }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(path, {}, stats)
    flags = report[:extra][:pdf_interactive_flags]

    assert_includes flags, 'JavaScript'
    assert_includes flags, 'OpenAction'
    assert_includes flags, 'AdditionalActions'
    assert_includes report[:extra][:pdf_interactive_note], 'never executes'
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_records_actionable_diagnostics_for_dense_degraded_text
    stats = {
      pages: 1,
      primitives: 0,
      edges: 0,
      text: 0,
      layers: [],
      elapsed_seconds: 0.5,
      text_mode: :glyphs,
      text_source_spans: 14,
      text_glyph_estimate: 1200,
      raster_fallback_used: true,
      text_renderers: [
        { page: 1, renderer: :labels, degraded: true, note: 'Poppler/MuPDF not found' }
      ]
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('scan.pdf', {}, stats)
    diagnostics = report[:extra][:diagnostics]
    assert_equal 'empty', diagnostics[:quality_level]
    assert_includes diagnostics[:signals], 'fallback_used'
    assert_includes diagnostics[:signals], 'source_text_seen_but_no_text_entities_created'
    assert_includes diagnostics[:signals], 'dense_text_glyph_workload'
    assert diagnostics[:recommended_actions].any? { |action| action.include?('Vector or Hybrid') }
  end

  def test_scale_crosscheck_low_confidence
    stats = {
      pages: 1,
      primitives: 40,
      edges: 40,
      text: 0,
      layers: [],
      elapsed_seconds: 0.5,
      text_renderers: [],
      resolved_scale: {
        factor: 48.0,
        notation: '1/4" = 1\'-0"',
        source: 'titleblock',
        confidence: 0.55
      },
      generic: { title_block: true, dimensions: 4 }
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('scale.pdf', {}, stats)
    crosscheck = report[:extra][:scale_crosscheck]
    refute_nil crosscheck
    assert_includes crosscheck['reasons'], 'low_confidence'
    assert report[:extra][:human_summary].to_s.include?('Scale note:')
  end

  def test_report_parity_floor_extras
    stats = {
      pages: 1,
      primitives: 50_001,
      edges: 50_001,
      text: 10,
      layers: [],
      elapsed_seconds: 2.0,
      text_renderers: [],
      text_mode: :labels,
      font_substitution_note: 'Non-embedded PDF fonts detected.',
      resolved_scale: {
        factor: 48.0,
        notation: '1/4" = 1\'-0"',
        source: 'titleblock',
        confidence: 0.50
      },
      generic: { title_block: true, dimensions: 4 }
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('large.pdf', {}, stats)
    extra = report[:extra]
    assert extra[:human_summary].to_s.include?('large.pdf')
    assert extra[:performance_hint].to_s.include?('one page at a time')
    assert_equal 'Non-embedded PDF fonts detected.', extra[:font_substitution_note]
    refute_nil extra[:scale_crosscheck]
  end

  def test_records_heavy_page_recognition_skip
    stats = {
      pages: 1,
      primitives: 25_000,
      edges: 25_000,
      text: 4,
      layers: [],
      elapsed_seconds: 3.0,
      text_renderers: [],
      recognition_skipped_pages: [
        { page: 1, reason: 'heavy_page', primitives: 25_000, paths: 13_000, stream_mb: 31.2 }
      ]
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('heavy.pdf', {}, stats)
    extra = report[:extra]
    assert_equal 1, extra[:recognition_skipped_pages].length
    assert_equal 'heavy_page', extra[:recognition_skipped_pages][0]['reason']
    assert_includes extra[:diagnostics][:signals], 'semantic_recognition_skipped_for_speed'
  end

  def test_emits_actual_text_entity_types_for_labels
    stats = {
      pages: 1,
      primitives: 40,
      edges: 40,
      text: 12,
      layers: [],
      elapsed_seconds: 0.8,
      text_renderers: [],
      text_mode: :labels,
      source_text_count: 12,
      source_text_span_ids: Array.new(12) { |index| "text_span:1:#{index}" },
      source_provenance_objects: Array.new(12) do |index|
        {
          source_kind: 'text_span', span_id: "text_span:1:#{index}",
          created_entity_type: 'native_label',
          resulting_entity_ids: ["persistent_id:#{1_000 + index}"]
        }
      end
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('text.pdf', {}, stats)
    extra = report[:extra]
    entity = extra[:actual_text_entity_types]
    refute_nil entity
    assert_equal 'labels', entity['entity_type']
    assert_equal 12, entity['count']
    assert_equal 12, entity['native_label']
    refute_nil report[:report_meta]
    assert_includes report[:report_meta][:build_stamp].to_s, 'sketchup'
  end

  def test_actual_text_entity_types_follow_delivered_provenance_not_requested_mode
    stats = {
      pages: 1,
      primitives: 40,
      edges: 40,
      text: 2,
      layers: [],
      elapsed_seconds: 0.8,
      text_renderers: [],
      text_mode: :text3d,
      source_text_count: 2,
      source_text_span_ids: ['text_span:1:0', 'text_span:1:1'],
      source_provenance_objects: [
        {
          source_kind: 'text_span', span_id: 'text_span:1:0',
          created_entity_type: 'native_3d_text',
          resulting_entity_ids: ['persistent_id:1101']
        },
        {
          source_kind: 'text_span', span_id: 'text_span:1:1',
          created_entity_type: 'native_label',
          resulting_entity_ids: ['persistent_id:1102']
        }
      ]
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('text.pdf', {}, stats)
    entity = report[:extra][:actual_text_entity_types]

    assert_equal 'mixed', entity['entity_type']
    assert_equal 2, entity['count']
    assert_equal 1, entity['native_3d_text']
    assert_equal 1, entity['native_label']
  end

  def test_builds_open_failure_report
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_open_failure(
      'bad.pdf',
      { import_mode: 'auto' },
      'not_a_pdf',
      'This file is not a valid PDF.'
    )

    assert_equal 'bcs.import_report/1.1', report[:schema]
    assert_equal true, report[:fallback][:used]
    assert_equal 'not_a_pdf', report[:fallback][:reason]
    assert_equal ['This file is not a valid PDF.'], report[:fallback][:notes]
    assert_equal 0, report[:result][:primitives]
    assert_equal 1, report[:result][:warnings]
    assert_equal 'not_a_pdf', report[:extra][:open_failure][:reason]
  end

  def test_source_provenance_summary_when_spans_recorded
    stats = {
      pages: 1,
      primitives: 10,
      edges: 20,
      text: 2,
      arcs: 0,
      layers: ['PDF Import'],
      text_renderers: [],
      elapsed_seconds: 1.0,
      text_mode: :labels,
      import_session_id: 'session-su-1',
      source_provenance_objects: [
        {
          object_id: 'text_span:1:0',
          page: 1,
          source_kind: 'text_span',
          span_id: 'text_span:1:0',
          created_entity_type: 'native_label',
          resulting_entity_ids: ['persistent_id:1201']
        }
      ]
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'sample.pdf',
      { import_mode: 'auto', import_text: true, text_mode: :labels },
      stats
    )
    prov = report[:extra][:source_provenance]
    refute_nil prov
    assert_equal 'bcs.source_provenance/1.0', prov[:schema]
    assert_equal 'session-su-1', prov[:import_session_id]
    assert_equal 1, prov[:object_count]
  end

  def test_model_3d_payload_reports_shelved_state
    stats = {
      pages: 1,
      primitives: 8,
      edges: 12,
      text: 0,
      layers: [],
      text_renderers: [],
      model_3d: {
        enabled: true,
        supported: true,
        depth_mm: 6.35,
        faces_extruded: 3
      }
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'solid.pdf',
      { import_mode: 'auto', extrude_to_3d: true, extrude_depth_mm: 6.35 },
      stats
    )

    assert_equal false, report[:extra][:model_3d]['enabled']
    assert_equal false, report[:extra][:model_3d]['supported']
    assert_equal 0, report[:extra][:model_3d]['faces_extruded']
    assert_equal 'shelved_by_owner', report[:extra][:model_3d]['skipped_reason']
  end

  def test_model_3d_intent_is_reported_from_text_evidence
    stats = {
      pages: 1,
      primitives: 8,
      edges: 12,
      text: 3,
      layers: [],
      text_renderers: [],
      text_mode: :labels,
      model_3d_texts: ['p1052 PL3/4"X7"', 'w1025 W12X30']
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'intent.pdf',
      { import_mode: 'auto', import_text: true, text_mode: :labels },
      stats
    )

    intent = report[:extra][:model_3d_intent]
    assert_equal true, intent['feasible']
    assert_equal 1, intent['plates'].length
    assert_equal 1, intent['members'].length
    assert_equal 'W12X30', intent['members'][0]['designation']
  end

  def test_parts_bootstrap_is_reported_from_page_text_map
    stats = {
      pages: 1,
      primitives: 8,
      edges: 12,
      text: 6,
      layers: [],
      text_renderers: [],
      text_mode: :labels,
      import_session_id: 'session-su-parts',
      page_text_map: {
        1 => [
          QAReportTextItem.new('QUAN', 1, 50.0, 500.0, 'h1'),
          QAReportTextItem.new('MARK', 1, 120.0, 500.0, 'h2'),
          QAReportTextItem.new('DESCRIPTION', 1, 220.0, 500.0, 'h3'),
          QAReportTextItem.new('2', 1, 50.0, 460.0, 'r1a'),
          QAReportTextItem.new('p1052', 1, 120.0, 460.0, 'r1b'),
          QAReportTextItem.new('PL3/4X7"', 1, 220.0, 460.0, 'r1c')
        ]
      }
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'parts.pdf',
      { import_mode: 'auto', import_text: true, text_mode: :labels },
      stats
    )

    bootstrap = report[:extra][:parts_bootstrap]
    assert_equal 'bcs.parts_bootstrap/1.0', bootstrap['schema']
    assert_equal 1, bootstrap['row_count']
    row = bootstrap['tables'][0]['rows'][0]
    assert_equal 'p1052', row['piece_mark']
    assert_equal 2, row['quantity']
    assert_equal 'PL', row['profile_hint']
  end

  # Round 20: every native-mesh attempt must survive the report and disk JSON.
  def test_text_height_crosscheck_reports_structured_attempts_and_fallbacks
    stats = {
      pages: 1, primitives: 5, edges: 5, text: 3, layers: [],
      elapsed_seconds: 0.2,
      mesh_text_telemetry: [
        {
          page: 1, source_span_id: 'span-a', requested_mode: :text3d,
          delivered_mode: :text3d, pdf_em_height_in: 0.1666666667,
          sketchup_letter_height_in: 0.121337890625,
          nominal_sketchup_letter_height_in: 0.145,
          visual_height_correction_reason: 'targeted_bbox_short_side',
          visual_height_source_points: 10.0,
          letter_height_ratio: 1491.0 / 2048.0,
          metric_source: :known_arial_family,
          requested_font: 'Arial Narrow', selected_font: 'Arial Narrow',
          delivered_font: 'Arial Narrow',
          matrix_x: 1.436458, residual_x: 0.90, total_x: 1.2928122,
          fit_status: :fitted, fit_reason: 'bbox_overflow_shrink',
          outcome: :complete, cleanup_outcome: :not_required
        },
        {
          page: 1, source_span_id: 'span-b', requested_mode: :text3d,
          delivered_mode: :labels, pdf_em_height_in: 0.10,
          sketchup_letter_height_in: 0.072802734375,
          letter_height_ratio: 1491.0 / 2048.0,
          metric_source: :default_arial_family,
          requested_font: 'RomanT', selected_font: 'Arial',
          delivered_font: nil,
          font_substitution_reason: 'RomanT unavailable; using Arial',
          matrix_x: 1.0, residual_x: 1.0, total_x: 1.0,
          fit_status: :rejected_outlier, fit_reason: 'residual_below_0_50',
          outcome: :failed_rotation, failure_phase: :rotation,
          failure_reason: 'text3d_rotation_transform_failed',
          cleanup_outcome: :complete
        }
      ],
      text_height_fallback_count: 2
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('t.pdf', {}, stats)
    cc = report[:extra][:text_height_crosscheck]
    assert_equal 'pdf_em_x_font_metric_then_local_x', cc[:policy]
    assert_equal 2, cc[:sample_count]
    assert_equal 2, cc[:attempts].length
    assert_equal 1, cc[:outcome_counts]['complete']
    assert_equal 1, cc[:outcome_counts]['failed_rotation']
    assert_equal 1, cc[:failure_phase_counts]['rotation']
    assert_equal 1, cc[:fit_reason_counts]['bbox_overflow_shrink']
    assert_equal 2, cc[:requested_mode_counts]['text3d']
    assert_equal 1, cc[:delivered_mode_counts]['text3d']
    assert_equal 1, cc[:delivered_mode_counts]['labels']
    assert_equal 1, cc[:fitted_count]
    assert_equal 1, cc[:rejected_outlier_count]
    assert_equal 1, cc[:failed_transform_count]
    assert_equal 2, cc[:fallback_count]
    assert_equal 2, cc[:height_fallback_count]
    assert_equal 1, cc[:visual_height_correction_count]
    assert_equal 1,
                 cc[:visual_height_correction_reasons]['targeted_bbox_short_side']
    assert_in_delta 0.145,
                    cc[:nominal_sketchup_letter_height_in][:max], 1.0e-9
    assert_equal 1, cc[:font_substitutions]['RomanT unavailable; using Arial']
    assert_in_delta 0.10, cc[:pdf_em_height_in][:min], 1.0e-6
    assert_in_delta 0.121337890625,
                    cc[:sketchup_letter_height_in][:max], 1.0e-9

    path = File.join(Dir.tmpdir, "qa_report_mesh_telemetry_#{Process.pid}.json")
    begin
      assert_equal path,
                   BlueCollarSystems::PDFVectorImporter::QAReport.write_json(report, path)
      loaded = JSON.parse(File.read(path))
      disk = loaded['extra']['text_height_crosscheck']
      assert_equal 2, disk['sample_count']
      assert_equal 'span-a', disk['attempts'][0]['source_span_id']
      assert_equal 'rotation', disk['attempts'][1]['failure_phase']
      assert_equal 'labels', disk['attempts'][1]['delivered_mode']
      refute_nil disk['pdf_em_height_in']
      refute_nil disk['sketchup_letter_height_in']
    ensure
      File.delete(path) if File.exist?(path)
    end
  end

  def test_text_height_crosscheck_survives_nil_malformed_and_nonfinite_fields
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 1, layers: [],
      mesh_text_telemetry: [
        {
          source_span_id: 'valid', requested_mode: :text3d,
          delivered_mode: :text3d, outcome: :complete,
          pdf_em_height_in: 0.1, sketchup_letter_height_in: 0.07,
          letter_height_ratio: 0.7, matrix_x: 1.0,
          residual_x: 1.0, total_x: 1.0
        },
        {
          source_span_id: 'partial', requested_mode: :text3d,
          delivered_mode: :labels, outcome: :failed_generation,
          failure_phase: :generation, pdf_em_height_in: nil,
          sketchup_letter_height_in: 'not-a-number',
          letter_height_ratio: Float::INFINITY,
          matrix_x: nil, residual_x: nil, total_x: nil
        }
      ]
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('t.pdf', {}, stats)
    cc = report[:extra][:text_height_crosscheck]
    refute_nil cc
    assert_equal 2, cc[:sample_count]
    assert_equal 1, cc[:pdf_em_height_in][:count]
    assert_equal 1, cc[:pdf_em_height_in][:missing_count]
    assert_equal 1, cc[:sketchup_letter_height_in][:invalid_count]
    assert_equal 1, cc[:letter_height_ratio][:invalid_count]

    path = File.join(Dir.tmpdir, "qa_report_partial_telemetry_#{Process.pid}.json")
    begin
      assert_equal path,
                   BlueCollarSystems::PDFVectorImporter::QAReport.write_json(report, path)
      loaded = JSON.parse(File.read(path))
      assert_equal 2, loaded['extra']['text_height_crosscheck']['attempts'].length
    ensure
      File.delete(path) if File.exist?(path)
    end
  end

  def test_text_height_crosscheck_present_when_only_fallbacks_occurred
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 1, layers: [],
      elapsed_seconds: 0.1,
      text_height_samples: [],
      text_height_fallback_count: 4
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('t.pdf', {}, stats)
    cc = report[:extra][:text_height_crosscheck]
    refute_nil cc, 'a fallback-only import must still surface the crosscheck'
    assert_equal 0, cc[:sample_count]
    assert_equal 4, cc[:fallback_count]
  end

  def test_text_height_crosscheck_absent_without_mesh_text
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 0, layers: [],
      elapsed_seconds: 0.1
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('t.pdf', {}, stats)
    assert_nil report[:extra][:text_height_crosscheck],
               'headless/label imports place no mesh text — block stays absent'
  end

  def valid_native_mesh_attempt
    {
      page: 1,
      source_span_id: 'text_span:1:0',
      requested_mode: :text3d,
      delivered_mode: :text3d,
      requested_font: 'Arial',
      selected_font: 'Arial',
      attempted_font: 'Arial',
      delivered_font: 'Arial',
      pdf_em_height_in: 0.1666666667,
      sketchup_letter_height_in: 0.121337890625,
      letter_height_ratio: 1491.0 / 2048.0,
      metric_source: :known_arial_family,
      matrix_x: 1.0,
      residual_x: 1.0,
      total_x: 1.0,
      fit_status: :fitted,
      fit_reason: 'bbox_overflow_shrink',
      fit_measurement_verified: true,
      source_height_verified: true,
      visual_fidelity_verified: true,
      outcome: :complete,
      cleanup_outcome: :not_required,
      resulting_entity_ids: ['persistent_id:1001', 'persistent_id:1002'],
      attempt_history: [
        {
          mode: :text3d, outcome: :complete, reason: nil,
          cleanup_outcome: :not_required, delivered_mode: :text3d,
          resulting_entity_ids: ['persistent_id:1001', 'persistent_id:1002']
        }
      ]
    }
  end

  def valid_native_mesh_stats
    {
      pages: 1, primitives: 1, edges: 1, text: 1, layers: [],
      text_mode: :text3d,
      source_text_count: 1,
      source_text_span_ids: ['text_span:1:0'],
      mesh_text_telemetry: [valid_native_mesh_attempt],
      text_renderers: [
        {
          page: 1, renderer: :add_3d_text, requested_mode: :text3d,
          delivered_mode: :text3d, degraded: false, count: 1
        }
      ],
      source_provenance_objects: [
        {
          source_kind: 'text_span',
          span_id: 'text_span:1:0',
          created_entity_type: 'native_3d_text',
          resulting_entity_ids: ['persistent_id:1001', 'persistent_id:1002']
        }
      ],
      import_report_publication_status: :published,
      import_report_path: 'contract_import_report.json'
    }
  end

  def contract_for(stats)
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'contract.pdf', {}, stats
    )
    report[:extra][:import_contract_ready]
  end

  def test_import_contract_clean_labels_do_not_require_mesh_telemetry
    contract = contract_for(
      pages: 1, primitives: 1, edges: 1, text: 1, layers: [],
      text_mode: :labels,
      source_text_count: 1,
      source_text_span_ids: ['text_span:1:0'],
      text_renderers: [
        {
          page: 1, requested_mode: :labels, delivered_mode: :labels,
          renderer: :labels, degraded: false, count: 1
        }
      ],
      source_provenance_objects: [
        {
          source_kind: 'text_span', span_id: 'text_span:1:0',
          created_entity_type: 'native_label',
          resulting_entity_ids: ['persistent_id:2001']
        }
      ],
      import_report_publication_status: :published,
      import_report_path: 'contract_import_report.json'
    )

    assert_equal true, contract[:ready]
    assert_equal true, contract[:checks][:native_3d_attempt_evidence]
  end

  def test_import_contract_accepts_complete_native_mesh_attempt_evidence
    contract = contract_for(valid_native_mesh_stats)

    assert_equal true, contract[:ready]
    assert contract[:checks].values.all?, contract.inspect
  end

  def test_import_contract_rejects_native_mesh_without_positive_visual_verification
    [:missing, nil, false].each do |state|
      stats = Marshal.load(Marshal.dump(valid_native_mesh_stats))
      attempt = stats[:mesh_text_telemetry][0]
      if state == :missing
        attempt.delete(:visual_fidelity_verified)
      else
        attempt[:visual_fidelity_verified] = state
      end

      contract = contract_for(stats)
      assert_equal false, contract[:ready], state.inspect
      assert_equal false, contract[:checks][:native_3d_attempt_evidence], state.inspect
    end
  end

  def test_import_contract_rejects_native_mesh_without_verified_source_height
    [:missing, nil, false].each do |state|
      stats = Marshal.load(Marshal.dump(valid_native_mesh_stats))
      attempt = stats[:mesh_text_telemetry][0]
      if state == :missing
        attempt.delete(:source_height_verified)
      else
        attempt[:source_height_verified] = state
      end
      attempt[:height_fallback_reason] = 'forced minimum-height fallback'

      contract = contract_for(stats)
      assert_equal false, contract[:ready], state.inspect
      assert_equal false,
                   contract[:checks][:native_3d_attempt_evidence], state.inspect
    end
  end

  def test_missing_provenance_never_infers_requested_native_type_or_readiness
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 1, layers: [],
      text_mode: :text3d, source_text_count: 1,
      source_text_span_ids: ['text_span:1:0'],
      text_renderers: [
        {
          page: 1, requested_mode: :text3d, delivered_mode: :labels,
          renderer: :labels, degraded: true,
          reason: 'text3d_mesh_unavailable', count: 1
        }
      ],
      provenance_record_failure_count: 1,
      import_report_publication_status: :published,
      import_report_path: 'missing_provenance_import_report.json'
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'contract.pdf', {}, stats
    )
    types = report[:extra][:actual_text_entity_types]
    refute types && types[:native_3d_text].to_i > 0,
           'requested text mode is not delivery evidence'
    contract = report[:extra][:import_contract_ready]
    assert_equal false, contract[:ready]
    assert_equal false, contract[:checks][:provenance_integrity]
  end

  def test_zero_source_text_vector_import_does_not_require_native_attempts
    contract = contract_for(
      pages: 1, primitives: 2, edges: 2, text: 0, layers: [],
      text_mode: :text3d, source_text_count: 0,
      source_text_span_ids: [],
      import_report_publication_status: :published,
      import_report_path: 'vector_only_import_report.json'
    )

    assert_equal true, contract[:ready], contract.inspect
    assert_equal true, contract[:checks][:native_3d_attempt_evidence]
  end

  def test_positive_source_text_count_without_delivery_evidence_fails_closed
    contract = contract_for(
      pages: 1, primitives: 1, edges: 1, text: 0, layers: [],
      text_mode: :text3d, source_text_count: 1,
      source_text_span_ids: ['text_span:1:0'],
      import_report_publication_status: :published,
      import_report_path: 'missing_delivery_import_report.json'
    )

    assert_equal false, contract[:ready]
    assert_equal false, contract[:checks][:native_3d_attempt_evidence]
  end

  def test_import_contract_rejects_each_named_integrity_failure
    cases = [
      [:no_failed_pages, lambda { |stats| stats[:failed_pages] = [1] }],
      [:telemetry_integrity, lambda { |stats| stats[:mesh_text_telemetry_record_failure_count] = 1 }],
      [:telemetry_integrity, lambda { |stats| stats[:mesh_text_telemetry_initialization_failure_count] = 1 }],
      [:telemetry_integrity, lambda { |stats| stats[:mesh_text_telemetry_invalid_sample_count] = 1 }],
      [:telemetry_integrity, lambda { |stats| stats[:mesh_text_telemetry_merge_failure_count] = 1 }],
      [:telemetry_integrity, lambda { |stats| stats[:mesh_text_telemetry_outer_merge_failure_count] = 1 }],
      [:telemetry_integrity, lambda { |stats| stats[:text_font_substitution_merge_failure_count] = 1 }],
      [:native_3d_attempt_evidence, lambda { |stats| stats[:mesh_text_telemetry][0].delete(:page) }],
      [:native_3d_source_identity, lambda { |stats| stats[:mesh_text_telemetry][0].delete(:source_span_id) }],
      [:cleanup_verified, lambda { |stats| stats[:mesh_text_telemetry][0][:cleanup_outcome] = :failed }],
      [:cleanup_verified, lambda { |stats| stats[:terminal_cleanup_failures] = [{ page: 1, reason: 'erase_unverified' }] }],
      [:terminal_delivery, lambda { |stats| stats[:mesh_text_telemetry][0][:delivered_mode] = :none }],
      [:report_generation, lambda { |stats| stats[:import_report_failures] = [{ stage: :generation, reason: 'boom' }] }],
      [:report_publication, lambda { |stats| stats[:import_report_failures] = [{ stage: :publication, reason: 'write_json_returned_nil' }] }]
    ]

    cases.each do |check_name, mutate|
      stats = Marshal.load(Marshal.dump(valid_native_mesh_stats))
      mutate.call(stats)
      contract = contract_for(stats)
      assert_equal false, contract[:ready], "#{check_name} failure was accepted"
      assert_equal false, contract[:checks][check_name],
                   "#{check_name} was not named explicitly: #{contract.inspect}"
    end
  end

  def test_import_contract_rejects_unknown_or_malformed_report_failure_entries
    [
      { stage: :unexpected, reason: 'boom' },
      { reason: 'missing stage' },
      'malformed failure'
    ].each do |failure|
      stats = Marshal.load(Marshal.dump(valid_native_mesh_stats))
      stats[:import_report_failures] = [failure]
      contract = contract_for(stats)
      assert_equal false, contract[:ready], failure.inspect
      assert_equal false, contract[:checks][:report_failure_ledger],
                   failure.inspect
    end
  end

  def test_import_contract_rejects_missing_and_invalid_attempt_records
    [nil, 'not-a-hash', {}, valid_native_mesh_attempt.merge(outcome: nil)].each do |bad|
      stats = valid_native_mesh_stats
      stats[:mesh_text_telemetry] = [bad]
      contract = contract_for(stats)
      assert_equal false, contract[:ready], bad.inspect
      assert_equal false, contract[:checks][:native_3d_attempt_evidence], bad.inspect
    end
  end

  def test_labels_import_with_any_malformed_attempt_record_fails_closed
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 1, layers: [],
      text_mode: :labels,
      mesh_text_telemetry: [
        { delivered_mode: :labels, cleanup_outcome: :complete }
      ],
      import_report_publication_status: :published,
      import_report_path: 'contract_import_report.json'
    }
    contract = contract_for(stats)

    assert_equal false, contract[:ready]
    assert_equal false, contract[:checks][:native_3d_attempt_evidence]
  end

  def test_terminal_raster_requires_exact_verified_cleanup_evidence
    [:missing, :not_attempted, :unknown].each do |cleanup|
      stats = Marshal.load(Marshal.dump(valid_native_mesh_stats))
      attempt = stats[:mesh_text_telemetry][0]
      attempt[:delivered_mode] = :raster
      attempt[:superseded_by_raster] = true
      attempt[:terminal_cleanup_outcome] = cleanup unless cleanup == :missing
      attempt[:attempt_history] << {
        mode: :raster, outcome: :complete, reason: 'native APIs unavailable',
        cleanup_outcome: cleanup, delivered_mode: :raster
      }
      contract = contract_for(stats)
      assert_equal false, contract[:ready], cleanup
      assert_equal false, contract[:checks][:cleanup_verified], cleanup
    end
  end

  def test_failed_native_visual_transform_never_counts_as_ready_delivery
    stats = Marshal.load(Marshal.dump(valid_native_mesh_stats))
    attempt = stats[:mesh_text_telemetry][0]
    attempt[:outcome] = :failed_scale
    attempt[:failure_phase] = :scale
    attempt[:failure_reason] = 'text3d_scale_transform_failed'
    attempt[:visual_fidelity_verified] = false
    attempt[:attempt_history][0][:outcome] = :failed_scale
    attempt[:attempt_history][0][:reason] = 'text3d_scale_transform_failed'
    contract = contract_for(stats)

    assert_equal false, contract[:ready]
    assert_equal false, contract[:checks][:native_3d_attempt_evidence]
  end

  def test_attempt_history_failure_requires_reason_and_consistent_terminal_mode
    missing_reason = Marshal.load(Marshal.dump(valid_native_mesh_stats))
    missing_reason[:mesh_text_telemetry][0][:attempt_history][0][:outcome] = :failed_generation
    missing_reason[:mesh_text_telemetry][0][:attempt_history][0][:reason] = nil
    assert_equal false, contract_for(missing_reason)[:ready]

    inconsistent = Marshal.load(Marshal.dump(valid_native_mesh_stats))
    inconsistent[:mesh_text_telemetry][0][:attempt_history][0][:delivered_mode] = :labels
    assert_equal false, contract_for(inconsistent)[:ready]
  end

  def test_publication_status_and_path_are_required_exactly
    [:missing, :pending, :failed, :unknown].each do |status|
      stats = Marshal.load(Marshal.dump(valid_native_mesh_stats))
      if status == :missing
        stats.delete(:import_report_publication_status)
      else
        stats[:import_report_publication_status] = status
      end
      contract = contract_for(stats)
      assert_equal false, contract[:ready], status
      assert_equal false, contract[:checks][:report_publication], status
    end

    stats = Marshal.load(Marshal.dump(valid_native_mesh_stats))
    stats.delete(:import_report_path)
    contract = contract_for(stats)
    assert_equal false, contract[:ready]
    assert_equal false, contract[:checks][:report_publication]
  end

  def test_import_contract_rejects_telemetry_summary_error_policy
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'contract.pdf', {}, valid_native_mesh_stats
    )
    report[:extra][:text_height_crosscheck] = {
      policy: 'telemetry_summary_error', error: 'forced summary failure'
    }
    contract = BlueCollarSystems::PDFVectorImporter::QAReport.
      build_import_contract_ready(report)

    assert_equal false, contract[:ready]
    assert_equal false, contract[:checks][:telemetry_integrity]
  end

  def test_even_numeric_summary_median_uses_mean_of_middle_pair
    summary = BlueCollarSystems::PDFVectorImporter::QAReport.
      numeric_summary([1.0, 2.0, 10.0, 20.0])

    assert_equal 6.0, summary[:median]
  end

  def test_metric_and_representation_fallbacks_are_reported_separately
    stats = valid_native_mesh_stats
    attempt = stats[:mesh_text_telemetry][0]
    attempt[:height_fallback_reason] = 'mesh_text_height_exception: RangeError'
    attempt[:delivered_mode] = :labels
    attempt[:outcome] = :failed_generation
    attempt[:failure_phase] = :generation
    attempt[:failure_reason] = 'text3d_mesh_unavailable'
    attempt[:cleanup_outcome] = :not_required
    attempt[:attempt_history] = [
      { mode: :text3d, outcome: :failed_generation,
        reason: 'text3d_mesh_unavailable', cleanup_outcome: :not_required },
      { mode: :labels, outcome: :complete, reason: nil,
        cleanup_outcome: :not_required }
    ]
    stats[:text_height_fallback_count] = 1
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'contract.pdf', {}, stats
    )
    crosscheck = report[:extra][:text_height_crosscheck]

    assert_equal 1, crosscheck[:metric_fallback_count]
    assert_equal 1, crosscheck[:representation_fallback_count]
    assert_equal 1,
                 crosscheck[:height_fallback_reasons]['mesh_text_height_exception: RangeError']
  end

  def test_metric_fallback_count_without_attempt_reason_fails_closed
    stats = valid_native_mesh_stats
    stats[:text_height_fallback_count] = 1
    contract = contract_for(stats)

    assert_equal false, contract[:ready]
    assert_equal false, contract[:checks][:height_fallback_reasons]
  end

  def test_renderer_claim_must_match_evidence_backed_final_entity_type
    contract = contract_for(
      pages: 1, primitives: 1, edges: 1, text: 1, layers: [],
      text_mode: :labels, source_text_count: 1,
      source_text_span_ids: ['text_span:1:0'],
      text_renderers: [
        {
          page: 1, renderer: :labels, requested_mode: :labels,
          delivered_mode: :labels, degraded: false, count: 1
        }
      ],
      source_provenance_objects: [
        {
          source_kind: 'text_span', span_id: 'text_span:1:0',
          created_entity_type: 'outline_curve_or_mesh',
          resulting_entity_ids: ['persistent_id:3001']
        }
      ],
      import_report_publication_status: :published,
      import_report_path: 'renderer_mismatch_import_report.json'
    )

    assert_equal false, contract[:ready]
    assert_equal false, contract[:checks][:renderer_provenance_consistency]
  end

  def test_duplicate_or_conflicting_final_provenance_per_span_fails_closed
    ['native_3d_text', 'native_label'].each do |second_type|
      stats = Marshal.load(Marshal.dump(valid_native_mesh_stats))
      stats[:source_provenance_objects] << {
        source_kind: 'text_span', span_id: 'text_span:1:0',
        created_entity_type: second_type,
        resulting_entity_ids: ['persistent_id:3999']
      }

      contract = contract_for(stats)
      assert_equal false, contract[:ready], second_type
      assert_equal false, contract[:checks][:provenance_integrity], second_type
    end
  end

  def test_verified_terminal_page_raster_accounts_for_every_source_span_on_page
    attempt = valid_native_mesh_attempt
    attempt[:source_span_id] = 'text_span:1:1'
    attempt[:delivered_mode] = :raster
    attempt[:outcome] = :failed_generation
    attempt[:failure_phase] = :generation
    attempt[:failure_reason] = 'text3d_mesh_unavailable_labels_unavailable'
    attempt[:cleanup_outcome] = :not_required
    attempt[:terminal_cleanup_outcome] = :verified
    attempt[:superseded_by_raster] = true
    attempt[:resulting_entity_ids] = ['persistent_id:901']
    attempt[:attempt_history] = [
      {
        mode: :text3d, outcome: :failed_generation,
        reason: 'text3d_mesh_unavailable',
        cleanup_outcome: :not_required
      },
      {
        mode: :raster, outcome: :complete,
        reason: 'text3d_mesh_unavailable_labels_unavailable',
        cleanup_outcome: :verified, delivered_mode: :raster,
        resulting_entity_ids: ['persistent_id:901']
      }
    ]
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 0, layers: [],
      text_mode: :text3d, source_text_count: 2,
      source_text_span_ids: ['text_span:1:0', 'text_span:1:1'],
      mesh_text_telemetry: [attempt],
      text_renderers: [
        {
          page: 1, renderer: :raster, requested_mode: :text3d,
          delivered_mode: :raster, degraded: true, count: 2
        }
      ],
      terminal_cleanup_events: [
        {
          page: 1, cleanup_outcome: :verified, delivered_mode: :raster,
          source_span_ids: ['text_span:1:0', 'text_span:1:1'],
          resulting_entity_ids: ['persistent_id:901']
        }
      ],
      terminal_text_delivery_records: [
        {
          page: 1, source_span_id: 'text_span:1:0',
          requested_mode: :text3d, delivered_mode: :raster,
          delivery_scope: :page_raster, cleanup_outcome: :verified,
          reason: 'text3d_mesh_unavailable_labels_unavailable',
          resulting_entity_ids: ['persistent_id:901']
        },
        {
          page: 1, source_span_id: 'text_span:1:1',
          requested_mode: :text3d, delivered_mode: :raster,
          delivery_scope: :page_raster, cleanup_outcome: :verified,
          reason: 'text3d_mesh_unavailable_labels_unavailable',
          resulting_entity_ids: ['persistent_id:901']
        }
      ],
      source_provenance_objects: [],
      import_report_publication_status: :published,
      import_report_path: 'mixed_terminal_raster_import_report.json'
    }

    contract = contract_for(stats)
    assert_equal true, contract[:ready], contract.inspect
    assert_equal true, contract[:checks][:source_text_delivery_accounted]
    assert_equal true, contract[:checks][:renderer_provenance_consistency]
  end

  def test_same_type_split_entities_require_unique_object_identity_evidence
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 2, layers: [],
      text_mode: :labels, source_text_count: 1,
      source_text_span_ids: ['text_span:1:0'],
      text_renderers: [
        {
          page: 1, renderer: :labels, requested_mode: :labels,
          delivered_mode: :labels, degraded: false, count: 2
        }
      ],
      source_provenance_objects: [
        {
          source_kind: 'text_span', span_id: 'text_span:1:0',
          object_id: 'label_fragment_1', created_entity_type: 'native_label',
          resulting_entity_ids: ['persistent_id:4001']
        },
        {
          source_kind: 'text_span', span_id: 'text_span:1:0',
          object_id: 'label_fragment_2', created_entity_type: 'native_label',
          resulting_entity_ids: ['persistent_id:4002']
        }
      ],
      import_report_publication_status: :published,
      import_report_path: 'split_label_import_report.json'
    }

    contract = contract_for(stats)
    assert_equal true, contract[:ready], contract.inspect
    assert_equal true, contract[:checks][:provenance_integrity]
    assert_equal true, contract[:checks][:renderer_provenance_consistency]
  end

  def test_native_attempt_requires_complete_stable_resulting_entity_ids
    mutations = {
      missing: lambda { |attempt| attempt.delete(:resulting_entity_ids) },
      empty: lambda { |attempt| attempt[:resulting_entity_ids] = [] },
      duplicate: lambda do |attempt|
        attempt[:resulting_entity_ids] = [
          'persistent_id:1001', 'persistent_id:1001'
        ]
      end,
      unknown: lambda do |attempt|
        attempt[:resulting_entity_ids] = ['synthetic_bucket:0']
      end
    }

    mutations.each do |name, mutate|
      stats = Marshal.load(Marshal.dump(valid_native_mesh_stats))
      mutate.call(stats[:mesh_text_telemetry][0])
      contract = contract_for(stats)
      assert_equal false, contract[:ready], name.inspect
      assert_equal false,
                   contract[:checks][:native_3d_attempt_evidence], name.inspect
    end
  end

  def test_provenance_rejects_synthetic_only_or_invalid_resulting_ids
    [
      :missing,
      [],
      ['persistent_id:1001', 'persistent_id:1001'],
      ['text_span:1:0']
    ].each do |value|
      stats = Marshal.load(Marshal.dump(valid_native_mesh_stats))
      entry = stats[:source_provenance_objects][0]
      if value == :missing
        entry.delete(:resulting_entity_ids)
      else
        entry[:resulting_entity_ids] = value
      end
      contract = contract_for(stats)
      assert_equal false, contract[:ready], value.inspect
      assert_equal false, contract[:checks][:provenance_integrity], value.inspect
    end
  end

  def test_attempt_resulting_ids_must_exactly_cross_link_to_provenance
    stats = Marshal.load(Marshal.dump(valid_native_mesh_stats))
    attempt = stats[:mesh_text_telemetry][0]
    attempt[:resulting_entity_ids] = ['persistent_id:9991']
    attempt[:attempt_history][0][:resulting_entity_ids] = ['persistent_id:9991']

    contract = contract_for(stats)
    assert_equal false, contract[:ready]
    assert_equal true, contract[:checks][:native_3d_attempt_evidence]
    assert_equal false, contract[:checks][:provenance_integrity]
  end

  def test_label_provenance_requires_actual_stable_resulting_entity_ids
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 1, layers: [],
      text_mode: :labels, source_text_count: 1,
      source_text_span_ids: ['text_span:1:0'],
      text_renderers: [
        {
          page: 1, renderer: :labels, requested_mode: :labels,
          delivered_mode: :labels, degraded: false, count: 1
        }
      ],
      source_provenance_objects: [
        {
          source_kind: 'text_span', span_id: 'text_span:1:0',
          object_id: 'synthetic_label_bucket',
          created_entity_type: 'native_label'
        }
      ],
      import_report_publication_status: :published,
      import_report_path: 'label_identity_import_report.json'
    }

    contract = contract_for(stats)
    assert_equal false, contract[:ready]
    assert_equal false, contract[:checks][:provenance_integrity]
  end

  def test_equal_cardinality_wrong_source_id_fails_exact_canonical_ledger
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 1, layers: [],
      text_mode: :labels, source_text_count: 1,
      source_text_span_ids: ['text_span:1:0'],
      text_renderers: [
        {
          page: 1, renderer: :labels, requested_mode: :labels,
          delivered_mode: :labels, degraded: false, count: 1
        }
      ],
      source_provenance_objects: [
        {
          source_kind: 'text_span', span_id: 'text_span:1:99',
          created_entity_type: 'native_label',
          resulting_entity_ids: ['persistent_id:5001']
        }
      ],
      import_report_publication_status: :published,
      import_report_path: 'wrong_source_id_import_report.json'
    }

    contract = contract_for(stats)
    assert_equal false, contract[:ready]
    assert_equal true, contract[:checks][:source_text_identity_integrity]
    assert_equal false, contract[:checks][:source_text_delivery_accounted]
  end
end
