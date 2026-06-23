#!/usr/bin/env ruby

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

require 'bc_pdf_vector_importer/report_dialog'

class ReportDialogTest < Minitest::Test
  R = BlueCollarSystems::PDFVectorImporter::ReportDialog

  def test_report_groups_text_renderers_by_page
    summary = R.build_summary(
      pages: 3,
      edges: 10,
      faces: 0,
      arcs: 0,
      text: 42,
      text_mode: :geometry,
      text_renderers: [
        { page: 1, renderer: :pdftocairo, degraded: false },
        { page: 2, renderer: :pdftocairo, degraded: false },
        { page: 3, renderer: :labels, degraded: true }
      ]
    )

    assert_includes summary, "Text renderer details:"
    assert_includes summary, "Poppler SVG (pdftocairo): pages 1-2."
    assert_includes summary, "SketchUp label fallback: page 3 (degraded)."
  end

  def test_format_page_list_compacts_ranges
    assert_equal "1-3, 7, 9-10", R.format_page_list([3, 2, 1, 10, 9, 7])
  end

  def test_report_notes_dense_glyph_component_performance_mode
    summary = R.build_summary(
      pages: 1,
      edges: 65_444,
      text: 1_919,
      text_mode: :geometry,
      text_renderers: [
        { page: 1, renderer: :pdftocairo, degraded: false,
          text_performance_mode: :glyph_components }
      ]
    )

    assert_includes summary,
      "Dense text used reusable glyph components for performance; outlines remain vector geometry."
  end
end
