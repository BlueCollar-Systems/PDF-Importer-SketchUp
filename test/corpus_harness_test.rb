#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tempfile'
require_relative 'support/corpus_harness'

class CorpusHarnessTest < Minitest::Test
  class ZeroPageParser
    attr_reader :page_count

    def initialize
      @page_count = 0
    end

    def parse
      true
    end

    def page_data(_page_number)
      nil
    end

    def release
      nil
    end
  end

  def test_headless_two_argument_text_mirrors_host_zero_leader_vector
    CorpusHarness.install_headless_stubs!
    entities = CorpusDummyEntities.new
    point = Geom::Point3d.new(1, 2, 3)

    text = entities.add_text('synthetic', point)
    vector = BlueCollarSystems::PDFVectorImporter::RepresentationFidelity
      .numeric_point(text.vector)

    assert_equal [0.0, 0.0, 0.0], vector
  end

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

  def test_zero_page_parser_result_is_a_harness_failure
    parser_class = BlueCollarSystems::PDFVectorImporter::PDFParser
    parser_factory = lambda { |_path| ZeroPageParser.new }

    Tempfile.create(['zero-page', '.pdf']) do |file|
      parser_class.stub(:new, parser_factory) do
        CorpusHarness.stub(:geometry_builder, Object.new) do
          result = CorpusHarness.analyze_pdf(
            :corpus_key => 'synthetic-zero-page', :path => file.path
          )

          assert_equal 0, result[:pages]
          assert_equal 'FAIL', result[:status]
          assert_equal 'PDF parser returned zero pages', result[:error]
        end
      end
    end
  end
end
