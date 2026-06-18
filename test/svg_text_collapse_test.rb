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
end
