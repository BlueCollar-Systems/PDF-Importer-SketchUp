#!/usr/bin/env ruby

require 'minitest/autorun'

class TextModeRoutingTest < Minitest::Test
  MAIN_PATH = File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/main.rb', __dir__)
  IMPORT_DIALOG_PATH = File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/import_dialog.rb', __dir__)

  def setup
    @main = File.read(MAIN_PATH)
    @import_dialog = File.read(IMPORT_DIALOG_PATH)
  end

  def test_3d_text_does_not_route_through_svg_glyph_renderer
    refute_match(/:text3d\]\.include\?\(requested_text_mode\)/, @main)
    assert_match(/use_svg_text = \[:geometry, :glyphs\]\.include\?\(requested_text_mode\)/, @main)
  end

  def test_labels_do_not_hide_native_annotations_behind_svg_visual_layer
    refute_match(/label_visual_text/, @main)
    refute_match(/builder\.text_group\.hidden = true/, @main)
  end

  def test_native_label_and_3d_text_renderers_are_reported
    assert_match(/renderer = builder_use_3d_text \? :add_3d_text : :labels/, @main)
    assert_match(/record_text_renderer\(stats, page_num,/, @main)
  end

  def test_svg_fallback_only_for_geometry_and_glyphs_modes
    assert_match(/note: 'SVG text unavailable'/, @main)
    assert_match(/degraded: true, note: 'SVG text unavailable'/, @main)
    assert_match(/Geometry\/Glyphs fail closed to[\s#]+labels/m, @main)
    assert_match(/fallback_use_3d = \(requested_text_mode == :text3d\)/, @main)
    assert_match(/fallback_mode = fallback_use_3d \? "3D text" : "labels"/, @main)
    refute_match(/else\s+SvgTextRenderer\.render/m, @main)
    svg_fallback_section = @main[/SVG glyph text unavailable\/disabled\..*?degraded: true, note: 'SVG text unavailable'/m]
    assert svg_fallback_section, 'expected SVG unavailable fallback block'
    refute_match(/SvgTextRenderer\.render/, svg_fallback_section)
    assert_match(/renderer: \(fallback_use_3d \? :add_3d_text : :labels\)/, svg_fallback_section)
  end

  def test_labels_with_layer_matching_disables_svg_text
    assert_match(
      /if match_pdf_layers && !ocg\.layer_list\.empty\? && requested_text_mode == :labels\s+use_svg_text = false/m,
      @main
    )
  end

  def test_import_dialog_maps_labels_string_to_labels_symbol
    assert_match(/when \/Labels\/i\s+then :labels/, @import_dialog)
    assert_match(/when \/Glyphs\/i\s+then :glyphs/, @import_dialog)
  end
end
