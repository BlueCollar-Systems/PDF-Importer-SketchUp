require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_paint_order'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_paint_binding'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_parser'

class IntegerNumericLegacyFidelityTest < Minitest::Test
  Subject = BlueCollarSystems::PDFVectorImporter

  def test_integer_page_and_crop_coordinates_keep_paint_geometry
    svg = '<svg viewBox="0 0 100 100"><rect x="10" y="20" width="30" height="40" fill="black"/></svg>'
    result = Subject::SvgPaintOrder.build(svg, [0, 0, 100, 100])
    assert_empty result[:excluded]
    assert_equal 1, result[:opaque_paths].length
    assert_equal [10.0, 40.0, 40.0, 80.0], result[:opaque_paths][0][:ink_bbox_pdf]
  end

  def test_integer_rgb_retains_exact_source_channel_proof
    assert Subject::SvgPaintOrder.opaque_fill?(:fill => [0, 0, 0], :alpha => 1.0)
    assert Subject::SvgPaintBinding.source_fill_style?(
      { :fill_rgb => [0.0, 0.0, 0.0] },
      { :fill_rgb => [0, 0, 0], :fill_opacity => 1.0 }
    )
    refute Subject::SvgPaintOrder.opaque_fill?(:fill => [0, 0, Float::INFINITY], :alpha => 1.0)
    refute Subject::SvgPaintBinding.source_fill_style?(
      { :fill_rgb => [0.0, 0.0, 0.0] },
      { :fill_rgb => [0, 0, Float::NAN], :fill_opacity => 1.0 }
    )
  end

  def test_unrepresentable_integer_coordinates_still_fail_before_paint
    svg = '<svg viewBox="0 0 100 100"><rect x="1" y="2" width="3" height="4"/></svg>'
    result = Subject::SvgPaintOrder.build(svg, [0, 0, 10 ** 400, 100])
    assert_equal 'invalid_page_box', result[:excluded].first[:reason]
    assert_raises(ArgumentError) { Subject::SvgPaintOrder.coordinate_mapping(svg, [0, 0, 10 ** 400, 100], {}) }
  end
end
