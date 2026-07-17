#!/usr/bin/env ruby

require 'minitest/autorun'
require 'tmpdir'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext') unless defined?(SRC_ROOT)
$LOAD_PATH.unshift(SRC_ROOT) unless $LOAD_PATH.include?(SRC_ROOT)

require 'bc_pdf_vector_importer/cli'

class CLITextIdentityGateTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  CLI = IMP::CLI

  Carrier = Struct.new(:source_span_id)

  class ParserDouble
    attr_reader :page_count

    def initialize
      @page_count = 2
    end

    def parse; true; end
    def page_data(_page); { content_streams: [], media_box: [0, 0, 612, 792] }; end
    def page_ocg_map(_page); {}; end
    def release; true; end
  end

  class OCGDouble
    def parse; true; end
    def layer_list; []; end
  end

  class MissingPageParserDouble < ParserDouble
    def page_data(page)
      return nil if page == 2
      super
    end
  end

  class PaintingTextParserDouble < ParserDouble
    def page_data(_page)
      {
        content_streams: ['BT /F1 12 Tf (MISSING TEXT) Tj ET'],
        media_box: [0, 0, 612, 792]
      }
    end
  end

  def test_malformed_later_page_identity_stops_before_artifact_producers
    parser = ParserDouble.new
    image_constructor_calls = 0
    original_pdf_new = IMP::PDFParser.method(:new)
    original_ocg_new = IMP::OCGParser.method(:new)
    original_image_new = IMP::EmbeddedImageExtractor.method(:new)
    original_extract_text = CLI.method(:extract_text)

    IMP::PDFParser.define_singleton_method(:new) { |*| parser }
    IMP::OCGParser.define_singleton_method(:new) { |*| OCGDouble.new }
    IMP::EmbeddedImageExtractor.define_singleton_method(:new) do |*|
      image_constructor_calls += 1
      raise 'artifact producer must not start before identity certification'
    end
    CLI.define_singleton_method(:extract_text) do |_parser, _path, page, _streams, _ocg, _opts|
      page == 1 ? [[Carrier.new(nil)], :external] : [[Object.new], :external]
    end

    Dir.mktmpdir('cli_identity_gate_') do |tmp|
      opts = {
        pages: :all, embedded_image_dir: File.join(tmp, 'embedded_images'),
        extract_embedded_images: true, import_text: true, scale: 1.0,
        bezier_segments: 8, text_mode: 'Labels'
      }
      assert_raises(IMP::TextSourceIdentity::IdentityError) do
        CLI.extract_pdf('identity-gate.pdf', opts, {})
      end
      assert_equal 0, image_constructor_calls
      assert_equal [], Dir.glob(File.join(tmp, '**', '*')),
                   'identity refusal must leave no downstream CLI artifacts'
    end
  ensure
    IMP::PDFParser.define_singleton_method(:new, original_pdf_new) if original_pdf_new
    IMP::OCGParser.define_singleton_method(:new, original_ocg_new) if original_ocg_new
    IMP::EmbeddedImageExtractor.define_singleton_method(:new, original_image_new) if original_image_new
    CLI.define_singleton_method(:extract_text, original_extract_text) if original_extract_text
  end

  def test_selected_page_missing_parser_data_fails_instead_of_being_omitted
    parser = MissingPageParserDouble.new
    error = assert_raises(RuntimeError) do
      CLI.certify_page_text_sources(
        parser, 'missing-page.pdf', [1, 2], { import_text: false }
      )
    end
    assert_match(/Page 2.*no page data/i, error.message)
  end

  def test_painting_text_with_zero_extracted_spans_fails_source_certification
    original_extract_text = CLI.method(:extract_text)
    CLI.define_singleton_method(:extract_text) do |*_args|
      [[], :internal]
    end

    error = assert_raises(IMP::RepresentationFidelity::ContractError) do
      CLI.certify_page_text_sources(
        PaintingTextParserDouble.new,
        'lost-text.pdf',
        [1],
        { import_text: true, text_mode: '3D Text' }
      )
    end
    assert_match(/Page 1/, error.message)
    assert_match(/3D Text/, error.message)
    assert_match(/text-show operation/i, error.message)
  ensure
    CLI.define_singleton_method(:extract_text, original_extract_text) if original_extract_text
  end

  def test_preflight_uses_resolved_helpers_instead_of_obsolete_bin_layout
    originals = {}
    helpers = {
      find_pdftocairo: 'C:/verified/Library/bin/pdftocairo.exe',
      find_pdftotext: 'C:/verified/Library/bin/pdftotext.exe',
      find_pdffonts: 'C:/verified/Library/bin/pdffonts.exe'
    }
    helpers.each do |method_name, path|
      originals[method_name] = IMP::DependencyResolver.method(method_name)
      IMP::DependencyResolver.define_singleton_method(method_name) { |*| path }
    end

    Dir.mktmpdir('cli_preflight_') do |tmp|
      pdf = File.join(tmp, 'fixture.pdf')
      File.open(pdf, 'wb') { |file| file.write("%PDF-1.4\n%%EOF\n") }
      report = CLI.run_preflight(pdf)
      helper_checks = report['checks'].select do |check|
        check['id'].to_s.start_with?('poppler_')
      end
      assert_equal 3, helper_checks.length
      assert helper_checks.all? { |check| check['status'] == 'pass' }
      assert(
        helper_checks.all? do |check|
          check['message'].include?('C:/verified/Library/bin/')
        end
      )
    end
  ensure
    originals.each do |method_name, original|
      IMP::DependencyResolver.define_singleton_method(method_name, original)
    end if originals
  end
end
