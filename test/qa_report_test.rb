#!/usr/bin/env ruby

require 'minitest/autorun'
require 'json'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'

QAReportTextItem = Struct.new(:text, :page_number, :bbox_x0, :bbox_y0, :id)

class QAReportTest < Minitest::Test
  def test_report_preserves_immutable_normalized_and_salvage_lineage
    lineage = {
      original_pdf_path: 'C:/owner/original.pdf',
      original_pdf_sha256: '1' * 64,
      immutable_pdf_path: 'C:/evidence/source.pdf',
      immutable_pdf_sha256: '2' * 64,
      normalized_pdf_path: 'C:/temp/salvaged.pdf',
      normalized_pdf_sha256: '3' * 64,
      salvage_note: 'normalized damaged xref'
    }
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 0, layers: [],
      text_renderers: [], source_lineage: lineage
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      lineage[:immutable_pdf_path], { import_mode: 'vector' }, stats
    )

    assert_equal JSON.parse(JSON.generate(lineage)),
                 JSON.parse(JSON.generate(report[:extra][:source_lineage]))
  end

  def test_report_binds_requested_mode_session_and_full_provenance_even_when_empty
    stats = {
      pages: 1,
      primitives: 1,
      edges: 1,
      text: 0,
      arcs: 0,
      layers: [],
      text_renderers: [],
      requested_text_mode: :labels,
      text_mode: :labels,
      import_session_id: 'session-report-1',
      source_provenance_objects: []
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.
      build_from_stats('sample.pdf', { import_mode: 'vector' }, stats)

    assert_equal 'labels', report[:extra][:requested_text_mode]
    assert_equal 'session-report-1', report[:extra][:import_session_id]
    assert_equal 'session-report-1',
                 report[:extra][:source_provenance][:import_session_id]
    assert_equal [], report[:extra][:source_provenance][:objects]
  end

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
        {
          page: 1, renderer: :pdftocairo, text_source: :external,
          degraded: false,
          solid_cache: {
            definition_builds: 2, instance_placements: 8
          },
          performance: {
            definition_build_ms: 4.5, instance_placement_ms: 1.25
          }
        },
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
    assert_equal 2,
                 report[:extra][:text_renderers][0]['solid_cache']['definition_builds']
    assert_in_delta 1.25,
                    report[:extra][:text_renderers][0]['performance']['instance_placement_ms'],
                    0.001
    assert_in_delta 48.0, report[:extra][:resolved_scale]['factor'], 0.01
    assert_equal 'high', report[:extra][:diagnostics][:quality_level]
    assert_includes report[:extra][:diagnostics][:signals], 'good_vector_content'
    assert_includes report[:extra][:diagnostics][:signals], 'pdf_layers_preserved'
    assert_includes report[:extra][:diagnostics][:signals], 'text_mode_geometry'
    assert report[:extra][:human_summary].to_s.include?('Imported')
    assert report[:extra][:human_summary].to_s.include?('sample.pdf')
  end

  # PH1-SU-2 (P1-3 fleet parity): the report must be attributable evidence.
  # BOTH surfaces are asserted — the JSON importer.version value must be the
  # real extension version (never 'unknown' when metadata is loaded, which is
  # the shipped-runtime arrangement), and the human summary must carry the
  # same version substring the other hosts' summaries carry.
  def test_report_attributes_importer_version_in_json_and_human_summary
    stats = { pages: 1, primitives: 3, edges: 3, text: 1, layers: [], elapsed_seconds: 0.2 }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('sample.pdf', {}, stats)

    expected = BlueCollarSystems::PDFVectorImporter::VERSION

    json_version = report[:importer][:version].to_s
    refute_empty json_version, 'JSON importer.version must be present'
    refute_equal 'unknown', json_version,
                 'JSON importer.version must resolve the real extension version'
    assert_equal expected, json_version

    summary = report[:extra][:human_summary].to_s
    assert_includes summary, "Importer v#{expected}",
                    'human summary must attribute the importer version'
    refute_includes summary, 'Importer vunknown'
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

  def test_does_not_fabricate_actual_text_entity_types_from_requested_mode
    stats = {
      pages: 1,
      primitives: 40,
      edges: 40,
      text: 12,
      layers: [],
      elapsed_seconds: 0.8,
      text_renderers: [],
      text_mode: :labels
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('text.pdf', {}, stats)
    extra = report[:extra]
    entity = extra[:actual_text_entity_types]
    assert_nil entity
    assert_equal false,
                 extra[:import_contract_ready][:checks][:actual_text_entity_types]
    refute_nil report[:report_meta]
    assert_includes report[:report_meta][:build_stamp].to_s, 'sketchup'
  end

  def test_extraction_only_report_never_claims_host_entity_delivery
    stats = {
      pages: 1, primitives: 12, edges: 0, text: 0, layers: [],
      execution_scope: :extraction_only, extracted_text_items: 2,
      text_mode: :text3d, text_renderers: [],
      text_source_span_ids: ['text_span:1:0', 'text_span:1:1']
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'extract-only.pdf', { text_mode: :text3d }, stats
    )
    extra = report[:extra]
    assert_equal 'extraction_only', extra[:execution_scope]
    assert_equal 2, extra[:extracted_text_items]
    assert_equal 0, report[:result][:text_entities]
    assert_nil extra[:actual_text_entity_types]
    assert_equal false, extra[:representation_fidelity][:ready]
    assert_equal true, extra[:representation_fidelity][:not_applicable]
    assert_includes extra[:representation_fidelity][:errors],
                    'host_representation_delivery_not_performed'
    contract = extra[:import_contract_ready]
    assert_equal false, contract[:ready]
    assert_equal false, contract[:checks][:host_entity_delivery]
  end

  def qa_transition(source_id, from_mode, to_mode)
    {
      source_span_id: source_id,
      importer_id: 'sketchup_pdf_vector_importer',
      page_number: source_id.split(':')[1].to_i,
      scope: :item,
      category: :exact_representation_impossible,
      affirmative_impossibility: true,
      generic_failure: false,
      from_mode: from_mode,
      to_mode: to_mode,
      reason_code: :source_item_identity_unavailable,
      attempted_renderer: "#{from_mode}_source_renderer",
      created_entity_ids: [],
      cleaned_entity_ids: [],
      cleanup_outcome: :not_required,
      evidence: { fresh_inventory_evaluation: true }
    }
  end

  def qa_page_mode_stats(requested_mode, delivered_mode, page_number)
    source_id = "text_span:#{page_number}:0"
    entity_id = 'persistent_id:811'
    {
      pages: 1, selected_pages: [page_number], primitives: 1, edges: 1,
      text: 1, layers: [], text_mode: requested_mode,
      requested_text_mode: requested_mode,
      text_source_span_ids: [source_id], source_provenance_objects: [],
      fallback_transitions: [], terminal_text_delivery_records: [],
      raster_delivery_records: [], source_glyph_physical_deliveries: [],
      text_attempts: [{
        page: page_number, source_span_ids: [source_id],
        requested_mode: delivered_mode, delivered_mode: delivered_mode,
        resulting_entity_ids: [entity_id], visual_fidelity_verified: true,
        attempt_history: [{
          mode: delivered_mode, outcome: :complete,
          resulting_entity_ids: [entity_id], visual_fidelity_verified: true,
          cleanup_outcome: :not_required
        }]
      }],
      page_text_delivery_records: [{
        page: page_number, source_span_ids: [source_id],
        requested_mode: delivered_mode, delivered_mode: delivered_mode,
        resulting_entity_ids: [entity_id],
        created_entity_type: delivered_mode == :geometry ?
          'page_path_geometry' : 'glyph_outline',
        visual_fidelity_verified: true
      }]
    }
  end

  def test_representation_fidelity_rejects_record_requested_mode_spoof
    stats = qa_page_mode_stats(:labels, :geometry, 1)

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'spoof.pdf', { text_mode: :labels, pages: [1] }, stats
    )
    fidelity = report[:extra][:representation_fidelity]

    assert_equal false, fidelity[:ready]
    assert fidelity[:errors].any? { |error| error.include?('requested_mode') },
           fidelity[:errors].join(', ')
  end

  def test_representation_fidelity_rejects_span_evidence_outside_selected_pages
    stats = qa_page_mode_stats(:geometry, :geometry, 2)
    stats[:selected_pages] = [1]

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'wrong-page.pdf', { text_mode: :geometry, pages: [1] }, stats
    )
    fidelity = report[:extra][:representation_fidelity]

    assert_equal false, fidelity[:ready]
    assert fidelity[:errors].any? { |error| error.include?('selected_page') },
           fidelity[:errors].join(', ')
  end

  def test_requested_raster_rejects_self_declared_non_raster_delivery
    entity_id = 'persistent_id:812'
    record = {
      page: 1, source_span_ids: [], requested_mode: :labels,
      delivered_mode: :raster, resulting_entity_ids: [entity_id],
      created_entity_type: 'Group', real_raster_verified: true,
      visual_fidelity_verified: true, cleanup_outcome: :not_required,
      delivery_scope: :page_raster,
      delivery_basis: :explicit_full_page_raster,
      full_page_raster_request: true, semantic_text_evaluated: false
    }
    stats = {
      pages: 1, selected_pages: [1], primitives: 1, edges: 0, text: 0,
      layers: [], text_mode: :raster, requested_text_mode: :raster,
      normalized_input_sha256: 'c' * 64,
      text_source_span_ids: [], text_attempts: [],
      source_provenance_objects: [], page_text_delivery_records: [],
      terminal_text_delivery_records: [record], raster_delivery_records: [record],
      fallback_transitions: [], source_glyph_physical_deliveries: []
    }

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'raster.pdf', { text_mode: :raster, pages: [1] }, stats
    )
    fidelity = report[:extra][:representation_fidelity]

    assert_equal false, fidelity[:ready]
    assert fidelity[:errors].any? { |error| error.include?('raster_delivery') },
           fidelity[:errors].join(', ')

    record[:requested_mode] = :raster
    record[:created_entity_type] = 'raster_image'
    record[:artifact_evidence] = {
      page_number: 1, pixel_width: 1200, pixel_height: 1600,
      png_signature_verified: true, page_binding_verified: true,
      box_binding_verified: true, content_sha256: 'b' * 64,
      content_byte_size: 48_000, source_pdf_sha256: 'c' * 64,
      source_pdf_binding_verified: true
    }
    accepted = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'raster.pdf', { text_mode: :raster, pages: [1] }, stats
    )[:extra][:representation_fidelity]
    assert_equal true, accepted[:ready], accepted[:errors].join(', ')

    record[:no_semantic_text] = true
    mislabeled = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'raster.pdf', { text_mode: :raster, pages: [1] }, stats
    )[:extra][:representation_fidelity]
    assert_equal false, mislabeled[:ready]
    assert mislabeled[:errors].any? { |error| error.include?('raster') },
           mislabeled[:errors].join(', ')
  end

  def test_source_glyph_3d_text_requires_and_accepts_complete_host_evidence
    id = 'text_span:1:0'
    entity_id = 'persistent_id:101'
    evidence = {
      placement_verified: true, rotation_verified: true,
      width_verified: true, height_verified: true,
      entity_type_verified: true, visual_fidelity_verified: true,
      source_glyph_identity_verified: true,
      positive_z_depth_verified: true
    }
    stats = {
      pages: 1, primitives: 1, edges: 0, text: 1, layers: [],
      text_mode: :text3d, text_source_span_ids: [id],
      source_provenance_objects: [{
        span_id: id, source_kind: 'text_span',
        created_entity_type: 'source_glyph_3d_text',
        resulting_entity_ids: [entity_id]
      }.merge(evidence)],
      text_attempts: [{
        source_span_id: id, requested_mode: :text3d,
        delivered_mode: :text3d, resulting_entity_ids: [entity_id],
        attempt_history: [{
          mode: :text3d, outcome: :complete,
          resulting_entity_ids: [entity_id], cleanup_outcome: :not_required
        }.merge(evidence)]
      }.merge(evidence)]
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'text3d.pdf', { text_mode: :text3d }, stats
    )
    fidelity = report[:extra][:representation_fidelity]
    assert_equal true, fidelity[:ready], fidelity[:errors].join(', ')
    assert_equal '3d_text',
                 report[:extra][:actual_text_entity_types]['entity_type']

    stats[:text_attempts][0].delete(:rotation_verified)
    failed = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'text3d.pdf', { text_mode: :text3d }, stats
    )
    assert_equal false, failed[:extra][:representation_fidelity][:ready]
  end

  def test_item_raster_fallback_requires_exact_adjacent_transition_ledger
    id = 'text_span:1:0'
    entity_id = 'persistent_id:901'
    transitions = [
      qa_transition(id, :text3d, :glyphs),
      qa_transition(id, :glyphs, :geometry),
      qa_transition(id, :geometry, :raster)
    ]
    history = transitions.map do |transition|
      {
        mode: transition[:from_mode], outcome: :failed,
        reason: transition[:reason_code], transition_proof: transition,
        created_entity_ids: [], cleaned_entity_ids: [],
        resulting_entity_ids: [], cleanup_outcome: :not_required,
        visual_fidelity_verified: false
      }
    end
    history << {
      mode: :raster, outcome: :complete,
      resulting_entity_ids: [entity_id], cleanup_outcome: :not_required,
      real_raster_verified: true, source_crop_binding_verified: true,
      visual_fidelity_verified: true
    }
    source_sha = 'd' * 64
    artifact = {
      source_span_id: id, page_number: 1,
      source_box: [10.0, 20.0, 40.0, 50.0],
      pixel_crop: [20, 40, 60, 60], pixel_width: 60, pixel_height: 60,
      png_signature_verified: true, page_binding_verified: true,
      source_crop_binding_verified: true, aspect_verified: true,
      alpha_channel_verified: true,
      transparent_background_verified: true,
      visible_pixel_verified: true,
      page_render_once_verified: true,
      page_render_content_sha256: 'e' * 64,
      content_sha256: 'f' * 64, content_byte_size: 1024,
      source_pdf_sha256: source_sha, source_pdf_binding_verified: true
    }
    stats = {
      pages: 1, primitives: 1, edges: 0, text: 1, layers: [],
      text_mode: :text3d, text_source_span_ids: [id],
      normalized_input_sha256: source_sha,
      fallback_transitions: transitions,
      source_provenance_objects: [],
      text_attempts: [{
        source_span_id: id, requested_mode: :text3d,
        delivered_mode: :raster, resulting_entity_ids: [entity_id],
        real_raster_verified: true, source_crop_binding_verified: true,
        visual_fidelity_verified: true, attempt_history: history
      }],
      terminal_text_delivery_records: [{
        page: 1, source_span_ids: [id], requested_mode: :text3d,
        delivered_mode: :raster, resulting_entity_ids: [entity_id],
        created_entity_type: 'raster_image',
        real_raster_verified: true, source_crop_binding_verified: true,
        visual_fidelity_verified: true, cleanup_outcome: :not_required,
        delivery_scope: :item_raster,
        artifact_evidence: artifact
      }]
    }
    stats[:raster_delivery_records] = [
      stats[:terminal_text_delivery_records][0].dup
    ]
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'fallback.pdf', { text_mode: :text3d }, stats
    )
    fidelity = report[:extra][:representation_fidelity]
    assert_equal true, fidelity[:ready], fidelity[:errors].join(', ')
    actual = report[:extra][:actual_text_entity_types]
    assert_equal 'raster', actual['entity_type']
    assert_equal 1, actual['raster_image']
    assert_equal 1, actual['count']

    stats[:terminal_text_delivery_records][0][:artifact_evidence][
      :alpha_channel_verified
    ] = false
    stats[:raster_delivery_records][0][:artifact_evidence][
      :alpha_channel_verified
    ] = false
    opaque = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'fallback.pdf', { text_mode: :text3d }, stats
    )[:extra][:representation_fidelity]
    assert_equal false, opaque[:ready]
    stats[:terminal_text_delivery_records][0][:artifact_evidence][
      :alpha_channel_verified
    ] = true
    stats[:raster_delivery_records][0][:artifact_evidence][
      :alpha_channel_verified
    ] = true

    stats[:fallback_transitions] = transitions.values_at(0, 2)
    broken = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'fallback.pdf', { text_mode: :text3d }, stats
    )
    assert_equal false, broken[:extra][:representation_fidelity][:ready]
    assert_includes broken[:extra][:representation_fidelity][:errors],
                    'fallback_transition_ledger_mismatch'
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
      source_provenance_objects: [
        { created_entity_type: 'native_3d_text' },
        { created_entity_type: 'native_label' }
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
          created_entity_type: 'native_label'
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

  def test_closed_shape_extrusion_is_disabled_without_blocking_3d_text
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
    assert_equal 'closed_shape_extrusion_disabled',
                 report[:extra][:model_3d]['skipped_reason']
    refute_match(/3D.text|text/i,
                 report[:extra][:model_3d]['skipped_reason'])
  end

  def test_fallback_transition_proofs_and_terminal_cleanup_are_loud
    stats = {
      pages: 1, primitives: 1, edges: 0, text: 0, layers: [],
      text_renderers: [{
        page: 1, renderer: :pdftocairo_real_raster, mode: :raster,
        requested_mode: :text3d, delivered_mode: :raster,
        degraded: true, reason: 'affirmative item-specific impossibility',
        count: 1, real_raster_verified: true
      }],
      raster_fallback_used: true,
      fallback_transitions: [{
        page: 1, source_span_id: 'text_span:1:0', from_mode: :text3d,
        to_mode: :glyphs, reason_code: :source_item_identity_unavailable,
        importer_id: 'sketchup_pdf_vector_importer', page_number: 1,
        affirmative_impossibility: true, generic_failure: false,
        cleanup_outcome: :not_required
      }],
      terminal_text_delivery_records: [{
        page: 1, source_span_ids: ['text_span:1:0'],
        requested_mode: :text3d, delivered_mode: :raster,
        real_raster_verified: true, visual_fidelity_verified: true,
        cleanup_outcome: :verified, delivery_scope: :page_raster
      }],
      terminal_cleanup_events: [{
        page: 1, cleanup_outcome: :verified,
        terminal_raster_entity_id: 'persistent_id:77'
      }]
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'fallback.pdf', { text_mode: :text3d }, stats
    )

    assert report[:fallback][:used]
    assert_equal '3d_text', report[:fallback][:text][:requested]
    assert_equal 'raster', report[:fallback][:text][:delivered]
    assert_equal 1, report[:extra][:fallback_transitions].length
    assert_equal true,
                 report[:extra][:fallback_transitions][0]['affirmative_impossibility']
    assert_equal 'sketchup_pdf_vector_importer',
                 report[:extra][:fallback_transitions][0]['importer_id']
    assert_equal 1, report[:extra][:fallback_transitions][0]['page_number']
    assert_equal 1, report[:extra][:terminal_text_delivery_records].length
    assert_equal true,
                 report[:extra][:terminal_text_delivery_records][0]['real_raster_verified']
    assert_equal 'verified',
                 report[:extra][:terminal_text_delivery_records][0]['cleanup_outcome']
    assert_equal 'page_raster',
                 report[:extra][:terminal_text_delivery_records][0]['delivery_scope']
    assert_equal 'verified',
                 report[:extra][:terminal_cleanup_events][0]['cleanup_outcome']
  end


  def test_image_only_terminal_raster_is_valid_without_fabricating_text_span_ids
    stats = {
      pages: 1, primitives: 0, edges: 0, text: 0, layers: [],
      source_input_sha256: 'a' * 64,
      normalized_input_sha256: 'b' * 64,
      text_source_span_ids: [], text_attempts: [],
      source_provenance_objects: [],
      terminal_text_delivery_records: [{
        page: 1, source_span_ids: [], no_semantic_text: true,
        delivery_basis: :verified_zero_canonical_text,
        semantic_text_evaluated: true, canonical_text_item_count: 0,
        requested_mode: :text3d, delivered_mode: :raster,
        resulting_entity_ids: ['persistent_id:91'],
        created_entity_type: 'raster_image',
        real_raster_verified: true, visual_fidelity_verified: true,
        cleanup_outcome: :not_required, delivery_scope: :page_raster,
        artifact_evidence: {
          page_number: 1, png_signature_verified: true,
          page_binding_verified: true, box_binding_verified: true
        }
      }],
      empty_page_source_inspections: [{
        page: 1, source_page_number: 1, canonical_text_item_count: 0,
        immutable_pdf_sha256: 'a' * 64, rendered_pdf_sha256: 'b' * 64,
        semantic_text_extraction_complete: true,
        decoded_stream_text_operators: false,
        decoded_form_stream_text_operators: false
      }]
    }
    stats[:raster_delivery_records] = [
      stats[:terminal_text_delivery_records][0].dup
    ]

    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'image-only.pdf', { text_mode: :text3d }, stats
    )
    fidelity = report[:extra][:representation_fidelity]

    assert_equal true, fidelity[:ready], fidelity[:errors].join(', ')
    assert_empty fidelity[:errors]

    stats[:empty_page_source_inspections][0][
      :semantic_text_extraction_complete
    ] = false
    false_proof = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'image-only.pdf', { text_mode: :text3d }, stats
    )[:extra][:representation_fidelity]
    assert_equal false, false_proof[:ready]
  end

  def test_image_only_page_fallback_and_physical_glyph_delivery_are_loud
    stats = {
      pages: 1, primitives: 0, edges: 0, text: 1, layers: [],
      text_renderers: [],
      page_representation_fallbacks: [{
        page: 1, scope: :page,
        reason_code: :visible_nontext_source_only,
        delivered_mode: :raster,
        real_raster_verified: true
      }],
      empty_page_source_inspections: [{
        page: 1, source_glyph_placements: 0,
        source_uses: 1, visible_nontext_source: true
      }],
      representation_ownership_group_forced_pages: [{
        page: 2, requested_text_mode: :text3d,
        requested_group_per_page: false, effective_group_per_page: true,
        reason_code: :representation_entity_ownership_required
      }],
      source_glyph_physical_deliveries: [{
        page: 2,
        source_unit_id: 'svg_glyph_placements:page:2',
        placement_indices: [2027, 3059],
        delivered_mode: :text3d,
        positive_z_depth_verified: true
      }]
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'source-pages.pdf', { text_mode: :text3d }, stats
    )

    assert_equal 'visible_nontext_source_only',
      report[:extra][:page_representation_fallbacks][0]['reason_code']
    assert_equal true,
      report[:extra][:empty_page_source_inspections][0]['visible_nontext_source']
    assert_equal 'representation_entity_ownership_required',
      report[:extra][:representation_ownership_group_forced_pages][0]['reason_code']
    assert_equal [2027, 3059],
      report[:extra][:source_glyph_physical_deliveries][0]['placement_indices']
  end

  def test_physical_source_glyph_delivery_requires_provenance_crosslink
    entity_id = 'persistent_id:701'
    unit_id = 'svg_glyph_placements:page:2:0-3'
    stats = {
      pages: 1, primitives: 1, edges: 0, text: 1, layers: [],
      text_source_span_ids: [], text_attempts: [],
      source_provenance_objects: [{
        object_id: unit_id, span_id: nil, page: 2,
        source_kind: 'svg_glyph_placement', semantic_identity_available: false,
        created_entity_type: 'source_glyph_3d_text',
        resulting_entity_ids: [entity_id], source_placement_indices: [0, 3],
        source_glyph_identity_verified: true,
        positive_z_depth_verified: true
      }],
      source_glyph_physical_deliveries: [{
        page: 2, source_unit_id: unit_id, placement_indices: [0, 3],
        resulting_entity_ids: [entity_id], delivered_mode: :text3d,
        visual_fidelity_verified: true, positive_z_depth_verified: true,
        source_glyph_identity_verified: true
      }]
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'physical.pdf', { text_mode: :text3d }, stats
    )
    fidelity = report[:extra][:representation_fidelity]
    assert_equal true, fidelity[:ready], fidelity[:errors].join(', ')

    stats[:source_glyph_physical_deliveries][0][:resulting_entity_ids] =
      ['persistent_id:702']
    failed = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'physical.pdf', { text_mode: :text3d }, stats
    )
    assert_equal false, failed[:extra][:representation_fidelity][:ready]
    assert_includes failed[:extra][:representation_fidelity][:errors],
                    'physical_glyph_delivery_crosslink_invalid'
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

  # Round 20 (R20-1b/R20-2): mesh-text sizing health must reach the report.
  def test_text_height_crosscheck_reports_samples_and_fallbacks
    stats = {
      pages: 1, primitives: 5, edges: 5, text: 3, layers: [],
      elapsed_seconds: 0.2,
      text_height_samples: [0.30, 0.10, 0.20],
      text_height_fallback_count: 2
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('t.pdf', {}, stats)
    cc = report[:extra][:text_height_crosscheck]
    refute_nil cc, 'crosscheck block must be present when samples exist'
    assert_equal 3, cc[:sample_count]
    assert_in_delta 0.10, cc[:min_in], 1e-6
    assert_in_delta 0.20, cc[:median_in], 1e-6
    assert_in_delta 0.30, cc[:max_in], 1e-6
    assert_equal 'nominal_pt_to_inch_x_scale', cc[:policy]
    assert_equal 2, cc[:fallback_count],
                 'Ruby 2.2-floor engagements must be visible in the report (R20-2)'
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

  # Round 22: width-fidelity health must reach the report (condensed
  # title-block parity — declared/rendered run-width factors).
  def test_text_width_crosscheck_reports_factors_and_counters
    stats = {
      pages: 1, primitives: 5, edges: 5, text: 3, layers: [],
      elapsed_seconds: 0.2,
      text_width_factor_samples: [1.4365, 0.5864, 0.7996],
      text_width_out_of_bounds_count: 1,
      text_width_skipped_near_1_count: 4,
      text_width_error_count: 0
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('t.pdf', {}, stats)
    cc = report[:extra][:text_width_crosscheck]
    refute_nil cc, 'width crosscheck must be present when factors were applied'
    assert_equal 3, cc[:sample_count]
    assert_in_delta 0.5864, cc[:min_factor], 1e-6
    assert_in_delta 0.7996, cc[:median_factor], 1e-6
    assert_in_delta 1.4365, cc[:max_factor], 1e-6
    assert_equal [0.5864, 0.7996, 1.4365], cc[:samples]
    assert_equal 'declared_span_width_over_rendered_run_width', cc[:policy]
    assert_equal 1, cc[:out_of_bounds_count]
    assert_equal 4, cc[:skipped_near_1_count]
    assert_equal 0, cc[:error_count]
  end

  def test_text_width_crosscheck_present_when_only_counters_occurred
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 1, layers: [],
      elapsed_seconds: 0.1,
      text_width_factor_samples: [],
      text_width_out_of_bounds_count: 2,
      text_width_skipped_near_1_count: 0,
      text_width_error_count: 1
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('t.pdf', {}, stats)
    cc = report[:extra][:text_width_crosscheck]
    refute_nil cc, 'out-of-bounds/error-only imports must still surface the block'
    assert_equal 0, cc[:sample_count]
    assert_equal 2, cc[:out_of_bounds_count]
    assert_equal 1, cc[:error_count],
                 'width-path failures must be visible in the report (R20-2)'
  end

  def test_text_width_crosscheck_absent_without_width_reconciliation
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 0, layers: [],
      elapsed_seconds: 0.1
    }
    report = BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('t.pdf', {}, stats)
    assert_nil report[:extra][:text_width_crosscheck],
               'no width reconciliation happened — block stays absent'
  end
end
