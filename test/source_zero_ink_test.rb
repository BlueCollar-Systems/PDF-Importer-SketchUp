require 'minitest/autorun'
require 'tmpdir'
require 'base64'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/logger'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/pdf_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/content_stream_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/text_parser'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/text_source_identity'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/source_zero_ink'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'
require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_run_control'

class SourceZeroInkTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  Z = IMP::SourceZeroInk
  FIXTURES = File.join(File.dirname(__FILE__), 'fixtures', 'source_zero_ink')

  def setup
    # Raw PDFs remain ignored by corpus containment. These bytes were authored
    # by the public fictional recipe; CI needs no FontTools or private corpus.
    @fixture_directory = Dir.mktmpdir('bc-public-zero-ink-')
    receipt = JSON.parse(File.read(File.join(FIXTURES,'CONTROLS.json')))
    receipt['controls'].each do |record|
      name = record.fetch('file')
      raise 'unsafe public fixture name' unless File.basename(name) == name && name =~ /\A[a-z0-9-]+\.pdf\z/i
      bytes = Base64.strict_decode64(record.fetch('pdf_base64'))
      raise 'changed public fixture bytes' unless Digest::SHA256.hexdigest(bytes) == record.fetch('sha256')
      File.binwrite(File.join(@fixture_directory,name),bytes)
    end
  end

  def teardown
    FileUtils.remove_entry(@fixture_directory) if @fixture_directory && File.directory?(@fixture_directory)
  end

  class Point
    attr_accessor :hidden
    def initialize; @hidden = false; @attributes = {}; @valid = true; end
    def typename; 'ConstructionPoint'; end
    def valid?; @valid; end
    def erase!; @valid = false; end
    def hidden?; @hidden; end
    def set_attribute(dict,key,value); @attributes[[dict,key]] = value; end
    def get_attribute(dict,key,default=nil); @attributes.fetch([dict,key],default); end
  end
  class Entities
    attr_reader :points
    def initialize(empty = false); @points = []; @empty = empty; end
    def to_a; @empty ? @points.select(&:valid?) : [:existing_page_geometry] + @points.select(&:valid?); end
    def add_cpoint(position); @points << Point.new; @points.last; end
  end
  class Page
    attr_reader :entities
    def initialize(empty = false); @entities = Entities.new(empty); @attributes = {}; end
    def persistent_id; 100; end
    def typename; 'Group'; end
    def delete_attribute(dict,key); @attributes.delete([dict,key]); end
    def set_attribute(dict, key, value); @attributes[[dict, key]] = value; end
    def get_attribute(dict, key, default = nil); @attributes.fetch([dict, key], default); end
  end
  class Model < Page
    def initialize(page); super(); @page=page; end
    def active_entities; self; end
    def to_a; [@page]; end
  end

  def source(name = 'empty-space-over-neighboring-ink.pdf')
    path = File.join(@fixture_directory, name)
    parser = IMP::PDFParser.new(path); parser.parse
    page = parser.page_data(1)
    items = IMP::TextParser.new(page[:content_streams], parser.page_font_maps(1),
      :strict_text_fidelity => true, :merge_text_runs => false).parse
    IMP::TextSourceIdentity.assign!(items, 1)
    item = items.find { |entry| entry.text == '    ' }
    refute_nil item
    item.bbox_x0 = 72.0; item.bbox_y0 = 144.0
    item.bbox_x1 = 112.0; item.bbox_y1 = 164.0
    [parser, page[:content_streams], item, Digest::SHA256.file(path).hexdigest]
  end

  def proof
    parser, streams, item, sha = source
    value = Z.qualify(parser, streams, item, 1, sha)
    refute_nil value, 'original embedded empty GID must qualify'
    value
  end

  def ledger(empty = false)
    page = Page.new(empty)
    records = Z.persist!(page, [proof], :text3d,
      :media_box => [0, 0, 288, 216], :scale => 1.0,
      :page_rotation => 0, :y_offset => 0.0)
    [page, records]
  end

  def reseal(value)
    value['proof_sha256'] = Z.digest(value.reject { |key, _| key == 'proof_sha256' })
    value
  end

  def test_original_raw_code_gid_program_and_every_character_are_bound
    value = proof
    assert Z.verify_proof!(value)
    assert_equal 4, value['source_character_count']
    assert_equal [32,32,32,32], value['source_character_layout'].map { |row| row['raw_code'] }
    assert_equal [1,1,1,1], value['source_character_layout'].map { |row| row['glyph_id'] }
    assert value['source_character_layout'].all? { |row| row['glyph_byte_range'][0] == row['glyph_byte_range'][1] }
    assert_equal [[72.0,144.0], [82.0,144.0], [92.0,144.0], [102.0,144.0]], value['source_character_layout'].map { |row| row['source_origin'] }
    assert_equal 40.0, value['run_advance']
    assert_match(/\A[0-9a-f]{64}\z/, value['source_font_program_sha256'])
    assert_equal 32, value['source_font_descriptor_flags']
    assert_equal '6 0 R', value['source_font_descriptor_reference']
    assert_equal '7 0 R', value['source_font_program_reference']
  end

  def test_unicode_space_with_visible_original_glyph_does_not_qualify
    parser, streams, item, sha = source('visible-space-must-retain-ink.pdf')
    assert_equal '    ', item.text
    assert_nil Z.qualify(parser, streams, item, 1, sha)
  end

  def test_source_metadata_is_missing_not_positive_zero_ink_evidence
    parser, streams, item, sha = source
    [:source_code_tokens, :source_text_matrix, :source_text_state, :source_paint_order].each do |field|
      clone = item.dup; clone.send("#{field}=", nil)
      assert_nil Z.qualify(parser, streams, clone, 1, sha), field.to_s
    end
    clone = item.dup; clone.source_decode_complete = false
    assert_nil Z.qualify(parser, streams, clone, 1, sha)
    clone = item.dup; clone.text = '   A'
    assert_nil Z.qualify(parser, streams, clone, 1, sha)
  end

  def test_neighboring_page_ink_never_creates_a_raster_or_fallback_claim
    page, records = ledger
    assert_empty page.entities.points
    record = records.first
    assert_equal 'verified_zero_ink', record['status']
    assert_equal [], record['resulting_entity_ids']
    assert_equal 0, record['native_visible_entities_created']
    assert_equal 'text3d', record['requested_mode']
    assert_equal records, Z.verify_page!(page, records)
  end

  def test_blank_only_page_has_one_hidden_nonpainting_durable_carrier
    page, records = ledger(true)
    assert_equal 1, page.entities.points.length
    assert page.entities.points.first.hidden?
    assert_equal records, Z.verify_page!(page)
    # Simulate serialization onto a newly read owner with the same stable ID.
    reopened = Page.new(true)
    carrier = reopened.entities.add_cpoint([0,0,0])
    carrier.hidden = true
    carrier.set_attribute(Z::DICTIONARY,'page_carrier',true)
    reopened.set_attribute(Z::DICTIONARY, 'ledger_json', page.get_attribute(Z::DICTIONARY, 'ledger_json'))
    reopened.set_attribute(Z::DICTIONARY, 'ledger_sha256', page.get_attribute(Z::DICTIONARY, 'ledger_sha256'))
    assert_equal records, Z.verify_page!(reopened, records)
    # This unit simulation does not establish real SketchUp save persistence.
  end

  def test_missing_duplicate_or_tampered_page_ledger_rejects
    page, records = ledger
    assert_raises(Z::Unavailable) { Z.persist!(page, [proof], :text3d,
      :media_box => [0,0,288,216], :scale => 1.0, :page_rotation => 0, :y_offset => 0.0) }
    page.set_attribute(Z::DICTIONARY, 'ledger_sha256', '0'*64)
    assert_raises(Z::Unavailable) { Z.verify_page!(page) }
    assert_raises(Z::Unavailable) { Z.verify_page!(Page.new) }
  end

  def test_delivery_rejects_changed_pdf_mode_page_owner_and_fake_physical_claim
    page, records = ledger
    record = records.first
    assert_raises(Z::Unavailable) { Z.verify_delivery!(record, '0'*64, :text3d, 1) }
    assert_raises(Z::Unavailable) { Z.verify_delivery!(record, nil, :glyphs, 1) }
    assert_raises(Z::Unavailable) { Z.verify_delivery!(record, nil, :text3d, 2) }
    ['native_visible_entities_created', 'resulting_entity_ids', 'page_owner_id'].each do |field|
      changed = Marshal.load(Marshal.dump(record))
      changed[field] = { 'native_visible_entities_created' => 1, 'resulting_entity_ids' => ['persistent_id:1'], 'page_owner_id' => 'persistent_id:0' }[field]
      changed['delivery_sha256'] = Z.digest(changed.reject { |key, _| key == 'delivery_sha256' })
      assert_raises(Z::Unavailable) { Z.verify_delivery!(changed) }
    end
  end

  def test_proof_rejects_truncated_duplicate_untyped_relocated_or_visible_glyph_evidence
    value = proof
    mutations = [
      proc { |p| p['source_character_layout'].pop },
      proc { |p| p['source_character_layout'][1]['index'] = 0 },
      proc { |p| p['source_character_layout'][0]['glyph_id'] = '1' },
      proc { |p| p['source_character_layout'][0]['glyph_byte_range'][1] += 1 },
      proc { |p| p['source_character_layout'][0]['source_origin'][0] += 1 },
      proc { |p| p['source_character_layout'][0]['advance'] += 1 },
      proc { |p| p['source_code_tokens'][0]['raw_hex'] = '20' },
      proc { |p| p['source_text'] = '   A' },
      proc { |p| p['source_span_id'] = 'text_span:2:0' },
      proc { |p| p['source_text_state']['font_size'] = '20' },
      proc { |p| p['source_font_descriptor_flags'] = 36 },
      proc { |p| p['source_font_program_reference'] = 'absent' },
      proc { |p| p['source_character_layout'][0]['raw_code'] = 128 },
      proc { |p| p['source_font_program_sha256'] = 'missing' }
    ]
    mutations.each do |mutate|
      changed = Marshal.load(Marshal.dump(value)); mutate.call(changed)
      assert_raises(Z::Unavailable) { Z.verify_proof!(reseal(changed)) }
    end
  end

  def test_text_state_and_tj_adjustments_are_retained_without_changing_semantics
    parser, streams, item, sha = source
    state = IMP::TextParser.new(['BT /F1 20 Tf 2 Tc 3 Tw 50 Tz 4 Ts 1 0 0 1 72 144 Tm [<20> -100 <202020>] TJ ET'], parser.page_font_maps(1), :strict_text_fidelity => true, :merge_text_runs => false).parse.first
    assert_equal '    ', state.text
    assert_equal [{:raw_hex=>'20'}, {:adjustment=>-100.0}, {:raw_hex=>'202020'}], state.source_code_tokens
    assert_equal 0.5, state.source_text_state[:horizontal_scale]
    assert_equal 4.0, state.source_text_state[:rise]
    scope = IMP::PdfColorSpace::ResourceScope.of(streams[0])
    adjusted_stream = 'BT /F1 20 Tf 2 Tc 3 Tw 50 Tz 4 Ts 1 0 0 1 72 144 Tm [<20> -100 <202020>] TJ ET'
    IMP::PdfColorSpace::ResourceScope.attach(adjusted_stream, scope)
    IMP::TextSourceIdentity.assign!([state],1)
    state.bbox_x0=72; state.bbox_y0=144; state.bbox_x1=112; state.bbox_y1=164
    adjusted = Z.qualify(parser, [adjusted_stream], state, 1, sha)
    refute_nil adjusted
    assert Z.verify_proof!(adjusted)
    assert_equal [[72.0,148.0],[80.5,148.0],[88.0,148.0],[95.5,148.0]], adjusted['source_character_layout'].map { |row| row['source_origin'] }
    assert_equal 31.0, adjusted['run_advance']
  end

  def test_blank_only_public_pdf_contains_only_one_empty_original_source_run
    parser, streams, item, sha = source('blank-only-page.pdf')
    value = Z.qualify(parser, streams, item, 1, sha)
    refute_nil value
    assert_equal 4, value['source_character_count']
    assert_equal 1, IMP::TextParser.new(streams, parser.page_font_maps(1),
      :strict_text_fidelity => true, :merge_text_runs => false).parse.length
  end

  def test_original_code_09_not_unicode_20_authenticates_mac_and_symbol_gid
    parser, streams, item, sha = source('raw-code-09-space.pdf')
    value = Z.qualify(parser, streams, item, 1, sha)
    refute_nil value
    assert_nil value['source_font_encoding']
    assert_equal 4, value['source_font_descriptor_flags']
    assert_equal [9,9,9,9], value['source_character_layout'].map { |row| row['raw_code'] }
    assert_equal [[1,0,6],[3,0,4]], value['source_character_layout'].first['cmap_routes']
    assert_equal [1,1,1,1], value['source_character_layout'].map { |row| row['glyph_id'] }
  end

  def original_program(parser)
    font = IMP::PdfColorSpace::Objects.new(parser).dict('5 0 R')
    Z::TrueTypeProgram.new(parser.embedded_font_program(font))
  end

  def test_symbolic_mapping_requires_original_flags_and_rejects_nonsymbolic_conflicts
    ['nonsymbolic-conflicting-cmap.pdf', 'conflicting-font-flags.pdf', 'missing-font-flags.pdf'].each do |name|
      parser, streams, item, sha = source(name)
      assert_equal '    ', item.text, name
      assert_nil Z.qualify(parser, streams, item, 1, sha), name
    end
    parser, streams, item, sha = source('nonsymbolic-conflicting-cmap.pdf')
    program = original_program(parser)
    unicode = program.instance_variable_get(:@cmaps).find { |table| table[:platform] == 3 && table[:encoding] == 1 }
    refute_nil unicode
    visible_gid = program.cmap_gid(unicode, 9)
    assert_equal 2, visible_gid
    assert_nil program.empty_range(visible_gid), 'the conflicting Unicode glyph actually has original ink'
    assert_raises(Z::Unavailable) { program.glyph_for_code(9, nil, 32) }
  end

  def test_winansi_byte_80_cannot_be_unicode_80_instead_of_visible_euro
    parser, streams, item, sha = source('winansi-visible-euro-tounicode-space.pdf')
    assert_equal [{:raw_hex=>'80808080'}], item.source_code_tokens
    assert_equal '    ', item.text
    program = original_program(parser)
    unicode = program.instance_variable_get(:@cmaps).find { |table| table[:platform] == 3 && table[:encoding] == 1 }
    refute_nil unicode
    assert_equal 1, program.cmap_gid(unicode, 128), 'adversarial wrong raw-as-Unicode lookup selects empty space'
    visible_gid = program.cmap_gid(unicode, 0x20ac)
    assert_equal 3, visible_gid
    assert_nil program.empty_range(visible_gid), 'authentic WinAnsi /Euro owns real original ink'
    assert_nil Z.qualify(parser, streams, item, 1, sha)
    assert_raises(Z::Unavailable) { program.glyph_for_code(128, '/WinAnsiEncoding', 32) }
  end

  def test_encoding_differences_must_not_use_the_base_encoding_space_glyph
    parser, streams, item, sha = source('encoding-differences-visible-A.pdf')
    assert_equal '    ', item.text
    program = original_program(parser)
    unicode = program.instance_variable_get(:@cmaps).find { |table| table[:platform] == 3 && table[:encoding] == 1 }
    refute_nil unicode
    assert_nil program.empty_range(program.cmap_gid(unicode, 65)), 'the overridden /A glyph owns ink'
    assert_nil Z.qualify(parser, streams, item, 1, sha)
  end

  def test_symbolic_flag_overrides_named_winansi_and_mixed_symbol_prefix_is_unavailable
    parser, streams, item, sha = source('symbolic-named-winansi-visible-A.pdf')
    program = original_program(parser)
    gid, routes = program.glyph_for_code(32,nil,4)
    assert_equal 2, gid
    assert_nil program.empty_range(gid), 'actual symbolic /A paints despite empty Unicode space'
    assert_nil Z.qualify(parser, streams, item, 1, sha)
    assert_raises(Z::Unavailable) { program.glyph_for_code(32,'/WinAnsiEncoding',4) }
    parser, streams, item, sha = source('ambiguous-symbol-prefixes.pdf')
    assert_nil Z.qualify(parser, streams, item, 1, sha)
    assert_raises(Z::Unavailable) { original_program(parser).glyph_for_code(9,nil,4) }
  end

  def test_truncated_invalid_head_and_nonmonotonic_original_loca_cannot_certify
    parser, streams, item, sha = source
    font = IMP::PdfColorSpace::Objects.new(parser).dict('5 0 R')
    bytes = parser.embedded_font_program(font)
    program = Z::TrueTypeProgram.new(bytes)
    tables = program.instance_variable_get(:@tables)
    broken = bytes.dup
    broken[tables['head'][0] + 12, 4] = [0].pack('N')
    assert_raises(Z::Unavailable) { Z::TrueTypeProgram.new(broken) }
    broken = bytes.dup
    at = tables['loca'][0]
    if program.instance_variable_get(:@loca_format) == 0
      broken[at,4] = [10,0].pack('nn')
    else
      broken[at,8] = [10,0].pack('NN')
    end
    assert_raises(Z::Unavailable) { Z::TrueTypeProgram.new(broken) }
    assert_raises(Z::Unavailable) { Z::TrueTypeProgram.new(bytes[0, bytes.length-1]) }
    broken = bytes.dup
    broken[tables['hhea'][0] + 34,2] = [0].pack('n')
    assert_raises(Z::Unavailable) { Z::TrueTypeProgram.new(broken) }
  end

  def zero_stats(records)
    record = records.first
    { :pages => 1, :selected_pages => [1], :requested_text_mode => :text3d,
      :text_mode => :text3d, :text => 0,
      :source_input_sha256 => record['source_proof']['source_pdf_sha256'],
      :normalized_input_sha256 => record['source_proof']['source_pdf_sha256'],
      :text_source_span_ids => [record['source_span_id']], :text_attempts => [],
      :zero_ink_text_deliveries => records,
      :source_provenance_objects => [{ :object_id => record['source_span_id'],
        :span_id => record['source_span_id'], :page => 1,
        :source_kind => 'zero_ink_text_span', :created_entity_type => 'source_zero_ink',
        :renderer => 'original_truetype_zero_ink', :resulting_entity_ids => [],
        :zero_ink_delivery => record }] }
  end

  def test_blank_only_readiness_and_accounting_require_the_complete_zero_ink_ledger
    page, records = ledger(true)
    stats = zero_stats(records)
    fidelity = IMP::QAReport.validate_representation_fidelity(stats)
    assert fidelity[:ready], fidelity[:errors].inspect
    counts = IMP::QAReport.text_delivery_accounting(stats)
    assert_equal 1, counts[:source_count]
    assert_equal 1, counts[:delivered_count]
    assert_equal 1, counts[:verified_zero_ink_count]
    assert_equal 0, counts[:unaccounted_count]
    assert_equal({}, IMP::QAReport.delivered_text_entity_counts(stats))
    assert stats[:text].zero?, 'zero-ink semantic spans are not physical text groups'
    report={:report_meta=>{:build_stamp=>'public-control'},:result=>{:text_entities=>0},
      :extra=>{:scale_crosscheck=>{},:representation_fidelity=>fidelity}}
    assert IMP::QAReport.build_import_contract_ready(report)[:ready]
    [:zero_ink_text_deliveries, :source_provenance_objects].each do |field|
      changed = Marshal.load(Marshal.dump(stats)); changed[field] = []
      refute IMP::QAReport.validate_representation_fidelity(changed)[:ready]
    end
  end

  def test_zero_ink_cannot_cover_wrong_source_page_mode_or_duplicate_provenance
    page, records = ledger
    stats = zero_stats(records)
    mutations = [
      proc { |s| s[:selected_pages] = [2] },
      proc { |s| s[:source_input_sha256] = '0'*64 },
      proc { |s| s[:normalized_input_sha256] = '0'*64 },
      proc { |s| s[:requested_text_mode] = :glyphs },
      proc { |s| s[:source_provenance_objects][0][:page] = 2 },
      proc { |s| s[:zero_ink_text_deliveries] *= 2 },
      proc { |s| s[:source_provenance_objects] *= 2 },
      proc { |s| s[:text_source_span_ids] = [] }
    ]
    mutations.each do |mutate|
      changed = Marshal.load(Marshal.dump(stats)); mutate.call(changed)
      refute IMP::QAReport.validate_representation_fidelity(changed)[:ready]
    end
  end

  def test_changed_original_raw_operand_metadata_cannot_qualify
    parser, streams, item, sha = source
    changed = item.dup; changed.source_code_tokens = [{ :raw_hex => '202020' }]
    assert_nil Z.qualify(parser, streams, changed, 1, sha)
    changed = item.dup; changed.source_show_operand = '<20202020>'
    assert_nil Z.qualify(parser, streams, changed, 1, sha)
    changed = item.dup; changed.source_paint_order = [0, 0]
    assert_nil Z.qualify(parser, streams, changed, 1, sha)
  end

  def test_empty_proof_batch_or_non_group_owner_cannot_succeed
    assert_raises(Z::Unavailable) { Z.persist!(Page.new, [], :text3d, {}) }
    other = Page.new
    def other.typename; 'ComponentInstance'; end
    assert_raises(Z::Unavailable) { Z.persist!(other, [proof], :text3d,
      :media_box=>[0,0,288,216], :scale=>1.0, :page_rotation=>0, :y_offset=>0.0) }
  end

  def test_partial_ledger_write_erases_only_the_new_hidden_carrier
    page = Page.new(true)
    original_set = page.method(:set_attribute)
    page.define_singleton_method(:set_attribute) do |dict,key,value|
      raise 'injected ledger write failure' if key == 'ledger_sha256'
      original_set.call(dict,key,value)
    end
    assert_raises(RuntimeError) { Z.persist!(page, [proof], :text3d,
      :media_box=>[0,0,288,216], :scale=>1.0, :page_rotation=>0, :y_offset=>0.0) }
    assert_nil page.get_attribute(Z::DICTIONARY, 'ledger_json')
    assert_nil page.get_attribute(Z::DICTIONARY, 'ledger_sha256')
    assert_empty page.entities.to_a
  end

  def resume_controller(model, pdf_sha)
    IMP::ImportRunControl::Controller.new(:model=>model, :pages=>[1,2],
      :requested_mode=>:text3d, :clock=>lambda { 0.0 },
      :identity=>{:pdf_sha256=>pdf_sha, :options_sha256=>'b'*64,
        :importer_sha256=>'c'*64, :package_sha256=>'d'*64, :source_tree_sha256=>'e'*64})
  end

  def test_durable_resume_roundtrip_keeps_typed_zero_ink_delivery_and_provenance_crosslink
    page, records = ledger(true)
    model = Model.new(page)
    stats = zero_stats(records)
    sha = stats[:source_input_sha256]
    visible = {:source_kind=>'text_span', :object_id=>'visible-unrelated-tree'}
    stats[:source_provenance_objects] << visible
    first = resume_controller(model,sha)
    first.certify_page!(page,1,:stats=>stats)
    reopened = resume_controller(model,sha)
    assert_equal [1], reopened.resumable_pages
    saved = reopened.journal['pages'].first['stats']
    assert_equal Z.canonical(records), saved['zero_ink_text_deliveries']
    assert_equal 1, saved['source_provenance_objects'].length
    assert_equal 'zero_ink_text_span', saved['source_provenance_objects'].first['source_kind']
    # Use the persisted JSON to check accounting; no physical glyph is fabricated.
    roundtrip = {}; saved.each { |key,value| roundtrip[key.to_sym]=value }
    assert IMP::QAReport.validate_representation_fidelity(roundtrip)[:ready]
    assert_equal 0, roundtrip[:text]
  end

  def test_resume_rejects_edited_zero_ink_ledger_hash_or_hidden_carrier
    [:ledger_json,:ledger_sha256,:page_carrier,:hidden].each do |mutation|
      page, records = ledger(true)
      sha = records.first['source_proof']['source_pdf_sha256']
      model = Model.new(page)
      resume_controller(model,sha).certify_page!(page,1,:stats=>zero_stats(records))
      case mutation
      when :ledger_json then page.set_attribute(Z::DICTIONARY,'ledger_json','[]')
      when :ledger_sha256 then page.set_attribute(Z::DICTIONARY,'ledger_sha256','0'*64)
      when :page_carrier then page.entities.points.first.set_attribute(Z::DICTIONARY,'page_carrier',false)
      when :hidden then page.entities.points.first.hidden=false
      end
      assert_raises(IMP::ImportRunControl::ResumeMismatch,mutation.to_s) do
        resume_controller(model,sha).resumable_pages
      end
    end
  end
end
