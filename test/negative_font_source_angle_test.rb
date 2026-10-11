require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class NegativeFontSourceAngleTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter

  def parsed_item(matrix, size = -12, text = 'ABC')
    stream = "BT /F1 #{size} Tf #{matrix.join(' ')} 10 90 Tm (#{text}) Tj ET"
    IMP::TextParser.new([stream], {}, strict_text_fidelity: true,
                       merge_text_runs: false).parse.first
  end

  def external_item(text, anchors)
    html = '<page width="200" height="200"><line xMin="10" yMin="100" xMax="30" yMax="110">' +
           '<word xMin="10" yMin="100" xMax="30" yMax="110">' + text +
           '</word></line></page>'
    IMP::ExternalTextExtractor.send(
      :parse_bbox_html, html, nominal_anchors: anchors, strict_text_fidelity: true
    ).first
  end

  def test_signed_font_size_is_physical_height_not_permission_to_drop_matrix_angle
    [
      [[0, 1, -1, 0], -90.0],
      [[0, -1, 1, 0], 90.0],
      [[-1, 0, 0, 1], -180.0],
      [[1, 0.25, 0.5, 1], -Math.atan(0.25) * 180.0 / Math::PI],
      [[1, 0, 0.5, -1], 0.0]
    ].each do |matrix, angle|
      source = parsed_item(matrix)
      original = source.to_a
      anchors = IMP.nominal_anchors_from_text_items([source])
      assert_equal 1, anchors.length, matrix.inspect
      anchor = anchors.first
      assert_in_delta source.font_size.abs, anchor.size_pt, 1e-12
      assert_in_delta angle, anchor.angle_deg, 1e-12
      assert_equal [source.x, source.y], [anchor.x, anchor.y]
      assert_equal original, source.to_a, 'raw signed source item must remain unchanged'
      observed = external_item('ABC', anchors)
      assert_in_delta angle, observed.angle, 1e-12
      assert_in_delta source.font_size.abs, observed.font_size, 1e-12
    end
  end

  def test_bbox_cannot_select_rotation_when_source_matrix_is_present
    [-12, 12].each do |size|
      horizontal = external_item('ABC', IMP.nominal_anchors_from_text_items([
        parsed_item([1, 0, 0, 1], size)
      ]))
      vertical = external_item('ABC', IMP.nominal_anchors_from_text_items([
        parsed_item([0, 1, -1, 0], size)
      ]))
      assert_equal [horizontal.bbox_x0, horizontal.bbox_y0, horizontal.bbox_x1, horizontal.bbox_y1],
                   [vertical.bbox_x0, vertical.bbox_y0, vertical.bbox_x1, vertical.bbox_y1]
      assert_equal 0.0, horizontal.angle
      assert_equal(-90.0, vertical.angle)
    end
  end

  def test_source_matrix_rotation_dominates_fraction_and_typ_spelling
    ['1/2', '1/2"', 'TYP', 'TYP.'].each do |text|
      [12, -12].each do |size|
        source = parsed_item([0, 1, -1, 0], size)
        observed = external_item(text, IMP.nominal_anchors_from_text_items([source]))
        assert_equal(-90.0, observed.angle, [text, size].inspect)
        assert_equal text, observed.text
      end
    end
  end

  def test_scanner_signed_height_also_retains_source_rotation
    anchors = IMP::NominalTextScanner.scan([
      'BT /F1 -12 Tf 0 1 -1 0 10 90 Tm (ABC) Tj ET'
    ])
    assert_equal 1, anchors.length
    assert_equal(-12.0, anchors.first.size_pt)
    observed = external_item('ABC', anchors)
    assert_equal(-90.0, observed.angle)
    assert_equal 12.0, observed.font_size
  end

  def test_unanchored_callout_behavior_is_unchanged
    ['1/2', '1/2"', 'TYP', 'TYP.'].each do |text|
      item = external_item(text, [])
      assert_equal 0.0, item.angle
      assert_equal 10.0, item.font_size
    end
  end

  def test_invalid_internal_heights_do_not_become_source_anchors
    [0, Float::INFINITY, -Float::INFINITY, Float::NAN].each do |size|
      item = IMP::TextParser::TextItem.new('ABC', 10, 90, size, -90, '/F1')
      assert_empty IMP.nominal_anchors_from_text_items([item])
    end
  end
end
