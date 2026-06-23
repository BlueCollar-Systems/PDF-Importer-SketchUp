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
    assert_match(/note: 'SVG text unavailable'|note: missing_renderer_note/, @main)
    assert_match(/degraded: true, note: missing_renderer_note/, @main)
    assert_match(/Geometry\/Glyphs fail closed to[\s#]+labels/m, @main)
    assert_match(/fallback_use_3d = \(requested_text_mode == :text3d\)/, @main)
    assert_match(/fallback_mode = fallback_use_3d \? "3D text" : "labels"/, @main)
    refute_match(/else\s+SvgTextRenderer\.render/m, @main)
    svg_fallback_section = @main[/Fallback text rendering.*?degraded: true, note: missing_renderer_note/m]
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

  def test_svg_glyphs_default_to_raw_edges_to_avoid_component_boxes
    renderer_path = File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/svg_text_renderer.rb', __dir__)
    renderer = File.read(renderer_path)

    assert_match(/raw_edge_glyphs = raw_edge_glyphs\?\(opts, placement_count, estimated_glyph_edges\)/, renderer)
    assert_match(/glyph_instances: visible_glyph_instances/, renderer)
    assert_match(/def self\.add_transformed_glyph_edges/, renderer)
    assert_match(/entities\.add_edges\(transformed\)/, renderer)
    assert_match(/add_glyph_segments_from_points/, renderer)
  end

  def test_svg_glyphs_flatten_large_import_component_fallback_by_default
    renderer_path = File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/svg_text_renderer.rb', __dir__)
    renderer = File.read(renderer_path)

    assert_match(/DEFAULT_EDGE_GLYPH_THRESHOLD = 5_000/, renderer)
    assert_match(/DEFAULT_RAW_GLYPH_EDGE_BUDGET = 6_000/, renderer)
    assert_match(/DEFAULT_FLATTEN_GLYPH_EDGE_BUDGET = 3_000/, renderer)
    assert_match(/estimated_glyph_edges = estimate_glyph_edge_count/, renderer)
    assert_match(/placement_count\.to_i > raw_edge_glyph_threshold/, renderer)
    assert_match(/edge_count <= raw_glyph_edge_budget/, renderer)
    assert_match(/flatten_glyph_instances = flatten_glyph_instances\?\(opts, estimated_glyph_edges\)/, renderer)
    assert_match(/group = entities\.add_group/, renderer)
    assert_match(/component_container: component_container/, renderer)
    assert_match(/inst = text_entities\.add_instance\(glyph_data, tr\)/, renderer)
    assert_match(/exploded_edges = explode_glyph_instance\(inst, text_layer\)/, renderer)
    assert_match(/flattened_glyph_instances: flattened_glyph_instances/, renderer)
  end

  def test_geometry_glyphs_preflight_warns_when_svg_renderer_missing
    assert_match(/svg_renderer_missing/, @main)
    assert_match(/SvgTextRenderer\.svg_renderer_available\?/, @main)
    assert_match(/Poppler \(pdftocairo\) or MuPDF \(mutool\)/, @main)
    assert_match(/Continue with degraded text\?/, @main)
  end

  def test_large_import_component_visibility_is_opt_in_for_emergency_performance
    renderer_path = File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/svg_text_renderer.rb', __dir__)
    renderer = File.read(renderer_path)

    assert_match(/def self\.flatten_glyph_instances\?\(opts, estimated_edge_count = nil\)/, renderer)
    assert_match(/BC_SU_KEEP_GLYPH_COMPONENTS/, renderer)
    assert_match(/return false if raw == '1' \|\| raw == 'true' \|\| raw == 'yes'/, renderer)
    assert_match(/return false if edge_count > flatten_glyph_edge_budget/, renderer)
  end
end
