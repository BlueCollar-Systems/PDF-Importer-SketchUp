#!/usr/bin/env ruby
# Text a PDF delivers as raw glyph codes is detected and reported, and nothing
# about what is drawn changes.
#
# Every fixture here is synthetic (SAMPLE fonts, fictional marks MS-1 / D042).

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext') unless defined?(SRC_ROOT)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

require 'bc_pdf_vector_importer/glyph_code_report'

GCR = BlueCollarSystems::PDFVectorImporter::GlyphCodeReport

def unmapped_font(resource = '/TT1', base = '/ABCDEF+Arial')
  {
    :resource => resource,
    :base_font => base,
    :subtype => '/Type0',
    :encoding => '/Identity-H',
    :has_to_unicode => false,
    :status => 'unmapped_glyph_codes',
    :reason => 'a Type0 font with an Identity CMap and no /ToUnicode'
  }
end

def mapped_font(resource = '/TT4', encoding = '/WinAnsiEncoding')
  {
    :resource => resource,
    :base_font => '/ArialMT',
    :subtype => '/TrueType',
    :encoding => encoding,
    :has_to_unicode => false,
    :status => 'mapped',
    :reason => 'a simple font whose /Encoding is a real character encoding'
  }
end

def span(codes, glyphs, chars = nil)
  {
    :font => '/TT1',
    :x => 10.0,
    :y => 20.0,
    :raw_codes => codes,
    :glyphs => glyphs,
    :delivered_characters => chars || (glyphs * 2)
  }
end

