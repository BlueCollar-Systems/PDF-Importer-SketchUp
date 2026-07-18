#!/usr/bin/env ruby
# Exact PDF text content is semantic source data.  Whitespace is never proof
# that a glyph has no ink: a PDF font may map any character code to a painted
# glyph, and native text/label modes must preserve the requested content.

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

require 'bc_pdf_vector_importer/primitives'
require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/primitive_extractor'

class TextWhitespacePreservationTest < Minitest::Test
  MOD = BlueCollarSystems::PDFVectorImporter
  TP = MOD::TextParser

  def parse_exact(literal, strict = true)
    stream = "BT /F1 12 Tf 1 0 0 1 10 20 Tm (#{literal}) Tj ET"
    opts = { strict_text_fidelity: strict }
    opts[:merge_text_runs] = false if strict
    TP.new([stream], {}, opts).parse
  end

  def normalize(text)
    item = TP::TextItem.new(
      text, 10.0, 20.0, 12.0, 0.0, 'F1', 12.0,
      10.0, 20.0, 30.0, 32.0, nil, 'text_span:1:0'
    )
    MOD::PrimitiveExtractor.extract(
      [], [item], [0.0, 0.0, 612.0, 792.0], 1
    ).text_items
  end

  def test_internal_parser_preserves_leading_and_trailing_spaces
    items = parse_exact(' A ')

    assert_equal 1, items.length
    assert_equal ' A ', items.first.text
  end

  def test_internal_parser_keeps_whitespace_only_source_content
    items = parse_exact('   ')

    assert_equal 1, items.length
    assert_equal '   ', items.first.text
  end

  def test_default_parser_does_not_normalize_semantic_source_content
    assert_equal ' A ', parse_exact(' A ', false).fetch(0).text
    assert_equal '   ', parse_exact('   ', false).fetch(0).text
  end

  def test_strict_run_merge_keeps_exact_chunk_boundaries
    parser = TP.new([], {}, strict_text_fidelity: true)
    first = TP::TextItem.new(' A', 0.0, 0.0, 12.0, 0.0, 'F1', 12.0)
    second = TP::TextItem.new('B ', 6.0, 0.0, 12.0, 0.0, 'F1', 12.0)

    merged = parser.send(:merge_run, [first, second])

    assert_equal ' AB ', merged.text
  end

  def test_normalized_ir_preserves_exact_source_content
    assert_equal ' A ', normalize(' A ').fetch(0).text
  end

  def test_normalized_ir_keeps_whitespace_only_source_content
    items = normalize('   ')

    assert_equal 1, items.length
    assert_equal '   ', items.first.text
  end
end
