require 'minitest/autorun'

ROOT = File.expand_path('..', __dir__) unless defined?(ROOT)
LIB = File.join(
  ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer'
) unless defined?(LIB)

%w[
  logger.rb command_runner.rb dependency_resolver.rb page_transform.rb
  text_parser.rb external_text_extractor.rb
].each { |name| require File.join(LIB, name) }

class ExternalTextExtractorBBoxTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  EXTRACTOR = IMP::ExternalTextExtractor
  ITEM = IMP::TextParser::TextItem

  def item(text, x, box)
    ITEM.new(
      text, x, 200.0, 10.0, 0.0, 'pdftotext', nil,
      box[0], box[1], box[2], box[3]
    )
  end

  def assert_bbox(expected, actual)
    assert_equal expected, [
      actual.bbox_x0, actual.bbox_y0, actual.bbox_x1, actual.bbox_y1
    ]
  end

  def test_stitched_denominator_preserves_union_source_bbox
    head = item('11/', 100.0, [100.0, 200.0, 112.0, 212.0])
    tail = item('16', 113.0, [113.0, 200.0, 124.0, 212.0])

    merged = EXTRACTOR.send(
      :stitch_fragmented_dimensions, [head, tail]
    ).find { |candidate| candidate.text == '11/16' }

    refute_nil merged
    assert_bbox [100.0, 200.0, 124.0, 212.0], merged
  end

  def test_repaired_whole_fraction_preserves_union_source_bbox
    head = item('9 1', 100.0, [100.0, 200.0, 112.0, 212.0])
    fraction = item('3/16', 113.0, [113.0, 200.0, 130.0, 212.0])

    merged = EXTRACTOR.send(
      :repair_whole_fraction_pairs, [head, fraction]
    ).find { |candidate| candidate.text == '9 3/16' }

    refute_nil merged
    assert_bbox [100.0, 200.0, 130.0, 212.0], merged
  end

  def test_angle_mark_stitch_accepts_variable_numeric_fragment_widths
    head = item('a1', 100.0, [100.0, 200.0, 114.0, 214.0])
    middle = item('2', 107.0, [107.0, 195.0, 114.0, 209.0])
    tail = item('34', 110.0, [110.0, 184.0, 124.0, 198.0])

    result = EXTRACTOR.send(
      :stitch_angle_mark_fragments, [head, middle, tail]
    )
    merged = result.find { |candidate| candidate.text == 'a1234' }

    refute_nil merged
    assert_equal ['a1234'], result.map(&:text)
    assert_bbox [100.0, 184.0, 124.0, 214.0], merged
    assert_in_delta(-58.0, merged.angle, 1.0)
  end
end
