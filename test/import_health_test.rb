#!/usr/bin/env ruby
# test/import_health_test.rb
# Unit tests for ImportHealth helpers without SketchUp runtime.

require 'minitest/autorun'

module UI
  class << self
    attr_reader :last_message
  end

  def self.messagebox(msg)
    @last_message = msg
    nil
  end
end

require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/import_health'

class ImportHealthTest < Minitest::Test
  H = BlueCollarSystems::PDFVectorImporter::ImportHealth

  def test_short_path_empty
    assert_equal 'n/a', H.short_path('')
    assert_equal 'n/a', H.short_path(nil)
  end

  def test_short_path_unchanged_when_short
    path = 'C:/Projects/drawing.pdf'
    assert path.length <= 72
    assert_equal path, H.short_path(path)
  end

  def test_short_path_unchanged_at_boundary
    path = 'x' * 72
    assert_equal 72, path.length
    assert_equal path, H.short_path(path)
  end

  def test_short_path_truncates_long_paths_with_ruby22_slice
    path = 'C:/very/long/' + ('nested/' * 12) + 'import_report.json'
    assert path.length > 72, 'fixture path should exceed display limit'

    result = H.short_path(path)
    assert result.start_with?('...'), 'expected leading ellipsis'
    assert_equal 72, result.length, '3-char prefix + 69-char tail'
    assert_equal path[-69, 69], result[3..-1], 'tail must use two-arg String#[] (Ruby 2.2 safe)'
  end

  def test_failed_representation_contract_is_preserved_and_shown_loudly
    H.record!({
      pages: 1, edges: 2, text: 0, layers: [],
      import_contract_ready: {
        ready: false,
        errors: ['source_delivery_set_mismatch']
      },
      representation_fidelity: {
        ready: false,
        errors: ['source_delivery_set_mismatch']
      }
    }, 'fixture.pdf')

    assert_equal false, H.snapshot[:import_contract_ready][:ready]
    H.show
    assert_includes UI.last_message, 'QA contract: NOT READY'
    assert_includes UI.last_message, 'source_delivery_set_mismatch'
  end
end

# Import Health displays the actual report summary. A visual-review warning
# stays separate from the native delivery contract and requested text mode.
class ImportHealthTest
  def test_embedded_image_display_warning_actual_report_summary_reaches_import_health
    require_relative '../extracted/sketchup_ext/bc_pdf_vector_importer/qa_report'
    q = BlueCollarSystems::PDFVectorImporter::QAReport
    stats = { :pages=>1,:primitives=>100,:edges=>100,:text=>1,:embedded_images=>1,
      :layers=>['PDF'],:text_mode=>:text3d,:peak_mb=>1.0,:ownership_bookkeeping=>{},
      :result_status=>'success',:requested_pages=>[1],:retained_pages=>[1],
      :embedded_image_paint_order=>[{ :page=>1,:qualified_count=>0,
        :unqualified=>[{ :image_id=>'persistent_id:42',:reason=>'clip is not one four-corner contour' }] }] }
    report = q.build_from_stats('fictional-picture.pdf',{},stats)
    # This fixture declares a separate delivery contract for UI rendering only;
    # it does not claim fictional geometry or image pixels were certified.
    stats[:import_contract_ready] = { :ready=>true }
    stats[:human_summary] = report[:extra][:human_summary]
    H.record!(stats,'fictional-picture.pdf')
    H.show
    assert_includes UI.last_message,'QA contract: READY'
    assert_includes UI.last_message,'Picture clipping or overlap remains unverified for 1 picture on page 1'
    assert_includes UI.last_message,'Content review: review'
    assert_includes UI.last_message,'1 warning recorded'
    refute_includes UI.last_message,'four-corner'
    refute_includes UI.last_message,'persistent_id:'
    assert_equal 'text3d',H.snapshot[:text_mode]
    assert_equal 'success',H.snapshot[:result_status]
  end

  def test_embedded_image_display_warning_older_health_snapshot_without_field_is_graceful
    H.record!({ :pages=>1,:edges=>100,:text=>1,:layers=>[],
      :text_mode=>:text3d,:result_status=>'success',
      :import_contract_ready=>{ :ready=>true },:human_summary=>'Imported the retained page.' },'older.pdf')
    H.show
    assert_includes UI.last_message,'QA contract: READY'
    assert_includes UI.last_message,'Imported the retained page.'
    refute_includes UI.last_message,'Picture clipping or overlap remains unverified'
  end
end
