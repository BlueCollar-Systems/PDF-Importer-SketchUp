require 'minitest/autorun'

ROOT = File.expand_path('..', __dir__) unless defined?(ROOT)
LIB = File.join(
  ROOT, 'extracted', 'sketchup_ext', 'bc_pdf_vector_importer'
) unless defined?(LIB)

%w[
  logger.rb command_runner.rb dependency_resolver.rb page_transform.rb
  text_parser.rb external_text_extractor.rb
].each { |name| require File.join(LIB, name) }

# Visual-oracle regression (private benchmark sheet, SketchUp v3.7.140, 2026-08-16):
# the "3/16" fillet-weld size at the lower-left EX101 base plate was dropped
# in EVERY text mode. pdftotext -bbox-layout joins the OTHER weld's "3/16"
# onto the "DEMO NOTES" line, and drop_redundant_fragments then rejected the
# genuinely separate "3/16" (23.5 pt below, 9.3 pt right) as a leftover of
# that composite because the composite text contains "3/16" and the anchor
# points were within dx<=42 / dy<=30. Dropping a source span is a fidelity
# failure; a fragment is redundant only when the composite actually contains
# it on the same line.
class ExternalTextExtractorRedundantFragmentTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  EXTRACTOR = IMP::ExternalTextExtractor
  ITEM = IMP::TextParser::TextItem

  # Made-up pdftotext -bbox-layout output (page 612 x 792 pt) that keeps the
  # source's relative geometry: the "DEMO NOTES 3 / 16" line and the
  # separate "3 / 16" weld size below-right of it.
  BBOX_WELD_NOTE_HTML = <<-HTML.freeze
<html xmlns="http://www.w3.org/1999/xhtml">
<body>
<doc>
  <page width="612.000000" height="792.000000">
    <flow>
      <block xMin="100.152716" yMin="300.336634" xMax="207.742544" yMax="314.310394">
        <line xMin="100.152716" yMin="300.336634" xMax="207.742544" yMax="314.310394">
          <word xMin="100.152716" yMin="300.336634" xMax="134.528398" yMax="311.130874">DEMO</word>
          <word xMin="137.832538" yMin="300.336634" xMax="176.768204" yMax="311.130874">NOTES</word>
          <word xMin="190.441064" yMin="300.783034" xMax="196.033868" yMax="310.227994">3</word>
          <word xMin="194.874924" yMin="302.027194" xMax="198.200360" yMax="313.271194">/</word>
          <word xMin="196.556936" yMin="304.865434" xMax="207.742544" yMax="314.310394">16</word>
        </line>
      </block>
    </flow>
    <flow>
      <block xMin="109.435937" yMin="324.420634" xMax="126.737417" yMax="337.827034">
        <line xMin="109.435937" yMin="324.420634" xMax="126.737417" yMax="337.827034">
          <word xMin="109.435937" yMin="324.420634" xMax="115.028741" yMax="333.865594">3</word>
          <word xMin="113.868260" yMin="325.547194" xMax="117.193696" yMax="336.791194">/</word>
          <word xMin="115.551809" yMin="328.382074" xMax="126.737417" yMax="337.827034">16</word>
        </line>
      </block>
    </flow>
  </page>
</doc>
</body>
</html>
  HTML

  PAGE_H = 792.0

  def item(text, x, y, box, font_size = 10.0)
    ITEM.new(
      text, x, y, font_size, 0.0, 'pdftotext', nil,
      box[0], box[1], box[2], box[3]
    )
  end

  # Red before the fix: parse_bbox_html returned only "DEMO NOTES 3/16".
  def test_separate_weld_fraction_below_composite_line_is_kept
    items = EXTRACTOR.send(:parse_bbox_html, BBOX_WELD_NOTE_HTML)
    texts = items.map(&:text)

    assert_includes texts, 'DEMO NOTES 3/16'
    assert_includes texts, '3/16',
                    "separate 3/16 weld size dropped as 'redundant': #{texts.inspect}"
    assert_equal 2, items.length, texts.inspect

    weld = items.find { |it| it.text == '3/16' }
    # Source bbox stays the pdftotext line box (PDF y-up).
    assert_in_delta 109.435937, weld.bbox_x0, 1e-6
    assert_in_delta 126.737417, weld.bbox_x1, 1e-6
    assert_in_delta PAGE_H - 337.827034, weld.bbox_y0, 1e-6
    assert_in_delta PAGE_H - 324.420634, weld.bbox_y1, 1e-6
  end

  # Direct predicate check with the same geometry (PDF y-up boxes):
  # composite line y 477.69..491.66, fragment y 454.17..467.58 -> no vertical
  # overlap -> not redundant even though the composite text contains "3/16"
  # and the anchors are within the old dx<=42 / dy<=30 window.
  def test_fragment_on_a_different_line_is_not_redundant
    composite = item(
      'DEMO NOTES 3/16', 100.152716, PAGE_H - 314.310394,
      [100.152716, PAGE_H - 314.310394, 207.742544, PAGE_H - 300.336634]
    )
    fragment = item(
      '3/16', 109.435937, PAGE_H - 337.827034,
      [109.435937, PAGE_H - 337.827034, 126.737417, PAGE_H - 324.420634]
    )

    kept = EXTRACTOR.send(:drop_redundant_fragments, [composite, fragment])

    assert_equal ['DEMO NOTES 3/16', '3/16'], kept.map(&:text)
  end

  # Positive case: a true same-line leftover (the fragment's box lies inside
  # the composite's box on the same baseline) is still dropped.
  def test_same_line_duplicate_fragment_is_still_dropped
    composite = item(
      'R 2 1/2', 100.0, 200.0, [100.0, 200.0, 140.0, 212.0]
    )
    leftover = item(
      '1/2', 128.0, 200.0, [128.0, 200.0, 140.0, 212.0]
    )

    kept = EXTRACTOR.send(:drop_redundant_fragments, [composite, leftover])

    assert_equal ['R 2 1/2'], kept.map(&:text)
  end

  # A same-line leftover whose glyphs are stacked (taller than the line box)
  # still overlaps the composite vertically and sits inside its x-range.
  def test_stacked_same_line_duplicate_fragment_is_still_dropped
    composite = item(
      'DEMO NOTES 3/16', 100.15, PAGE_H - 314.31,
      [100.15, PAGE_H - 314.31, 207.74, PAGE_H - 300.34]
    )
    leftover = item(
      '3/16', 190.44, PAGE_H - 314.31,
      [190.44, PAGE_H - 314.31, 207.74, PAGE_H - 300.78]
    )

    kept = EXTRACTOR.send(:drop_redundant_fragments, [composite, leftover])

    assert_equal ['DEMO NOTES 3/16'], kept.map(&:text)
  end

  # A fragment on the same baseline but horizontally OUTSIDE the composite's
  # box is a separate callout, not a leftover.
  def test_same_baseline_fragment_outside_composite_x_range_is_kept
    composite = item(
      'R 2 1/2', 100.0, 200.0, [100.0, 200.0, 140.0, 212.0]
    )
    separate = item(
      '1/2', 160.0, 200.0, [160.0, 200.0, 172.0, 212.0]
    )

    kept = EXTRACTOR.send(:drop_redundant_fragments, [composite, separate])

    assert_equal ['R 2 1/2', '1/2'], kept.map(&:text)
  end
end
