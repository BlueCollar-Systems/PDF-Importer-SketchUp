#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tempfile'
require_relative 'support/corpus_harness'

class CorpusHarnessFakeParser
  attr_reader :page_count, :released

  def initialize(page_count, parse_error = nil)
    @page_count = page_count
    @parse_error = parse_error
    @released = false
  end

  def parse
    raise @parse_error if @parse_error
    true
  end

  def page_data(_page)
    { content_streams: [], media_box: [0, 0, 612, 792] }
  end

  def page_ocg_map(_page)
    {}
  end

  def release
    @released = true
  end
end

class CorpusHarnessTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter

  def test_stress_pdf_optout_is_not_hard_coded
    assert_empty CorpusHarness::STRESS_PDF_SLUGS
  end

  def test_size_heavy_pdf_skips_page_count_preflight
    Tempfile.create(['heavy', '.pdf']) do |f|
      f.binmode
      f.truncate((CorpusHarness::HEAVY_PDF_MB + 1).to_i * 1024 * 1024)
      f.flush

      klass = nil
      original = nil
      begin
        klass = class << CorpusHarness; self; end
        original = CorpusHarness.method(:estimate_page_count)
        klass.define_method(:estimate_page_count) do |_path|
          raise 'estimate_page_count should not run for size-heavy PDFs'
        end

        assert_nil CorpusHarness.page_count_hint_for(f.path)
      ensure
        if klass && original
          klass.define_method(:estimate_page_count) { |path| original.call(path) }
        end
      end
    end
  end

  def analyze_with_salvage_seams(source, prepared, parser, prepare = nil)
    cleanup_paths = []
    prepare ||= proc { |_path| [prepared, 'salvaged via test seam'] }
    cleanup = proc { |path| cleanup_paths << path }
    parser_factory = proc { |_path| parser }

    result = nil
    IMP::PdfSalvage.stub(:prepare_if_needed, prepare) do
      IMP::PdfSalvage.stub(:cleanup, cleanup) do
        IMP::PDFParser.stub(:new, parser_factory) do
          CorpusHarness.stub(:page_count_hint_for, nil) do
            CorpusHarness.stub(:extract_page_text, [[], :internal]) do
              result = CorpusHarness.analyze_pdf(
                path: source, corpus_key: 'test/salvage.pdf'
              )
            end
          end
        end
      end
    end
    [result, cleanup_paths]
  end

  def test_analyze_pdf_cleans_prepared_path_after_success
    Tempfile.create(['corpus-harness-success', '.pdf']) do |source|
      Tempfile.create(['corpus-harness-prepared', '.pdf']) do |prepared|
        parser = CorpusHarnessFakeParser.new(1)
        result, cleanup = analyze_with_salvage_seams(
          source.path, prepared.path, parser
        )

        assert_equal 'OK', result[:status]
        assert_equal 1, result[:pages]
        assert_equal [prepared.path], cleanup
        assert parser.released
      end
    end
  end

  def test_analyze_pdf_fails_closed_and_cleans_when_salvaged_parser_has_zero_pages
    Tempfile.create(['corpus-harness-zero', '.pdf']) do |source|
      Tempfile.create(['corpus-harness-prepared-zero', '.pdf']) do |prepared|
        parser = CorpusHarnessFakeParser.new(0)
        result, cleanup = analyze_with_salvage_seams(
          source.path, prepared.path, parser
        )

        assert_equal 'FAIL', result[:status]
        assert_match(/zero pages after production salvage/i, result[:error])
        assert_equal [prepared.path], cleanup
        assert parser.released
      end
    end
  end

  def test_analyze_pdf_reports_salvage_error_and_runs_safe_cleanup
    Tempfile.create(['corpus-harness-salvage-error', '.pdf']) do |source|
      parser = CorpusHarnessFakeParser.new(1)
      prepare = proc do |_path|
        raise IMP::PdfSalvage::SalvageError, 'fixture cannot be repaired'
      end
      result, cleanup = analyze_with_salvage_seams(
        source.path, source.path, parser, prepare
      )

      assert_equal 'FAIL', result[:status]
      assert_match(/fixture cannot be repaired/, result[:error])
      assert_equal [source.path], cleanup
      refute parser.released
    end
  end

  def test_analyze_pdf_cleans_prepared_path_after_timeout
    Tempfile.create(['corpus-harness-timeout', '.pdf']) do |source|
      Tempfile.create(['corpus-harness-prepared-timeout', '.pdf']) do |prepared|
        parser = CorpusHarnessFakeParser.new(
          1, Timeout::Error.new('forced timeout')
        )
        result, cleanup = analyze_with_salvage_seams(
          source.path, prepared.path, parser
        )

        assert_equal 'TIMEOUT', result[:status]
        assert_equal [prepared.path], cleanup
        assert parser.released
      end
    end
  end
end
