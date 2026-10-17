require 'minitest/autorun'
$LOAD_PATH.unshift(File.expand_path('../extracted/sketchup_ext', __dir__))
require 'json'
require 'bc_pdf_vector_importer/pdf_parser'
require 'bc_pdf_vector_importer/svg_item_representation_renderer'

class SourceFillOnlyPaintTest < Minitest::Test
  Q = BlueCollarSystems::PDFVectorImporter::SourceFillOnlyPaint
  Parser = BlueCollarSystems::PDFVectorImporter::PDFParser
  FONT = [{ :resource=>'/F1', :subtype=>'/Type1' }].freeze
  STREAM = 'BT /F1 16 Tf (ABO) Tj ET'.freeze
  SVG = '<svg><defs><g id="glyph-0-0"><path d="M 0 0 L 2 0 L 2 2 Z"/></g></defs><g fill="black"><use xlink:href="#glyph-0-0" x="1" y="2"/></g></svg>'.freeze
  SHA = '1'*64

  def proof(stream=STREAM,svg=SVG,fonts=FONT,annotations=false)
    Q.prepare([stream],fonts,annotations,svg,SHA,1)
  end

  def test_missing_or_malformed_original_evidence_preserves_policy
    [nil,[],[nil]].each { |streams| assert_equal Q::PRESERVED,Q.prepare(streams,FONT,false,SVG,SHA,1)[:status] }
    [nil,[],[{:resource=>'/F1',:subtype=>'/Type3'}]].each { |fonts| assert_equal Q::PRESERVED,proof(STREAM,SVG,fonts)[:status] }
    [nil,true].each { |annotations| assert_equal Q::PRESERVED,proof(STREAM,SVG,FONT,annotations)[:status] }
  end

  def test_stroke_unknown_forms_graphics_state_and_malformed_operators_protect_source
    [STREAM.sub('(ABO)','2 Tr (ABO)'),STREAM.sub('(ABO)','1 Tr (ABO)'),STREAM.sub('(ABO)','3 Tr (ABO)'),
      '/Fm1 Do '+STREAM,'/GS1 gs '+STREAM,'BI /W 1 ID xxx EI '+STREAM,
      STREAM.sub(' ET',' mystery ET'),STREAM.sub('(ABO)','1.5 Tr (ABO)'),
      STREAM.sub('(ABO)','(broken'),STREAM+' Q',STREAM.sub(' ET',''),
      STREAM.sub('16 Tf','16 20 Tf')].each do |stream|
      assert_equal Q::PRESERVED,proof(stream)[:status],stream
    end
  end

  def test_array_quote_and_q_restore_are_explicit_not_ignored
    ["BT /F1 16 Tf [(A[) 12 (B])] TJ ET", "BT /F1 16 Tf (ABO) ' ET",
      'BT /F1 16 Tf 1 2 (ABO) " ET',
      'q BT /F1 16 Tf 2 Tr ET Q '+STREAM].each do |stream|
      assert_equal Q::QUALIFIED,proof(stream)[:status],proof(stream).inspect
    end
    assert_equal Q::PRESERVED,proof('BT /F1 16 Tf 2 Tr ET BT (ABO) Tj ET')[:status]
  end

  def test_actual_open_page_path_is_not_hidden_or_misidentified_as_text_stroke
    assert_equal Q::QUALIFIED,proof('2 w 0 0 m 10 5 l S '+STREAM)[:status]
  end

  def test_svg_stroked_use_definition_and_fill_or_opacity_uncertainty_protect_all_instances
    [SVG.sub('<use ','<use stroke="black" stroke-width="3" '),
      SVG.sub('Z"/>','Z" stroke="black" stroke-width="20"/>'),
      SVG.sub('<path ','<path fill="none" '),
      SVG.sub('<g fill="black">','<g fill="url(#unknown)">'),
      SVG.sub('<g fill="black">','<g fill="black" opacity="0.5">'),
      SVG.sub('<use ','<use visibility="hidden" '),
      SVG.sub('<defs>','<style>use{stroke:black}</style><defs>'),
      SVG.sub('</defs>','<g id="glyph-0-0"><path d="M 0 0 L 1 1"/></g></defs>')].each do |svg|
      assert_equal Q::PRESERVED,proof(STREAM,svg)[:status],svg
    end
  end

  def test_binding_mutation_cannot_reuse_qualified_proof
    row=proof
    assert Q.qualified?(row,SHA,1,Digest::SHA256.hexdigest(SVG))
    refute Q.qualified?(row,'2'*64,1,Digest::SHA256.hexdigest(SVG))
    refute Q.qualified?(row,SHA,2,Digest::SHA256.hexdigest(SVG))
    refute Q.qualified?(row,SHA,1,'3'*64)
    assert_raises(RuntimeError) { row[:svg]=nil }
    refute Q.qualified?(row.merge(:svg=>nil),SHA,1,Digest::SHA256.hexdigest(SVG))
  end

  def test_binary_and_utf8_encoded_streams_preserve_identical_qualification
    stream="BT /F1 16 Tf (caf\xC3\xA9) Tj ET".force_encoding(Encoding::UTF_8)
    assert_equal Q::QUALIFIED,proof(stream)[:status]
    assert_equal proof(stream)[:proof_sha256],proof(stream.dup.force_encoding(Encoding::BINARY))[:proof_sha256]
  end

  def test_dense_stream_work_and_allocation_are_linear_and_finitely_bounded
    metrics=[]
    [20000,80000].each do |count|
      stream='BT /F1 16 Tf '+('(A) Tj '*count)+' ET'
      GC.start
      allocated=GC.stat[:total_allocated_objects]
      start=Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result=proof(stream)
      seconds=Process.clock_gettime(Process::CLOCK_MONOTONIC)-start
      allocation=GC.stat[:total_allocated_objects]-allocated
      assert_equal Q::QUALIFIED,result[:status]
      assert_equal count,result[:original][:text_show_count]
      assert_operator seconds,:<,15.0
      assert_operator allocation,:<,4000000
      metrics << {:shows=>count,:bytes=>stream.bytesize,:seconds=>seconds,:allocated_objects=>allocation}
    end
    assert_operator metrics[1][:allocated_objects].to_f/metrics[0][:allocated_objects],:<,5.2
    # Dense-stream metrics are assertions only; CI does not write source fixtures.

  end

  def test_total_page_budget_is_not_reset_for_each_small_stream
    result=Q.prepare(Array.new(4) { 'BT /F1 16 Tf '+('(A) Tj '*32000)+' ET' },FONT,false,SVG,SHA,1)
    assert_equal Q::PRESERVED,result[:status]
    assert_equal 'page token bound',result[:reason]
  end

  def test_unexpected_inspection_error_preserves_policy_instead_of_fallback
    renderer=BlueCollarSystems::PDFVectorImporter::SvgTextRenderer
    old=renderer.method(:svg_tag_attribute_map)
    renderer.define_singleton_method(:svg_tag_attribute_map) { |_tag| raise 'authored unexpected inspection failure' }
    row=proof
    assert_equal Q::PRESERVED,row[:status]
    assert_equal 'source_paint_inspection_failed',row[:reason]
  ensure
    renderer.define_singleton_method(:svg_tag_attribute_map) { |tag| old.call(tag) } if old
  end
end
