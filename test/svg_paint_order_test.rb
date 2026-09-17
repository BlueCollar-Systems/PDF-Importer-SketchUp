require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_paint_order'

class SvgPaintOrderTest < Minitest::Test
  Subject = BlueCollarSystems::PDFVectorImporter::SvgPaintOrder
  Renderer = BlueCollarSystems::PDFVectorImporter::SvgTextRenderer
  Cairo = BlueCollarSystems::PDFVectorImporter::CairoGlyphSource
  BOX = [0, 0, 100, 100].freeze
  DEFINITIONS = '<defs><g id="glyph-0-0"><path d="M 0 0 L 4 0 L 4 6 L 0 6 Z"/></g></defs>'.freeze

  def document(body, definitions = DEFINITIONS)
    '<svg viewBox="0 0 100 100">' + definitions + body + '</svg>'
  end

  def use(x = 10, y = 20, extra = '')
    '<use xlink:href="#glyph-0-0" x="' + x.to_s + '" y="' + y.to_s + '" ' + extra + '/>'
  end

  def mask(extra = '')
    '<path fill="white" d="M 9 19 L 15 19 L 15 27 L 9 27 Z" ' + extra + '/>'
  end

  def test_glyph_and_mask_order_use_the_same_original_document_offsets
    svg = document(use + mask + use(40))
    result = Subject.build(svg, BOX)
    assert_empty result[:excluded]
    first, last = result[:glyphs]
    white = result[:white_paths].first
    assert_equal(-1, first[:paint_order] <=> white[:paint_order])
    assert_equal(-1, white[:paint_order] <=> last[:paint_order])
    assert_equal svg.index('<use'), first[:svg_document_offset]
    assert_equal svg.index('<path fill="white"'), white[:svg_document_offset]
    assert_equal [10.0, 74.0, 14.0, 80.0], first[:ink_bbox_pdf]
    assert_equal 0.0, first[:loops][0][0][2]
  end

  def test_nested_affine_style_and_page_offsets_are_explicit
    svg = document('<g transform="translate(5 7)" fill="white"><g transform="scale(2)">' +
      '<rect x="1" y="2" width="3" height="4"/>' + '</g></g>')
    result = Subject.build(svg, [100, 200, 300, 400],
      :svg_page_box => [120, 240, 220, 340], :scale => 2, :x_offset => 3, :y_offset => 4)
    white = result[:white_paths].first
    assert_equal [27.0, 121.0, 33.0, 129.0], white[:ink_bbox_pdf]
    assert_in_delta 27.0 / 36.0 + 3, white[:bounds][0], 1.0e-12
    assert_in_delta 121.0 / 36.0 + 4, white[:bounds][1], 1.0e-12
    assert_equal :nonzero, white[:fill_rule]
  end

  def test_clip_mask_filter_and_hidden_ancestors_never_supply_paint_proof
    ['clip-path="url(#c)"', 'mask="url(#m)"', 'filter="url(#f)"',
     'display="none"', 'visibility="hidden"'].each do |attribute|
      result = Subject.build(document('<g ' + attribute + '>' + mask + use + '</g>'), BOX)
      assert_empty result[:white_paths], attribute
      assert_empty result[:glyphs], attribute
      assert_equal 2, result[:excluded].length, attribute
    end
  end

  def test_context_is_restored_after_an_unsupported_group
    result = Subject.build(document('<g clip-path="url(#c)">' + mask + use + '</g>' + mask + use), BOX)
    assert_equal 1, result[:white_paths].length
    assert_equal 1, result[:glyphs].length
    assert_equal 1, result[:glyphs].first[:placement_index]
  end

  def test_opacity_and_inline_style_override_do_not_make_translucent_white_opaque
    result = Subject.build(document('<g opacity="0.5">' + mask + '</g>' +
      mask('style="fill-opacity:0.3"') + mask('fill-opacity="0.1" style="fill-opacity:1;fill-rule:evenodd"')), BOX)
    assert_equal 1, result[:white_paths].length
    assert_equal 1.0, result[:white_paths].first[:fill_opacity]
    assert_equal :evenodd, result[:white_paths].first[:fill_rule]
  end

  def test_identical_opaque_repaint_retains_first_placement_and_last_order
    svg = document(use + mask + use)
    result = Subject.build(svg, BOX)
    glyph = result[:glyphs].first
    assert_equal 1, result[:glyphs].length
    assert_equal 0, glyph[:placement_index]
    assert_equal [0, 1], glyph[:placement_indices]
    assert_equal 2, glyph[:paint_orders].length
    assert_equal(-1, result[:white_paths].first[:paint_order] <=> glyph[:paint_order])
    assert_same glyph, result[:glyphs_by_placement_index][1]
    assert_equal svg.rindex('<use'), glyph[:svg_document_offset]
  end

  def test_differing_color_and_translucent_repaints_remain_distinct
    result = Subject.build(document(use + use(10, 20, 'fill="red"') +
      use(10, 20, 'fill-opacity=".5"') + use(10, 20, 'fill-opacity=".5"')), BOX)
    assert_equal 4, result[:glyphs].length
    assert_equal [1.0, 0.0, 0.0], result[:glyphs][1][:fill_rgb]
    assert_equal [0.5, 0.5], result[:glyphs].last(2).map { |g| g[:fill_opacity] }
  end

  def test_differing_fill_rules_do_not_steal_the_order_of_an_identical_outline
    compound = '<defs><g id="glyph-0-0"><path d="M 0 0 L 20 0 L 20 20 L 0 20 Z M 5 5 L 15 5 L 15 15 L 5 15 Z"/></g></defs>'
    svg = document(use(10,20,'fill-rule="nonzero"') + mask +
      use(10,20,'fill-rule="evenodd"'), compound)
    result = Subject.build(svg, BOX)
    assert_equal 2, result[:glyphs].length
    assert_equal [:nonzero,:evenodd], result[:glyphs].map { |g| g[:fill_rule] }
    assert_equal [[0],[1]], result[:glyphs].map { |g| g[:placement_indices] }
    assert_equal(-1, result[:glyphs][0][:paint_order] <=> result[:white_paths][0][:paint_order])
    assert_equal(-1, result[:white_paths][0][:paint_order] <=> result[:glyphs][1][:paint_order])
  end

  def test_unsupported_glyph_definition_cannot_certify_an_untransformed_copy
    definitions = '<defs><path id="glyph-0-0" transform="scale(3)" d="M 0 0 L 4 0 L 4 6 Z"/></defs>'
    result = Subject.build(document(use, definitions), BOX)
    assert_empty result[:glyphs]
    assert_equal 'unsupported_glyph_definition', result[:excluded].first[:reason]
  end

  def test_unknown_transform_and_rounded_rect_are_excluded
    result = Subject.build(document('<g transform="unknown(2)">' + mask + '</g>' +
      '<rect width="10" height="10" rx="2" fill="white"/>'), BOX)
    assert_empty result[:white_paths]
    assert_equal ['unsupported_transform', 'unsupported_rounded_rectangle'], result[:excluded].map { |x| x[:reason] }
  end

  def test_empty_source_definitions_are_distinguished_from_unsupported_ink
    definitions = '<defs><g id="glyph-0-0"></g></defs>'
    result = Subject.build(document(use, definitions), BOX)
    assert_empty result[:glyphs]
    assert_equal 'empty_source_glyph_definition', result[:excluded].first[:reason]
  end

  def test_css_transform_and_duplicate_definition_ids_are_not_guessed
    result = Subject.build(document('<g style="transform:scale(2)">' + mask + use + '</g>'), BOX)
    assert_empty result[:glyphs]
    assert_empty result[:white_paths]
    assert_equal ['unsupported_css_transform'], result[:excluded].map { |e| e[:reason] }.uniq
    result = Subject.build(document(use, DEFINITIONS + DEFINITIONS), BOX)
    assert_empty result[:glyphs]
    assert_equal 'unsupported_glyph_definition', result[:excluded].first[:reason]
  end

  def test_document_styles_and_unbalanced_context_fail_closed
    ['<svg viewBox="0 0 100 100"><style>path{fill:white}</style></svg>',
     '<svg viewBox="0 0 100 100"><g>' + mask + '</svg>'].each do |svg|
      result = Subject.build(svg, BOX)
      assert_empty result[:white_paths]
      refute_empty result[:excluded]
    end
  end

  def test_comments_and_definitions_are_not_painted_masks
    svg = document('<!-- ' + mask + ' -->' + mask,
      '<defs><path id="not-a-glyph" fill="white" d="M 0 0 L 5 0 L 5 5 Z"/></defs>')
    assert_equal 1, Subject.build(svg, BOX)[:white_paths].length
  end

  def test_source_use_offset_survives_nested_regexes_without_geometry_changes
    svg = document('<g fill="rgb(10%,20%,30%)">' + use(10, 20, 'transform="matrix(1,0,0,1,0,0)"') + '</g>')
    placement = Renderer.parse_use_placements(svg).first
    assert_equal svg.index('<use'), placement[:source_svg_offset]
    assert_equal [1.0, 0.0, 0.0, 1.0, 0.0, 0.0], placement[:matrix]
    assert_equal [0.1, 0.2, 0.3], placement[:fill_rgb]
    assert_equal [10.0, 20.0], [placement[:x], placement[:y]]
  end

  def clip_definition(id, path, extra = '', rule = 'nonzero')
    '<clipPath id="' + id + '" ' + extra + '><path clip-rule="' + rule + '" d="' + path + '"/></clipPath>'
  end

  def test_covered_linear_clip_keeps_exact_compound_contours_and_clip_rule
    triangle = 'M 10 10 L 30 10 L 20 30 Z M 17 15 L 23 15 L 20 20 Z'
    defs = '<defs>' + clip_definition('outer', 'M 0 0 L 50 0 L 50 50 L 0 50 Z') +
      clip_definition('ink', triangle, '', 'evenodd') + '</defs>'
    body = '<g transform="translate(5 7)" clip-path="url(#outer)"><g clip-path="url(#ink)">' +
      '<rect width="50" height="50" fill="white"/></g></g>'
    svg = document(body, defs)
    result = Subject.build(svg, BOX)
    assert_empty result[:excluded]
    white = result[:white_paths].first
    assert_equal 2, white[:loops].length
    assert_equal :evenodd, white[:fill_rule]
    assert_equal [15.0, 63.0, 35.0, 83.0], white[:ink_bbox_pdf]
    assert_equal ['outer','ink'], white[:clip_ids]
    assert_equal svg.index('<rect width='), white[:svg_document_offset]
    assert_includes white[:clip_proof], 'covers_exact_linear_clip'
  end

  def test_exact_rectangle_clip_intersection_and_unsupported_multiple_complex_clips
    inner = 'M 10 10 L 30 10 L 20 30 Z'
    defs = '<defs>' + clip_definition('inner', inner) +
      clip_definition('other', 'M 15 5 L 35 5 L 25 25 Z') + '</defs>'
    partial = '<g clip-path="url(#inner)"><rect width="20" height="20" fill="white"/></g>'
    multiple = '<g clip-path="url(#inner)"><g clip-path="url(#other)">' +
      '<rect width="50" height="50" fill="white"/></g></g>'
    result = Subject.build(document(partial, defs), BOX)
    assert_empty result[:excluded]
    assert_equal [10.0, 80.0, 20.0, 90.0], result[:white_paths].first[:ink_bbox_pdf]
    assert_equal 'exact_linear_clip_intersection_with_axis_aligned_rectangles', result[:white_paths].first[:clip_proof]
    result = Subject.build(document(multiple, defs), BOX)
    assert_empty result[:white_paths]
    assert_equal 'unsupported_clip_intersection', result[:excluded].first[:reason]
  end

  def test_bounding_box_containment_is_not_complex_clip_containment
    defs = '<defs>' + clip_definition('inner', 'M 20 20 L 40 20 L 40 40 L 20 40 Z') +
      clip_definition('triangle', 'M 0 0 L 50 0 L 0 50 Z') + '</defs>'
    # Partial intersection is computed from actual polygon edges, never from
    # the larger bounding box of its complex clip.
    body = '<g clip-path="url(#inner)"><g clip-path="url(#triangle)">' +
      '<rect width="50" height="50" fill="white"/></g></g>'
    result = Subject.build(document(body, defs), BOX)
    assert_empty result[:excluded]
    assert_equal [20.0, 70.0, 30.0, 80.0], result[:white_paths].first[:ink_bbox_pdf]
    assert_equal 'exact_linear_clip_intersection_with_axis_aligned_rectangles', result[:white_paths].first[:clip_proof]
  end

  def test_rectangle_clipping_preserves_concave_gap_and_opposite_hole_winding
    concave = [[0,0],[4,0],[4,4],[3,4],[3,1],[1,1],[1,4],[0,4],[0,0]]
    clipped = Subject.clip_loop_to_rectangle(concave, [0,2,4,4])
    assert_equal [[0.0,2],[4.0,2],[4,4],[3,4],[3.0,2],[1.0,2],[1,4],[0,4],[0.0,2]], clipped
    hole = [[1,1],[1,3],[3,3],[3,1],[1,1]]
    clipped_hole = Subject.clip_loop_to_rectangle(hole, [0,0,2,4])
    area2 = clipped_hole.each_cons(2).map { |a,b| a[0]*b[1]-b[0]*a[1] }.inject(0.0, :+)
    assert_operator area2, :<, 0.0
    assert_equal 2, clipped_hole.map { |p| p[0] }.max
  end

  def test_unsupported_clip_units_curves_or_duplicate_ids_remain_excluded
    path = 'M 10 10 L 30 10 L 20 30 Z'
    definitions = [
      clip_definition('c', path, 'clipPathUnits="objectBoundingBox"'),
      clip_definition('c', 'M 10 10 C 20 0 30 10 20 30 Z'),
      clip_definition('c', path) + clip_definition('c', path)
    ]
    body = '<g clip-path="url(#c)"><rect width="50" height="50" fill="white"/></g>'
    definitions.each do |definition|
      result = Subject.build(document(body, '<defs>' + definition + '</defs>'), BOX)
      assert_empty result[:white_paths]
      assert_equal 'unsupported_clip-path', result[:excluded].first[:reason]
    end
  end

  def test_missing_clip_rule_never_guesses_away_inherited_evenodd_holes
    defs = '<defs clip-rule="evenodd"><clipPath id="c"><path d="M 0 0 L 20 0 L 20 20 L 0 20 Z M 5 5 L 15 5 L 15 15 L 5 15 Z"/></clipPath></defs>'
    body = '<g clip-path="url(#c)"><rect width="50" height="50" fill="white"/></g>'
    result = Subject.build(document(body, defs), BOX)
    assert_empty result[:white_paths]
    assert_equal 'unsupported_clip-path', result[:excluded].first[:reason]
  end
end
