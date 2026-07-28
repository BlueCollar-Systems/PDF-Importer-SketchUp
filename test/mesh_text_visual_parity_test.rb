#!/usr/bin/env ruby
require_relative 'mesh_text_scaling_test'

class VisualFontLayerManager
  def resolve(_name)
    Object.new
  end

  def match_pdf_layers
    false
  end

  def text_fallback_layer
    Object.new
  end
end

class FixedWidthTransformEntities < DummyTransformEntities
  attr_reader :generated_entities

  def initialize(width)
    super()
    @fixed_width = width.to_f
    @generated_entities = []
  end

  def add_3d_text(_text, _align, font, bold, italic, height, tolerance,
                  _extrusion, filled, _z)
    @font_style_args << [font, bold, italic]
    @height_args << height
    @tolerance_args << tolerance
    @filled_args << filled
    @generated_entities = [
      DummyRenderedTextEntity.new(@fixed_width, height, typename: 'Edge'),
      DummyFaceEntity.new
    ]
    @entities.concat(@generated_entities)
    true
  end
end

class MeshTextVisualParityTest < Minitest::Test
  def builder_with_fonts(fonts, extra = {})
    options = {
      scale_factor: 1.0,
      import_text: true,
      use_3d_text: true,
      installed_font_families: fonts
    }.merge(extra)
    GB.new(Object.new, [], [], LETTER, options)
  end

  def render_item(text, family, ratio, bbox_height = 2.0)
    item = TI.new(text, 50.0, 100.0, 12.0, 0.0, 'pdftotext', nil,
                  50.0, 100.0, 150.0, 100.0 + bbox_height)
    item.source_font_family = family
    item.source_font_bold = family == 'Arial'
    item.source_font_italic = false
    item.font_to_sketchup_letter_ratio = ratio
    item.font_to_sketchup_letter_ratio_source = :known_font
    item
  end

  def build_item_with_fonts(item, fonts)
    entities = DummyTransformEntities.new
    builder = GB.new(Object.new, [], [item], LETTER, scale_factor: 1.0,
                     import_text: true, use_3d_text: true,
                     group_per_page: false, target_entities: entities,
                     layer_manager: VisualFontLayerManager.new,
                     installed_font_families: fonts)
    builder.define_singleton_method(:mesh_text_residual_x_scale) do |*_args|
      [1.0, :fitted, 'bbox_exact_match', true]
    end
    [builder.build, entities]
  end

  def test_exact_known_ratios_and_12pt_arial_canary
    builder = builder_with_fonts(['Arial', 'Arial Narrow', 'RomanT'])
    arial = render_item('SECTION A', 'Arial', 1491.0 / 2048.0)
    romant = render_item('R', 'RomanT', 1538.0 / 2048.0)
    assert_in_delta 0.121337890625,
                    builder.send(:mesh_text_height_inches, arial, 0.0, 792.0), 1.0e-12
    assert_in_delta (12.0 / 72.0) * (1538.0 / 2048.0),
                    builder.send(:mesh_text_height_inches, romant, 0.0, 792.0), 1.0e-12
  end

  def test_span_bbox_content_never_changes_vertical_metric
    builder = builder_with_fonts(['Arial'])
    %w[1234 () gypq SECTION].each do |text|
      tiny = render_item(text, 'Arial', 1491.0 / 2048.0, 0.5)
      tall = render_item(text, 'Arial', 1491.0 / 2048.0, 50.0)
      assert_in_delta builder.send(:mesh_text_height_inches, tiny, 0.0, 792.0),
                      builder.send(:mesh_text_height_inches, tall, 0.0, 792.0), 1.0e-12
    end
  end

  def test_unavailable_romant_substitutes_arial_and_uses_arial_metric
    builder = builder_with_fonts(['Arial'])
    item = render_item('R', 'RomanT', 1538.0 / 2048.0)
    profile = builder.send(:mesh_text_font_profile, item)
    assert_equal 'Arial', profile[:family]
    assert_match(/RomanT.*Arial/, profile[:substitution_reason])
    assert_in_delta 1491.0 / 2048.0, profile[:letter_height_ratio], 1.0e-12
  end

  def test_poisoned_arial_ratio_cannot_override_known_family_metric
    builder = builder_with_fonts(['Arial'])
    item = render_item('A', 'Arial', 0.90)
    item.font_to_sketchup_letter_ratio_source = :font_descriptor_ascent
    profile = builder.send(:mesh_text_font_profile, item)
    assert_in_delta 1491.0 / 2048.0, profile[:letter_height_ratio], 1.0e-12
    assert_equal :known_arial_family, profile[:metric_source]
  end

  def test_poisoned_romant_ratio_cannot_override_known_family_metric
    builder = builder_with_fonts(['RomanT'])
    item = render_item('R', 'RomanT', 0.90)
    item.font_to_sketchup_letter_ratio_source = :font_descriptor_ascent
    profile = builder.send(:mesh_text_font_profile, item)
    assert_in_delta 1538.0 / 2048.0, profile[:letter_height_ratio], 1.0e-12
    assert_equal :known_romant, profile[:metric_source]
  end

  def test_installed_unknown_family_accepts_trusted_descriptor_ascent
    builder = builder_with_fonts(['Drafting Sans'])
    item = render_item('D', 'Drafting Sans', 0.83)
    item.font_to_sketchup_letter_ratio_source = :font_descriptor_ascent
    profile = builder.send(:mesh_text_font_profile, item)
    assert_equal 'Drafting Sans', profile[:family]
    assert_in_delta 0.83, profile[:letter_height_ratio], 1.0e-12
    assert_equal :font_descriptor_ascent, profile[:metric_source]
  end

  def test_installed_unknown_family_rejects_untrusted_metric_truthfully
    builder = builder_with_fonts(['Drafting Sans'])
    item = render_item('D', 'Drafting Sans', 0.83)
    item.font_to_sketchup_letter_ratio_source = :known_font
    profile = builder.send(:mesh_text_font_profile, item)
    assert_in_delta 1491.0 / 2048.0, profile[:letter_height_ratio], 1.0e-12
    assert_equal :default_arial_family, profile[:metric_source]
  end

  def test_installed_unknown_family_rejects_out_of_range_metric_truthfully
    builder = builder_with_fonts(['Drafting Sans'])
    item = render_item('D', 'Drafting Sans', 0.99)
    item.font_to_sketchup_letter_ratio_source = :font_descriptor_ascent
    profile = builder.send(:mesh_text_font_profile, item)
    assert_in_delta 1491.0 / 2048.0, profile[:letter_height_ratio], 1.0e-12
    assert_equal :default_arial_family, profile[:metric_source]
  end

  def test_installed_unknown_family_rejects_nonfinite_metric_truthfully
    builder = builder_with_fonts(['Drafting Sans'])
    item = render_item('D', 'Drafting Sans', Float::INFINITY)
    item.font_to_sketchup_letter_ratio_source = :font_descriptor_ascent
    profile = builder.send(:mesh_text_font_profile, item)
    assert_in_delta 1491.0 / 2048.0, profile[:letter_height_ratio], 1.0e-12
    assert_equal :default_arial_family, profile[:metric_source]
  end

  def test_successful_substitution_is_reported_by_build_result
    item = render_item('R', 'RomanT', 1538.0 / 2048.0)
    result, entities = build_item_with_fonts(item, ['Arial'])
    assert_equal ['Arial', false, false], entities.font_style_args.last
    assert_equal [
      {
        page: 1,
        source_span_id: nil,
        requested_font: 'RomanT',
        delivered_font: 'Arial',
        reason: 'RomanT unavailable; using Arial'
      }
    ], result[:text_font_substitutions]
  end

  def test_selected_family_and_style_are_passed_to_add_3d_text
    builder = builder_with_fonts(['Arial Narrow'])
    item = render_item('TITLE', 'Arial Narrow', 1491.0 / 2048.0)
    item.source_font_bold = true
    item.source_font_italic = true
    entities = DummyTransformEntities.new
    builder.send(:place_mesh_text, entities, item, 0.0, 0.0, nil)
    assert_equal ['Arial Narrow', true, true], entities.font_style_args.last
  end

  def test_matrix_x_accepts_only_finite_positive_trusted_values
    builder = builder_with_fonts(['Arial'])
    item = render_item('MATRIX', 'Arial', 1491.0 / 2048.0)
    cases = [
      [nil, 1.0],
      [0.0, 1.0],
      [-0.25, 1.0],
      [Float::NAN, 1.0],
      [Float::INFINITY, 1.0],
      [-Float::INFINITY, 1.0],
      [1.436458, 1.436458]
    ]
    cases.each do |value, expected|
      item.trusted_text_matrix_x_scale = value
      assert_in_delta expected, builder.send(:mesh_text_matrix_x_scale, item), 1.0e-12,
                      "matrix-X validation failed for #{value.inspect}"
    end
  end

  def test_trusted_matrix_x_can_grow_while_bbox_residual_never_grows
    builder = builder_with_fonts(['Arial Narrow'])
    item = render_item('ONE FRAME', 'Arial Narrow', 1491.0 / 2048.0)
    item.trusted_text_matrix_x_scale = 1.436458
    item.bbox_x0, item.bbox_x1 = 0.0, 200.0
    generated = [DummyRenderedTextEntity.new(1.0, 0.1)]

    residual, status, reason = builder.send(
      :mesh_text_residual_x_scale, item, generated, 0.0, 1.436458
    )

    assert_equal [1.0, :skipped, 'no_overflow'], [residual, status, reason]
    assert_in_delta 1.436458,
                    builder.send(:mesh_text_matrix_x_scale, item) * residual, 1.0e-6
  end

  def test_residual_boundary_is_inclusive_at_half_and_never_grows
    builder = builder_with_fonts(['Arial'])
    item = render_item('BOM', 'Arial', 1491.0 / 2048.0)
    item.bbox_x0 = 0.0
    generated = [DummyRenderedTextEntity.new(1.0, 0.1)]

    item.bbox_x1 = 72.0
    assert_equal [1.0, :skipped, 'no_overflow', false],
                 builder.send(:mesh_text_residual_x_scale, item, generated, 0.0, 1.0)

    item.bbox_x1 = 36.0
    residual, status, reason = builder.send(
      :mesh_text_residual_x_scale, item, generated, 0.0, 1.0
    )
    assert_in_delta 0.50, residual, 1.0e-12
    assert_equal [:fitted, 'bbox_overflow_shrink'], [status, reason]

    item.bbox_x1 = 35.999928
    residual, status, reason = builder.send(
      :mesh_text_residual_x_scale, item, generated, 0.0, 1.0
    )
    assert_operator residual, :<, 0.50
    assert_equal [:rejected_outlier, 'residual_below_0_50'], [status, reason]
  end

  def test_residual_axis_and_angle_tolerance_boundaries
    builder = builder_with_fonts(['Arial'])
    item = render_item('AXIS', 'Arial', 1491.0 / 2048.0)
    generated = [DummyRenderedTextEntity.new(1.0, 0.1)]

    item.bbox_x0, item.bbox_x1 = 0.0, 36.0
    [0.0, 3.0].each do |angle|
      residual, status, = builder.send(
        :mesh_text_residual_x_scale, item, generated, angle, 1.0
      )
      assert_in_delta 0.50, residual, 1.0e-12
      assert_equal :fitted, status
    end

    item.bbox_y0, item.bbox_y1 = 0.0, 36.0
    [90.0, -90.0].each do |angle|
      residual, status, = builder.send(
        :mesh_text_residual_x_scale, item, generated, angle, 1.0
      )
      assert_in_delta 0.50, residual, 1.0e-12
      assert_equal :fitted, status
    end

    assert_equal [1.0, :skipped, 'diagonal_angle', false],
                 builder.send(:mesh_text_residual_x_scale, item, generated, 3.01, 1.0)
  end

  def test_page_rotations_compose_bbox_and_display_angle_exactly_once
    item = render_item('ROTATED PAGE', 'Arial', 1491.0 / 2048.0)
    item.angle = 0.0
    item.bbox_x0, item.bbox_x1 = 0.0, 36.0
    item.bbox_y0, item.bbox_y1 = 100.0, 102.0
    generated = [DummyRenderedTextEntity.new(1.0, 0.1)]

    [[90, 90.0], [270, 90.0]].each do |page_rotation, expected_display_angle|
      builder = builder_with_fonts(['Arial'], page_rotation: page_rotation)
      display_angle = builder.send(:display_text_angle, item, item.angle)
      assert_in_delta expected_display_angle, display_angle, 1.0e-12
      assert_in_delta 0.50,
                      builder.send(:mesh_text_bbox_run_width_inches, item, display_angle),
                      1.0e-12
      residual, status, = builder.send(
        :mesh_text_residual_x_scale, item, generated, display_angle, 1.0
      )
      assert_in_delta 0.50, residual, 1.0e-12
      assert_equal :fitted, status
    end
  end

  def test_place_mesh_text_multiplies_subunit_matrix_by_residual_before_placement
    builder = builder_with_fonts(['Arial'])
    item = render_item('COMPOSED SHRINK', 'Arial', 1491.0 / 2048.0)
    item.angle = 90.0
    item.trusted_text_matrix_x_scale = 0.8
    item.bbox_x0, item.bbox_x1 = 10.0, 12.0
    item.bbox_y0 = 0.0
    item.bbox_y1 = 0.6 / GB::PDF_POINT_TO_INCH
    entities = FixedWidthTransformEntities.new(1.0)
    anchor_pdf = builder.send(:mesh_label_anchor_pdf, item)
    expected_anchor = builder.send(
      :text_point_to_su, item, anchor_pdf[0], anchor_pdf[1], 0.0, 0.0
    )

    assert builder.send(:place_mesh_text, entities, item, 0.0, 0.0, Object.new)

    display_angle = builder.send(:display_text_angle, item, anchor_pdf[2])
    matrix_x = builder.send(:mesh_text_matrix_x_scale, item)
    residual_x, fit_status, fit_reason = builder.send(
      :mesh_text_residual_x_scale,
      item,
      entities.generated_entities,
      display_angle,
      matrix_x
    )
    assert_in_delta 0.8, matrix_x, 1.0e-12,
                    'valid trusted subunit matrix-X must not default to 1.0'
    assert_in_delta 0.75, residual_x, 1.0e-12
    assert_equal [:fitted, 'bbox_overflow_shrink'], [fit_status, fit_reason]
    assert_in_delta 0.6, matrix_x * residual_x, 1.0e-12

    assert_equal [:scaling, :translation, :rotation],
                 entities.transforms.map { |args| args.first.kind }
    scale, translation, rotation = entities.transforms.map(&:first)
    assert_same ORIGIN, scale.args[0]
    assert_equal [ORIGIN, 0.6, 1.0, 1.0], scale.args,
                 'placement must call scaling with exact [0.6, 1.0, 1.0] arguments'
    translated_anchor = translation.args[0]
    assert_in_delta expected_anchor.x, translated_anchor.x, 1.0e-12
    assert_in_delta expected_anchor.y, translated_anchor.y, 1.0e-12
    assert_same translated_anchor, rotation.args[0]
  end

  def test_vertical_raw_angles_compose_with_page_rotation_once_before_axis_selection
    generated = [DummyRenderedTextEntity.new(1.0, 0.1)]
    cases = [
      [90.0, 90, 0.0, :x],
      [-90.0, 90, 0.0, :x],
      [90.0, 270, 0.0, :x],
      [-90.0, 270, 0.0, :x],
      [90.0, 180, 90.0, :y],
      [-90.0, 180, 90.0, :y]
    ]

    cases.each do |raw_angle, page_rotation, expected_angle, expected_axis|
      builder = builder_with_fonts(['Arial'], page_rotation: page_rotation)
      item = render_item('VERTICAL', 'Arial', 1491.0 / 2048.0)
      item.angle = raw_angle
      item.bbox_x0, item.bbox_x1 = 10.0, 12.0
      item.bbox_y0, item.bbox_y1 = 100.0, 136.0
      display_angle = builder.send(:display_text_angle, item, raw_angle)
      transformed = BlueCollarSystems::PDFVectorImporter::PageTransform.transform_bbox(
        item.bbox_x0, item.bbox_y0, item.bbox_x1, item.bbox_y1,
        LETTER, page_rotation
      )
      x_points = (transformed[2] - transformed[0]).abs
      y_points = (transformed[3] - transformed[1]).abs
      run_points = expected_axis == :x ? x_points : y_points
      cross_points = expected_axis == :x ? y_points : x_points

      assert_in_delta expected_angle, display_angle, 1.0e-12,
                      "raw #{raw_angle}, page #{page_rotation} display angle"
      assert_in_delta 36.0, run_points, 1.0e-12,
                      "raw #{raw_angle}, page #{page_rotation} along-run axis"
      assert_in_delta 2.0, cross_points, 1.0e-12,
                      "raw #{raw_angle}, page #{page_rotation} cross axis"
      assert_in_delta 0.50,
                      builder.send(:mesh_text_bbox_run_width_inches, item, display_angle),
                      1.0e-12
      residual, status, reason = builder.send(
        :mesh_text_residual_x_scale, item, generated, display_angle, 1.0
      )
      assert_in_delta 0.50, residual, 1.0e-12
      assert_equal [:fitted, 'bbox_overflow_shrink'], [status, reason]
    end
  end

  def test_invalid_bbox_values_skip_residual_reconciliation
    builder = builder_with_fonts(['Arial'])
    item = render_item('INVALID', 'Arial', 1491.0 / 2048.0)
    generated = [DummyRenderedTextEntity.new(1.0, 0.1)]
    [nil, Float::NAN, Float::INFINITY].each do |bad|
      item.bbox_x1 = bad
      assert_equal [1.0, :skipped, 'invalid_width', false],
                   builder.send(:mesh_text_residual_x_scale, item, generated, 0.0, 1.0)
    end
    item.bbox_x0 = 50.0
    item.bbox_x1 = 50.0
    assert_equal [1.0, :skipped, 'invalid_width', false],
                 builder.send(:mesh_text_residual_x_scale, item, generated, 0.0, 1.0)
  end

  def test_diagonal_matrix_x_uses_exact_local_transform_order_and_created_entities_only
    builder = builder_with_fonts(['Arial Narrow'])
    item = render_item('DIAGONAL', 'Arial Narrow', 1491.0 / 2048.0)
    item.angle = 41.0
    item.trusted_text_matrix_x_scale = 1.436458
    sentinel = DummyRenderedTextEntity.new(9.0, 9.0)
    entities = DummyTransformEntities.new([sentinel])
    builder.define_singleton_method(:mesh_text_residual_x_scale) do |*_args|
      [1.0, :fitted, 'bbox_exact_match', true]
    end
    label_x, label_y, = builder.send(:mesh_label_anchor_pdf, item)
    expected_anchor = builder.send(:text_point_to_su, item, label_x, label_y, 0.0, 0.0)

    assert builder.send(:place_mesh_text, entities, item, 0.0, 0.0, Object.new)
    assert_equal [:scaling, :translation, :rotation],
                 entities.transforms.map { |args| args.first.kind }

    scale, translation, rotation = entities.transforms.map(&:first)
    assert_same ORIGIN, scale.args[0]
    assert_in_delta 1.436458, scale.args[1], 1.0e-12
    assert_equal [1.0, 1.0], scale.args[2..3], 'Y and Z scale must remain exactly 1.0'
    anchor = translation.args[0]
    assert_in_delta expected_anchor.x, anchor.x, 1.0e-12
    assert_in_delta expected_anchor.y, anchor.y, 1.0e-12
    assert_same anchor, rotation.args[0], 'rotation must reuse the unchanged translation anchor'
    assert(entities.transforms.all? do |args|
      targets = args[1..-1]
      !targets.any? { |entity| entity.equal?(sentinel) } &&
        targets.all? { |entity| !entity.equal?(sentinel) }
    end)
    assert_includes entities.entities, sentinel
  end
end
