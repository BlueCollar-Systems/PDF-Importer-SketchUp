# test/svg_text_embed_test.rb
# Unit tests for SvgTextRenderer's Ghostscript font-embedding fallback.
# Pure helpers only (no SketchUp / external tools). Ruby 2.2 compatible.

require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/svg_text_renderer'

class SvgTextEmbedTest < Minitest::Test
  R = BlueCollarSystems::PDFVectorImporter::SvgTextRenderer

  PDFFONTS_WITH_UNEMBEDDED = [
    'name                 type        encoding   emb sub uni object ID',
    '-------------------- ----------- ---------- --- --- --- ---------',
    'ABCDEE+Calibri       TrueType    WinAnsi    yes yes yes      8  0',
    'Symbol               Type 1      Builtin    no  no  no      12  0'
  ].join("\n") + "\n"

  PDFFONTS_ALL_EMBEDDED = [
    'name                 type            encoding     emb sub uni object ID',
    '-------------------- --------------- ------------ --- --- --- ---------',
    'ABCDEE+Calibri       TrueType        WinAnsi      yes yes yes      8  0',
    'WXYZAB+Arial         CID TrueType    Identity-H   yes yes yes     21  0'
  ].join("\n") + "\n"

  def test_detects_unembedded_font
    assert R.pdffonts_reports_unembedded?(PDFFONTS_WITH_UNEMBEDDED)
  end

  def test_all_embedded_returns_false
    refute R.pdffonts_reports_unembedded?(PDFFONTS_ALL_EMBEDDED)
  end

  def test_empty_or_nil_returns_false
    refute R.pdffonts_reports_unembedded?('')
    refute R.pdffonts_reports_unembedded?(nil)
  end

  def test_ghostscript_args_shape
    args = R.ghostscript_embed_args('gs', 'in.pdf', 'out.pdf')
    assert_equal 'gs', args[0]
    assert_includes args, '-sDEVICE=pdfwrite'
    assert_includes args, '-dEmbedAllFonts=true'
    assert_includes args, '-dNOSAFER'
    oi = args.index('-o')
    assert_equal 'out.pdf', args[oi + 1]   # output path follows -o
    assert_equal 'in.pdf', args[-1]        # input path is last
  end

  def test_ghostscript_args_keep_spaced_paths_intact
    inp = 'C:/Users/Rowdy Payton/Desktop/a b.pdf'
    out = 'C:/Users/Rowdy Payton/AppData/Local/Temp/x y.pdf'
    args = R.ghostscript_embed_args('gs', inp, out)
    assert_includes args, inp   # single argv element; no shell splitting
    assert_includes args, out
  end
end
