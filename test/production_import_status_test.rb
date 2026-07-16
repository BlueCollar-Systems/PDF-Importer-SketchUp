#!/usr/bin/env ruby

require 'minitest/autorun'

REPO_ROOT = File.expand_path('..', __dir__)
SRC_ROOT = File.join(REPO_ROOT, 'extracted', 'sketchup_ext')
$LOAD_PATH.unshift(SRC_ROOT)

module Sketchup
  class Importer
    ImportCanceled = 0
    ImportFail = 1
    ImportSuccess = 2
  end

  class << self
    attr_accessor :test_active_model

    def active_model
      @test_active_model
    end
  end
end

require 'bc_pdf_vector_importer/main'

class ProductionImportStatusTest < Minitest::Test
  IMP = BlueCollarSystems::PDFVectorImporter
  ImporterClass = IMP::PDFFileImporter

  def test_file_importer_returns_failure_when_required_report_publication_failed
    original_gate = IMP.method(:handle_open_gate)
    original_pipeline = IMP.method(:run_pipeline)
    original_dialog = IMP::ImportDialog.method(:show)
    Sketchup.test_active_model = Object.new

    IMP.define_singleton_method(:handle_open_gate) do |_path|
      nil
    end
    IMP::ImportDialog.define_singleton_method(:show) do |_path|
      { import_text: true, text_mode: :labels }
    end
    IMP.define_singleton_method(:run_pipeline) do |_model, _path, _opts|
      {
        pages: 1,
        import_contract_ready: false,
        import_report_failure: {
          stage: :publication, reason: 'write_json_returned_nil'
        }
      }
    end

    begin
      status = ImporterClass.new.load_file('x.pdf', nil)
      assert_equal Sketchup::Importer::ImportFail, status
    ensure
      IMP.define_singleton_method(:handle_open_gate, original_gate)
      IMP.define_singleton_method(:run_pipeline, original_pipeline)
      IMP::ImportDialog.define_singleton_method(:show, original_dialog)
      Sketchup.test_active_model = nil
    end
  end

  def test_pipeline_success_requires_exact_published_status_and_report_path
    base = {
      pages: 1,
      import_contract_ready: true,
      import_report_publication_status: :published,
      import_report_path: 'x_import_report.json'
    }
    assert_equal true, IMP.pipeline_result_success?(base)

    [nil, :pending, :failed, :unknown].each do |status|
      stats = base.dup
      stats[:import_report_publication_status] = status
      assert_equal false, IMP.pipeline_result_success?(stats), status.inspect
    end

    stats = base.dup
    stats.delete(:import_report_path)
    assert_equal false, IMP.pipeline_result_success?(stats)
  end

  def test_live_batch_seam_uses_real_auto_config_and_native_3d_text
    source = File.read(File.join(REPO_ROOT, 'tools', 'sketchup_batch_import.rb'))
    refute_includes source, 'ImportConfig.auto'
    assert_includes source, "ImportConfig.from_mode('Auto')"
    assert_match(/opts\[:text_mode\]\s*=\s*:text3d/, source)
    assert_includes source, 'pipeline_result_success?'
  end

  def test_native_3d_text_disables_pre_attempt_page_raster_heuristics
    [:text3d, 'text3d', '3d_text'].each do |mode|
      assert_equal false, IMP.page_raster_heuristics_allowed?(mode), mode
    end
    [:labels, :geometry, nil].each do |mode|
      assert_equal true, IMP.page_raster_heuristics_allowed?(mode), mode.inspect
    end

    source = File.read(File.join(SRC_ROOT, 'bc_pdf_vector_importer', 'main.rb'))
    assert_operator source.scan('page_raster_heuristics_allowed?(').length, :>=, 3,
                    'the production helper and both page-raster heuristic gates must use the invariant'
  end
end
