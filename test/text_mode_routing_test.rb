#!/usr/bin/env ruby

require 'minitest/autorun'

class TextModeRoutingTest < Minitest::Test
  MAIN_PATH = File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/main.rb', __dir__)

  def setup
    @main = File.read(MAIN_PATH)
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
end
