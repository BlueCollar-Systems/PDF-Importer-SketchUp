#!/usr/bin/env ruby
# Inline image data (BI <dict> ID <data> EI) may contain any byte, including
# a whitespace-delimited "EI". Both content-stream walkers used to end the
# image at the first such EI, which mis-ends about one image per 25 MB of
# image bytes and desynchronises every operator after it (a sheet sliced
# into 41,817 strips carries 6 MB). ContentStreamParser.inline_image_boundary
# proves the boundary instead: exact length for unfiltered data (or /L), the
# filter's own end-of-data for ASCIIHex/ASCII85/RunLength/DCT, a COMPLETE
# inflate for Flate, and only then the old EI scan.

require 'minitest/autorun'
require 'zlib'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext') unless defined?(SRC_ROOT)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/content_stream_parser'

class InlineImageBoundaryTest < Minitest::Test
  PARSER = BlueCollarSystems::PDFVectorImporter::ContentStreamParser

  def bin(text)
    value = text.dup
    value.force_encoding(Encoding::BINARY)
    value
  end

  def scan(stream, wanted = %w[BI Do q Q cm m l S])
    out = []
    PARSER.scan_operators(bin(stream), wanted) { |op, operands| out << [op, operands] }
    out
  end

  def operators_after_image(stream)
    tokens = PARSER.new([], nil).send(:tokenize_content_stream, bin(stream))
    tokens.select { |token| token[:type] == :operator }.map { |token| token[:value] }
  end

  def test_unfiltered_data_is_measured_not_scanned
    data = bin(" EI ") # four gray samples that spell a false EI
    stream = "q 4 0 0 1 10 20 cm BI /W 4 /H 1 /BPC 8 /CS /G ID " + data + " EI Q /Im0 Do"
    ops = scan(stream)
    bi = ops.find { |op, _| op == 'BI' }
    assert_equal data, bi[1][1]
    assert_includes bi[1][0], '/W 4'
    assert_equal ['/Im0'], ops.find { |op, _| op == 'Do' }[1]
    assert_equal %w[q cm BI Q Do], ops.map(&:first)
    assert_equal %w[q cm Q Do], operators_after_image(stream)
  end

  def test_rgb_and_packed_bit_lengths_are_exact
    rgb = bin([1, 2, 3, 4, 5, 6].pack('C*'))
    stream = "BI /W 2 /H 1 /BPC 8 /CS /RGB ID " + rgb + " EI Q"
    assert_equal rgb, scan(stream).first[1][1]
    packed = bin([0b10101010, 0b01010101].pack('C*')) # 2 rows of 5 one-bit gray samples
    stream = "BI /W 5 /H 2 /BPC 1 /CS /G ID " + packed + "\nEI q"
    assert_equal packed, scan(stream).first[1][1]
    mask = bin([0xFF].pack('C*'))
    stream = "BI /W 8 /H 1 /IM true ID " + mask + " EI Q"
    assert_equal mask, scan(stream).first[1][1]
  end

  def test_pdf2_length_key_wins
    data = bin("\x00 EI \x00 EI \x00")
    stream = "BI /W 1 /H 1 /L #{data.bytesize} /F /Fl ID " + data + " EI Q"
    ops = scan(stream)
    assert_equal data, ops.first[1][1]
    assert_equal %w[BI Q], ops.map(&:first)
  end

  def test_flate_data_containing_a_false_ei_ends_at_the_complete_stream
    pixels = bin("ab EI cd EI\nef")
    deflated = Zlib::Deflate.deflate(pixels, Zlib::NO_COMPRESSION) # stored block keeps the bytes verbatim
    assert_includes deflated, " EI ", 'fixture must carry a false EI inside the compressed bytes'
    stream = "q BI /W #{pixels.bytesize} /H 1 /BPC 8 /CS /G /F /Fl ID " + deflated +
             "\nEI Q 10 10 m 20 20 l S"
    ops = scan(stream)
    bi = ops.find { |op, _| op == 'BI' }
    assert_equal deflated, bi[1][1]
    assert_equal pixels, Zlib::Inflate.inflate(bi[1][1])
    assert_equal %w[q BI Q m l S], ops.map(&:first)
    assert_equal %w[q Q m l S], operators_after_image(stream)
  end

  def test_flate_without_any_complete_stream_falls_back_to_the_first_ei
    garbage = bin("\x01\x02 EI \x03")
    stream = "BI /W 3 /H 1 /F /Fl ID " + garbage + " EI Q"
    ops = scan(stream)
    assert_equal bin("\x01\x02"), ops.first[1][1]
  end

  def test_filter_end_of_data_markers
    hex = "BI /W 2 /H 1 /BPC 8 /CS /G /F /AHx ID 4549 4549> EI Q"
    assert_equal '4549 4549>', scan(hex).first[1][1]
    a85 = "BI /W 4 /H 1 /BPC 8 /CS /G /F /A85 ID 87cURD~> EI Q"
    assert_equal '87cURD~>', scan(a85).first[1][1]
    rl = bin([2, 0x20, 0x45, 0x49, 128].pack('C*')) # literal run " EI" then EOD
    stream = "BI /W 3 /H 1 /BPC 8 /CS /G /F /RL ID " + rl + " EI Q"
    assert_equal rl, scan(stream).first[1][1]
    jpeg = bin("\xFF\xD8 EI \xFF\xD9")
    stream = "BI /W 1 /H 1 /BPC 8 /CS /RGB /F /DCT ID " + jpeg + " EI Q"
    assert_equal jpeg, scan(stream).first[1][1]
    assert_equal %w[BI Q], scan(stream).map(&:first)
  end

  def test_contradicted_length_falls_back_to_the_ei_scan
    # /W 8 claims 8 bytes but the image really has 3: EI is not where the
    # count says, so the proof is refused and the scan takes over.
    data = bin("\x01\x02\x03")
    stream = "BI /W 8 /H 1 /BPC 8 /CS /G ID " + data + " EI Q"
    ops = scan(stream)
    assert_equal data, ops.first[1][1]
    assert_equal %w[BI Q], ops.map(&:first)
  end

  def test_missing_ei_consumes_the_rest_of_the_stream
    stream = "BI /W 2 /H 1 /BPC 8 /CS /G ID \x01\x02 Q q"
    ops = scan(stream)
    assert_equal ['BI'], ops.map(&:first)
  end

  def test_existing_inline_count_fixture_still_counts_every_image
    stream = "q 2 0 0 3 11 13 cm BI /W 1 /H 1 /BPC 8 /CS /RGB ID " \
             "abcEIx-not-an-operator\x00payload\nEI Q\n" \
             "q BI /W 1 /H 1 /BPC 8 /CS /G ID z\nEI Q"
    assert_equal 2, scan(stream).count { |op, _| op == 'BI' }
  end

  def test_boundary_helper_reports_offsets
    stream = bin("BI /W 1 /H 1 /BPC 8 /CS /G ID x EI Q")
    boundary = PARSER.inline_image_boundary(stream, 2)
    assert_equal ' /W 1 /H 1 /BPC 8 /CS /G', boundary[:dictionary]
    assert_equal 'x', stream.byteslice(boundary[:data_start], boundary[:data_end] - boundary[:data_start])
    assert_equal 'Q', stream.byteslice(boundary[:resume], 2).strip
    assert_nil PARSER.inline_image_boundary(bin('BI /W 1 /H 1'), 2)
  end
end
