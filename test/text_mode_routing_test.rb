#!/usr/bin/env ruby
# test/text_mode_routing_test.rb
#
  # Text-mode routing locks: the requested text mode must reach the renderer
  # that implements it (TEXTMODE-1). Geometry/Glyphs use the existing edge /
  # component SVG renderer; 3D Text uses the separate filled-solid source SVG
  # renderer so it can preserve glyph identity and verify positive Z depth.
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

  def test_3d_text_uses_separate_exact_source_outline_solid_renderer
    assignments = assignments_to(@main, 'use_svg_text')
    routing = assignments.find { |a| a.include?(':geometry') }
    refute_nil routing, 'expected the use_svg_text routing assignment to test :geometry'
    assert_includes routing, ':glyphs',
                    'SVG glyph routing must cover Glyphs mode'
    assert_includes routing, 'requested_text_mode',
                    'SVG routing must be driven by the requested text mode'
    assignments.each do |a|
      refute_match(/:text3d|:labels/, a,
                   "3D Text / Labels must never route through the edge/component renderer: #{a.strip}")
    end
    solid_assignments = assignments_to(@main, 'use_svg_3d_text')
    assert solid_assignments.any? { |a| a.include?(':text3d') && a.include?('requested_text_mode') }
    assert_match(/Svg3DTextRenderer\.render_svg/, @main)
    assert_match(/:renderer\s*=>\s*:svg_source_3d_text/, @main)
    assert_match(/:positive_z_depth_verified\s*=>\s*true/, @main)
  end

  def test_labels_do_not_hide_native_annotations_behind_svg_visual_layer
    # Whole-file banned tokens: the label-visual-layer regression identifiers
    # exist nowhere in main.rb.
    refute_match(/label_visual_text/, @main)
    refute_match(/text_group\.hidden\s*=\s*true/, @main,
                 'native text group must never be hidden behind an SVG visual layer')
  end

  def test_labels_and_exact_source_3d_text_renderers_are_reported
    assert_match(/builder_use_3d_text\s*=\s*false/, @main,
                 'unproven native font identity must not be the default 3D path')
    assert_match(/:renderer\s*=>\s*:svg_source_3d_text/, @main)
    assert_match(/record_text_renderer\(\s*stats,\s*page_num,/, @main,
                  'renderer outcomes must be recorded in the report stats')
  end

  def test_labels_subset_fallback_does_not_render_unmatched_page_glyphs
    assert_match(
      /preserve_unmatched_source_placements\s*=>\s*false/,
      @main,
      'Labels item fallback must not duplicate successful page labels as anonymous 3D glyphs'
    )
  end

  def test_generic_svg_failure_stops_without_substitution
    assert_match(/def self\.enforce_requested_text_delivery!/, @main)
    assert_match(/no representation fallback.*authorized/m, @main)
    refute_match(/fallback_use_3d/, @main)
    refute_match(/native_fb_text_objects/, @main)
    refute_match(/degraded:\s*true,\s*reason:\s*'svg_text_unavailable'/, @main)
    refute_match(/renderer:\s*\([^\n]*\?\s*:add_3d_text\s*:\s*:labels/, @main)
    refute_match(/actual_source_association_impossibility_proof!/, @main,
                 'one association query must not impersonate distinct Glyph/Geometry attempts')
    refute_match(/stop_unimplemented_item_fallback!/, @main)
    assert_match(/SvgItemRepresentationRenderer\.render_svg/, @main,
                 'each item Glyph/Geometry rung must run its distinct renderer')
    assert_match(/controller\.advance!\(proof\)/, @main,
                 'only a validated item proof may advance an unsuccessful rung')
    assert_match(/complete_text3d_item_fallbacks!/, @main,
                 '3D Text failures must enter the finite item-scoped ladder')
    assert_match(/verified_item_raster_entity!/, @main,
                 'the terminal rung must verify a real source-bound host raster entity')
  end

  def test_labels_with_layer_matching_disables_svg_text
    assert_match(
      /if\s+match_pdf_layers\s*&&\s*!ocg\.layer_list\.empty\?\s*&&\s*\[:text,\s*:labels\]\.include\?\(requested_text_mode\)\s+use_svg_text\s*=\s*false/m,
      @main,
      'Text/Labels with PDF-layer matching must use internal parsing, not SVG text'
    )
  end

  def test_import_dialog_maps_labels_string_to_labels_symbol
    assert_match(
      /when\s+'text',\s*'flat_text',\s*'editable_text'\s+then\s+:text/m,
      @import_dialog
    )
    assert_match(
      /when\s+'labels',\s*'label',\s*'add_text'\s+then\s+:labels/m,
      @import_dialog
    )
    assert_match(/when\s+'glyphs'\s+then\s+:glyphs/, @import_dialog)
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
    # User-facing contract: the preflight stops explicitly and directs the
    # user to a free external renderer; a source-only RBZ cannot repair this
    # by being reinstalled and the importer never offers a downgrade.
    assert_match(/free Poppler\/MuPDF SVG/, @main)
    assert_match(/renderer, which is unavailable/, @main)
    assert_match(/import is stopping without/, @main)
    assert_match(/changing the requested representation/, @main)
    assert_match(/BC_PDFTOCAIRO_PATH/, @main)
    assert_match(/BC_MUTOOL_PATH/, @main)
    assert_match(/Compatibility Report/, @main)
    refute_match(/Reinstall the extension/, @main)
    refute_match(/Continue with degraded text\?/, @main)
  end

  def test_large_import_component_visibility_is_opt_in_for_emergency_performance
    assert_match(/def self\.flatten_glyph_instances\?\(\s*opts,\s*estimated_edge_count\s*=\s*nil\s*\)/, renderer)
    assert_match(/BC_SU_KEEP_GLYPH_COMPONENTS/, renderer)
    assert_match(/return false if raw\s*==\s*'1'\s*\|\|\s*raw\s*==\s*'true'\s*\|\|\s*raw\s*==\s*'yes'/, renderer)
    assert_match(/return false if edge_count\s*>\s*flatten_glyph_edge_budget/, renderer)
  end
end
