require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/late_pdf_overlays'

class LatePdfOverlaysTest < Minitest::Test
  Parser = BlueCollarSystems::PDFVectorImporter::ContentStreamParser
  Subject = BlueCollarSystems::PDFVectorImporter::LatePdfOverlays
  Compositor = BlueCollarSystems::PDFVectorImporter::PlanarWhiteKnockout
  RECTANGLE = '0 1 1 rg 0 1 1 RG 2 w 10 20 30 40 re B'.freeze
  EFFECTS = { '/Alpha' => { :alpha => 0.3, :stroke_alpha => :preserve,
                           :mask_clear => :preserve, :blend_normal => :preserve } }.freeze

  def parse(stream = RECTANGLE)
    Parser.new(['/Alpha gs ' + stream], nil, {}, EFFECTS).parse
  end

  def test_exact_rectangle_retains_both_paints_and_source_bounds
    path = parse.first
    record = Subject.rectangle_record(path, 4)
    assert_equal [10.0, 20.0, 40.0, 60.0], record[:bounds]
    assert_equal 2.0, record[:stroke_width]
    assert_equal 0.3, record[:fill_opacity]
    assert_equal 1.0, record[:stroke_opacity]
    assert_same path, record[:path]
    assert_equal 4, record[:path_index]
  end

  def test_visible_fill_and_miter_bands_partition_expanded_stroke_bounds
    paints = Subject.paint_polygons(Subject.rectangle_record(parse.first))
    assert_equal 5, paints.length
    assert_equal [[11.0, 21.0], [39.0, 21.0], [39.0, 59.0], [11.0, 59.0]], paints[0][:points]
    assert_equal [0.3, 1.0, 1.0, 1.0, 1.0], paints.map { |paint| paint[:opacity] }
    areas = paints.map { |paint| Compositor.loop_area(paint[:points]) }
    assert_equal 28.0 * 38.0, areas.first
    assert_equal 32.0 * 42.0, areas.inject(0.0, :+)
  end

  def test_transformed_width_uses_uniform_ctm_and_rejects_shear_or_nonuniform_scale
    record = Subject.rectangle_record(parse('2 0 0 2 5 7 cm ' + RECTANGLE).first)
    assert_equal [25.0, 47.0, 85.0, 127.0], record[:bounds]
    assert_equal 4.0, record[:stroke_width]
    assert_nil Subject.rectangle_record(parse('2 0 0 3 0 0 cm ' + RECTANGLE).first)
    assert_nil Subject.rectangle_record(parse('1 0 0.2 1 0 0 cm ' + RECTANGLE).first)
    assert_equal 1.0, Subject.uniform_ctm_scale([0, 1, -1, 0, 0, 0])
  end

  def test_any_clip_even_a_covering_page_rectangle_excludes_late_overlay
    assert_nil Subject.rectangle_record(parse('0 0 1000 1000 re W n ' + RECTANGLE).first)
    paths = parse('q 0 0 1000 1000 re W n ' + RECTANGLE + ' Q ' + RECTANGLE)
    assert_nil Subject.rectangle_record(paths[0])
    refute_nil Subject.rectangle_record(paths[1])
  end

  def test_unknown_transparency_unproven_stroke_and_nonmiter_or_dashed_style_are_excluded
    ['/Unknown gs ', '1 M ', '1 j ', '[2 1] 0 d '].each do |prefix|
      assert_nil Subject.rectangle_record(parse(prefix + RECTANGLE).first)
    end
    path = parse.first
    path.source_stroke_opacity = 0.5
    assert_nil Subject.rectangle_record(path)
    path.source_stroke_opacity = 1.0
    path.source_stroke_style_proven = false
    assert_nil Subject.rectangle_record(path)
    refute_nil Subject.rectangle_record(parse('[] 0 d ' + RECTANGLE).first)
  end

  def test_only_final_suffix_after_all_text_and_other_paints_is_eligible
    paths = parse(RECTANGLE + ' 0 g 0 0 1 1 re f ' + RECTANGLE + ' ' + RECTANGLE)
    result = Subject.eligible_records(paths, [[0, 0]])
    assert_equal [2, 3], result.map { |record| record[:path_index] }
    last = paths[-1].source_paint_order
    assert_empty Subject.eligible_records(paths, [last])
    assert_empty Subject.eligible_records(paths, [nil])
    assert_empty Subject.eligible_records(paths, [], [nil])
    paths[1].source_paint_order = nil
    assert_empty Subject.eligible_records(paths, [])
  end

  def test_open_curved_degenerate_or_too_thick_shapes_are_excluded
    path = parse.first
    path.subpaths[0].closed = false
    assert_nil Subject.rectangle_record(path)
    assert_nil Subject.rectangle_record(parse(RECTANGLE.sub('2 w', '40 w')).first)
    assert_nil Subject.rectangle_record(parse('0 0 m 10 0 l 10 10 l h B').first)
  end

  def test_no_filename_color_or_mode_specific_eligibility
    path = parse.first
    path.fill_color, path.stroke_color = [1.0, 0.2, 0.7], [0.1, 0.2, 0.3]
    path.source_fill_opacity = 0.81
    record = Subject.rectangle_record(path)
    assert_equal [1.0, 0.2, 0.7], record[:fill_rgb]
    assert_equal [0.1, 0.2, 0.3], record[:stroke_rgb]
    assert_equal 0.81, record[:fill_opacity]
  end
end
