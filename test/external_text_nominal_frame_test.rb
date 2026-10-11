require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/logger'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/text_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/nominal_text_scanner'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/external_text_extractor'

class ExternalTextNominalFrameTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter

  def html(box, height)
    x0, y0, x1, y1 = box
    attrs = "xMin=\"#{x0}\" xMax=\"#{x1}\" yMin=\"#{height-y1}\" yMax=\"#{height-y0}\""
    "<page height=\"#{height}\"><line #{attrs}><word #{attrs}>BEAM</word></line></page>"
  end

  def test_rotated_lines_match_nominal_anchors_in_original_pdf_coordinates
    [90, 180, 270].each do |rotation|
      media = [10.0, 20.0, 310.0, 520.0]
      displayed = IMP::PageTransform.transform_bbox(100, 200, 132, 208, media, rotation)
      height = IMP::PageTransform.effective_height(media, rotation)
      source = IMP::NominalTextScanner::Anchor.new(100, 200, 14, 0)
      # A different source item happens to occupy the old, wrong frame.
      decoy = IMP::NominalTextScanner::Anchor.new(displayed[0], displayed[1], 34, 45)
      items = IMP::ExternalTextExtractor.send(:parse_bbox_html, html(displayed, height),
        :media_box => media, :page_rotation => rotation,
        :nominal_anchors => [source, decoy], :strict_text_fidelity => true)
      assert_equal 1, items.length
      assert_in_delta 14, items.first.font_size, 1e-9, "rotation #{rotation} uses the source size"
      assert_in_delta 0, items.first.angle, 1e-9, "rotation #{rotation} uses the source angle"
    end
  end

  def test_crop_offset_is_applied_before_nominal_anchor_matching
    source = IMP::NominalTextScanner::Anchor.new(180, 300, 14, 20)
    decoy = IMP::NominalTextScanner::Anchor.new(80, 100, 34, 45)
    items = IMP::ExternalTextExtractor.send(:parse_bbox_html, html([80, 100, 112, 108], 500),
      :offset_x_pts => 100, :offset_y_pts => 200,
      :nominal_anchors => [source, decoy], :strict_text_fidelity => true)
    assert_in_delta 14, items.first.font_size, 1e-9
    assert_in_delta 20, items.first.angle, 1e-9
  end

  def test_positive_source_nominal_size_is_not_clamped_to_one_point
    anchor = IMP::NominalTextScanner::Anchor.new(100, 200, 0.5, 0)
    items = IMP::ExternalTextExtractor.send(:parse_bbox_html, html([100, 200, 110, 201], 500),
      :nominal_anchors => [anchor], :strict_text_fidelity => true)
    assert_in_delta 0.5, items.first.font_size, 1e-9
  end

  def test_negative_source_nominal_size_keeps_its_small_physical_height_and_angle
    anchor = IMP::NominalTextScanner::Anchor.new(100, 200, -0.5, -90)
    items = IMP::ExternalTextExtractor.send(:parse_bbox_html, html([100, 200, 110, 201], 500),
      :nominal_anchors => [anchor], :strict_text_fidelity => true)
    assert_in_delta 0.5, items.first.font_size, 1e-9
    assert_in_delta(-90, items.first.angle, 1e-9)
  end
end
