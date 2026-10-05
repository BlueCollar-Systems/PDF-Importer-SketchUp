require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/geometry_builder'

class SeparationFillFidelityTest < Minitest::Test
  Parser = BlueCollarSystems::PDFVectorImporter::ContentStreamParser
  PDF = BlueCollarSystems::PDFVectorImporter::PDFParser
  Builder = BlueCollarSystems::PDFVectorImporter::GeometryBuilder

  def test_device_gray_colors_are_unchanged
    stroke = Parser.new(["0 G\n0 0 m\n10 0 l\nS\n"], nil).parse.fetch(0)
    fill = Parser.new(["1 g\n0 0 10 10 re\nf\n"], nil).parse.fetch(0)
    assert_equal [0.0, 0.0, 0.0], stroke.stroke_color
    assert_equal [1.0, 1.0, 1.0], fill.fill_color
    assert fill.subpaths.fetch(0).closed
  end

  def test_fill_operator_closes_an_open_contour_and_fill_and_stroke_does_not
    filled = Parser.new(["0 0 m\n10 0 l\n5 8 l\nf\n"], nil).parse.fetch(0)
    sub = filled.subpaths.fetch(0)
    assert filled.fill
    refute filled.stroke
    assert sub.closed
    assert sub.fill_closed
    assert_equal [0.0, 0.0], sub.segments.last.points.last

    both = Parser.new(["0 0 m\n10 0 l\n5 8 l\nB\n"], nil).parse.fetch(0)
    open = both.subpaths.fetch(0)
    assert both.fill
    assert both.stroke
    refute open.closed
    assert open.fill_closed
    assert_equal 3, open.segments.length

    builder = Builder.allocate
    assert builder.send(:subpath_filled?, sub)
    assert builder.send(:subpath_filled?, open)
  end

  def test_unresolved_separation_tint_keeps_the_numeric_fallback
    path = Parser.new(["/Cs8 cs\n1 scn\n0 0 m\n10 0 l\n10 10 l\n0 10 l\nf\n"], nil).parse.fetch(0)
    assert_equal [1.0, 1.0, 1.0], path.fill_color
  end

  def test_separation_black_tint_is_black_ink
    spaces = {
      '/Cs8' => ['/Separation', '/Black', '/DeviceCMYK', {
        '/FunctionType' => '2',
        '/C0' => %w[0 0 0 0],
        '/C1' => %w[0 0 0 1],
        '/N' => '1'
      }]
    }
    stream = "/Cs8 CS\n1 SCN\n0 0 m\n20 0 l\nS\n/Cs8 cs\n1 scn\n0 0 m\n10 0 l\n10 10 l\n0 10 l\nf\n"
    paths = Parser.new([stream], nil, {}, {}, spaces).parse
    assert_equal [0.0, 0.0, 0.0], paths[0].stroke_color
    assert_equal [0.0, 0.0, 0.0], paths[1].fill_color
  end

  def test_page_separation_survives_a_bracket_inside_a_string
    with_pdf(separation_pdf('(range])')) do |parser|
      spaces = parser.page_color_spaces(1)
      entry = spaces['/Cs8']
      assert_kind_of Array, entry
      assert_equal '/Separation', entry[0]
      streams = parser.page_data(1)[:content_streams]
      path = Parser.new(streams, parser, {}, {}, spaces).parse.fetch(0)
      assert_equal [0.0, 0.0, 0.0], path.fill_color
      assert path.subpaths.fetch(0).closed
    end
  end

  def separation_pdf(note)
    function = "<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [0 0 0 1] /N 1 /Comment (#{note}) >>"
    stream = "/Cs8 cs\n1 scn\n0 0 m\n10 0 l\n10 10 l\n0 10 l\nf\n"
    resources = "<< /ColorSpace << /Cs8 [/Separation /Black /DeviceCMYK #{function}] >> >>"
    objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources #{resources} /Contents 4 0 R >>",
      "<< /Length #{stream.bytesize} >>\nstream\n#{stream}endstream"
    ]
    pdf = "%PDF-1.4\n".dup
    offsets = [0]
    objects.each_with_index do |body, index|
      offsets << pdf.bytesize
      pdf << (index + 1).to_s + " 0 obj\n" + body + "\nendobj\n"
    end
    xref = pdf.bytesize
    pdf << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
    offsets.drop(1).each { |offset| pdf << format('%010d 00000 n ', offset) + "\n" }
    pdf << "trailer\n<< /Size #{objects.length + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    pdf
  end

  def with_pdf(bytes)
    dir = Dir.mktmpdir('separation-fill-')
    path = File.join(dir, 'sheet.pdf')
    File.binwrite(path, bytes)
    parser = PDF.new(path)
    parser.parse
    yield parser
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end
end
