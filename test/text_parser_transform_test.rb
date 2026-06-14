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
end
