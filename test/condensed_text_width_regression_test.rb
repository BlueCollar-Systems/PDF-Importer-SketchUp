#!/usr/bin/env ruby
# test/condensed_text_width_regression_test.rb
#
# Round 22 regression — condensed title-block text (anisotropic Tm).
# Owner live-host evidence: title blocks that declare text matrices like
# Tm = [8.156 0 0 10.2] draw glyphs ~20% narrower than tall, and condensed
# span extents run down to a measured 0.5864 of the host font's natural
# run width (expanded cases up to 1.4365). v3.7.94 rendered every run at
# the host font's natural width, so long title-block strings overlapped
# while short dimension text looked fine.
#
# Locks, all runnable in stubs (no live host needed):
#   1. Anisotropic Tm must NEVER shrink the height driver — font_size comes
#      from the vertical matrix component only (Round 13 contract).
#   2. Long condensed strings, the measured cluster, an expanded case, and
#      a near-1 control must all deliver a final run width within 3% of the
#      PDF-declared extent.

require_relative 'mesh_text_scaling_test'

# add_3d_text stub that renders the run at a controlled "host font natural
# width" instead of the shared 3x-height default.
class NaturalWidthEntities < DummyTransformEntities
  def initialize(natural_width_in)
    super()
    @natural_width_in = natural_width_in.to_f
  end

  def add_3d_text(_text, _align, _font, _bold, _italic, height, tol, _extrusion, _filled, _z)
    @height_args << height
    @tolerance_args << tol
    @entities << DummyRenderedTextEntity.new(@natural_width_in, height, typename: 'Edge')
    @entities << DummyFaceEntity.new
    true
  end
end

class CondensedTextWidthRegressionTest < Minitest::Test
  TP = BlueCollarSystems::PDFVectorImporter::TextParser

  # ── 1. Anisotropic Tm: height driver uses the vertical component only ────
  def test_anisotropic_tm_does_not_shrink_the_height_driver
    stream = 'BT /F1 1 Tf 8.156 0 0 10.2 100 200 Tm (STD. SHOP PRIMER U.N.O.) Tj ET'
    item = TP.new([stream], {}, strict_text_fidelity: true).parse.first

    refute_nil item
    assert_equal 'STD. SHOP PRIMER U.N.O.', item.text
    assert_in_delta 10.2, item.font_size, 1e-6,
                    'font_size must come from the VERTICAL Tm component only — ' \
                    'the condensed 8.156 horizontal scale must not shrink height'
    assert_in_delta 0.0, item.angle, 1e-6
  end

  # ── 2. Declared-vs-final run width within 3% across the measured cases ───
  # Each case models a measured span: the host font would render the run at
  # its natural width; the PDF declares natural * ratio. After width
  # fidelity the FINAL width (rendered * applied factor) must be within 3%
  # of the declared extent — including the near-1 control, which skips the
  # transform and passes on natural width alone.
  MEASURED_CASES = [
    # [label,                          text,                       ratio ]
    ['worst condensed (0.5864)',       'STD. SHOP PRIMER U.N.O.',  0.5864],
    ['condensed cluster (0.7996)',     'ALL HOLES 13/16" DIA. U.N.O.', 0.7996],
    ['expanded narrow-font (1.4365)',  'ONE FRAME',                1.4365],
    ['control dimension (0.9950)',     "3'-6 1/2\"",               0.9950]
  ].freeze

  def test_condensed_title_block_strings_land_within_3_percent_of_declared
    MEASURED_CASES.each do |label, text, ratio|
      font_pts = 8.0
      natural_in = text.length * 0.55 * font_pts / 72.0
      declared_in = natural_in * ratio
      declared_pts = declared_in * 72.0

      item = TI.new(text, 50.0, 100.0, font_pts, 0.0, 'pdftotext', nil,
                    50.0, 100.0, 50.0 + declared_pts, 100.0 + font_pts * 1.2)
      ents = NaturalWidthEntities.new(natural_in)
      b = make_builder(LETTER)
      assert b.send(:place_mesh_text, ents, item, 0.0, 0.0, nil),
             "#{label}: mesh must be delivered"

      fits = ents.transforms.select { |args| args[0].kind == :scaling }
      applied = fits.empty? ? 1.0 : fits[0][0].args[1]
      final_in = natural_in * applied
      deviation = (final_in - declared_in).abs / declared_in
      assert_operator deviation, :<=, 0.03,
                      "#{label}: final width must be within 3% of the " \
                      "declared extent (got #{(deviation * 100).round(2)}%)"

      # The height side of every case stays the faithful nominal.
      assert_in_delta font_pts / 72.0, ents.height_args[0], 1e-9,
                      "#{label}: height must stay the faithful nominal"
      unless fits.empty?
        assert_equal [1.0, 1.0], fits[0][0].args[2..3],
                     "#{label}: height/depth factors must be exactly 1.0"
      end
    end
  end

  # The control case must take the skip path, proving the 3% acceptance is
  # not achieved by force-fitting well-matched runs.
  def test_near_1_control_uses_the_skip_path
    text = "3'-6 1/2\""
    font_pts = 8.0
    natural_in = text.length * 0.55 * font_pts / 72.0
    declared_pts = natural_in * 0.9950 * 72.0
    item = TI.new(text, 50.0, 100.0, font_pts, 0.0, 'pdftotext', nil,
                  50.0, 100.0, 50.0 + declared_pts, 100.0 + font_pts * 1.2)
    ents = NaturalWidthEntities.new(natural_in)
    b = make_builder(LETTER)
    b.send(:place_mesh_text, ents, item, 0.0, 0.0, nil)

    assert_empty ents.transforms.select { |args| args[0].kind == :scaling }
    assert_equal 1, b.instance_variable_get(:@text_width_skipped_near_1_count)
  end
end
