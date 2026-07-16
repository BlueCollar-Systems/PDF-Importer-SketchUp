#!/usr/bin/env ruby
# test/text_mode_routing_test.rb
#
# Text-mode routing locks: the requested text mode must reach the renderer
# that implements it (TEXTMODE-1), and the SVG glyph path stays reserved for
# Geometry/Glyphs.
#
# RB-11 (2026-07-12 roadblock audit, re-scoped 2026-07-16): earlier versions
# asserted exact implementation wording (full assignment expressions, comment
# text, spacing-sensitive literals), so a cosmetic reformat broke the suite
# and a rename could silently disarm refutes. Rebuilt so that:
#   * every scoped extraction fails LOUDLY when its anchor is missing;
#   * assertions anchor on stable identifiers, symbols, and report-contract
#     values, tolerant of whitespace/formatting;
#   * refutes are either whole-file banned tokens or run over loudly-isolated
#     scopes (never over a silently-empty fragment).
# The protections are unchanged — nothing was weakened. Behavioral report
# locks live in test/textmode1_invariant_test.rb (production-path values).

require 'minitest/autorun'

class TextModeRoutingTest < Minitest::Test
  MAIN_PATH = File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/main.rb', __dir__)
  IMPORT_DIALOG_PATH = File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/import_dialog.rb', __dir__)
  RENDERER_PATH = File.expand_path('../extracted/sketchup_ext/bc_pdf_vector_importer/svg_text_renderer.rb', __dir__)

  def setup
    @main = File.read(MAIN_PATH)
    @import_dialog = File.read(IMPORT_DIALOG_PATH)
  end

  def renderer
    @renderer ||= File.read(RENDERER_PATH)
  end

  # All single-line assignments to [name]; fails loudly when none exist so a
  # rename/restructure cannot silently disarm the per-assignment refutes.
  def assignments_to(source, name)
    lines = source.scan(/^[ \t]*#{Regexp.escape(name)}\s*=(?!=)[^\n]*/)
    refute_empty lines, "expected at least one assignment to #{name}"
    lines
  end

  def test_3d_text_does_not_route_through_svg_glyph_renderer
    assignments = assignments_to(@main, 'use_svg_text')
    routing = assignments.find { |a| a.include?(':geometry') }
    refute_nil routing, 'expected the use_svg_text routing assignment to test :geometry'
    assert_includes routing, ':glyphs',
                    'SVG glyph routing must cover Glyphs mode'
    assert_includes routing, 'requested_text_mode',
                    'SVG routing must be driven by the requested text mode'
    assignments.each do |a|
      refute_match(/:text3d|:labels/, a,
                   "3D Text / Labels must never route through the SVG glyph renderer: #{a.strip}")
    end
  end

  def test_labels_do_not_hide_native_annotations_behind_svg_visual_layer
    # Whole-file banned tokens: the label-visual-layer regression identifiers
    # exist nowhere in main.rb.
    refute_match(/label_visual_text/, @main)
    refute_match(/text_group\.hidden\s*=\s*true/, @main,
                 'native text group must never be hidden behind an SVG visual layer')
  end

  def test_native_label_and_3d_text_renderers_are_reported
    assert_match(/builder_use_3d_text\s*\?\s*:add_3d_text\s*:\s*:labels/, @main,
                 'native renderer selection must distinguish :add_3d_text from :labels')
    assert_match(/record_text_renderer\(\s*stats,\s*page_num,/, @main,
                 'native renderer outcomes must be recorded in the report stats')
  end

  def test_svg_fallback_only_for_geometry_and_glyphs_modes
    # Report contract values for the degraded fallback record.
    assert_match(/note:\s*(?:'SVG text unavailable'|missing_renderer_note)/, @main)
    assert_match(/degraded:\s*true,\s*reason:\s*'svg_text_unavailable'/, @main)

    # Fallback ladder: SVG-unavailable falls to 3D Text for the mesh/outline
    # family (:text3d, :geometry, :glyphs) and to Labels otherwise.
    fb_assignments = assignments_to(@main, 'fallback_use_3d')
    ladder = fb_assignments.find { |a| a.include?('requested_text_mode') }
    refute_nil ladder, 'expected fallback_use_3d to be derived from requested_text_mode'
    [':text3d', ':geometry', ':glyphs'].each do |mode|
      assert_includes ladder, mode,
                      "#{mode} must fall back to 3D Text when SVG text is unavailable"
    end
    refute_match(/:labels/, ladder,
                 'Labels must not be routed into the 3D-text fallback')

    # No SVG rendering inside the SVG-unavailable fallback: the else branch
    # must not re-enter SvgTextRenderer.
    refute_match(/else\s+SvgTextRenderer\.render/m, @main)
    svg_fallback_section = @main[/Fallback text rendering.*?count: native_fb_text_objects/m]
    refute_nil svg_fallback_section, 'expected SVG unavailable fallback block'
    refute_match(/SvgTextRenderer\.render/, svg_fallback_section)
    assert_match(/renderer:\s*\(\s*fallback_use_3d\s*\?\s*:add_3d_text\s*:\s*:labels\s*\)/,
                 svg_fallback_section,
                 'fallback must report the natively delivered renderer')
  end

  def test_labels_with_layer_matching_disables_svg_text
    assert_match(
      /if\s+match_pdf_layers\s*&&\s*!ocg\.layer_list\.empty\?\s*&&\s*requested_text_mode\s*==\s*:labels\s+use_svg_text\s*=\s*false/m,
      @main,
      'Labels with PDF-layer matching must use internal parsing, not SVG text'
    )
  end

  def test_import_dialog_maps_labels_string_to_labels_symbol
    assert_match(/when\s+\/Labels\/i\s+then\s+:labels/, @import_dialog)
    assert_match(/when\s+\/Glyphs\/i\s+then\s+:glyphs/, @import_dialog)
  end

  def test_svg_glyphs_default_to_raw_edges_to_avoid_component_boxes
    assert_match(/raw_edge_glyphs\?\(\s*opts,\s*placement_count,\s*estimated_glyph_edges\s*\)/, renderer,
                 'raw-edge decision must weigh placement count and edge estimate')
    assert_match(/glyph_instances:\s*visible_glyph_instances/, renderer)
    assert_match(/def self\.add_transformed_glyph_edges/, renderer)
    assert_match(/entities\.add_edges\(\s*transformed\s*\)/, renderer)
    assert_match(/add_glyph_segments_from_points/, renderer)
  end

  def test_svg_glyphs_flatten_large_import_component_fallback_by_default
    assert_match(/DEFAULT_EDGE_GLYPH_THRESHOLD\s*=\s*5_?000\b/, renderer)
    assert_match(/DEFAULT_RAW_GLYPH_EDGE_BUDGET\s*=\s*6_?000\b/, renderer)
    assert_match(/DEFAULT_FLATTEN_GLYPH_EDGE_BUDGET\s*=\s*3_?000\b/, renderer)
    assert_match(/estimated_glyph_edges\s*=\s*estimate_glyph_edge_count/, renderer)
    assert_match(/placement_count\.to_i\s*>\s*raw_edge_glyph_threshold/, renderer)
    assert_match(/edge_count\s*<=\s*raw_glyph_edge_budget/, renderer)
    assert_match(/flatten_glyph_instances\s*=\s*flatten_glyph_instances\?\(\s*opts,\s*estimated_glyph_edges\s*\)/, renderer)
    assert_match(/group\s*=\s*entities\.add_group/, renderer)
    assert_match(/component_container:\s*component_container/, renderer)
    assert_match(/inst\s*=\s*text_entities\.add_instance\(\s*glyph_data,\s*tr\s*\)/, renderer)
    assert_match(/exploded_edges\s*=\s*explode_glyph_instance\(\s*inst,\s*text_layer\s*\)/, renderer)
    assert_match(/flattened_glyph_instances:\s*flattened_glyph_instances/, renderer)
  end

  def test_geometry_glyphs_preflight_warns_when_svg_renderer_missing
    assert_match(/svg_renderer_missing/, @main)
    assert_match(/SvgTextRenderer\.svg_renderer_available\?/, @main)
    # User-facing contract: the preflight names both free engines and asks
    # before degrading (never a silent downgrade).
    assert_match(/Poppler \(pdftocairo\) or MuPDF \(mutool\)/, @main)
    assert_match(/Continue with degraded text\?/, @main)
  end

  def test_large_import_component_visibility_is_opt_in_for_emergency_performance
    assert_match(/def self\.flatten_glyph_instances\?\(\s*opts,\s*estimated_edge_count\s*=\s*nil\s*\)/, renderer)
    assert_match(/BC_SU_KEEP_GLYPH_COMPONENTS/, renderer)
    assert_match(/return false if raw\s*==\s*'1'\s*\|\|\s*raw\s*==\s*'true'\s*\|\|\s*raw\s*==\s*'yes'/, renderer)
    assert_match(/return false if edge_count\s*>\s*flatten_glyph_edge_budget/, renderer)
  end
end
