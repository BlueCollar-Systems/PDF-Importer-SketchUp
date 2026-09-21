require 'minitest/autorun'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/main'

class OriginalAnnotationPipelineTest < Minitest::Test
  Importer = BlueCollarSystems::PDFVectorImporter
  Builder = Struct.new(:page_group)

  class Parser
    attr_reader :parse_count, :release_count
    attr_accessor :parse_error
    def initialize; @parse_count = @release_count = 0; end
    def parse
      @parse_count += 1
      raise @parse_error if @parse_error
    end
    def release; @release_count += 1; end
    def page_annotation_entries(_page); ['8 0 R']; end
    def page_data(_page); { :media_box=>[0,0,200,100] }; end
    def pages; ['7 0 R']; end
    def find_inherited(_dictionary,_key); 0; end
  end

  class Provider
    attr_reader :report, :cleanup_count, :verify_count, :geometry_records
    attr_accessor :prepare_error
    def initialize
      @report = { :composite_status=>'SOURCE_UNSUPPORTED_GEOMETRY_RETAINED',
        :composite_reason=>'synthetic source composite scope unavailable' }
      @geometry_records = [{ :source_pdf_sha256=>'fictional-source', :annotation_ref=>'8 0 R' }]
      @cleanup_count = @verify_count = 0
    end
    def prepare!
      if @prepare_error
        @report[:composite_status] = 'RENDERER_FAILED'
        @report[:composite_reason] = @prepare_error.message
        raise @prepare_error
      end
    end
    def verify_original_file!; @verify_count += 1; end
    def cleanup; @cleanup_count += 1; end
  end

  def setup
    @parser, @provider = Parser.new, Provider.new
    @stats, @opts, @delivered = {}, { :scale=>1.0 }, []
    @page_group, @model, @layer = Object.new, Object.new, Object.new
  end

  def with_pipeline
    Importer.stub(:cached_source_pdf_sha256!,'fictional-source') do
      Importer.stub(:safe_find_pdftocairo,'fictional-helper') do
        Importer::PDFParser.stub(:new,@parser) do
          Importer::AnnotationCompositeProvider::Page.stub(:new,@provider) do
            Importer::SourceRoundAnnotationInk.stub(:dictionary,{}) do
              Importer::AnnotationMicrostrokeDisplay.stub(:apply!,lambda do |page,provider,_stats,context|
                @delivered << [page,provider.geometry_records,context]
              end) { yield }
            end
          end
        end
      end
    end
  end

  def apply(prepared = 'prepared.pdf')
    Importer.apply_original_annotation_microstrokes!(Builder.new(@page_group),@model,@stats,@opts,
      'original.pdf',prepared,@parser,1,2.0,@layer)
  end

  def test_owned_original_parser_is_reused_until_release_and_unsupported_composite_keeps_geometry
    with_pipeline { 2.times { apply } }
    assert_equal 1,@parser.parse_count
    assert_equal 0,@parser.release_count
    assert_equal 2,@provider.cleanup_count
    assert_equal 2,@provider.verify_count
    assert_equal 2,@delivered.length
    assert_same @provider.geometry_records,@delivered.first[1]
    assert_same @page_group,@delivered.first[0]
    assert_equal [0,0,200,100],@delivered.first[2][:media_box]
    assert_equal 'fictional-source',@delivered.first[2][:source_pdf_sha256]
    assert_equal 2.0,@delivered.first[2][:page_y_offset]
    assert_same @layer,@delivered.first[2][:layer]
    Importer.release_original_annotation_cache!(@opts[:original_annotation_cache])
    assert_equal 1,@parser.release_count
    assert_empty @opts[:original_annotation_cache]
  end

  def test_borrowed_original_parser_is_not_released_or_reparsed
    with_pipeline { apply('original.pdf') }
    assert_equal 0,@parser.parse_count
    Importer.release_original_annotation_cache!(@opts[:original_annotation_cache])
    assert_equal 0,@parser.release_count
    assert_equal 1,@provider.cleanup_count
  end

  def test_renderer_failure_keeps_actionable_report_and_cleans_up_without_delivery
    @provider.prepare_error = Importer::RepresentationFidelity::ContractError.new('stderr: source renderer failed')
    error = assert_raises(Importer::RepresentationFidelity::ContractError) { with_pipeline { apply } }
    assert_equal 'stderr: source renderer failed',error.message
    assert_empty @delivered
    assert_equal 1,@provider.cleanup_count
    assert_same @provider.report,@stats[:original_annotation_ink].first
    assert_equal 'RENDERER_FAILED',@stats[:original_annotation_ink].first[:composite_status]
    assert_match(/source renderer failed/,@stats[:original_annotation_ink].first[:composite_reason])
  end

  def test_unreadable_optional_original_reports_scope_without_losing_existing_import
    @parser.parse_error = RuntimeError.new('unsupported original object stream')
    with_pipeline { apply }
    assert_empty @delivered
    assert_equal 1,@parser.release_count
    assert_equal 0,@provider.cleanup_count
    report = @stats[:original_annotation_ink].first
    assert_equal 'ORIGINAL_SOURCE_UNPROVEN_EXISTING_IMPORT_UNCHANGED',report[:composite_status]
    assert_match(/unsupported original object stream/,report[:composite_reason])
  end
end
