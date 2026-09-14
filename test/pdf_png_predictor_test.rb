require 'minitest/autorun'
require 'zlib'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'

class PdfPngPredictorTest < Minitest::Test
  PARSER = BlueCollarSystems::PDFVectorImporter::PDFParser
  RGB = [10,20,30,40,50,60,15,30,45,75,90,105].pack('C*')
  FILTERED = [
    [0,10,20,30,40,50,60,0,15,30,45,75,90,105],
    [1,10,20,30,30,30,30,1,15,30,45,60,60,60],
    [2,10,20,30,40,50,60,2,5,10,15,35,40,45],
    [3,10,20,30,35,40,45,3,10,20,30,48,50,53],
    [4,10,20,30,30,30,30,4,5,10,15,35,40,45]
  ].freeze

  def test_rgb_rows_and_left_neighbours_use_all_color_components
    parser = PARSER.new('unused.pdf')
    FILTERED.each do |bytes|
      assert_equal RGB, parser.apply_png_predictor(bytes.pack('C*'), 2, 3, 8)
    end
  end

  def test_stream_decoder_passes_colors_and_bits_from_decode_parameters
    parser = PARSER.new('unused.pdf')
    bytes = Zlib::Deflate.deflate(FILTERED[4].pack('C*'))
    raw = "1 0 obj\n<< /Length #{bytes.bytesize} /Filter /FlateDecode /DecodeParms << /Predictor 15 /Colors 3 /Columns 2 /BitsPerComponent 8 >> >>\nstream\n".b + bytes + "\nendstream\nendobj".b
    parser.stub(:get_raw_object, raw) { assert_equal RGB, parser.get_stream_data(1) }
  end

  def test_default_single_channel_predictor_still_decodes_xref_rows
    parser = PARSER.new('unused.pdf')
    assert_equal [10,20,15,25].pack('C*'), parser.apply_png_predictor([2,10,20,2,5,5].pack('C*'),2)
  end

  def test_packed_and_sixteen_bit_samples_use_byte_strides
    parser = PARSER.new('unused.pdf')
    assert_equal [128,255].pack('C*'), parser.apply_png_predictor([1,128,127].pack('C*'),9,1,1)
    assert_equal [1,2,4,6].pack('C*'), parser.apply_png_predictor([1,1,2,3,4].pack('C*'),2,1,16)
  end

  def test_truncated_rows_and_invalid_filters_are_not_silent_successes
    parser = PARSER.new('unused.pdf')
    assert_raises(ArgumentError) { parser.apply_png_predictor([0,1].pack('C*'),2) }
    assert_raises(ArgumentError) { parser.apply_png_predictor([5,1,2].pack('C*'),2) }
    assert_raises(ArgumentError) { parser.apply_png_predictor('',0) }
  end
end
