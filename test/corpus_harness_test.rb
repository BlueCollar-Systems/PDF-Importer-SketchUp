#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tempfile'
require_relative 'support/corpus_harness'

class CorpusHarnessTest < Minitest::Test
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
end
