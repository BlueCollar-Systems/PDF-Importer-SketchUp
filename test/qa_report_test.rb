#!/usr/bin/env ruby

require 'minitest/autorun'
require 'json'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'

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
end
