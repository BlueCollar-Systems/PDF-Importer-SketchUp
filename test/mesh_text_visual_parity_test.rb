#!/usr/bin/env ruby
require_relative 'mesh_text_scaling_test'

class MeshTextVisualParityTest < Minitest::Test
  def builder_with_fonts(fonts)
    GB.new(Object.new, [], [], LETTER, scale_factor: 1.0,
           import_text: true, use_3d_text: true,
           installed_font_families: fonts)
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

  def test_selected_family_and_style_are_passed_to_add_3d_text
    builder = builder_with_fonts(['Arial Narrow'])
    item = render_item('TITLE', 'Arial Narrow', 1491.0 / 2048.0)
    item.source_font_bold = true
    item.source_font_italic = true
    entities = DummyTransformEntities.new
    builder.send(:place_mesh_text, entities, item, 0.0, 0.0, nil)
    assert_equal ['Arial Narrow', true, true], entities.font_style_args.last
  end
end
