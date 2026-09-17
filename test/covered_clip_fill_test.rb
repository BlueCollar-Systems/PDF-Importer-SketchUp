require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/primitives'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/primitive_extractor'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/late_pdf_overlays'

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

  def test_partial_rectangle_intersects_linear_clip_and_preserves_stroke_behavior
    partial = parse("#{TRIANGLE} W n 0 0 5 5 re f")[0]
    assert_equal :nonzero, partial.clip_fill_rule
    assert_equal [[3.5,5],[2,2],[5,2],[5,5]], contour(partial)
    assert_nil parse("#{TRIANGLE} W n 0 0 10 10 re B")[0].clip_fill_rule
    ancestor = parse("0 0 5 5 re W n #{TRIANGLE} W n 0 0 10 10 re f")[0]
    assert_equal :nonzero, ancestor.clip_fill_rule
    assert_equal contour(partial), contour(ancestor)
  end

  def contour(path, index = 0)
    path.subpaths[index].segments.drop(1).map { |segment| segment.points[0] }
  end

  def winding(path, x, y)
    loops = path.subpaths.each_index.map { |index| contour(path, index).map { |xy| Point.new(*xy) } }
    Builder.contour_winding(Point.new(x,y), loops)
  end

  def test_slightly_short_paint_keeps_notch_without_expanding_boundary
    notch = '0 0 m 8 0 l 8 4 l 10 5 l 8 6 l 8 10 l 0 10 l h'
    path = parse("#{notch} W* n 0 0 9.9999 10 re f")[0]
    assert_equal :evenodd, path.clip_fill_rule
    assert_equal 9.9999, contour(path).map(&:first).max
    assert_includes contour(path), [8,4]
    assert_equal 0, winding(path,9,2)
    assert_equal 1, winding(path,9,5).abs
  end

  def test_three_contours_keep_two_evenodd_counters_under_partial_clip
    path = parse('0 0 10 10 re 2 2 2 2 re 6 6 2 2 re W* n 0 0 9.9999 10 re f')[0]
    assert_equal :evenodd, path.clip_fill_rule
    assert_equal 3, path.subpaths.length
    assert_equal 1, winding(path,1,1).abs
    assert_equal 0, winding(path,3,3).abs % 2
    assert_equal 0, winding(path,7,7).abs % 2
    assert_equal 9.9999, contour(path).map(&:first).max
  end

  def test_three_contours_keep_nonzero_hole_and_separate_component
    source = '0 0 10 10 re 2 2 m 2 4 l 4 4 l 4 2 l h 12 0 2 2 re'
    path = parse("#{source} W n 0 0 13 10 re f")[0]
    assert_equal :nonzero, path.clip_fill_rule
    assert_equal 3, path.subpaths.length
    assert_equal 0, winding(path,3,3)
    assert_equal 1, winding(path,1,1).abs
    assert_equal 1, winding(path,12.5,1).abs
    assert_equal 0, winding(path,13.5,1)
  end

  def test_five_compound_contours_keep_holes_and_nested_islands
    source = '0 0 20 20 re 2 2 5 5 re 3 3 2 2 re 12 12 5 5 re 13 13 2 2 re'
    path = parse("#{source} W* n 0 0 19.9999 20 re f")[0]
    assert_equal 5, path.subpaths.length
    assert_equal 1, winding(path,1,1).abs % 2
    assert_equal 0, winding(path,2.5,2.5).abs % 2
    assert_equal 1, winding(path,4,4).abs % 2
    assert_equal 0, winding(path,12.5,12.5).abs % 2
    assert_equal 1, winding(path,14,14).abs % 2
  end

  def test_empty_intersection_has_no_fill_and_source_clip_state_remains_exact
    paths = parse("#{TRIANGLE} W n 20 20 5 5 re f 0 0 10 10 re f")
    assert_equal :nonzero, paths[0].clip_fill_rule
    assert_empty paths[0].subpaths
    assert_equal [[2,2],[8,2],[5,8]], contour(paths[1])
  end

  def test_empty_clip_passes_extraction_and_build_without_creating_geometry_or_text_evidence
    path = parse("#{TRIANGLE} W n 20 20 5 5 re f")[0]
    importer = BlueCollarSystems::PDFVectorImporter
    page = importer::PrimitiveExtractor.extract([path], [], [0,0,30,30], 1)
    assert_empty page.primitives
    assert_empty importer::LatePdfOverlays.eligible_records([path], [])
    assert_equal 1.0, path.source_fill_opacity
    refute_nil path.source_paint_order
    # This target deliberately has no geometry creation API. Empty source ink
    # must skip drawing entirely, including the compound-fill host entry point.
    model = Struct.new(:active_entities, :layers).new(Object.new, {'PDF Import' => Object.new})
    builder = Builder.new(model, [path], [], [0,0,30,30], :group_per_page => false)
    assert_nil builder.send(:compute_path_bbox, path)
    result = builder.build
    assert_equal [0,0,0,0], result.values_at(:edges, :faces, :arcs, :text_objects)
    assert_empty builder.fill_only_groups
    assert_empty result[:source_provenance_objects]
    assert_empty result[:text_attempts]
    assert_empty result[:text_delivery_failures]
  end

  def test_partial_curved_clip_is_not_flattened_or_claimed_as_exact_linear_clip
    path = parse('0 0 m 10 0 10 10 0 10 c h W n 0 0 5 5 re f')[0]
    assert_nil path.clip_fill_rule
  end

  def test_fill_winding_preserves_counters_and_evenodd_distinction
    outer = [[0,0],[10,0],[10,10],[0,10]].map { |xy| Point.new(*xy) }
    inner = [[3,3],[7,3],[7,7],[3,7]].map { |xy| Point.new(*xy) }
    assert_equal 1, Builder.contour_winding(Point.new(1,1), [outer, inner.reverse])
    assert_equal 0, Builder.contour_winding(Point.new(5,5), [outer, inner.reverse])
    assert_equal 2, Builder.contour_winding(Point.new(5,5), [outer, inner])
    assert_equal 0, Builder.contour_winding(Point.new(12,5), [outer, inner])
  end

  def test_source_polygon_overlapping_clip_is_not_an_arc_fit_candidate
    clips = [[10, 10, 20, 20]]
    assert Builder.overlaps_clip_fill?([9, 9, 21, 21], clips)
    assert Builder.overlaps_clip_fill?([12, 12, 18, 18], clips)
    refute Builder.overlaps_clip_fill?([21, 21, 30, 30], clips)
    refute Builder.overlaps_clip_fill?(nil, clips)
  end
end
