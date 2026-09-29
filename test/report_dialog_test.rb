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

  def test_completion_status_names_composited_inline_pictures_and_omissions
    stats = {
      pages: 6, edges: 10, text: 4,
      inline_image_composites: [
        { page: 5, inline_image_instance_count: 2175, region_count: 1, delivery: :inline_images_composited, placed: true },
        { page: 6, inline_image_instance_count: 2000, region_count: 2, delivery: :inline_images_composited, placed: true }
      ],
      inline_image_vector_retentions: [
        { page: 6, inline_image_instance_count: 175, delivery: :inline_images_omitted }
      ]
    }
    status = R.completion_status(stats)
    assert_includes status, 'Inline image pieces composited into 3 placed pictures on pages 5-6 (vectors kept).'
    assert_includes status, 'Inline images not placed on page 6 (vectors kept).'
    assert_equal [[5, 2175, 1], [6, 2000, 2]], R.inline_image_composited_pages(stats)
    assert_empty R.inline_image_composited_pages(inline_image_composites: [{ page: 7, inline_image_instance_count: 0, region_count: 1 }])
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

  def test_cancelled_copy_names_kept_pages_and_exact_resume_page
    stats = {
      :cancelled => true,
      :retained_pages => [1, 2],
      :next_page => 3,
      :pages => 2
    }
    assert_equal(
      'PDF import cancelled — pages 1-2 kept; resume starts at page 3.',
      R.cancelled_status(stats)
    )
    summary = R.build_summary(stats)
    assert_includes summary, 'Import Cancelled'
    assert_includes summary, 'Pages 1-2 were kept.'
    assert_includes summary, 'Resume starts at page 3.'
    refute_includes summary, 'Import Complete!'
  end
end
