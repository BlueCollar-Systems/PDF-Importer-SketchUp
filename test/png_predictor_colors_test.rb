# Flate images encoded with a PNG predictor must be un-filtered against the
# real row width. /Columns counts pixels, so a 3-colour row is Columns * 3
# bytes and the Sub/Average/Paeth left neighbour is 3 bytes back. Reading only
# /Columns un-filtered every colour image against a 1-byte-per-pixel row: on a
# 401 x 251 DeviceRGB logo it returned 301,151 bytes where the image is
# 301,953, and the extractor rejected the placement as "decoded raw image byte
# length does not match its dimensions".

$LOAD_PATH.unshift File.expand_path('../extracted/sketchup_ext', __dir__)

require 'minitest/autorun'
require 'zlib'
require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/pdf_parser'

class PngPredictorColorsTest < Minitest::Test
  PARSER = BlueCollarSystems::PDFVectorImporter::PDFParser

  def parser
    PARSER.allocate
  end

  # Encode rows with a chosen PNG filter type, the way a PDF writer does.
  def encode(rows, filter_type, bpp)
    out = ''.dup.force_encoding('BINARY')
    previous = Array.new(rows.first.length, 0)
    rows.each do |row|
      out << [filter_type].pack('C')
      encoded = Array.new(row.length) do |i|
        left = i >= bpp ? row[i - bpp] : 0
        up = previous[i]
        up_left = i >= bpp ? previous[i - bpp] : 0
        case filter_type
        when 0 then row[i]
        when 1 then (row[i] - left) & 0xFF
        when 2 then (row[i] - up) & 0xFF
        when 3 then (row[i] - ((left + up) / 2)) & 0xFF
        when 4 then (row[i] - PARSER.allocate.send(:paeth_predict, left, up, up_left)) & 0xFF
        end
      end
      out << encoded.pack('C*')
      previous = row
    end
    out
  end

  def rgb_rows(columns, height)
    (0...height).map do |y|
      (0...columns).flat_map { |x| [(x * 7 + y) % 256, (x * 13 + y * 3) % 256, (x + y * 11) % 256] }
    end
  end

  def test_three_colour_rows_round_trip_through_every_filter_type
    columns = 9
    height = 6
    rows = rgb_rows(columns, height)
    (0..4).each do |filter_type|
      encoded = encode(rows, filter_type, 3)
      decoded = parser.send(:apply_png_predictor, encoded, columns, 3, 8)
      assert_equal columns * 3 * height, decoded.bytesize,
                   "filter #{filter_type}: wrong length"
      assert_equal rows.flatten, decoded.unpack('C*'),
                   "filter #{filter_type}: wrong pixels"
    end
  end

  def test_grayscale_default_still_round_trips
    columns = 12
    rows = (0...4).map { |y| (0...columns).map { |x| (x * 5 + y) % 256 } }
    (0..4).each do |filter_type|
      encoded = encode(rows, filter_type, 1)
      # colors/bpc default to 1/8, the old single-channel behaviour
      decoded = parser.send(:apply_png_predictor, encoded, columns)
      assert_equal rows.flatten, decoded.unpack('C*'), "filter #{filter_type}"
    end
  end

  def test_row_width_uses_colors_and_bit_depth
    # 4 pixels, 3 colours, 8 bits = 12 bytes + 1 filter byte per row.
    rows = [[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], [13] * 12]
    encoded = encode(rows, 2, 3)
    assert_equal 2 * 13, encoded.bytesize
    assert_equal 24, parser.send(:apply_png_predictor, encoded, 4, 3, 8).bytesize
    # 16-bit samples double the row and the pixel stride.
    assert_equal 48, parser.send(:apply_png_predictor, 'x' * (2 * 25), 4, 3, 16).bytesize
    # Sub-byte depths pack several pixels per byte and never go below 1 bpp.
    assert_equal 2, parser.send(:apply_png_predictor, 'x' * 4, 8, 1, 1).bytesize
  end

  def test_short_and_degenerate_buffers_are_returned_untouched
    assert_equal '', parser.send(:apply_png_predictor, '', 4, 3, 8)
    assert_equal 'ab', parser.send(:apply_png_predictor, 'ab', 4, 3, 8)
    # Guards against zero or negative parameters from a malformed dictionary.
    assert_equal 4, parser.send(:apply_png_predictor, "\x00abcd", 4, 0, 0).bytesize
  end

  def test_a_flate_rgb_image_stream_decodes_to_its_exact_pixel_count
    columns = 401
    height = 251
    rows = rgb_rows(columns, height)
    encoded = encode(rows, 1, 3) # Sub, as the owner's logo uses
    assert_equal height * (columns * 3 + 1), encoded.bytesize
    decoded = parser.send(:apply_png_predictor, Zlib::Inflate.inflate(Zlib::Deflate.deflate(encoded)),
                          columns, 3, 8)
    assert_equal columns * height * 3, decoded.bytesize
    assert_equal rows.flatten, decoded.unpack('C*')
  end
end
