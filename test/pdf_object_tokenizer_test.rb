#!/usr/bin/env ruby
require 'minitest/autorun'
require 'timeout'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'

class PdfObjectTokenizerTest < Minitest::Test
  def setup
    @parser = BlueCollarSystems::PDFVectorImporter::PDFParser.allocate
  end

  def parse(text)
    Timeout.timeout(2) { @parser.send(:parse_object_value, text) }
  end

  def test_printable_trailer_ids_containing_array_delimiters
    source = '<< /ID [(one]two) (three[four)] /Size 17 /Root 5 0 R >>'
    value = parse(source)
    assert_equal ['(one]two)', '(three[four)'], value['/ID']
    assert_equal '17', value['/Size']
    assert_equal '5 0 R', value['/Root']
  end

  def test_nested_containers_ignore_all_delimiters_in_literal_strings
    value = parse('<< /A [<< /S (hello >> ] << [ world) /N 4 >> [1 2]] /B 9 >>')
    assert_equal '(hello >> ] << [ world)', value['/A'][0]['/S']
    assert_equal '4', value['/A'][0]['/N']
    assert_equal ['1', '2'], value['/A'][1]
    assert_equal '9', value['/B']
  end

  def test_nested_parentheses_and_escaped_parentheses
    value = parse('<< /A [(outer(inner]value)end) (escaped\)value)] /B true >>')
    assert_equal ['(outer(inner]value)end)', '(escaped\)value)'], value['/A']
    assert_equal true, value['/B']
  end

  def test_even_backslashes_do_not_escape_the_closing_parenthesis
    literal = '(tail' + ('\\' * 2) + ')'
    value = parse('<< /A [' + literal + ' 42] /B 8 >>')
    assert_equal [literal, '42'], value['/A']
    assert_equal '8', value['/B']
  end

  def test_comments_do_not_close_arrays_or_dicts
    source = "<< /A [1 % ] >> (ignored\r\n 2] % >> [ ignored\n /B 7 >>"
    value = parse(source)
    assert_equal ['1', '2'], value['/A']
    assert_equal '7', value['/B']
  end

  def test_hex_strings_and_nested_references_keep_original_tokens
    value = parse('<< /A [<5B5D2829> 7 0 R [-.5 +2.25 null false]] /B /Name#5D >>')
    assert_equal ['<5B5D2829>', '7 0 R', ['-.5', '+2.25', nil, false]], value['/A']
    assert_equal '/Name#5D', value['/B']
  end

  def test_top_level_array_uses_same_literal_aware_boundary
    assert_equal ['(a]b)', {'/Text' => '(>>)'}], parse('[(a]b) << /Text (>>) >>] trailing')
  end

  def test_dictionary_extraction_stops_after_real_closing_delimiter
    value = parse('<< /Text (>>) /Other [1 (])] >> stream ignored')
    assert_equal '(>>)', value['/Text']
    assert_equal ['1', '(])'], value['/Other']
  end

  def test_unmatched_delimiters_and_truncated_objects_cannot_stall
    [')', '>', '{', '}', '] >> ) }', '/A [unterminated', '/A (unterminated\\'].each do |text|
      tokens = Timeout.timeout(2) { @parser.send(:tokenize_pdf, text) }
      assert_kind_of Array, tokens
    end
    assert_equal [], parse('[1 (unterminated]')
  end

  def test_many_nested_containers_scan_iteratively
    text = '[' * 200 + '(] >>)' + ']' * 200
    tokens = Timeout.timeout(2) { @parser.send(:tokenize_pdf, text + ' 9') }
    assert_equal [text, '9'], tokens
  end
end
