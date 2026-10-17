require 'minitest/autorun'
$LOAD_PATH.unshift(File.expand_path('../extracted/sketchup_ext', __dir__))
require 'bc_pdf_vector_importer/main'

class SourceFillOnlyPaintPipelineTest < Minitest::Test
  I=BlueCollarSystems::PDFVectorImporter
  SVG='<svg><defs><g id="glyph-0-0"><path d="M 0 0 L 2 0 L 2 2 Z"/></g></defs><use href="#glyph-0-0"/></svg>'.freeze
  STREAM='BT /F1 16 Tf (ABO) Tj ET'.freeze
  class Parser
    attr_reader :parse_count,:page_reads,:release_count
    attr_accessor :parse_error,:original_stream
    def initialize
      @parse_count=@page_reads=@release_count=0
      @original_stream=STREAM
    end
    def parse;@parse_count+=1;raise @parse_error if @parse_error;end
    def release;@release_count+=1;end
    def page_data(_page)
      @page_reads+=1
      {:source_content_streams=>[@original_stream],:content_streams=>[STREAM]}
    end
    def page_font_glyph_code_status(_page);[{:resource=>'/F1',:subtype=>'/Type1'}];end
    def page_has_annotations?(_page);false;end
    def page_annotation_entries(_page);[];end
  end
  Builder=Struct.new(:page_group)
  def setup
    @parser=Parser.new
    @raw={:source_content_streams=>[STREAM],:content_streams=>[STREAM]}
    @opts={:source_fill_only_paint_cache=>{},:source_fill_only_original_context=>{
      :source_path=>'original.pdf',:prepared_path=>'original.pdf',:parser=>@parser,:raw=>@raw}}
    @stats={};@document={:svg=>SVG};@hash_calls=0
  end
  def with_digest
    I.stub(:cached_source_pdf_sha256!,lambda { |_opts,_path|@hash_calls+=1;'1'*64 }) { yield }
  end
  def prepare;I.source_fill_only_paint_for_page!(@stats,@opts,1,@document);end

  def test_many_spans_reuse_one_immutable_compact_page_proof_and_borrow_existing_page
    values=nil
    with_digest { values=Array.new(100) {prepare} }
    assert values.all? { |value| value.equal?(values.first) }
    assert values.first[:proof].frozen?
    assert_equal I::SourceFillOnlyPaint::QUALIFIED,values.first[:proof][:status]
    assert_equal 1,values.first[:proof][:original][:text_show_count]
    refute values.first[:proof][:original].key?(:text_shows)
    assert_equal 1,@stats[:source_fill_only_paint_pages].length
    assert_equal 1,@hash_calls
    assert_equal 0,@parser.parse_count
    assert_equal 0,@parser.page_reads
    I.release_original_annotation_cache!(@opts[:original_annotation_cache])
    assert_equal 0,@parser.release_count
  end

  def test_original_parser_is_shared_with_annotation_path_and_released_once
    original=Parser.new
    @opts[:source_fill_only_original_context][:prepared_path]='prepared.pdf'
    I::PDFParser.stub(:new,original) do
      with_digest do
        prepare
        I.apply_original_annotation_microstrokes!(Builder.new(Object.new),Object.new,@stats,@opts,
          'original.pdf','prepared.pdf',@parser,1,0,nil)
      end
    end
    assert_equal 1,original.parse_count
    assert_equal 1,original.page_reads
    assert_equal 0,@parser.parse_count
    I.release_original_annotation_cache!(@opts[:original_annotation_cache])
    assert_equal 1,original.release_count
  end

  def test_original_unexpanded_stream_protects_form_even_when_prepared_stream_is_fill_only
    @raw[:source_content_streams]=['/OriginalForm Do']
    value=nil;with_digest {value=prepare}
    assert_equal I::SourceFillOnlyPaint::PRESERVED,value[:proof][:status]
    assert_includes value[:proof][:reason],'Do'
    assert_equal 1,@stats[:source_fill_only_paint_pages].length
  end

  def test_unavailable_original_is_cached_as_preservation_without_item_failure
    original=Parser.new;original.parse_error=RuntimeError.new('authored unsupported original')
    @opts[:source_fill_only_original_context][:prepared_path]='prepared.pdf'
    values=nil
    I::PDFParser.stub(:new,original) {with_digest {values=Array.new(8) {prepare}}}
    assert values.all? { |value| value.equal?(values.first) }
    assert_equal I::SourceFillOnlyPaint::PRESERVED,values.first[:proof][:status]
    assert_equal 1,original.parse_count
    assert_equal 1,original.release_count
    assert_equal 1,@stats[:source_fill_only_paint_pages].length
  end
end
