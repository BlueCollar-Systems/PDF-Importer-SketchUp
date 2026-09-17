require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder'

class PagePaintBoundsTest < Minitest::Test
  Parser = BlueCollarSystems::PDFVectorImporter::ContentStreamParser
  Builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder

  def setup
    @builder = Builder.allocate
    @builder.instance_variable_set(:@media_box, [0, 0, 100, 80])
  end

  def path(stream)
    Parser.new([stream], nil).parse.fetch(0)
  end

  def outside?(value)
    value = path(value) if value.is_a?(String)
    @builder.send(:paint_entirely_outside_page?, value, @builder.send(:compute_path_bbox, value))
  end

  def test_round_stroke_wholly_outside_is_not_imported
    assert outside?('0.6 w 1 J 1 j -1 80.4 m 101 80.4 l S')
    refute outside?('0.6 w 1 J 1 j -1 80.2 m 101 80.2 l S')
    refute outside?('0.6 w 1 J 1 j -1 80.3 m 101 80.3 l S')
  end

  def test_single_open_line_has_no_miter_even_when_miter_style_is_selected
    assert outside?('0.6 w 0 j 100 M 1 80.4 m 99 80.4 l S')
    refute outside?('0.6 w 0 j 100 M 1 80.4 m 99 80.4 l h S')
  end

  def test_square_caps_use_conservative_corner_radius
    refute outside?('2 w 2 J 1 j 101.3 30 m 105 35 l S')
    assert outside?('2 w 2 J 1 j 102 30 m 105 35 l S')
  end

  def test_miter_join_uses_source_limit
    refute outside?('2 w 0 j 10 M 102 20 m 103 30 l 102 40 l S')
    assert outside?('2 w 0 j 1 M 102 20 m 103 30 l 102 40 l S')
  end

  def test_affine_stroke_expansion_uses_both_matrix_axes
    refute outside?('4 0 3 1 -240 0 cm 2 w 1 J 1 j 0 80.5 m 5 80.5 l S')
    # Horizontal shear contributes to x expansion even if a == 0.
    refute outside?('0 1 4 0 0 0 cm 2 w 1 J 1 j 10 25.5 m 20 25.5 l S')
    assert outside?('0 1 4 0 0 0 cm 2 w 1 J 1 j 10 27 m 20 27 l S')
  end

  def test_fill_bounds_and_partial_intersections
    assert outside?('101 10 3 3 re f')
    assert outside?('-4 10 3 3 re f')
    refute outside?('99 10 3 3 re f')
    refute outside?('100 10 3 3 re f')
  end

  def test_bezier_control_hull_is_retained_when_it_reaches_page
    refute outside?('2 w 1 j 10 90 m 20 30 30 30 40 90 c S')
    assert outside?('2 w 1 j 10 90 m 20 89 30 89 40 90 c S')
  end

  def test_nonzero_page_origin
    @builder.instance_variable_set(:@media_box, [20, -10, 120, 70])
    refute outside?('119 10 3 3 re f')
    assert outside?('121 10 3 3 re f')
    assert outside?('40 -12 3 1 re f')
  end

  def test_unknown_style_and_hairline_are_retained
    value = path('1 w 0 100 m 50 100 l S')
    value.source_stroke_style_proven = false
    refute outside?(value)
    refute outside?('0 w 0 100 m 50 100 l S')
    value.source_stroke_style_proven = true
    value.ctm = nil
    refute outside?(value)
  end

  def test_nonfinite_or_invalid_page_bounds_are_retained
    @builder.instance_variable_set(:@media_box, [0, 0, Float::NAN, 80])
    refute outside?('0 100 10 10 re f')
    @builder.instance_variable_set(:@media_box, [100, 80, 0, 0])
    refute outside?('0 100 10 10 re f')
  end
end
