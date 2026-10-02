require 'minitest/autorun'
require 'timeout'
require 'tmpdir'
require 'zlib'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'

# The object tokenizer runs on SketchUp's UI thread with no timeout, so it has
# to finish on every input. It used to count "[" and "]" inside string
# literals and to stand still on a delimiter no branch consumed; a document ID
# written as a literal string holding "]" froze the import.
# Every fixture is synthetic (job D042, marks EX100).
class PdfTokenizerTerminationTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  BIN = Encoding::BINARY
  LIMIT = 10

  # A helper that stops consuming input: the tokenizer must raise, not spin.
  class StuckStringParser < IMP::PDFParser
    private

    def literal_string_end(_text, start)
      start
    end
  end

  def parser
    @parser ||= IMP::PDFParser.new('d042-not-read.pdf')
  end

  def bounded(seconds = LIMIT)
    Timeout.timeout(seconds) { yield }
  rescue Timeout::Error
    flunk "the tokenizer did not finish within #{seconds} s"
  end

  def tokens(text, subject = parser)
    bounded { subject.send(:tokenize_pdf, text) }
  end

  def dict(text)
    bounded { parser.send(:parse_dict_string, text) }
  end

  def array(text)
    bounded { parser.send(:parse_array_string, text) }
  end

  # -------------------------------------------------------------------
  # Brackets inside literal strings are data
  # -------------------------------------------------------------------
  def test_closing_bracket_inside_a_string_does_not_end_the_array
    parsed = dict('<< /ID [(a]b)(c)] /Size 7 >>')
    assert_equal ['(a]b)', '(c)'], parsed['/ID']
    assert_equal '7', parsed['/Size']
    assert_equal ['(a]b)', '(c)'], array('[(a]b)(c)]')
    assert_equal ['/ID', '[(a]b)(c)]', '/Size', '7'], tokens('/ID [(a]b)(c)] /Size 7')
  end

  def test_opening_bracket_inside_a_string_does_not_swallow_what_follows
    parsed = dict('<< /Marks [(a[b)] /Size 7 >>')
    assert_equal ['(a[b)'], parsed['/Marks']
    assert_equal '7', parsed['/Size']
    assert_equal ['(a[b)'], array('[(a[b)]')
  end

  def test_escaped_bracket_and_hex_string
    assert_equal ['(\])', '<5D>'], array('[(\]) <5D>]')
    parsed = dict('<< /K [(\]) <5D>] /Next /EX100 >>')
    assert_equal ['(\])', '<5D>'], parsed['/K']
    assert_equal '/EX100', parsed['/Next']
  end

  def test_escaped_backslash_before_a_bracket_or_the_closing_parenthesis
    # "(\\])" is a backslash and a bracket; "(a\\)" ends after its backslash.
    assert_equal ['(\\\\])', '<5D>'], array('[(\\\\]) <5D>]')
    assert_equal ['(a\\\\)', '(b])'], array('[(a\\\\)(b])]')
    parsed = dict('<< /K [(a\\\\)(b])] /Size 7 >>')
    assert_equal ['(a\\\\)', '(b])'], parsed['/K']
    assert_equal '7', parsed['/Size']
    assert_equal ['(a\\\\)', '/N'], tokens('(a\\\\) /N')
  end

  def test_escaped_parentheses_do_not_open_or_close_a_string
    assert_equal ['(a\)]b)', '/N'], array('[(a\)]b) /N]')
    assert_equal ['(a\(]b)', '/N'], array('[(a\(]b) /N]')
    assert_equal ['(a\)b)', '/N'], tokens('(a\)b) /N')
  end

  def test_nested_parentheses_inside_an_array_string
    assert_equal ['(a(]b)c)', '(d)'], array('[(a(]b)c)(d)]')
    assert_equal ['(a(b)c)'], tokens('(a(b)c)')
  end

  def test_nested_arrays_with_strings
    assert_equal [['(a])', ['(b[)']], '(c)'], array('[[(a]) [(b[)]] (c)]')
    parsed = dict('<< /Kids [[(a])] [[(b[) 4 0 R]]] /Count 2 >>')
    assert_equal [['(a])'], [['(b[)', '4 0 R']]], parsed['/Kids']
    assert_equal '2', parsed['/Count']
  end

  def test_dictionary_inside_an_array_keeps_its_bracketed_strings
    parsed = array('[<< /K [(x]y)] /H <AB> >> 3]')
    assert_equal [{ '/K' => ['(x]y)'], '/H' => '<AB>' }, '3'], parsed
  end

  def test_comment_inside_an_array_is_skipped
    assert_equal %w[1 2], array("[1 % ] not the end\n 2]")
    parsed = dict("<< /A [1 % ] not the end\n 2] /B 3 >>")
    assert_equal %w[1 2], parsed['/A']
    assert_equal '3', parsed['/B']
  end

  def test_indexed_lookup_table_holding_brackets_stays_whole
    table = "(\000\000\000]\377\000[)".dup.force_encoding(BIN)
    text = '[/Indexed /DeviceRGB 1 '.dup.force_encoding(BIN) << table << ']'
    assert_equal ['/Indexed', '/DeviceRGB', '1', table], array(text)
  end

  def test_well_formed_values_are_unchanged
    assert_equal ['1', '2', %w[3 4], '/N', '5 0 R'], array('[1 2 [3 4] /N 5 0 R]')
    assert_equal ['0', '0', '612', '792'], array('[0 0 612 792]')
    assert_equal [], array('[]')
    parsed = dict('<< /Type /Page /MediaBox [0 0 612 792] /Parent 2 0 R /T (EX100) /H <feff> /D << /W 0 >> >>')
    assert_equal '/Page', parsed['/Type']
    assert_equal %w[0 0 612 792], parsed['/MediaBox']
    assert_equal '2 0 R', parsed['/Parent']
    assert_equal '(EX100)', parsed['/T']
    assert_equal '<feff>', parsed['/H']
    assert_equal({ '/W' => '0' }, parsed['/D'])
    assert_equal ['12', '0', 'obj', '<< /A 1 >>', 'endobj'], tokens('12 0 obj << /A 1 >> endobj')
  end

  # -------------------------------------------------------------------
  # Delimiters no branch consumes
  # -------------------------------------------------------------------
  def test_stray_delimiters_at_top_level_are_dropped
    [')', '}', '{', '>'].each do |stray|
      assert_equal ['/A', '1', '/B', '2'], tokens("/A 1 #{stray} /B 2"), "stray #{stray.inspect} in the middle"
      assert_equal ['/A', '1'], tokens("#{stray}/A 1"), "stray #{stray.inspect} first"
      assert_equal ['/A', '1'], tokens("/A 1#{stray}"), "stray #{stray.inspect} last"
      assert_equal [], tokens(stray), "stray #{stray.inspect} alone"
    end
    assert_equal [], tokens(')}>{)}>{')
    assert_equal({ '/A' => '1', '/B' => '2' }, dict('<< /A 1 ) } > { /B 2 >>'))
  end

  def test_text_left_behind_a_misread_array_terminates
    # What the old scanner left behind after cutting "[(a]b)(c)]" at the first
    # "]": text with a stray ")". It is the exact shape that never returned.
    assert_equal ['b', '(c)'], tokens('b)(c)]')
    assert_equal ['.', '(EX100].)'], tokens('.)(EX100].)]')
  end

  def test_nested_dictionary_ending_in_a_hex_string_terminates
    parsed = dict('<</Style<</Panose<0102>>>/Next 1>>')
    assert_equal '1', parsed['/Next']
    assert_kind_of Hash, parsed['/Style']
    assert parsed['/Style']['/Panose'].start_with?('<0102')
    assert_equal '12', tokens('12 0 obj<</Contents<feff0044>>>endobj').first
  end

  def test_unterminated_input_terminates
    assert_equal [], array('[1 2')
    assert_equal [], array('[(a]')
    assert_equal ['[(a]'], tokens('[(a]')
    assert_equal ['(abc'], tokens('(abc')
    assert_equal ['(abc\\'], tokens('(abc\\')
    assert_equal ['<AB'], tokens('<AB')
    assert_kind_of Array, tokens('<< /A')
    assert_equal ['[1 [2'], tokens('[1 [2')
    assert_equal({}, dict('<<'))
    assert_equal [], tokens('% comment without a line end')
    assert_equal [], tokens('')
  end

  # -------------------------------------------------------------------
  # Hard guard and time bounds
  # -------------------------------------------------------------------
  def test_a_branch_that_consumes_nothing_raises_instead_of_spinning
    stuck = StuckStringParser.new('d042-not-read.pdf')
    error = assert_raises(RuntimeError) { tokens('/T (EX100) /N 1', stuck) }
    assert_match(/no progress at byte 3/, error.message)
  end

  def test_every_delimiter_mix_terminates
    alphabet = ['[', ']', '(', ')', '<', '>', '{', '}', '/', '%', '\\', ' ', "\n", 'a', '1', '<<', '>>', '(', '[']
    random = Random.new(42)
    cases = Array.new(3000) do
      Array.new(1 + random.rand(40)) { alphabet[random.rand(alphabet.length)] }.join
    end
    bounded(120) do
      cases.each do |text|
        assert_kind_of Array, parser.send(:tokenize_pdf, text), text.inspect
        assert_kind_of Array, parser.send(:parse_array_string, text), text.inspect
        assert_kind_of Hash, parser.send(:parse_dict_string, text), text.inspect
        refute_nil parser.send(:parse_object_value, text), text.inspect
      end
    end
  end

  def test_long_runs_finish_in_bounded_time
    bounded(60) do
      assert_equal [], parser.send(:tokenize_pdf, ') ' * 20_000)
      assert_equal 5000, parser.send(:parse_array_string, '[' + '(a]b)' * 5000 + ']').length
      assert_equal 5000, parser.send(:tokenize_pdf, '(a]b) ' * 5000).length
    end
  end

  # -------------------------------------------------------------------
  # Whole documents: the ID array sits in front of the entries the parser
  # needs, as a PDF writer puts it there.
  # -------------------------------------------------------------------
  PAGE_OBJECTS = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>',
    "<< /Length 14 >>\nstream\n0 0 m 10 0 l S\nendstream"
  ].freeze
  BRACKET_ID = '[(D042].)(EX100[.)]'.freeze

  def document_body
    data = "%PDF-1.5\n".dup.force_encoding(BIN)
    offsets = []
    PAGE_OBJECTS.each_with_index do |object, index|
      offsets << data.bytesize
      data << "#{index + 1} 0 obj\n" << object << "\nendobj\n"
    end
    [data, offsets]
  end

  def write_table_document(path)
    data, offsets = document_body
    xref = data.bytesize
    data << "xref\n0 #{offsets.length + 1}\n0000000000 65535 f \n"
    offsets.each { |offset| data << format('%010d 00000 n ', offset) << "\n" }
    data << "trailer\n<< /Size #{offsets.length + 1} /ID #{BRACKET_ID} /Root 1 0 R >>\n"
    data << "startxref\n#{xref}\n%%EOF\n"
    File.binwrite(path, data)
    path
  end

  def write_stream_document(path)
    data, offsets = document_body
    xref = data.bytesize
    offsets << xref
    rows = [[0, 0, 65_535]] + offsets.map { |offset| [1, offset, 0] }
    table = rows.map do |type, offset, generation|
      [type, (offset >> 16) & 255, (offset >> 8) & 255, offset & 255, (generation >> 8) & 255, generation & 255].pack('C*')
    end.join
    packed = Zlib::Deflate.deflate(table)
    data << "#{offsets.length} 0 obj\n<<\n/Type /XRef\n/Size #{rows.length}\n/Root 1 0 R\n"
    data << "/ID #{BRACKET_ID}\n/Index [0 #{rows.length} ]\n/W [1 3 2]\n"
    data << "/Filter /FlateDecode/Length #{packed.bytesize}\n>>\nstream\n"
    data << packed << "\nendstream\nendobj\nstartxref\n#{xref}\n%%EOF\n"
    File.binwrite(path, data)
    path
  end

  def assert_document_parses(kind)
    Dir.mktmpdir('pdf_tokenizer_termination') do |dir|
      path = send("write_#{kind}_document", File.join(dir, 'd042.pdf'))
      subject = IMP::PDFParser.new(path)
      bounded { subject.parse }
      assert_equal 1, subject.page_count
      trailer = subject.instance_variable_get(:@trailer)
      assert_equal ['(D042].)', '(EX100[.)'], trailer['/ID']
      assert_equal '1 0 R', trailer['/Root']
      page = bounded { subject.page_data(1) }
      assert_equal [0.0, 0.0, 612.0, 792.0], page[:media_box].map(&:to_f)
      assert_equal ['0 0 m 10 0 l S'], page[:content_streams].map(&:strip)
      subject.release
    end
  end

  def test_trailer_id_with_brackets_in_literal_strings_parses
    assert_document_parses(:table)
  end

  def test_cross_reference_stream_id_with_brackets_in_literal_strings_parses
    assert_document_parses(:stream)
  end
end
