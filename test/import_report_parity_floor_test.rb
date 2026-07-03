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

  def test_report_extra_matches_checked_in_floor
    report = parity_smoke_report
    extra = report[:extra] || {}
    missing = floor['required_extra_fields'].reject { |field| extra.key?(field.to_sym) || extra.key?(field) }
    assert_empty missing, "Missing SketchUp report parity fields: #{missing.join(', ')}"
  end
end
