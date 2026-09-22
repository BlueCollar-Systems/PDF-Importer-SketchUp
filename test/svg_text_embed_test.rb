# test/svg_text_embed_test.rb
# Unit tests for SvgTextRenderer's Ghostscript font-embedding fallback.
# Pure helpers only (no SketchUp / external tools). Ruby 2.2 compatible.

require 'minitest/autorun'
require 'minitest/mock'
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
    assert_includes args, '-dSAFER'
    refute_includes args, '-dNOSAFER'
    assert_includes args, '<</NeverEmbed []>> setdistillerparams'
    assert_operator args.index('-f'), :>, args.index('-c')
    oi = args.index('-o')
    assert_equal 'out.pdf', args[oi + 1]   # output path follows -o
    assert_equal 'in.pdf', args[-1]        # input path is last
  end

  def test_ghostscript_args_keep_spaced_paths_intact
    inp = 'C:/Users/example/Desktop/a b.pdf'
    out = 'C:/Users/example/AppData/Local/Temp/x y.pdf'
    args = R.ghostscript_embed_args('gs', inp, out)
    assert_includes args, inp   # single argv element; no shell splitting
    assert_includes args, out
  end

  C = BlueCollarSystems::PDFVectorImporter::CommandRunner

  def setup
    @previous_font_check_cache = R.instance_variable_get(:@font_check_cache)
    @previous_font_inventory_cache = R.instance_variable_get(:@font_inventory_cache)
    R.instance_variable_set(:@font_check_cache, {})
    R.instance_variable_set(:@font_inventory_cache, {})
  end

  def teardown
    R.instance_variable_set(:@font_check_cache, @previous_font_check_cache)
    R.instance_variable_set(:@font_inventory_cache, @previous_font_inventory_cache)
  end

  def inventory_run(output, ok = true, stderr = '')
    { :ok => ok, :stdout => output, :stderr => stderr }
  end

  def with_inventory_runs(replies)
    calls = []
    runner = lambda do |args, opts|
      calls << [args, opts]
      reply = replies.fetch(calls.length - 1)
      raise reply if reply.is_a?(Exception)
      reply
    end
    R.stub(:find_pdffonts, 'pdffonts') do
      C.stub(:run, runner) { yield calls }
    end
  end

  def test_failed_inventory_then_healthy_inventory_reaches_font_repair
    repairs = []
    embed = lambda do |path, gs|
      repairs << [path, gs]
      'embedded.pdf'
    end
    with_inventory_runs([
      inventory_run('', false), inventory_run(PDFFONTS_WITH_UNEMBEDDED)
    ]) do |calls|
      R.stub(:find_ghostscript, 'gs') do
        R.stub(:embed_fonts_cached, embed) do
          assert_equal 'drawing.pdf', R.ensure_renderable_pdf('drawing.pdf', 'cairo')
          assert_empty repairs
          assert_equal 'embedded.pdf', R.ensure_renderable_pdf('drawing.pdf', 'cairo')
          assert_equal [['drawing.pdf', 'gs']], repairs
          assert R.pdf_needs_embedding?('drawing.pdf', 'cairo')
          assert_equal 2, calls.length
        end
      end
    end
  end

  def test_missing_inventory_helper_is_not_cached_as_no_repair
    helpers = [nil, 'pdffonts']
    R.stub(:find_pdffonts, lambda { |_exe| helpers.shift }) do
      C.stub(:run, inventory_run(PDFFONTS_WITH_UNEMBEDDED)) do
        refute R.pdf_needs_embedding?('drawing.pdf', 'cairo')
        assert R.pdf_needs_embedding?('drawing.pdf', 'cairo')
        assert_empty helpers
      end
    end
  end

  def test_empty_or_malformed_inventory_is_retried
    ['', 'not a font inventory', PDFFONTS_ALL_EMBEDDED + 'truncated font row'].each do |bad|
      R.instance_variable_set(:@font_check_cache, {})
      with_inventory_runs([
        inventory_run(bad), inventory_run(PDFFONTS_WITH_UNEMBEDDED)
      ]) do |calls|
        refute R.pdf_needs_embedding?('drawing.pdf', 'cairo')
        assert R.pdf_needs_embedding?('drawing.pdf', 'cairo')
        assert_equal 2, calls.length
      end
    end
  end

  def test_inventory_exception_is_retried
    with_inventory_runs([
      IOError.new('temporary helper failure'), inventory_run(PDFFONTS_WITH_UNEMBEDDED)
    ]) do |calls|
      refute R.pdf_needs_embedding?('drawing.pdf', 'cairo')
      assert R.pdf_needs_embedding?('drawing.pdf', 'cairo')
      assert_equal 2, calls.length
    end
  end

  def test_successful_all_embedded_inventory_is_cached
    with_inventory_runs([inventory_run(PDFFONTS_ALL_EMBEDDED)]) do |calls|
      2.times { refute R.pdf_needs_embedding?('drawing.pdf', 'cairo') }
      assert_equal 1, calls.length
    end
  end

  def test_complete_empty_font_table_is_cached
    empty_table = PDFFONTS_ALL_EMBEDDED.lines.first(2).join
    with_inventory_runs([inventory_run(empty_table)]) do |calls|
      2.times { refute R.pdf_needs_embedding?('drawing.pdf', 'cairo') }
      assert_equal 1, calls.length
    end
  end

  def test_inventory_diagnostics_do_not_cache_negative_result
    with_inventory_runs([
      inventory_run(PDFFONTS_ALL_EMBEDDED, true, 'font inventory error'),
      inventory_run(PDFFONTS_WITH_UNEMBEDDED)
    ]) do |calls|
      refute R.pdf_needs_embedding?('drawing.pdf', 'cairo')
      assert R.pdf_needs_embedding?('drawing.pdf', 'cairo')
      assert_equal 2, calls.length
    end
  end

  def test_complete_unembedded_inventory_with_diagnostics_is_cached
    with_inventory_runs([
      inventory_run(PDFFONTS_WITH_UNEMBEDDED, true, "No display font for 'Symbol'")
    ]) do |calls|
      2.times { assert R.pdf_needs_embedding?('drawing.pdf', 'cairo') }
      assert_equal 1, calls.length
    end
  end

  def test_truncated_positive_inventory_does_not_enter_cache
    with_inventory_runs([
      inventory_run(PDFFONTS_WITH_UNEMBEDDED + 'truncated font row'),
      inventory_run(PDFFONTS_ALL_EMBEDDED)
    ]) do |calls|
      assert R.pdf_needs_embedding?('drawing.pdf', 'cairo')
      refute R.pdf_needs_embedding?('drawing.pdf', 'cairo')
      assert_equal 2, calls.length
    end
  end

  def test_unused_symbol_startup_warning_requires_complete_inventory
    warning = "Syntax Error: No display font for 'Symbol'\n"
    inventory = PDFFONTS_WITH_UNEMBEDDED.sub('Symbol ', 'Helvetica ')
    with_inventory_runs([inventory_run(inventory, true, warning)]) do |calls|
      R.stub(:find_ghostscript, nil) do
        assert_equal 'drawing.pdf', R.ensure_renderable_pdf('drawing.pdf', 'cairo')
        2.times do
          assert_empty R.source_missing_display_fonts(warning, 'drawing.pdf', 'cairo')
        end
        assert_equal 1, calls.length, 'reuse the completed document inventory'
      end
    end
  end

  def test_symbol_font_in_source_is_not_excused_as_startup_warning
    warning = "Syntax Error: No display font for 'Symbol'\n"
    with_inventory_runs([inventory_run(PDFFONTS_WITH_UNEMBEDDED, true, warning)]) do
      assert_equal ['Symbol'], R.source_missing_display_fonts(warning, 'drawing.pdf', 'cairo')
    end
  end

  def test_incomplete_or_failed_inventory_cannot_prove_unused_symbol
    warning = "Syntax Error: No display font for 'Symbol'\n"
    ['', PDFFONTS_ALL_EMBEDDED + 'truncated font row'].each do |output|
      with_inventory_runs([inventory_run(output)]) do
        assert_equal ['Symbol'], R.source_missing_display_fonts(warning, 'drawing.pdf', 'cairo')
      end
    end
    with_inventory_runs([inventory_run(PDFFONTS_ALL_EMBEDDED, false)]) do
      assert_equal ['Symbol'], R.source_missing_display_fonts(warning, 'drawing.pdf', 'cairo')
    end
  end

  def test_other_diagnostics_and_fonts_remain_unresolved
    warning = "Syntax Error: No display font for 'Symbol'\n"
    mixed = warning + "Syntax Error: damaged font data\n"
    # Mixed render stderr without a completed inventory cannot excuse Symbol.
    assert_equal ['Symbol'], R.source_missing_display_fonts(mixed, 'drawing.pdf', 'cairo')
    assert_equal ['Arial'], R.source_missing_display_fonts("No display font for 'Arial'", 'drawing.pdf', 'cairo')
    # Mixed render stderr may still strip unused Symbol when inventory proves
    # no Symbol row (Helvetica substituted like the unused-symbol case).
    inventory = PDFFONTS_WITH_UNEMBEDDED.sub('Symbol ', 'Helvetica ')
    with_inventory_runs([inventory_run(inventory, true, warning)]) do
      assert_empty R.source_missing_display_fonts(mixed, 'drawing.pdf', 'cairo')
    end
    # Inventory-side non-Symbol diagnostics still leave Symbol unresolved.
    R.instance_variable_set(:@font_check_cache, {})
    R.instance_variable_set(:@font_inventory_cache, {})
    with_inventory_runs([inventory_run(PDFFONTS_ALL_EMBEDDED, true, 'damaged font data')]) do
      assert_equal ['Symbol'], R.source_missing_display_fonts(warning, 'drawing.pdf', 'cairo')
    end
  end
end
