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

class VectorDeliveryReasonTest < Minitest::Test
  I=BlueCollarSystems::PDFVectorImporter
  REASON='affirmative item-specific requested-representation impossibility'.freeze
  # Metadata recording must never invoke or mutate the supplied native group.
  class NativeGroupMustNotBeTouched
    def method_missing(name,*_args)
      raise "delivery reporting touched native geometry: #{name}"
    end
  end
  def record(requested,delivered)
    item=I::TextParser::TextItem.new
    item.text='AB';item.source_span_id='text_span:1:0'
    item.bbox_x0,item.bbox_y0,item.bbox_x1,item.bbox_y1=1.0,2.0,3.0,4.0
    evidence={:source_text_sha256=>Digest::SHA256.hexdigest(item.text),
      :source_bbox_pdf=>[1.0,2.0,3.0,4.0],:source_anchor=>[1.0,2.0,0.0],
      :source_rotation_radians=>0.0,:expected_width=>2.0/72.0,
      :expected_height=>2.0/72.0,:expected_depth=>0.0}
    native_group=NativeGroupMustNotBeTouched.new
    item_before=Marshal.dump(item)
    result={:group=>native_group,:mode=>delivered,:source_span_id=>item.source_span_id,
      :group_entity_id=>'persistent_id:101',:renderer=>:fictional_vector_metadata_test,
      :physical_entity_ids=>['persistent_id:102'],:expected_evidence=>evidence,
      :edge_count=>4,:face_count=>1,:placement_indices=>[0],:glyph_ids=>['glyph-0-0']}
    [:visual_fidelity_verified,:identity_verified,:placement_verified,:rotation_verified,
      :size_verified,:entity_type_verified,:visibility_verified,:content_verified,
      :physical_geometry_verified,:physical_style_verified,:transform_verified].each { |key|result[key]=true }
    transitions=requested==delivered ? [] : [{:source_span_id=>item.source_span_id,
      :from_mode=>requested,:to_mode=>delivered,:reason_code=>:fixture_affirmative_item_proof}]
    result_before=Marshal.dump(result.reject { |key,_value|key==:group })
    stats={:text=>0,:edges=>0,:faces=>0};history=[]
    assert I.record_item_vector_delivery!(stats,1,item,requested,result,history,transitions)
    assert_equal result_before,Marshal.dump(result.reject { |key,_value|key==:group })
    assert_equal item_before,Marshal.dump(item)
    assert_same native_group,result[:group]
    [stats,history,transitions]
  end

  def test_direct_requested_vector_delivery_does_not_report_impossibility
    [:glyphs,:geometry].each do |mode|
      stats,history,transitions=record(mode,mode)
      row=stats[:text_renderers].last
      assert_equal mode,row[:requested_mode]
      assert_equal mode,row[:delivered_mode]
      assert_equal false,row[:degraded]
      assert_nil row[:reason]
      assert_empty stats[:fallback_transitions]
      assert_empty transitions
      assert_equal :complete,history.last[:outcome]
      assert_equal 1,stats[:text]
      assert_equal 4,stats[:edges]
      assert_equal 1,stats[:faces]
    end
  end

  def test_actual_mode_step_down_keeps_reason_and_transition_ledger
    [[:glyphs,:geometry],[:text3d,:glyphs]].each do |requested,delivered|
      stats,history,transitions=record(requested,delivered)
      row=stats[:text_renderers].last
      assert_equal requested,row[:requested_mode]
      assert_equal delivered,row[:delivered_mode]
      assert_equal true,row[:degraded]
      assert_equal REASON,row[:reason]
      assert_equal [transitions.first.merge(:page=>1)],stats[:fallback_transitions]
      assert_equal delivered,history.last[:mode]
      assert_equal ['persistent_id:101'],row[:resulting_entity_ids]
    end
  end
end
