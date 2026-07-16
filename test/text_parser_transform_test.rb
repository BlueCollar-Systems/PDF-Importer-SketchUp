#!/usr/bin/env ruby

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/text_parser'

class TextParserTransformTest < Minitest::Test
  TP = BlueCollarSystems::PDFVectorImporter::TextParser

  def parse_items(stream)
    TP.new([stream], {}, strict_text_fidelity: true).parse
  end

  def test_ctm_transforms_text_position_and_angle
    item = parse_items(
      'q 0 1 -1 0 100 200 cm BT /F1 12 Tf 1 0 0 1 10 20 Tm (A) Tj ET Q'
    ).first

    assert_equal 'A', item.text
    assert_in_delta 80.0, item.x, 1e-6
    assert_in_delta 210.0, item.y, 1e-6
    assert_in_delta(-90.0, item.angle, 1e-6)
  end

  def test_q_restore_removes_ctm_for_later_text
    items = parse_items(
      'q 0 1 -1 0 100 200 cm BT /F1 12 Tf 1 0 0 1 10 20 Tm (A) Tj ET Q ' \
      'BT /F1 12 Tf 1 0 0 1 10 20 Tm (B) Tj ET'
    )
    item = items.find { |candidate| candidate.text == 'B' }

    refute_nil item
    assert_in_delta 10.0, item.x, 1e-6
    assert_in_delta 20.0, item.y, 1e-6
    assert_in_delta 0.0, item.angle, 1e-6
  end

  def test_font_metadata_and_trusted_matrix_x_reach_item
    maps = {'F1' => {
      map: {}, code_lengths: [1], source_font_family: 'Arial Narrow',
      source_font_bold: false, source_font_italic: false,
      font_to_sketchup_letter_ratio: 1491.0 / 2048.0,
      font_to_sketchup_letter_ratio_source: :known_arial_family
    }}
    item = TP.new(['BT /F1 12 Tf 1.436458 0 0 1 10 20 Tm (ONE FRAME) Tj ET'],
                  maps, strict_text_fidelity: true).parse.first
    assert_equal 'Arial Narrow', item.source_font_family
    assert_in_delta 1.436458, item.trusted_text_matrix_x_scale, 1.0e-6
  end

  def test_tz_multiplies_trusted_x_without_changing_vertical_size
    item = TP.new(['BT /F1 12 Tf 80 Tz 1 0 0 2 0 0 Tm (A) Tj ET'], {},
                  strict_text_fidelity: true).parse.first
    assert_in_delta 24.0, item.font_size, 1.0e-9
    assert_in_delta 0.4, item.trusted_text_matrix_x_scale, 1.0e-9
  end
end
