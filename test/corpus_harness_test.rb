#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tempfile'
require_relative 'support/corpus_harness'

class CorpusHarnessTest < Minitest::Test
  def test_size_heavy_pdf_skips_page_count_preflight
    Tempfile.create(['heavy', '.pdf']) do |f|
      f.binmode
      f.truncate((CorpusHarness::HEAVY_PDF_MB + 1).to_i * 1024 * 1024)
      f.flush

      klass = class << CorpusHarness; self; end
      original = CorpusHarness.method(:estimate_page_count)
      klass.define_method(:estimate_page_count) do |_path|
        raise 'estimate_page_count should not run for size-heavy PDFs'
      end

      assert_nil CorpusHarness.page_count_hint_for(f.path)
    ensure
      klass.define_method(:estimate_page_count) { |path| original.call(path) } if klass && original
    end
  end
end
