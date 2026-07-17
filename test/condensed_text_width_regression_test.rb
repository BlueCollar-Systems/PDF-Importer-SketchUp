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
#      a near-1 control must all prove exact final host bounds against the
#      PDF-declared extent.

require_relative 'mesh_text_scaling_test'

# add_3d_text stub that renders the run at a controlled "host font natural
# width" instead of the shared 3x-height default.
class NaturalWidthEntities < DummyTransformEntities
  def initialize(natural_width_in)
    super()
    @natural_width_in = natural_width_in.to_f
  end

  def add_3d_text(_text, _align, _font, _bold, _italic, height, tol, _z, _filled, extrusion)
    @height_args << height
    @tolerance_args << tol
    @entities << DummyRenderedTextEntity.new(@natural_width_in, height,
                                              typename: 'Edge', depth: extrusion)
    @entities << DummyFaceEntity.new(@natural_width_in, height, depth: extrusion)
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
    item.source_span_id = FidelityFixtureIdentity.next_span_id
    assert_equal 'STD. SHOP PRIMER U.N.O.', item.text
    assert_in_delta 10.2, item.font_size, 1e-6,
                    'font_size must come from the VERTICAL Tm component only — ' \
                    'the condensed 8.156 horizontal scale must not shrink height'
    assert_in_delta 0.0, item.angle, 1e-6
  end

  # ── 2. Declared-vs-final run width exact across the measured cases ───────
  # Each case models a measured span: the host font would render the run at
  # its natural width; the PDF declares natural * ratio. After width
  # fidelity the FINAL host bounds must match the declared extent — including
  # the near-1 control, which must not be hidden behind a skip heuristic.
  MEASURED_CASES = [
    # [label,                          text,                       ratio ]
    ['worst condensed (0.5864)',       'STD. SHOP PRIMER U.N.O.',  0.5864],
    ['condensed cluster (0.7996)',     'ALL HOLES 13/16" DIA. U.N.O.', 0.7996],
    ['expanded narrow-font (1.4365)',  'ONE FRAME',                1.4365],
    ['control dimension (0.9950)',     "3'-6 1/2\"",               0.9950]
  ].freeze

  def test_condensed_title_block_strings_match_declared_host_bounds
    MEASURED_CASES.each do |label, text, ratio|
      font_pts = 8.0
      natural_in = text.length * 0.55 * font_pts / 72.0
      declared_in = natural_in * ratio
      declared_pts = declared_in * 72.0

      item = identified_text_item(
        text, 50.0, 100.0, font_pts, 0.0, 'pdftotext', nil,
        50.0, 100.0, 50.0 + declared_pts, 100.0 + font_pts * 1.2
      )
      ents = NaturalWidthEntities.new(natural_in)
      b = make_builder(LETTER)
      assert b.send(:place_mesh_text, ents, item, 0.0, 0.0, nil),
             "#{label}: mesh must be delivered"

      fits = ents.transforms.select { |args| args[0].kind == :scaling }
      assert_equal 0, fits.length, "#{label}: width fitting must not be applied"
      final_bounds = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity.bounds(
        ents.to_a
      )
      assert_in_delta natural_in, final_bounds[:width], 1.0e-8,
                      "#{label}: final host width is the natural rendered width"
      letter_h = sketchup_letter_height_in(font_pts)
      assert_in_delta letter_h, final_bounds[:height], 1.0e-8,
                      "#{label}: final host height must equal SketchUp letter height"

      # The height side of every case stays the faithful letter-height nominal.
      assert_in_delta letter_h, ents.height_args[0], 1e-9,
                      "#{label}: height must stay the faithful letter-height nominal"
      attempt = b.text_attempts.fetch(0)
      assert_equal item.source_span_id, attempt[:source_span_id]
      assert attempt[:visual_fidelity_verified]
      assert attempt[:width_verified]
      assert attempt[:height_verified]
    end
  end

  def test_near_1_control_is_fitted_and_verified_exactly
    text = "3'-6 1/2\""
    font_pts = 8.0
    natural_in = text.length * 0.55 * font_pts / 72.0
    declared_pts = natural_in * 0.9950 * 72.0
    item = identified_text_item(
      text, 50.0, 100.0, font_pts, 0.0, 'pdftotext', nil,
      50.0, 100.0, 50.0 + declared_pts, 100.0 + font_pts * 1.2
    )
    ents = NaturalWidthEntities.new(natural_in)
    b = make_builder(LETTER)
    assert b.send(:place_mesh_text, ents, item, 0.0, 0.0, nil)

    fits = ents.transforms.select { |args| args[0].kind == :scaling }
    assert_equal 0, fits.length, 'width fitting must not be applied near ratio 1.0'
    final_bounds = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity.bounds(
      ents.to_a
    )
    assert_in_delta natural_in, final_bounds[:width], 1.0e-8,
                    'final host width is the natural rendered width'
    assert b.text_attempts.fetch(0)[:visual_fidelity_verified]
  end
end