class GlyphCodeReportTest < Minitest::Test
  # ── the trigger ──

  def test_a_font_with_no_tounicode_but_a_real_encoding_is_not_reported
    # The whole point of the narrow trigger. Measured on 120 corpus sheets:
    # 155 of 297 page-1 fonts have no /ToUnicode and decode perfectly.
    record = GCR.page_record(1, [mapped_font], [], GCR::ATTRIBUTION_PER_ITEM)
    block = GCR.delivery_block([record])

    assert_empty block[:fonts_affected]
    assert_equal 0, block[:items_affected]
    assert_equal [], block[:pages_affected]
    assert_equal '', GCR.summary_line(block)
  end

  def test_a_type0_identity_font_with_no_tounicode_is_reported
    record = GCR.page_record(1, [unmapped_font, mapped_font],
                             [span('0030003600100016', 4)],
                             GCR::ATTRIBUTION_PER_ITEM)
    block = GCR.delivery_block([record])

    assert_equal 1, block[:fonts_affected].length
    assert_equal '/ABCDEF+Arial', block[:fonts_affected][0][:base_font]
    assert_equal 1, block[:items_affected]
    assert_equal 4, block[:glyphs_affected]
    assert_equal [1], block[:pages_affected]
  end

  # ── what the report may and may not claim ──

  def test_the_report_never_claims_a_recovery
    record = GCR.page_record(1, [unmapped_font], [span('001a', 1)],
                             GCR::ATTRIBUTION_PER_ITEM)
    block = GCR.delivery_block([record])

    assert_equal false, block[:recovery_attempted]
    assert_match(/does not yet recover/, block[:note])
    assert_match(/Nothing was recovered/, GCR.summary_line(block))
  end

  def test_codes_are_recorded_as_hex_never_as_text
    # 0x30 0x36 are "0" and "6". A record that printed them as characters
    # would read as if the drawing said "06".
    record = GCR.page_record(1, [unmapped_font], [span('0030003600100016', 4)],
                             GCR::ATTRIBUTION_PER_ITEM)
    block = GCR.delivery_block([record])

    assert_equal '0030003600100016', block[:items][0][:raw_codes]
  end

  def test_a_page_examined_only_at_font_level_says_so_for_the_whole_import
    # Poppler's -bbox-layout output carries no font identity. That is a limit
    # of the run, and one such page makes the whole item list incomplete.
    per_item = GCR.page_record(1, [unmapped_font], [span('001a', 1)],
                               GCR::ATTRIBUTION_PER_ITEM)
    fonts_only = GCR.page_record(2, [unmapped_font], [],
                                 GCR::ATTRIBUTION_FONTS_ONLY)
    block = GCR.delivery_block([per_item, fonts_only])

    assert_equal GCR::ATTRIBUTION_FONTS_ONLY, block[:attribution]
    assert_equal [1, 2], block[:pages_affected]
    refute_match(/\d+ text item/, GCR.summary_line(block))
  end

  def test_every_page_per_item_keeps_the_item_wording
    a = GCR.page_record(1, [unmapped_font], [span('001a', 1)],
                        GCR::ATTRIBUTION_PER_ITEM)
    b = GCR.page_record(2, [unmapped_font], [span('001b', 1)],
                        GCR::ATTRIBUTION_PER_ITEM)
    block = GCR.delivery_block([a, b])

    assert_equal GCR::ATTRIBUTION_PER_ITEM, block[:attribution]
    assert_match(/2 text items/, GCR.summary_line(block))
  end

  # ── the cap must never hide the count ──

  def test_the_item_cap_truncates_the_list_and_never_the_counts
    spans = Array.new(GCR::ITEM_CAP + 25) { span('0030', 1) }
    record = GCR.page_record(1, [unmapped_font], spans,
                             GCR::ATTRIBUTION_PER_ITEM)
    block = GCR.delivery_block([record])

    assert_equal GCR::ITEM_CAP, block[:items].length
    assert_equal true, block[:items_truncated]
    assert_equal GCR::ITEM_CAP + 25, block[:items_affected]
    assert_equal GCR::ITEM_CAP + 25, block[:glyphs_affected]
  end

  # ── the operator line ──

  def test_a_clean_sheet_says_nothing_at_all
    record = GCR.page_record(1, [mapped_font, mapped_font('/TT5')], [],
                             GCR::ATTRIBUTION_PER_ITEM)
    assert_equal '', GCR.summary_line(GCR.delivery_block([record]))
  end

  def test_the_line_names_the_font_and_warns_the_text_can_read_as_ordinary
    record = GCR.page_record(1, [unmapped_font], [span('0030003600100016', 4)],
                             GCR::ATTRIBUTION_PER_ITEM)
    line = GCR.summary_line(GCR.delivery_block([record]), 'See the report.')

    assert_match(/ABCDEF\+Arial/, line)
    assert_match(/raw glyph codes, not characters/, line)
    assert_match(/read as ordinary text/, line)
    assert_match(/See the report\./, line)
  end

  def test_two_affected_fonts_read_as_plural
    row = GCR.page_record(
      1,
      [unmapped_font('/TT1', '/ABCDEF+Arial'),
       unmapped_font('/TT2', '/GHIJKL+ArialNarrow')],
      [span('0030', 1)],
      GCR::ATTRIBUTION_PER_ITEM
    )
    line = GCR.summary_line(GCR.delivery_block([row]))

    assert_match(/Those fonts carry no Unicode map/, line)
    refute_match(/That font carries/, line)
  end

  def test_one_affected_font_reads_as_singular
    row = GCR.page_record(1, [unmapped_font], [span('0030', 1)],
                          GCR::ATTRIBUTION_PER_ITEM)
    line = GCR.summary_line(GCR.delivery_block([row]))

    assert_match(/That font carries no Unicode map/, line)
  end

  def test_the_block_is_published_even_when_nothing_was_affected
    block = GCR.delivery_block([])
    assert_equal GCR::SCHEMA, block[:schema]
    assert_equal 0, block[:items_affected]
  end

  def test_one_font_used_on_several_pages_is_listed_once
    a = GCR.page_record(1, [unmapped_font], [span('001a', 1)],
                        GCR::ATTRIBUTION_PER_ITEM)
    b = GCR.page_record(2, [unmapped_font], [span('001b', 1)],
                        GCR::ATTRIBUTION_PER_ITEM)
    block = GCR.delivery_block([a, b])

    assert_equal 1, block[:fonts_affected].length
    assert_equal 2, block[:items_affected]
  end
end
