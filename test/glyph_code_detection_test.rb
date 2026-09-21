#!/usr/bin/env ruby
# The trigger itself: which fonts are reported as delivering raw glyph codes.
#
# This is the crux of the change. A check that fired on "no /ToUnicode" would
# condemn the many fonts that carry none and decode perfectly, because WinAnsi
# and MacRoman are real encodings. Measured on 120 corpus sheets: 297 fonts on
# page 1, 4 affected, 155 with no /ToUnicode that are correctly left alone.
#
# Fixtures are synthetic font dictionaries (SAMPLE subsets).

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext') unless defined?(SRC_ROOT)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

module BlueCollarSystems
  module PDFVectorImporter
    unless defined?(Logger)
      module Logger
        def self.warn(*_args); end
        def self.info(*_args); end
        def self.debug(*_args); end
        def self.error(*_args); end
      end
    end
  end
end

require 'bc_pdf_vector_importer/pdf_parser'

PARSER_CLASS = BlueCollarSystems::PDFVectorImporter::PDFParser

class GlyphCodeDetectionTest < Minitest::Test
  def setup
    # No file is read: classify_font_glyph_codes is handed dictionaries
    # directly, and resolve_object returns a Hash unchanged.
    @parser = PARSER_CLASS.new('unused-in-this-test.pdf')
  end

  def classify(dict, name = '/TT1')
    @parser.send(:classify_font_glyph_codes, name, dict)
  end

  # ── the one case that must fire ──

  def test_type0_identity_h_without_tounicode_is_unmapped
    row = classify('/Subtype' => '/Type0',
                   '/BaseFont' => '/ABCDEF+Arial',
                   '/Encoding' => '/Identity-H')

    assert_equal 'unmapped_glyph_codes', row[:status]
    assert_equal '/Identity-H', row[:encoding]
    assert_equal false, row[:has_to_unicode]
    assert_match(/glyph indices/, row[:reason])
  end

  def test_identity_v_fires_too
    row = classify('/Subtype' => '/Type0', '/Encoding' => '/Identity-V')
    assert_equal 'unmapped_glyph_codes', row[:status]
  end

  # ── the cases that must NOT fire ──

  def test_a_simple_winansi_font_without_tounicode_is_mapped
    row = classify('/Subtype' => '/TrueType',
                   '/BaseFont' => '/ArialMT',
                   '/Encoding' => '/WinAnsiEncoding')

    assert_equal 'mapped', row[:status]
    assert_equal false, row[:has_to_unicode]
    assert_match(/real character encoding/, row[:reason])
  end

  def test_a_simple_font_with_no_encoding_at_all_is_mapped
    row = classify('/Subtype' => '/Type1', '/BaseFont' => '/Helvetica')
    assert_equal 'mapped', row[:status]
  end

  def test_type0_with_tounicode_is_mapped
    row = classify('/Subtype' => '/Type0',
                   '/Encoding' => '/Identity-H',
                   '/ToUnicode' => '12 0 R')

    assert_equal 'mapped', row[:status]
    assert_equal true, row[:has_to_unicode]
    assert_match(/ToUnicode/, row[:reason])
  end

  def test_type0_with_a_named_cmap_that_maps_characters_is_mapped
    row = classify('/Subtype' => '/Type0', '/Encoding' => '/UniJIS-UCS2-H')
    assert_equal 'mapped', row[:status]
    assert_match(/maps codes to characters/, row[:reason])
  end

  def test_tounicode_on_a_descendant_font_counts
    # Mirrors extract_font_to_unicode_map, which looks there too.
    descendant = { '/Subtype' => '/CIDFontType2', '/ToUnicode' => '9 0 R' }
    row = classify('/Subtype' => '/Type0',
                   '/Encoding' => '/Identity-H',
                   '/DescendantFonts' => [descendant])

    assert_equal 'mapped', row[:status]
    assert_equal true, row[:has_to_unicode]
  end

  # ── failing to read a font is not the same as the font being broken ──

  def test_an_unreadable_font_dictionary_is_not_reported_as_unmapped
    row = classify(nil)
    assert_equal 'mapped', row[:status]
    assert_match(/could not be read/, row[:reason])
  end

  # ── an embedded CMap stream is not assumed to be Identity ──

  def test_an_encoding_stream_reference_is_not_treated_as_identity
    # /Encoding may be an embedded CMap stream. It cannot be recognised as
    # Identity without decoding it, and guessing would condemn a font whose
    # CMap maps characters perfectly well.
    row = classify('/Subtype' => '/Type0', '/Encoding' => '7 0 R')
    assert_equal 'mapped', row[:status]
  end
end
