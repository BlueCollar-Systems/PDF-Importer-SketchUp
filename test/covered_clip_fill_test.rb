require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder'

class CoveredClipFillTest < Minitest::Test
  Parser = BlueCollarSystems::PDFVectorImporter::ContentStreamParser
  Builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder
  Point = Struct.new(:x, :y)
  TRIANGLE = '2 2 m 8 2 l 5 8 l h'.freeze

  def parse(content)
    Parser.new([content], nil).parse
  end

  def test_covering_rectangle_preserves_compound_clip_and_evenodd_holes
    paths = parse("q #{TRIANGLE} 4 3 2 2 re W* n 0 0 10 10 re f Q")
    assert_equal 1, paths.length
    assert_equal :evenodd, paths[0].clip_fill_rule
    assert_equal 2, paths[0].subpaths.length
    assert_equal [2, 2], paths[0].subpaths[0].segments[0].points[0]
  end

  def test_clip_is_in_page_coordinates_and_restored_by_Q
    paths = parse("q 2 0 0 2 10 20 cm #{TRIANGLE} W n 0 0 10 10 re f Q 0 0 10 10 re f")
    assert_equal :nonzero, paths[0].clip_fill_rule
    assert_equal [14, 24], paths[0].subpaths[0].segments[0].points[0]
    assert_nil paths[1].clip_fill_rule
    assert_equal [0, 0], paths[1].subpaths[0].segments[0].points[0]
  end

  def test_nested_covering_rectangle_clip_does_not_remove_the_compound_clip
    paths = parse("0 0 10 10 re W n #{TRIANGLE} W n 0 0 10 10 re f")
    assert_equal :nonzero, paths[0].clip_fill_rule
  end

  def test_partial_or_stroked_fill_is_not_misrepresented_as_entire_clip
    assert_nil parse("#{TRIANGLE} W n 0 0 5 5 re f")[0].clip_fill_rule
    assert_nil parse("#{TRIANGLE} W n 0 0 10 10 re B")[0].clip_fill_rule
    assert_nil parse("0 0 5 5 re W n #{TRIANGLE} W n 0 0 10 10 re f")[0].clip_fill_rule
  end

  def test_fill_winding_preserves_counters_and_evenodd_distinction
    outer = [[0,0],[10,0],[10,10],[0,10]].map { |xy| Point.new(*xy) }
    inner = [[3,3],[7,3],[7,7],[3,7]].map { |xy| Point.new(*xy) }
    assert_equal 1, Builder.contour_winding(Point.new(1,1), [outer, inner.reverse])
    assert_equal 0, Builder.contour_winding(Point.new(5,5), [outer, inner.reverse])
    assert_equal 2, Builder.contour_winding(Point.new(5,5), [outer, inner])
    assert_equal 0, Builder.contour_winding(Point.new(12,5), [outer, inner])
  end
end
