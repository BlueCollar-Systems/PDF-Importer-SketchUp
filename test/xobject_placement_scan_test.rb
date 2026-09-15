#!/usr/bin/env ruby
# test/xobject_placement_scan_test.rb
#
# Stream-wide XObject / embedded-image discovery (S-505 regression).
#
# XObjectParser#track_placements and EmbeddedImageExtractor#walk_streams
# used to tokenize the whole page stream into hashes under a 500,000-token
# cap. A dense 48x36 sheet expands to ~934k tokens with its only image `Do`
# at 86 % of the stream, so the logo was silently dropped with a WARN.
# Both scanners now use ContentStreamParser.scan_operators, a streaming
# q/Q/cm/Do walk with a bounded operand window and no token cap.
#
#   1. Parity: scan_operators yields the same (operator, operands) sequence
#      as the legacy placement tokenizer (copied here verbatim, cap removed)
#      for strings, hex strings, dictionaries, arrays, comments, escapes,
#      inline images and binary bytes.
#   2. A synthetic stream of > 600,000 tokens followed by a Form `Do` and an
#      Image `Do` is placed completely by both scanners with no token-limit
#      warning.
#
# Fictional content only (PRIV-1). Ruby 2.2 compatible syntax (RB22).

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

require 'bc_pdf_vector_importer/logger'
require 'bc_pdf_vector_importer/content_stream_parser'
require 'bc_pdf_vector_importer/xobject_parser'
require 'bc_pdf_vector_importer/embedded_image_extractor'

BlueCollarSystems::PDFVectorImporter::Logger.debug = false

