#!/usr/bin/env ruby
# Custom /Encoding Differences must become characters, and a long page
# stream must be painted past the token-array safety cap.

require 'minitest/autorun'
require 'tmpdir'
require_relative 'support/synthetic_pdf_builder'

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(ROOT, 'extracted', 'sketchup_ext'))
require 'bc_pdf_vector_importer/pdf_parser'
require 'bc_pdf_vector_importer/text_parser'
require 'bc_pdf_vector_importer/content_stream_parser'
require 'bc_pdf_vector_importer/logger'

class EncodingDifferencesAndStreamBudgetTest < Minitest::Test
  Parser = BlueCollarSystems::PDFVectorImporter::PDFParser
  Text = BlueCollarSystems::PDFVectorImporter::TextParser
  Streams = BlueCollarSystems::PDFVectorImporter::ContentStreamParser

  def test_differences_encoding_recovers_the_glyph_names
    content = "BT /F1 12 Tf 10 80 Td (\\011\\012\\013) Tj ET"
    stream = SyntheticPdfBuilder.stream_object('', content)
    font = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding 6 0 R >>'
    encoding = '<< /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [9 /W /I /D] >>'
    page = '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] ' \
           '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>'
    bodies = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      page,
      stream,
      font,
      encoding
    ]
    parser = nil
    Dir.mktmpdir('enc-diff') do |dir|
      path = SyntheticPdfBuilder.write(File.join(dir, 'diff.pdf'), bodies)
      parser = Parser.new(path)
      parser.parse
      maps = parser.page_font_maps(1)
      refute_empty maps
      items = Text.new(parser.page_data(1)[:content_streams], maps,
                       { :strict_text_fidelity => true }, {}).parse
      assert_equal ['WID'], items.map { |item| item.text.to_s }
    end
  ensure
    parser.release if parser
  end

  def test_page_parse_continues_past_the_token_array_cap
    ops = (0...30).map { |i| "#{i} 0 m #{i} 10 l S" }.join("\n")
    with_token_cap(4) do
      listed = Streams.new([ops], nil).send(:tokenize_content_stream, ops)
      assert listed.length <= 5, 'the token array keeps its safety cap'

      paths = Streams.new([ops], nil).parse
      assert_equal 30, paths.length
      assert paths.all? { |path| path.stroke }
    end
  end

  def with_token_cap(cap)
    old = Streams::MAX_TOKENS_PER_STREAM
    Streams.send(:remove_const, :MAX_TOKENS_PER_STREAM)
    Streams.const_set(:MAX_TOKENS_PER_STREAM, cap)
    yield
  ensure
    Streams.send(:remove_const, :MAX_TOKENS_PER_STREAM) if Streams.const_defined?(:MAX_TOKENS_PER_STREAM)
    Streams.const_set(:MAX_TOKENS_PER_STREAM, old)
  end
end
