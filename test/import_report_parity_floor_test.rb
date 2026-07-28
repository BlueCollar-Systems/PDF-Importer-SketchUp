#!/usr/bin/env ruby

require 'json'
require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'

class ImportReportParityFloorTest < Minitest::Test
  FLOOR_PATH = File.expand_path('fixtures/sketchup_report_parity_floor.json', __dir__)

  def floor
    JSON.parse(File.read(FLOOR_PATH))
  end

  def parity_smoke_report
    stats = {
      pages: 1,
      primitives: 50_001,
      edges: 50_001,
      text: 3,
      layers: [],
      elapsed_seconds: 1.0,
      text_renderers: [],
      text_mode: :labels,
      source_text_count: 3,
      source_text_span_ids: [
        'text_span:1:0', 'text_span:1:1', 'text_span:1:2'
      ],
      source_provenance_objects: Array.new(3) do |index|
        {
          source_kind: 'text_span', span_id: "text_span:1:#{index}",
          created_entity_type: 'native_label',
          resulting_entity_ids: ["persistent_id:#{6_000 + index}"]
        }
      end,
      font_substitution_note: 'Non-embedded PDF fonts detected.',
      resolved_scale: {
        factor: 48.0,
        notation: '1/4" = 1\'-0"',
        source: 'titleblock',
        confidence: 0.50
      },
      generic: { title_block: true, dimensions: 3 }
    }
    BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats('parity.pdf', {}, stats)
  end

  def native_mesh_report
    stats = {
      pages: 1, primitives: 1, edges: 1, text: 1, layers: [],
      text_mode: :text3d,
      source_text_count: 1,
      source_text_span_ids: ['text_span:1:0'],
      text_renderers: [
        {
          page: 1, renderer: :add_3d_text, requested_mode: :text3d,
          delivered_mode: :text3d, count: 1, degraded: false
        }
      ],
      source_provenance_objects: [
        {
          source_kind: 'text_span', span_id: 'text_span:1:0',
          created_entity_type: 'native_3d_text',
          resulting_entity_ids: ['persistent_id:6101']
        }
      ],
      mesh_text_telemetry: [
        {
          page: 1, source_span_id: 'text_span:1:0', requested_mode: :text3d,
           delivered_mode: :text3d, outcome: :complete,
           visual_fidelity_verified: true,
          source_height_verified: true,
          fit_status: :fitted, fit_reason: 'bbox_overflow_shrink',
          fit_measurement_verified: true,
          cleanup_outcome: :not_required,
          resulting_entity_ids: ['persistent_id:6101'],
          delivered_font: 'Arial',
          pdf_em_height_in: 0.1, sketchup_letter_height_in: 0.07,
          letter_height_ratio: 0.7, matrix_x: 1.0,
          residual_x: 1.0, total_x: 1.0,
          attempt_history: [
            {
              mode: :text3d, outcome: :complete,
              cleanup_outcome: :not_required, delivered_mode: :text3d,
              resulting_entity_ids: ['persistent_id:6101']
            }
          ]
        }
      ]
    }
    BlueCollarSystems::PDFVectorImporter::QAReport.build_from_stats(
      'native.pdf', {}, stats
    )
  end

  def assert_conditional_fields(report, native_mesh)
    extra = report[:extra] || {}
    floor.fetch('conditional_extra_fields', {}).each_key do |field|
      required = case field
                 when 'actual_text_entity_types' then true
                 when 'text_height_crosscheck' then native_mesh
                 else
                   flunk "Unknown conditional report field must define a test predicate: #{field}"
                 end
      next unless required
      key = extra.key?(field.to_sym) ? field.to_sym : field
      assert extra.key?(key), "Missing conditional SketchUp report field: #{field}"
      refute_nil extra[key], "Conditional SketchUp report field is null: #{field}"
    end
  end

  def test_report_extra_matches_checked_in_floor
    report = parity_smoke_report
    extra = report[:extra] || {}
    missing = floor['required_extra_fields'].reject { |field| extra.key?(field.to_sym) || extra.key?(field) }
    assert_empty missing, "Missing SketchUp report parity fields: #{missing.join(', ')}"
    assert_conditional_fields(report, false)
  end

  def test_native_mesh_report_enforces_conditional_telemetry_floor
    assert_conditional_fields(native_mesh_report, true)
  end
end
