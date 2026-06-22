# test/svg_text_collapse_test.rb
# Unit tests for SvgTextRenderer's missing-font / collapsed-glyph guard.
# Regression cover for the "Symbol font -> 296 glyphs piled at the page
# corner -> illegible blob" defect. Ruby 2.2 compatible (no &., #sum, #then).

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_text_renderer'

class SvgTextCollapseTest < Minitest::Test
  R = BlueCollarSystems::PDFVectorImporter::SvgTextRenderer

  # n identical degenerate placements at the page corner, mimicking what
  # pdftocairo emits when it has "No display font for 'Symbol'".
  def collapsed(n)
    Array.new(n) do
      { glyph_id: 'glyph-0-1', x: 0.0, y: 0.0,
        matrix: [0.0, -0.12, -0.12, 0.0, 2592.0, 1728.0] }
    end
  end

  # n distinct, advancing placements (legitimate text run).
  def normal(n)
    (0...n).map do |i|
      { glyph_id: "glyph-0-#{i}", x: 0.0, y: 0.0,
        matrix: [0.12, 0.0, 0.0, -0.12, 100.0 + i * 7.0, 500.0] }
    end
  end

  def test_identical_transforms_share_signature
    a = collapsed(3)
    assert_equal R.placement_signature(a[0]), R.placement_signature(a[2])
  end

  def test_distinct_positions_have_distinct_signatures
    p = normal(2)
    refute_equal R.placement_signature(p[0]), R.placement_signature(p[1])
  end

  def test_x_y_offsets_fold_into_signature
    base = { glyph_id: 'g', x: 0.0, y: 0.0, matrix: [1.0, 0.0, 0.0, 1.0, 10.0, 20.0] }
    moved = { glyph_id: 'g', x: 5.0, y: 0.0, matrix: [1.0, 0.0, 0.0, 1.0, 5.0, 20.0] }
    # 5 (e) + 5 (x) == 10 (e) + 0 (x): same effective placement.
    assert_equal R.placement_signature(base), R.placement_signature(moved)
  end

  def test_detects_bulk_collapse_only
    placements = collapsed(296) + normal(20)
    keys = R.collapsed_signature_keys(placements)
    assert_equal 1, keys.length
    assert_includes keys, R.placement_signature(collapsed(1)[0])
  end

  def test_normal_text_is_not_flagged
    assert_empty R.collapsed_signature_keys(normal(50))
  end

  def test_threshold_boundary
    refute_includes R.collapsed_signature_keys(collapsed(11)),
                    R.placement_signature(collapsed(1)[0])
    assert_includes R.collapsed_signature_keys(collapsed(12)),
                    R.placement_signature(collapsed(1)[0])
  end

  def test_missing_display_fonts_parsing
    err = "Syntax Error: No display font for 'Symbol'\n" \
          "Syntax Error: No display font for 'ZapfDingbats'\n" \
          "Syntax Error: No display font for 'Symbol'\n"
    assert_equal ['Symbol', 'ZapfDingbats'], R.missing_display_fonts(err)
  end

  def test_missing_display_fonts_empty_inputs
    assert_empty R.missing_display_fonts('')
    assert_empty R.missing_display_fonts(nil)
  end

  def test_parses_mutool_font_path_ids_and_placements
    svg = '<svg viewBox="0 0 100 100"><defs>' \
          '<path id="font_7_38" d="M.1 0L.2 0Z"/>' \
          '</defs><use data-text="C" xlink:href="#font_7_38" ' \
          'transform="matrix(9,0,0,-9,10,20)"/></svg>'

    defs = R.parse_glyph_defs(svg)
    assert_equal 'M.1 0L.2 0Z', defs['font_7_38']

    placements = R.parse_use_placements(svg)
    assert_equal 1, placements.length
    assert_equal 'font_7_38', placements[0][:glyph_id]
    assert_equal [9.0, 0.0, 0.0, -9.0, 10.0, 20.0], placements[0][:matrix]
  end

  def test_svg_render_args_support_mutool
    renderer = { kind: :mutool, exe: 'mutool' }
    variants = R.svg_render_arg_variants(renderer, 'in.pdf', 'out.svg', 3, true)

    assert_equal ['mutool', 'draw', '-q', '-F', 'svg', '-b', 'CropBox',
                  '-o', 'out.svg', 'in.pdf', '3'], variants[0]
    assert_equal ['mutool', 'draw', '-q', '-F', 'svg',
                  '-o', 'out.svg', 'in.pdf', '3'], variants[1]
  end

  def test_temp_svg_path_is_extensionless_for_pdftocairo_multi_page_svg
    path = R.temp_svg_path
    refute_match(/\.svg\z/i, path)
  end

  def test_glyph_component_flattening_defaults_on_with_escape_hatch
    old = ENV['BC_SU_KEEP_GLYPH_COMPONENTS']
    ENV.delete('BC_SU_KEEP_GLYPH_COMPONENTS')
    assert R.flatten_glyph_instances?({})

    ENV['BC_SU_KEEP_GLYPH_COMPONENTS'] = '1'
    refute R.flatten_glyph_instances?({})
    refute R.flatten_glyph_instances?({ flatten_glyph_instances: false })
    assert R.flatten_glyph_instances?({ flatten_glyph_instances: true })
  ensure
    if old.nil?
      ENV.delete('BC_SU_KEEP_GLYPH_COMPONENTS')
    else
      ENV['BC_SU_KEEP_GLYPH_COMPONENTS'] = old
    end
  end

  class DummyEdge
    attr_accessor :layer
    def typename
      'Edge'
    end
  end

  class DummyInstance
    def initialize(exploded)
      @exploded = exploded
    end

    def explode
      @exploded
    end
  end

  def test_explode_glyph_instance_counts_edges_and_applies_layer
    edge = DummyEdge.new
    exploded_edges = R.explode_glyph_instance(DummyInstance.new([edge]), 'PDF Text')

    assert_equal 1, exploded_edges
    assert_equal 'PDF Text', edge.layer
  end
end