module LegacyPlacementTokenizer
  # Verbatim copy of the pre-fix XObjectParser#tokenize_stream minus the cap.
  def self.tokenize(stream)
    tokens = []
    i = 0
    len = stream.length
    while i < len
      c = stream[i]
      if c =~ /[\s\x00]/; i += 1; next; end
      if c == '%'
        eol = stream.index(/[\r\n]/, i) || len
        i = eol + 1; next
      end
      if c == '('
        depth = 1
        j = i + 1
        while j < len && depth > 0
          if stream[j] == '\\'
            j += 2
            next
          end
          depth += 1 if stream[j] == '('
          depth -= 1 if stream[j] == ')'
          j += 1
        end
        tokens << { type: :string, value: stream[i...j] }
        i = j
        next
      end
      if c == '<' && (i + 1 >= len || stream[i + 1] != '<')
        j = stream.index('>', i) || len
        tokens << { type: :hex_string, value: stream[i..j] }
        i = j + 1
        next
      end
      if c == '<' && i + 1 < len && stream[i + 1] == '<'
        depth = 1
        j = i + 2
        while j < len - 1 && depth > 0
          if stream[j, 2] == '<<'
            depth += 1
            j += 2
          elsif stream[j, 2] == '>>'
            depth -= 1
            j += 2
          else
            j += 1
          end
        end
        tokens << { type: :dict, value: stream[i...j] }
        i = j
        next
      end
      if c == '>' && i + 1 < len && stream[i + 1] == '>'
        i += 2
        next
      end
      if c == '['
        depth = 1
        j = i + 1
        while j < len && depth > 0
          depth += 1 if stream[j] == '['
          depth -= 1 if stream[j] == ']'
          j += 1
        end
        tokens << { type: :array, value: stream[i...j] }
        i = j
        next
      end
      if c == ']'
        i += 1
        next
      end
      if c == '/'
        j = i + 1
        while j < len && stream[j] !~ /[\s\[\]<>(){}\/\%]/; j += 1; end
        tokens << { type: :name, value: stream[i...j] }
        i = j; next
      end
      j = i
      while j < len && stream[j] !~ /[\s\[\]<>(){}\/\%]/; j += 1; end
      if j == i
        i += 1
        next
      end
      word = stream[i...j]
      if word == 'BI'
        id_pos = stream.index(/\sID[\s\n\r]/, j)
        if id_pos
          ei_pos = stream.index(/[\s\n\r]EI(?=[\s\n\r\/\[<])/, id_pos + 3)
          if ei_pos
            i = ei_pos + 3
          else
            i = len
          end
        else
          i = j
        end
        next
      end
      if word =~ /\A[+-]?\d*\.?\d+\z/
        tokens << { type: :number, value: word.to_f }
      else
        tokens << { type: :operator, value: word }
      end
      i = j
    end
    tokens
  end

  # The legacy placement walk reduced to its observable sequence.
  def self.sequence(stream, wanted)
    out = []
    operands = []
    tokenize(stream).each do |tok|
      if tok[:type] == :operator
        if wanted.include?(tok[:value])
          out << [tok[:value], operands.select { |t| t[:type] == :number || t[:type] == :name }.map { |t| t[:value] }]
        end
        operands.clear
      else
        operands << tok
      end
    end
    out
  end
end

class ScanOperatorsParityTest < Minitest::Test
  PARSER = BlueCollarSystems::PDFVectorImporter::ContentStreamParser
  WANTED = %w[q Q cm Do].freeze

  def streaming_sequence(stream)
    out = []
    PARSER.scan_operators(stream, WANTED) { |op, operands| out << [op, operands.dup] }
    out
  end

  FIXTURES = [
    "q 1 0 0 1 10 20 cm /Im0 Do Q",
    "q 2 0 0 2 0 0 cm (/Im0 Do) Tj <2f496d3020446f> Tj /Im1 Do Q",
    "/OC /MC0 BDC q .5 0 0 -.5 100 200.25 cm /Fm0 Do Q EMC",
    "q (nested (paren) and \\) escape) Tj /X Do Q % /Im9 Do comment\nq /Y Do Q",
    "q << /Type /Fake /Do 1 >> BDC [1 2] 0 d /Z Do Q >> ]",
    "q BI /W 1 /H 1 /CS /G /BPC 8 ID \x00/Im0 Do EI Q /A Do",
    "q 1 0 0 1 5 5 cm BI /W 1 /H 1 ID \xff\xfe EI 3 0 0 3 1 1 cm /B Do Q",
    "1 2 3 4 5 6 7 8 cm /C Do 1 2 3 cm /D Do",
    "q\r\n1 0 0 1 0 0 cm\r\n/E Do\r\nQ\x00/F Do",
    "q /Gm\xE9 Do Q"
  ].freeze

  def test_streaming_walk_matches_legacy_tokenizer_sequence
    FIXTURES.each do |fixture|
      [fixture, fixture.dup.force_encoding(Encoding::BINARY)].each do |stream|
        expected = LegacyPlacementTokenizer.sequence(stream.dup.force_encoding(Encoding::BINARY), WANTED)
        actual = streaming_sequence(stream)
        assert_equal expected, actual, "parity mismatch for #{fixture.inspect}"
      end
    end
  end

  def test_yields_are_specific_and_named
    assert_equal [['Do', ['/Im0']]], streaming_sequence('1 0 0 1 0 0 cm /Im0 Do').select { |op, _| op == 'Do' }
    assert_equal [['cm', [1.0, 0.0, 0.0, 1.0, 10.0, 20.0]]], streaming_sequence('1 0 0 1 10 20 cm')
    assert_equal 0, PARSER.scan_operators(nil, WANTED) { |_op, _operands| flunk 'no stream' }
    assert_equal 2, PARSER.scan_operators('q Q', WANTED) { |_op, _operands| nil }
  end

  def test_inline_image_is_counted_when_wanted_and_its_bytes_are_skipped
    count = 0
    dos = []
    PARSER.scan_operators("q BI /W 1 /H 1 ID \x00/Im0 Do\x00 EI /Real Do Q", %w[BI Do]) do |op, operands|
      count += 1 if op == 'BI'
      dos << operands.first if op == 'Do'
    end
    assert_equal 1, count
    assert_equal ['/Real'], dos
  end

  def test_operand_window_is_bounded
    stream = (['1'] * 5000).join(' ') + ' 2 0 0 2 7 8 cm /Im0 Do'
    seen = []
    PARSER.scan_operators(stream, WANTED) { |op, operands| seen << [op, operands.length] }
    assert_equal ['cm', PARSER::SCAN_OPERAND_WINDOW], seen[0]
    assert_equal ['Do', 1], seen[1]
  end
end

class LatePlacementFakePDF
  FORM_STREAM = "0 0 m 5 5 l S\n".freeze
  RGB_BYTES = [255, 0, 0, 0, 255, 0].pack('C*')

  attr_writer :stream

  def page_data(_page_num)
    { content_streams: [@stream] }
  end

  def page_resources(_page_num)
    { '/XObject' => { '/Fm0' => '20 0 R', '/Im0' => '21 0 R' } }
  end

  def resolve_object(ref)
    case ref
    when '20 0 R' then { '/Subtype' => '/Form', '/BBox' => [0, 0, 10, 10] }
    when '21 0 R'
      { '/Subtype' => '/Image', '/Width' => '2', '/Height' => '1',
        '/BitsPerComponent' => '8', '/ColorSpace' => '/DeviceRGB' }
    else ref
    end
  end

  def get_stream_data(obj_num)
    obj_num == 20 ? FORM_STREAM : RGB_BYTES
  end

  def get_raw_object(_obj_num)
    bytes = RGB_BYTES
    "21 0 obj\n<< /Length #{bytes.bytesize} >>\nstream\n#{bytes}endstream\nendobj"
  end

  def parse_stream_length(raw)
    raw[/\/Length\s+(\d+)/, 1].to_i
  end

  def extract_stream_filters(_raw, _dict)
    []
  end

  def to_dict(obj)
    obj.is_a?(Hash) ? obj : nil
  end
end

class LatePlacementAfterSixHundredThousandTokensTest < Minitest::Test
  LOGGER = BlueCollarSystems::PDFVectorImporter::Logger
  XOBJ = BlueCollarSystems::PDFVectorImporter::XObjectParser
  IMAGES = BlueCollarSystems::PDFVectorImporter::EmbeddedImageExtractor
  DENSE_PREFIX = ("0 0 m 1 1 l S\n" * 100_000).freeze # 700,000 tokens

  def dense_stream
    DENSE_PREFIX + "q 2 0 0 2 10 20 cm /Fm0 Do Q\nq 1 0 0 1 300 400 cm /Im0 Do Q\n"
  end

  def token_count(stream)
    stream.split(/\s+/).length
  end

  def setup
    LOGGER.reset
    @stream = dense_stream
    assert_operator token_count(@stream), :>, 600_000
  end

  def test_form_xobject_placement_after_the_dense_prefix_is_tracked
    pdf = LatePlacementFakePDF.new
    parser = XOBJ.new(pdf)
    form = XOBJ::FormXObject.new(20, 'Fm0', [0, 0, 10, 10], nil, LatePlacementFakePDF::FORM_STREAM, 0, nil, [])
    parser.instance_variable_set(:@form_xobjects, { 'Fm0' => form })
    parser.count_references([@stream])
    parser.track_placements([@stream])
    assert_equal [[2.0, 0.0, 0.0, 2.0, 10.0, 20.0]], form.instance_xforms
    assert_equal 1, form.usage_count
    expanded = parser.expanded_paths([@stream])
    assert_equal 1, expanded.length
    assert_equal [[10.0, 20.0], [20.0, 30.0]],
                 expanded[0].subpaths[0].segments.map { |s| s.points[-1] }
    refute LOGGER.warnings.any? { |w| w =~ /token limit/ }, LOGGER.warnings.inspect
  end

  def test_image_placement_after_the_dense_prefix_is_extracted
    pdf = LatePlacementFakePDF.new
    pdf.stream = @stream
    extractor = IMAGES.new(pdf, nil)
    assets = extractor.extract_page(1, nil, false)
    assert_equal 1, assets.length, LOGGER.warnings.inspect
    asset = assets[0]
    assert_equal 'Im0', asset.name
    assert_equal 21, asset.obj_num
    assert_equal [1.0, 0.0, 0.0, 1.0, 300.0, 400.0], asset.ctm
    assert_equal [300.0, 400.0, 301.0, 401.0], asset.bbox_pts
    assert_equal 0, extractor.inline_image_count
    refute LOGGER.warnings.any? { |w| w =~ /token limit/ }, LOGGER.warnings.inspect
  end

  def test_image_inside_a_form_after_the_dense_prefix_is_extracted_with_the_form_ctm
    pdf = LatePlacementFakePDF.new
    pdf.stream = DENSE_PREFIX + "q 2 0 0 2 10 20 cm /Fm0 Do Q\n"
    pdf.define_singleton_method(:get_stream_data) do |obj_num|
      obj_num == 20 ? "q 1 0 0 1 1 1 cm /Im0 Do Q\n" : LatePlacementFakePDF::RGB_BYTES
    end
    extractor = IMAGES.new(pdf, nil)
    assets = extractor.extract_page(1, nil, false)
    assert_equal 1, assets.length, LOGGER.warnings.inspect
    assert_equal [2.0, 0.0, 0.0, 2.0, 12.0, 22.0], assets[0].ctm
  end
end
