#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tempfile'
require_relative 'support/corpus_harness'

class CorpusHarnessTest < Minitest::Test
  class ZeroPageParser
    attr_reader :page_count, :release_count

    def initialize(forbidden_calls)
      @page_count = 0
      @release_count = 0
      @forbidden_calls = forbidden_calls
    end

    def parse
      true
    end

    def page_data(_page_number)
      @forbidden_calls[:page_data] += 1
      raise 'zero-page analysis must not request page data'
    end

    def release
      @release_count += 1
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
        # Module#define_method is PRIVATE on Ruby 2.2 (public only from 2.5), and
        # SketchUp 2017 ships Ruby 2.2 -- so a bare klass.define_method raises
        # NoMethodError on the runtime we actually target while passing on any
        # modern Ruby. Route through send so the stub works on the floor.
        klass.send(:define_method, :estimate_page_count) do |_path|
          raise 'estimate_page_count should not run for size-heavy PDFs'
        end

        assert_nil CorpusHarness.page_count_hint_for(f.path)
      ensure
        if klass && original
          klass.send(:define_method, :estimate_page_count) { |path| original.call(path) }
        end
      end
    end
  end

  def test_zero_page_parser_result_is_a_harness_failure
    parser_class = BlueCollarSystems::PDFVectorImporter::PDFParser
    forbidden_calls = {
      :page_data => 0,
      :extract_page_text => 0,
      :helper_probe => 0
    }
    parsers = []
    parser_factory = lambda do |_path|
      parser = ZeroPageParser.new(forbidden_calls)
      parsers << parser
      parser
    end
    extract_tripwire = lambda do |*_args|
      forbidden_calls[:extract_page_text] += 1
      raise 'zero-page analysis must not extract text'
    end
    helper_tripwire = lambda do
      forbidden_calls[:helper_probe] += 1
      raise 'zero-page analysis must not probe external helpers'
    end

    Tempfile.create(['zero-page', '.pdf']) do |file|
      parser_class.stub(:new, parser_factory) do
        CorpusHarness.stub(:geometry_builder, Object.new) do
          CorpusHarness.stub(:extract_page_text, extract_tripwire) do
            CorpusHarness.stub(:pdftotext_available?, helper_tripwire) do
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

    refute_empty parsers
    assert_equal 1, parsers.last.release_count,
                 'the analysis parser must be released exactly once'
    assert parsers.all? { |parser| parser.release_count == 1 },
           'page-count preflight and analysis parsers must both be released'
    assert_equal 0, forbidden_calls[:page_data]
    assert_equal 0, forbidden_calls[:extract_page_text]
    assert_equal 0, forbidden_calls[:helper_probe]
  end
end
